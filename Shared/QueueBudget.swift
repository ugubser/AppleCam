import Foundation

/// A full queue drops new frames briefly; a stalled reader becomes a visible error.
public struct QueueBudget {
    public enum Decision: Equatable { case enqueue, drop, stalled }
    private var blockedSince: Double?
    public init() {}
    public mutating func decision(depth: Int, now: Double) -> Decision {
        guard depth >= CameraContract.queueCapacity else { blockedSince = nil; return .enqueue }
        guard now.isFinite else { return .stalled }
        if let start = blockedSince { return now - start >= 2 ? .stalled : .drop }
        blockedSince = now
        return .drop
    }
}
