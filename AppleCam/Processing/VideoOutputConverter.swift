#if SWIFT_PACKAGE
import AppleCamCore
#endif
import CoreImage
import CoreMedia
import Metal

/// Adapts processed frames to the format explicitly negotiated by a virtual-camera consumer.
/// Aspect-fit preserves the entire picture; no keying or capture-mode substitution happens here.
final class VideoOutputConverter {
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var current: CaptureConfiguration?
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CameraError.message("Metal is unavailable for virtual-camera output.") }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }
    func convert(_ sample: CMSampleBuffer, to configuration: CaptureConfiguration) throws -> CMSampleBuffer {
        guard configuration.isValid, let input = sample.imageBuffer else { throw CameraError.message("Invalid virtual-camera format or frame.") }
        if CVPixelBufferGetWidth(input) == configuration.width && CVPixelBufferGetHeight(input) == configuration.height {
            if sample.duration.isNumeric, sample.duration.seconds + 0.0000001 >= configuration.duration.seconds { return sample }
            return try package(input, original: sample, configuration: configuration)
        }
        if current != configuration {
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: configuration.width, kCVPixelBufferHeightKey: configuration.height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            let result = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            guard result == kCVReturnSuccess else { throw CameraError.operation("Allocate virtual-camera pool", result) }
            current = configuration
        }
        guard let pool else { throw CameraError.message("Missing output pool.") }
        var output: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary, &output)
        guard allocation == kCVReturnSuccess, let output else { throw CameraError.operation("Allocate virtual-camera frame", allocation) }
        let image = CIImage(cvPixelBuffer: input)
        let bounds = CGRect(x: 0, y: 0, width: configuration.width, height: configuration.height)
        let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = resized.transformed(by: CGAffineTransform(translationX: (bounds.width - resized.extent.width) / 2,
                                                                y: (bounds.height - resized.extent.height) / 2))
        let composite = centered.composited(over: CIImage(color: .black).cropped(to: bounds))
        context.render(composite, to: output, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        CVBufferPropagateAttachments(input, output)
        return try package(output, original: sample, configuration: configuration)
    }
    private func package(_ output: CVPixelBuffer, original sample: CMSampleBuffer, configuration: CaptureConfiguration) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        let described = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output, formatDescriptionOut: &description)
        guard described == noErr, let description else { throw CameraError.operation("Describe virtual-camera frame", described) }
        var timing = CMSampleTimingInfo(duration: CMTimeMaximum(sample.duration, configuration.duration), presentationTimeStamp: sample.presentationTimeStamp, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: output, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &result)
        guard status == noErr, let result else { throw CameraError.operation("Package virtual-camera frame", status) }
        return result
    }
}
