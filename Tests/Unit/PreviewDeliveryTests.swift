import XCTest
@testable import AppleCamCore

final class PreviewDeliveryTests: XCTestCase {
    func testUnblockedDeliveryReceivesEveryFrame() {
        let mailbox = LatestFrameMailbox<Int>()
        for frame in 0..<60 {
            let ticket = mailbox.offer(frame)
            XCTAssertNotNil(ticket)
            XCTAssertEqual(mailbox.take(ticket: ticket!), frame)
        }
    }
    func testBlockedUIKeepsOnlyNewestFrameAndOneScheduledDelivery() {
        let mailbox = LatestFrameMailbox<Int>()
        let ticket = mailbox.offer(0)!
        for frame in 1..<100 { XCTAssertNil(mailbox.offer(frame)) }
        XCTAssertEqual(mailbox.take(ticket: ticket), 99)
        XCTAssertNil(mailbox.take(ticket: ticket))
        XCTAssertNotNil(mailbox.offer(100))
    }
    func testOldCallbackCannotConsumeFrameFromRestartedSession() {
        let mailbox = LatestFrameMailbox<Int>()
        let old = mailbox.offer(1)!
        mailbox.invalidate()
        let fresh = mailbox.offer(2)!
        XCTAssertNil(mailbox.take(ticket: old))
        XCTAssertEqual(mailbox.take(ticket: fresh), 2)
    }
    func testSupersededFramesAreReleased() {
        final class Frame {}
        let mailbox = LatestFrameMailbox<Frame>()
        var first: Frame? = Frame()
        weak var weakFirst = first
        _ = mailbox.offer(first!)
        first = nil
        XCTAssertNotNil(weakFirst)
        _ = mailbox.offer(Frame())
        XCTAssertNil(weakFirst)
        mailbox.invalidate()
    }
    func testCountersUseActualElapsedTimeAndReportStalls() {
        var counter = FrameRateCounter()
        counter.reset(at: 10)
        for _ in 0..<60 { counter.record() }
        XCTAssertEqual(counter.sample(at: 12), 30)
        XCTAssertEqual(counter.sample(at: 13), 0)
        for _ in 0..<15 { counter.record() }
        XCTAssertEqual(counter.sample(at: 13.5), 30)
    }
    func testResetDoesNotCarryFramesIntoNewSession() {
        var counter = FrameRateCounter()
        counter.reset(at: 10); counter.record()
        XCTAssertEqual(counter.sample(at: 10), 0)
        counter.reset(at: 20)
        XCTAssertEqual(counter.sample(at: 21), 0)
    }
}
