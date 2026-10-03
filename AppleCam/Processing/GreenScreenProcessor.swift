#if SWIFT_PACKAGE
import AppleCamCore
#endif
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers

/// All use is serialized on FrameProducer.queue. No frame or private image is written to disk.
final class GreenScreenProcessor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let mattePipeline: MTLComputePipelineState
    private let matte: MTLTexture
    private let maskBuffer: CVPixelBuffer
    private var cache: CVMetalTextureCache
    private let context: CIContext
    private let background: CVPixelBuffer
    let width: Int
    let height: Int

    init(background image: CGImage, width: Int = CameraContract.width, height: Int = CameraContract.height) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CameraError.message("Metal is unavailable. Green-screen processing cannot start.")
        }
        self.device = device; commandQueue = queue
        self.width = width; self.height = height
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "keyComposite") else { throw CameraError.message("Cannot load the green-screen shader.") }
        pipeline = try device.makeComputePipelineState(function: function)
        guard let matteFunction = library.makeFunction(name: "keyMatte") else { throw CameraError.message("Cannot load the mask shader.") }
        mattePipeline = try device.makeComputePipelineState(function: matteFunction)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
        guard let matte = device.makeTexture(descriptor: descriptor) else { throw CameraError.message("Cannot allocate the mask texture.") }
        self.matte = matte
        maskBuffer = try Self.makeBuffer(width: width, height: height)
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let cache else { throw CameraError.operation("Create Metal texture cache", result) }
        self.cache = cache
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        background = try Self.makeBuffer(width: width, height: height)
        let source = CIImage(cgImage: image)
        let scale = max(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(translationX: (CGFloat(width) - scaled.extent.width) / 2,
                                                               y: (CGFloat(height) - scaled.extent.height) / 2))
        // Transparent PNG regions are explicitly rejected, never silently replaced.
        context.render(centered, to: background, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        CVPixelBufferLockBaseAddress(background, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(background, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(background)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width where base[y * CVPixelBufferGetBytesPerRow(background) + x * 4 + 3] != 255 {
                throw CameraError.message("This background contains transparency. Choose an opaque PNG or JPEG.")
            }
        }
    }

    static func loadBackground(_ url: URL, maximumDimension: Int = 4096) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type as String),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            throw CameraError.message("Cannot read this background. Choose a PNG or JPEG image.")
        }
        return image
    }

    static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw CameraError.operation("Allocate processing frame", status) }
        return buffer
    }

    private func texture(_ buffer: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw CameraError.message("Green-screen processing received an unsupported frame.")
        }
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapper)
        guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
            throw CameraError.operation("Map processing texture", status)
        }
        return (wrapper, texture)
    }

    /// The returned buffer is a local-only mask. `output` always contains the composite.
    @discardableResult
    func render(_ input: CVPixelBuffer, into output: CVPixelBuffer, settings: KeySettings, maskPreview: Bool = false) throws -> CVPixelBuffer? {
        guard settings.isValid else { throw CameraError.message("Invalid green-screen settings. Pick a green screen colour and try again.") }
        let source = try texture(input), backdrop = try texture(background), destination = try texture(output), mask = try texture(maskBuffer)
        guard let command = commandQueue.makeCommandBuffer(), let first = command.makeComputeCommandEncoder() else {
            throw CameraError.message("Cannot submit green-screen processing.")
        }
        var values: [Float] = [settings.tolerance, settings.softness, settings.spill, settings.protection,
                               settings.fillHoles, Float(settings.colors.count), maskPreview ? 1 : 0]
        for c in settings.colors { values += [c.x, c.y, c.z] }
        first.setComputePipelineState(mattePipeline)
        first.setTexture(source.1, index: 0); first.setTexture(matte, index: 1)
        first.setBytes(&values, length: values.count * MemoryLayout<Float>.size, index: 0)
        dispatch(first, pipeline: mattePipeline); first.endEncoding()
        guard let second = command.makeComputeCommandEncoder() else { throw CameraError.message("Cannot submit compositing.") }
        second.setComputePipelineState(pipeline)
        second.setTexture(source.1, index: 0); second.setTexture(backdrop.1, index: 1)
        second.setTexture(destination.1, index: 2); second.setTexture(matte, index: 3); second.setTexture(mask.1, index: 4)
        second.setBytes(&values, length: values.count * MemoryLayout<Float>.size, index: 0)
        dispatch(second, pipeline: pipeline); second.endEncoding()
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime((source.0, backdrop.0, destination.0, mask.0)) {}
        guard command.status == .completed else { throw command.error ?? CameraError.message("Green-screen processing failed. Camera stopped.") }
        return maskPreview ? maskBuffer : nil
    }
    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) {
        let w = pipeline.threadExecutionWidth, h = min(8, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    /// Screen coordinates are top-left based, matching BGRA pixel-buffer rows.
    static func sample(_ buffer: CVPixelBuffer, x: Double, y: Double) throws -> SIMD3<Float> {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { throw CameraError.message("Click inside the camera image.") }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw CameraError.message("Cannot sample this frame.") }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let px = min(w - 1, Int(x * Double(w))), py = min(h - 1, Int(y * Double(h)))
        var sum = SIMD3<Float>(); var count: Float = 0
        for row in max(0, py - 2)...min(h - 1, py + 2) {
            for column in max(0, px - 2)...min(w - 1, px + 2) {
                let offset = row * CVPixelBufferGetBytesPerRow(buffer) + column * 4
                sum += SIMD3(Float(base[offset + 2]), Float(base[offset + 1]), Float(base[offset])); count += 1
            }
        }
        return sum / (255 * count)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    float3 linearRGB(float3 c) { return select(pow((c + 0.055f) / 1.055f, float3(2.4f)), c / 12.92f, c <= 0.04045f); }
    float3 encodedRGB(float3 c) { return select(1.055f * pow(c, float3(1.0f / 2.4f)) - 0.055f, 12.92f * c, c <= 0.0031308f); }
    float3 closest(float3 c, constant float* p) {
        float3 chroma = c / max(0.001f, c.r + c.g + c.b), selected = float3(p[7], p[8], p[9]);
        float best = INFINITY;
        for (uint i = 0; i < uint(p[5]); ++i) {
            float3 key = float3(p[7+i*3], p[8+i*3], p[9+i*3]);
            float d = distance_squared(chroma, key / (key.r + key.g + key.b));
            if (d < best) { best = d; selected = key; }
        }
        return selected;
    }
    kernel void keyMatte(texture2d<float, access::read> camera [[texture(0)]],
                         texture2d<float, access::write> matte [[texture(1)]],
                         constant float* p [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
        if (pos.x >= matte.get_width() || pos.y >= matte.get_height()) return;
        float3 c = camera.read(pos).rgb, key = closest(c, p);
        float sum = c.r + c.g + c.b, a = 1;
        if (sum >= 0.001f) {
            a = smoothstep(p[0], p[0]+p[1], distance(c / sum, key / (key.r + key.g + key.b)));
            float green = max(0.0f, c.g-max(c.r,c.b)) / sum;
            float neutral = 1-smoothstep(0.015f, 0.10f, green);
            float dark = (1-smoothstep(0.02f, 0.12f, max(c.r,max(c.g,c.b)))) * (1-smoothstep(0.10f,0.30f,green));
            a = max(a, p[3]*max(neutral,dark));
        }
        matte.write(float4(a), pos);
    }
    kernel void keyComposite(texture2d<float, access::read> camera [[texture(0)]],
                             texture2d<float, access::read> background [[texture(1)]],
                             texture2d<float, access::write> output [[texture(2)]],
                             texture2d<float, access::read> matte [[texture(3)]],
                             texture2d<float, access::write> mask [[texture(4)]],
                             constant float* p [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
        if (pos.x >= output.get_width() || pos.y >= output.get_height()) return;
        float3 c = camera.read(pos).rgb, key = closest(c,p);
        float a = matte.read(pos).r;
        if (p[4] > 0 && pos.x >= 2 && pos.y >= 2 && pos.x+2 < output.get_width() && pos.y+2 < output.get_height()) {
            float perimeter = 1;
            for (int y = -2; y <= 2; ++y) for (int x = -2; x <= 2; ++x) {
                if (abs(x) == 2 || abs(y) == 2) perimeter = min(perimeter, matte.read(uint2(int2(pos)+int2(x,y))).r);
            }
            a += (1-a)*p[4]*smoothstep(0.95f,1.0f,perimeter);
        }
        float3 foreground = clamp(linearRGB(c) - (1.0f-a)*linearRGB(key), float3(0), float3(a));
        foreground.g -= p[2]*max(0.0f, foreground.g-max(foreground.r,foreground.b));
        float3 composite = foreground+(1.0f-a)*linearRGB(background.read(pos).rgb);
        output.write(float4(encodedRGB(clamp(composite,0.0f,1.0f)),1),pos);
        if (p[6] > 0) mask.write(float4(float3(a),1),pos);
    }
    """
}
