import XCTest
@testable import AppleCamCore

final class FrameAdmissionTests: XCTestCase {
    private func send(_ admission: inout FrameAdmission, _ timestamp: Double, _ now: Double,
                      width: Int = 1920) throws -> Bool {
        try admission.shouldSend(timestamp: timestamp, now: now, width: width, height: 1080, isBGRA: true)
    }
    func testLateStartupFrameIsDiscardedThenFreshFramePasses() throws {
        var admission = FrameAdmission()
        XCTAssertFalse(try send(&admission, 8, 10))
        XCTAssertFalse(try send(&admission, 8.033, 10.033))
        XCTAssertTrue(try send(&admission, 10.06, 10.07))
    }
    func testSustainedLateFramesStopAtTwoSeconds() throws {
        var admission = FrameAdmission()
        XCTAssertFalse(try send(&admission, 9, 10))
        XCTAssertFalse(try send(&admission, 10.99, 11.99))
        XCTAssertThrowsError(try send(&admission, 11, 12)) {
            XCTAssertTrue($0.localizedDescription.contains("Output stopped"))
        }
    }
    func testFreshFrameResetsLatePeriodWithoutRelaxingAgeLimit() throws {
        var admission = FrameAdmission()
        XCTAssertFalse(try send(&admission, 9, 10))
        XCTAssertTrue(try send(&admission, 11, 11.01))
        XCTAssertFalse(try send(&admission, 11.1, 12))
        XCTAssertFalse(try send(&admission, 12.9, 13.9))
        XCTAssertTrue(try send(&admission, 13.99, 14))
    }
    func testOtherInvalidFramesStillFailImmediately() throws {
        var admission = FrameAdmission()
        XCTAssertThrowsError(try send(&admission, .nan, 10))
        XCTAssertThrowsError(try send(&admission, 12, 10))
        XCTAssertThrowsError(try send(&admission, 10, 10, width: 640))
        XCTAssertTrue(try send(&admission, 10, 10))
        XCTAssertThrowsError(try send(&admission, 10, 10.01))
    }
    func testRejectionMessagesAreReadable() {
        for rejection in [FrameGate.Rejection.invalidTime, .future, .expired, .nonIncreasing, .wrongFormat] {
            XCTAssertFalse(rejection.localizedDescription.contains("error "))
            XCTAssertNotNil(rejection.errorDescription)
        }
    }
}
