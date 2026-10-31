#if SWIFT_PACKAGE
import AppleCamCore
#endif
import CoreImage
import Metal

/// Difference key against a background picture. Confined to one serial queue (SceneOutput.queue in the app).
/// Output is premultiplied: the camera colour where it differs from the picture, transparent where it matches.
final class BackgroundMaskProcessor {
    private let commandQueue: MTLCommandQueue
    private let mattePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let matte: MTLTexture
    private let plate: CVPixelBuffer
    private let maskBuffer: CVPixelBuffer
    private let cache: CVMetalTextureCache
    let plateID: UUID
    let width: Int
    let height: Int

    init(plate image: CGImage, id: UUID) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CameraError.message("Metal is unavailable. Background mask processing cannot start.")
        }
        commandQueue = queue; plateID = id
        width = image.width; height = image.height
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let matteFunction = library.makeFunction(name: "differenceMatte"),
              let compositeFunction = library.makeFunction(name: "differenceComposite") else {
            throw CameraError.message("Cannot load the background mask shader.")
        }
        mattePipeline = try device.makeComputePipelineState(function: matteFunction)
        compositePipeline = try device.makeComputePipelineState(function: compositeFunction)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
        guard let matte = device.makeTexture(descriptor: descriptor) else { throw CameraError.message("Cannot allocate the mask texture.") }
        self.matte = matte
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let cache else { throw CameraError.operation("Create Metal texture cache", result) }
        self.cache = cache
        maskBuffer = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        plate = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        // Pixels are copied 1:1 without colour conversion, so they compare exactly with camera frames.
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        context.render(CIImage(cgImage: image, options: [.colorSpace: NSNull()]), to: plate,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
    }

    private func texture(_ buffer: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw CameraError.message("Background mask processing received an unsupported frame.")
        }
        if let mismatch = BackgroundPlate(width: width, height: height)
            .mismatch(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) {
            throw CameraError.message(mismatch)
        }
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapper)
        guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
            throw CameraError.operation("Map processing texture", status)
        }
        return (wrapper, texture)
    }

    /// Returns the local-only mask when `maskPreview` is set. `output` always receives the premultiplied foreground.
    @discardableResult
    func render(_ input: CVPixelBuffer, into output: CVPixelBuffer, settings: DifferenceKeySettings, maskPreview: Bool = false) throws -> CVPixelBuffer? {
        guard settings.isValid else { throw CameraError.message("Invalid background mask settings.") }
        let source = try texture(input), backdrop = try texture(plate), destination = try texture(output), mask = try texture(maskBuffer)
        guard let command = commandQueue.makeCommandBuffer(), let first = command.makeComputeCommandEncoder() else {
            throw CameraError.message("Cannot submit background mask processing.")
        }
        var values: [Float] = [settings.threshold, settings.softness, settings.lighting, settings.cleanup, maskPreview ? 1 : 0]
        first.setComputePipelineState(mattePipeline)
        first.setTexture(source.1, index: 0); first.setTexture(backdrop.1, index: 1); first.setTexture(matte, index: 2)
        first.setBytes(&values, length: values.count * MemoryLayout<Float>.size, index: 0)
        dispatch(first, pipeline: mattePipeline); first.endEncoding()
        guard let second = command.makeComputeCommandEncoder() else { throw CameraError.message("Cannot submit background mask processing.") }
        second.setComputePipelineState(compositePipeline)
        second.setTexture(source.1, index: 0); second.setTexture(matte, index: 1)
        second.setTexture(destination.1, index: 2); second.setTexture(mask.1, index: 3)
        second.setBytes(&values, length: values.count * MemoryLayout<Float>.size, index: 0)
        dispatch(second, pipeline: compositePipeline); second.endEncoding()
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime((source.0, backdrop.0, destination.0, mask.0)) {}
        guard command.status == .completed else { throw command.error ?? CameraError.message("Background mask processing failed. Camera stopped.") }
        return maskPreview ? maskBuffer : nil
    }
    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) {
        let w = pipeline.threadExecutionWidth, h = min(8, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    // Mirrors DifferenceKey in AppleCamCore. Colours are averaged over 3×3 pixels first to suppress sensor noise.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    float3 average(texture2d<float, access::read> t, int2 p) {
        int2 limit = int2(t.get_width() - 1, t.get_height() - 1);
        float3 sum = 0;
        for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) sum += t.read(uint2(clamp(p + int2(x, y), int2(0), limit))).rgb;
        return sum / 9;
    }
    kernel void differenceMatte(texture2d<float, access::read> camera [[texture(0)]],
                                texture2d<float, access::read> plate [[texture(1)]],
                                texture2d<float, access::write> matte [[texture(2)]],
                                constant float* p [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
        if (pos.x >= matte.get_width() || pos.y >= matte.get_height()) return;
        float3 c = average(camera, int2(pos)), b = average(plate, int2(pos));
        float3 w = float3(0.2126f, 0.7152f, 0.0722f);
        float ca = dot(c, w), ba = dot(b, w);
        float3 chroma = (c - ca) - (b - ba);
        float luma = (ca - ba) * (1 - p[2]);
        float d = sqrt(dot(chroma, chroma) + luma * luma);
        matte.write(float4(smoothstep(p[0], p[0] + p[1], d)), pos);
    }
    kernel void differenceComposite(texture2d<float, access::read> camera [[texture(0)]],
                                    texture2d<float, access::read> matte [[texture(1)]],
                                    texture2d<float, access::write> output [[texture(2)]],
                                    texture2d<float, access::write> mask [[texture(3)]],
                                    constant float* p [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
        if (pos.x >= output.get_width() || pos.y >= output.get_height()) return;
        float a = matte.read(pos).r;
        if (p[3] > 0 && pos.x >= 3 && pos.y >= 3 && pos.x + 3 < output.get_width() && pos.y + 3 < output.get_height()) {
            float lo = 1, hi = 0;
            for (int y = -3; y <= 3; ++y) for (int x = -3; x <= 3; ++x) {
                if (abs(x) == 3 || abs(y) == 3) {
                    float v = matte.read(uint2(int2(pos) + int2(x, y))).r;
                    lo = min(lo, v); hi = max(hi, v);
                }
            }
            a += (1 - a) * p[3] * smoothstep(0.95f, 1.0f, lo);
            a *= 1 - p[3] * (1 - smoothstep(0.0f, 0.05f, hi));
        }
        output.write(float4(camera.read(pos).rgb * a, a), pos);
        if (p[4] > 0) mask.write(float4(float3(a), 1), pos);
    }
    """
}
