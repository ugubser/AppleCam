import Foundation

/// Retains at most one pending image and schedules at most one UI delivery.
/// A generation ticket prevents an old delivery from consuming a restarted session.
public final class LatestFrameMailbox<Element> {
    private let lock = NSLock()
    private var pending: Element?
    private var scheduled = false
    private var generation: UInt64 = 0
    public init() {}

    public func offer(_ value: Element) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        pending = value
        guard !scheduled else { return nil }
        scheduled = true
        return generation
    }
    public func take(ticket: UInt64) -> Element? {
        lock.lock(); defer { lock.unlock() }
        guard ticket == generation else { return nil }
        let result = pending
        pending = nil; scheduled = false
        return result
    }
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        pending = nil; scheduled = false
    }
}

/// Event rate over actual monotonic elapsed time, including intervals with no events.
/// Each instance belongs to one serial queue; input and UI delivery use separate instances.
public struct FrameRateCounter {
    private var startedAt: Double = 0
    public private(set) var count = 0
    public init() {}
    public mutating func reset(at time: Double) { startedAt = time; count = 0 }
    public mutating func record() { count += 1 }
    public mutating func sample(at time: Double) -> Double {
        guard time.isFinite, time > startedAt else { return 0 }
        let rate = Double(count) / (time - startedAt)
        reset(at: time)
        return rate
    }
}
