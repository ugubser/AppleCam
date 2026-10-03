import XCTest
@testable import AppleCamCore

final class CameraContractTests: XCTestCase {
    private func accept(_ gate: inout FrameGate, _ time: Double, now: Double,
                        width: Int = 1920, bgra: Bool = true) throws {
        try gate.accept(timestamp: time, now: now, width: width, height: 1080, isBGRA: bgra)
    }
    func testFreshIncreasingFrames() throws {
        var gate = FrameGate()
        try accept(&gate, 10, now: 10.01)
        try accept(&gate, 10.033, now: 10.04)
        XCTAssertEqual(gate.lastAccepted, 10.033)
    }
    func testRejectsReplayAndBackwardsTime() throws {
        var gate = FrameGate()
        try accept(&gate, 10, now: 10)
        for time in [10.0, 9.99] {
            XCTAssertThrowsError(try accept(&gate, time, now: 10)) {
                XCTAssertEqual($0 as? FrameGate.Rejection, .nonIncreasing)
            }
        }
    }
    func testExpiredFutureAndInvalidTimestamps() {
        for (time, now, reason) in [(1.0, 2.0, FrameGate.Rejection.expired),
                                    (3.0, 2.0, .future), (.nan, 2.0, .invalidTime),
                                    (1.0, .infinity, .invalidTime), (-1.0, 0.0, .invalidTime)] {
            var gate = FrameGate()
            XCTAssertThrowsError(try accept(&gate, time, now: now)) {
                XCTAssertEqual($0 as? FrameGate.Rejection, reason)
            }
            XCTAssertNil(gate.lastAccepted)
        }
    }
    func testBadFrameDoesNotAdvanceClock() throws {
        var gate = FrameGate()
        XCTAssertThrowsError(try accept(&gate, 10, now: 10, width: 1280))
        XCTAssertThrowsError(try accept(&gate, 10, now: 10, bgra: false))
        try accept(&gate, 9.99, now: 10)
    }
    func testBrowserCannotEnableDisabledCamera() {
        var state = CaptureDemand()
        state.consumerStarted()
        XCTAssertFalse(state.shouldCapture)
        XCTAssertFalse(state.shouldPublish)
        state.enabled = true
        XCTAssertTrue(state.shouldPublish)
    }
    func testPreviewAndConsumersAreIndependent() {
        var state = CaptureDemand()
        state.preview = true
        XCTAssertTrue(state.shouldCapture)
        XCTAssertFalse(state.shouldPublish)
        state.enabled = true
        state.consumerStarted(); state.consumerStarted()
        state.preview = false
        state.consumerStopped()
        XCTAssertTrue(state.shouldCapture)
        state.consumerStopped(); state.consumerStopped()
        XCTAssertFalse(state.shouldCapture)
        XCTAssertEqual(state.consumers, 0)
    }
    func testFailureCannotResumeOnNewConsumerOrResetAlone() {
        var state = CaptureDemand()
        state.enabled = true
        state.consumerStarted()
        state.fail("Input lost")
        state.consumerStarted()
        XCTAssertFalse(state.shouldCapture)
        state.reset()
        XCTAssertFalse(state.shouldPublish)
        state.enabled = true
        XCTAssertTrue(state.shouldPublish)
    }
    func testRapidDemandCyclesLeaveNoCapture() {
        var state = CaptureDemand()
        state.enabled = true
        for _ in 0..<100 {
            state.consumerStarted(); state.preview = true
            state.consumerStopped(); state.preview = false
        }
        XCTAssertFalse(state.shouldCapture)
    }
}
