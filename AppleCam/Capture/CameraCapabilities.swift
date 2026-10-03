#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AVFoundation

enum CameraCapabilities {
    static func ranges(for device: AVCaptureDevice) -> [CameraCapability] {
        let values = device.formats.flatMap { format -> [CameraCapability] in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard size.width > 0, size.height > 0 else { return [] }
            return format.videoSupportedFrameRateRanges.map {
                CameraCapability(width: Int(size.width), height: Int(size.height), minimumFPS: $0.minFrameRate, maximumFPS: $0.maxFrameRate)
            }
        }
        return Array(Set(values)).sorted { ($0.width, $0.height, $0.maximumFPS) < ($1.width, $1.height, $1.maximumFPS) }
    }
    static func configurations(for device: AVCaptureDevice) -> [CaptureConfiguration] {
        Array(Set(ranges(for: device).flatMap(\.choices))).sorted { ($0.width, $0.height, $0.fps) < ($1.width, $1.height, $1.fps) }
    }
    static func selection(for requested: CaptureConfiguration, device: AVCaptureDevice) -> (AVCaptureDevice.Format, CMTime)? {
        guard requested.isValid else { return nil }
        for format in device.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(size.width) == requested.width, Int(size.height) == requested.height else { continue }
            for range in format.videoSupportedFrameRateRanges {
                if let duration = CaptureFrameTiming.duration(minimum: range.minFrameDuration, maximum: range.maxFrameDuration, target: requested.duration) {
                    return (format, duration)
                }
            }
        }
        return nil
    }
}
