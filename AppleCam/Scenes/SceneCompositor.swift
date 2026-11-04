#if SWIFT_PACKAGE
import AppleCamCore
#endif
import CoreImage
import CoreMedia
import Metal

/// Confined to SceneOutput.queue. Uses one linear-light GPU composition for preview and publication.
final class SceneCompositor {
    let configuration: CaptureConfiguration
    let context: CIContext
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let bounds: CGRect
    private var pool: CVPixelBufferPool?
    /// Canvas buffers that may be in use at once. Recording raises it: the encoder holds a few frames while it works.
    var outputBufferLimit = 5
    private var cameraKeyer: GreenScreenProcessor?
    private var maskKeyer: BackgroundMaskProcessor?
    private var keyed: CVPixelBuffer?
    init(configuration: CaptureConfiguration) throws {
        guard configuration.isValid, let device = MTLCreateSystemDefaultDevice() else {
            throw CameraError.message("Metal is required for scene composition.")
        }
        self.configuration = configuration
        bounds = CGRect(x: 0, y: 0, width: configuration.width, height: configuration.height)
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: configuration.width, kCVPixelBufferHeightKey: configuration.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess else { throw CameraError.operation("Create scene frame pool", status) }
    }
    /// The webcam picture after keying, plus the local-only mask when `mask` is set.
    func cameraImage(_ buffer: CVPixelBuffer, keying: CameraKeying, mask: Bool) throws -> (CIImage, CIImage?) {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if keyed.map({ CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height }) ?? true, keying != .off {
            keyed = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        }
        switch keying {
        case .off: return (CIImage(cvPixelBuffer: buffer), nil)
        case .greenScreen(let key):
            if cameraKeyer?.width != width || cameraKeyer?.height != height {
                cameraKeyer = try GreenScreenProcessor(width: width, height: height)
            }
            guard let cameraKeyer, let keyed else { throw CameraError.message("Camera keyer is unavailable.") }
            let maskBuffer = try cameraKeyer.render(buffer, into: keyed, settings: key, maskPreview: mask, transparent: true)
            return (CIImage(cvPixelBuffer: keyed), maskBuffer.map { CIImage(cvPixelBuffer: $0) })
        case .backgroundMask(let settings, let plate):
            if maskKeyer?.plateID != plate.id { maskKeyer = try BackgroundMaskProcessor(plate: plate.image, id: plate.id) }
            guard let maskKeyer, let keyed else { throw CameraError.message("Background mask is unavailable.") }
            let maskBuffer = try maskKeyer.render(buffer, into: keyed, settings: settings, maskPreview: mask)
            return (CIImage(cvPixelBuffer: keyed), maskBuffer.map { CIImage(cvPixelBuffer: $0) })
        }
    }
    func compose(scene: CameraScene, images: [UUID: CIImage]) throws -> CVPixelBuffer? {
        guard scene.isValid else { throw CameraError.message("This scene contains invalid layer settings.") }
        var picture = CIImage(color: CIColor(red: scene.canvasRed, green: scene.canvasGreen, blue: scene.canvasBlue)).cropped(to: bounds)
        for layer in scene.layers.reversed() where layer.visible {
            guard let source = images[layer.id], !source.extent.isEmpty else {
                throw CameraError.message("\(layer.name) is not delivering a picture. Output stopped.")
            }
            let content = layer.placement.contentRect(source: source.extent.size, canvas: bounds.size)
            let topBox = layer.placement.viewport(canvas: bounds.size)
            let clip = CGRect(x: topBox.minX, y: bounds.height - topBox.maxY, width: topBox.width, height: topBox.height)
            let moved = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: content.width / source.extent.width, y: content.height / source.extent.height))
                .transformed(by: CGAffineTransform(translationX: content.minX, y: bounds.height - content.maxY))
                .cropped(to: clip)
            picture = moved.composited(over: picture)
        }
        guard let pool else { throw CameraError.message("Scene frame pool is unavailable.") }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: outputBufferLimit] as CFDictionary, &output)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let output else { throw CameraError.operation("Allocate scene frame", status) }
        context.render(picture.cropped(to: bounds), to: output, bounds: bounds, colorSpace: space)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return output
    }
    /// Local preview frames are scaled on the GPU to at most this many pixels on the longer side; the interface never
    /// shows the canvas larger. Published frames are unaffected.
    static let previewMaxDimension: CGFloat = 1920
    private var previewPool: CVPixelBufferPool?
    private var previewSize = CGSize.zero
    /// Renders a downscaled copy into a reusable IOSurface buffer for `AVSampleBufferDisplayLayer`, so the main thread
    /// never creates or copies a full image per frame. Returns nil when the display still holds every pooled buffer.
    func previewBuffer(_ image: CIImage) throws -> CVPixelBuffer? {
        let scaled = Self.scaled(image, maxDimension: Self.previewMaxDimension)
        let extent = scaled.extent.integral
        if previewPool == nil || previewSize != extent.size {
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: Int(extent.width), kCVPixelBufferHeightKey: Int(extent.height),
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess else { throw CameraError.operation("Create preview frame pool", status) }
            previewPool = pool; previewSize = extent.size
        }
        guard let previewPool else { throw CameraError.message("Preview frame pool is unavailable.") }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, previewPool,
            [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let buffer else { throw CameraError.operation("Allocate preview frame", status) }
        context.render(scaled, to: buffer, bounds: extent, colorSpace: space)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
    /// A small, fully rendered still for the scene buttons.
    func thumbnail(_ image: CIImage, maxDimension: CGFloat = 320) throws -> CGImage {
        let scaled = Self.scaled(image, maxDimension: maxDimension)
        guard let picture = context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: space, deferred: false) else {
            throw CameraError.message("Cannot draw the scene thumbnail.")
        }
        return picture
    }
    private static func scaled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let origin = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let longest = max(origin.extent.width, origin.extent.height)
        guard longest > maxDimension else { return origin }
        return origin.transformed(by: CGAffineTransform(scaleX: maxDimension / longest, y: maxDimension / longest))
    }
}
