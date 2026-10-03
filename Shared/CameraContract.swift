import Foundation

public enum CameraContract {
    public static let name = "AppleCam"
    public static let hostBundleID = "com.vanguardsignals.AppleCam"
    public static let extensionBundleID = "com.vanguardsignals.AppleCam.CameraExtension"
    public static let deviceID = UUID(uuidString: "ACAA54A8-6F29-4A2E-8020-2830E324521C")!
    public static let sourceID = UUID(uuidString: "8524247A-1A2C-4F4A-AD02-360EF97C1F11")!
    public static let sinkID = UUID(uuidString: "17F31502-9EA5-4433-BB7C-B42BF08CE765")!
    public static let width = 1920
    public static let height = 1080
    public static let fps: Int32 = 30
    public static let queueCapacity = 2
    public static let maximumFrameAge: Double = 0.15
}

/// Shared by host and extension. Call from their respective serial frame queues.
public struct FrameGate {
    public enum Rejection: LocalizedError, Equatable {
        case invalidTime, future, expired, nonIncreasing, wrongFormat
        public var errorDescription: String? {
            switch self {
            case .invalidTime: return "The camera supplied an invalid frame timestamp."
            case .future: return "The camera frame timestamp is ahead of the system clock."
            case .expired: return "The camera frame arrived too late to send."
            case .nonIncreasing: return "The camera supplied repeated or out-of-order frame timestamps."
            case .wrongFormat: return "The camera frame is not 1920 × 1080 BGRA."
            }
        }
    }
    public private(set) var lastAccepted: Double?
    public init() {}
    public mutating func accept(timestamp: Double, now: Double,
                                width: Int, height: Int, isBGRA: Bool) throws {
        guard timestamp.isFinite, now.isFinite, timestamp >= 0, now >= 0 else {
            throw Rejection.invalidTime
        }
        guard width == CameraContract.width, height == CameraContract.height, isBGRA else {
            throw Rejection.wrongFormat
        }
        guard timestamp <= now + 0.005 else { throw Rejection.future }
        guard now - timestamp <= CameraContract.maximumFrameAge else { throw Rejection.expired }
        if let previous = lastAccepted, timestamp <= previous { throw Rejection.nonIncreasing }
        lastAccepted = timestamp
    }
}

/// Discard individual late frames without ever forwarding or retimestamping them.
/// A continuous two-second period without a fresh frame remains a visible failure.
public struct FrameAdmission {
    private var gate = FrameGate()
    private var staleSince: Double?
    public init() {}
    public mutating func shouldSend(timestamp: Double, now: Double,
                                    width: Int, height: Int, isBGRA: Bool) throws -> Bool {
        do {
            try gate.accept(timestamp: timestamp, now: now, width: width, height: height, isBGRA: isBGRA)
            staleSince = nil
            return true
        } catch FrameGate.Rejection.expired {
            if let start = staleSince, now - start >= 2 {
                throw CameraError.message("Camera frames have been arriving over 150 ms late for 2 seconds. Output stopped; restart the camera and check its capture load.")
            }
            if staleSince == nil { staleSince = now }
            return false
        }
    }
}

/// Demand alone never enables output. A failure requires an explicit new start.
public struct CaptureDemand: Equatable {
    public var enabled = false
    public var preview = false
    public private(set) var consumers = 0
    public private(set) var failure: String?
    public init() {}
    public var shouldCapture: Bool { failure == nil && (preview || (enabled && consumers > 0)) }
    public var shouldPublish: Bool { failure == nil && enabled && consumers > 0 }
    public mutating func consumerStarted() { consumers += 1 }
    public mutating func consumerStopped() { consumers = max(0, consumers - 1) }
    public mutating func fail(_ reason: String) { failure = reason; enabled = false; preview = false }
    public mutating func reset() { failure = nil }
}

import CoreMedia

/// Camera descriptors can quantize nominal 30 fps to a nearby hardware clock tick.
/// Accept at most one 100 ns UVC interval tick; never turn 29.97 or 25 fps into 30.
public enum CaptureFrameTiming {
    /// Capture timestamps belong to the session clock, not necessarily the host clock.
    public static func hostTimestamp(_ timestamp: CMTime, from clock: CMClockOrTimebase?) throws -> CMTime {
        guard timestamp.isNumeric, let clock else { throw FrameGate.Rejection.invalidTime }
        let result = CMSyncConvertTime(timestamp, from: clock, to: CMClockGetHostTimeClock())
        guard result.isNumeric, result.seconds >= 0 else { throw FrameGate.Rejection.invalidTime }
        return result
    }

    public static func duration(minimum: CMTime, maximum: CMTime,
                                target: CMTime = CMTime(value: 1, timescale: CameraContract.fps)) -> CMTime? {
        guard minimum.isNumeric, maximum.isNumeric, target.isNumeric,
              minimum.seconds > 0, maximum.seconds > 0, target.seconds > 0,
              CMTimeCompare(minimum, maximum) <= 0 else { return nil }
        if CMTimeCompare(target, minimum) >= 0 && CMTimeCompare(target, maximum) <= 0 {
            return target
        }
        let boundary = CMTimeCompare(target, minimum) < 0 ? minimum : maximum
        guard abs(CMTimeSubtract(boundary, target).seconds) <= 0.0000001 else { return nil }
        // Use the supported boundary itself: an approximately equal but out-of-range
        // time can raise an Objective-C exception in AVCaptureDevice setters.
        return boundary
    }
}
