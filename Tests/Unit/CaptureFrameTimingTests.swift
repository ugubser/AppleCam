import XCTest
import CoreMedia
@testable import AppleCamCore

final class CaptureFrameTimingTests: XCTestCase {
    func testClockConversionPreservesCaptureAgeAcrossDifferentEpochs() throws {
        let host = CMClockGetHostTimeClock()
        var clock: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: host, timebaseOut: &clock), noErr)
        let session = try XCTUnwrap(clock)
        let anchor = CMClockGetTime(host)
        XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(session, rate: 1,
            anchorTime: CMTime(seconds: 10, preferredTimescale: 1_000_000), immediateSourceTime: anchor), noErr)
        let converted = try CaptureFrameTiming.hostTimestamp(CMTime(seconds: 9.9, preferredTimescale: 1_000_000), from: session)
        XCTAssertEqual(converted.seconds, anchor.seconds - 0.1, accuracy: 0.000001)
        // Conversion must not make an old capture fresh by replacing its timestamp with "now".
        let stale = try CaptureFrameTiming.hostTimestamp(CMTime(seconds: 8, preferredTimescale: 1_000_000), from: session)
        XCTAssertEqual(stale.seconds, anchor.seconds - 2, accuracy: 0.000001)
    }
    func testMissingClockAndInvalidCaptureTimestampFail() {
        XCTAssertThrowsError(try CaptureFrameTiming.hostTimestamp(.zero, from: nil))
        for timestamp in [CMTime.invalid, .indefinite, .positiveInfinity] {
            XCTAssertThrowsError(try CaptureFrameTiming.hostTimestamp(timestamp, from: CMClockGetHostTimeClock()))
        }
    }
    func testBRIOReportedClockTickIsAcceptedAndPreserved() {
        let reported = CMTime(value: 1_000_000, timescale: 30_000_030)
        let result = CaptureFrameTiming.duration(minimum: reported, maximum: reported)
        XCTAssertEqual(result, reported)
        XCTAssertNotEqual(result, CMTime(value: 1, timescale: 30))
    }
    func testQuantizationOnSlowerSideIsAccepted() {
        let reported = CMTime(value: 333_334, timescale: 10_000_000)
        XCTAssertEqual(CaptureFrameTiming.duration(minimum: reported, maximum: reported), reported)
    }
    func testExactThirtyWithinRangeStaysExact() {
        let result = CaptureFrameTiming.duration(minimum: CMTime(value: 1, timescale: 60),
                                                maximum: CMTime(value: 1, timescale: 15))
        XCTAssertEqual(result, CMTime(value: 1, timescale: 30))
    }
    func testDifferentRatesAreNotSubstituted() {
        for reported in [CMTime(value: 1001, timescale: 30_000), CMTime(value: 1, timescale: 25),
                         CMTime(value: 1, timescale: 60), CMTime(value: 1, timescale: 5)] {
            XCTAssertNil(CaptureFrameTiming.duration(minimum: reported, maximum: reported))
        }
    }
    func testBeyondOneHardwareTickIsRejected() {
        let reported = CMTime(value: 333_335, timescale: 10_000_000)
        XCTAssertNil(CaptureFrameTiming.duration(minimum: reported, maximum: reported))
    }
    func testInvalidRangesAreRejected() {
        let valid = CMTime(value: 1, timescale: 30)
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .zero, CMTime(value: -1, timescale: 30)] {
            XCTAssertNil(CaptureFrameTiming.duration(minimum: time, maximum: valid))
            XCTAssertNil(CaptureFrameTiming.duration(minimum: valid, maximum: time))
        }
        XCTAssertNil(CaptureFrameTiming.duration(minimum: CMTime(value: 1, timescale: 15), maximum: valid))
    }
}
