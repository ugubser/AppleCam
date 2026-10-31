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
    private var cameraKeyer: GreenScreenProcessor?
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
    func cameraImage(_ buffer: CVPixelBuffer, key: KeySettings, enabled: Bool, mask: Bool) throws -> (CIImage, CIImage?) {
        guard enabled else { return (CIImage(cvPixelBuffer: buffer), nil) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if cameraKeyer?.width != width || cameraKeyer?.height != height {
            cameraKeyer = try GreenScreenProcessor(width: width, height: height)
            keyed = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        }
        guard let cameraKeyer, let keyed else { throw CameraError.message("Camera keyer is unavailable.") }
        let maskBuffer = try cameraKeyer.render(buffer, into: keyed, settings: key, maskPreview: mask, transparent: true)
        return (CIImage(cvPixelBuffer: keyed), maskBuffer.map { CIImage(cvPixelBuffer: $0) })
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
            [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary, &output)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let output else { throw CameraError.operation("Allocate scene frame", status) }
        context.render(picture.cropped(to: bounds), to: output, bounds: bounds, colorSpace: space)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return output
    }
    func preview(_ buffer: CVPixelBuffer) throws -> CGImage {
        try preview(CIImage(cvPixelBuffer: buffer))
    }
    func preview(_ image: CIImage) throws -> CGImage {
        guard let image = context.createCGImage(image, from: image.extent) else { throw CameraError.message("Cannot draw the scene preview.") }
        return image
    }
}
