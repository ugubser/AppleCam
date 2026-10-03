import Foundation
import CoreMedia

public struct CaptureConfiguration: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public init(width: Int = 1920, height: Int = 1080, fps: Double = 30) {
        self.width = width; self.height = height; self.fps = fps
    }
    public var isValid: Bool {
        width > 0 && height > 0 && width <= 16384 && height <= 16384 && fps.isFinite && fps > 0 && fps <= 1000 &&
        (1_000_000_000 / fps).isFinite && 1_000_000_000 / fps < Double(Int.max)
    }
    public var duration: CMTime { CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000_000) }
    public var resolution: String { "\(width) × \(height)" }
    public var rateLabel: String { String(format: "%.3f", fps).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) + " fps" }
    public var label: String { "\(resolution) · \(rateLabel)" }
}

/// Throttle only when the receiver explicitly requests a lower rate. Deadlines
/// accumulate independently of arrival jitter, avoiding a 30-to-15 fps sawtooth.
public struct OutputCadence {
    private var next: Double?
    public init() {}
    public mutating func shouldEmit(timestamp: Double, inputFPS: Double, outputFPS: Double) -> Bool {
        guard timestamp.isFinite, inputFPS.isFinite, outputFPS.isFinite, inputFPS > 0, outputFPS > 0 else { return false }
        guard outputFPS < inputFPS - 0.001 else { return true }
        let period = 1 / outputFPS
        guard let deadline = next else { next = timestamp + period; return true }
        guard timestamp + period * 0.05 >= deadline else { return false }
        if timestamp - deadline > period * 2 { next = timestamp + period; return true }
        next = deadline + max(1, floor((timestamp - deadline) / period) + 1) * period
        return true
    }
}

/// One device-reported resolution and frame-rate interval. Separate ranges are never merged across gaps.
public struct CameraCapability: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var minimumFPS: Double
    public var maximumFPS: Double
    public init(width: Int, height: Int, minimumFPS: Double, maximumFPS: Double) {
        self.width = width; self.height = height; self.minimumFPS = minimumFPS; self.maximumFPS = maximumFPS
    }
    public func supports(_ configuration: CaptureConfiguration) -> Bool {
        guard configuration.isValid, width == configuration.width, height == configuration.height,
              minimumFPS > 0, maximumFPS >= minimumFPS else { return false }
        return CaptureFrameTiming.duration(minimum: CMTime(seconds: 1 / maximumFPS, preferredTimescale: 1_000_000_000),
            maximum: CMTime(seconds: 1 / minimumFPS, preferredTimescale: 1_000_000_000), target: configuration.duration) != nil
    }
    public var choices: [CaptureConfiguration] {
        let common: [Double] = [1, 5, 7.5, 10, 15, 20, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 90, 100, 120, 144, 165, 180, 200, 240]
        var rates = common.filter { supports(CaptureConfiguration(width: width, height: height, fps: $0)) }
        for boundary in [minimumFPS, maximumFPS] where boundary.isFinite && boundary > 0 {
            if !rates.contains(where: { abs(1 / $0 - 1 / boundary) <= 0.0000001 }) { rates.append(boundary) }
        }
        return rates.sorted().map { CaptureConfiguration(width: width, height: height, fps: $0) }
    }
}
