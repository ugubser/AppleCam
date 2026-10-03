import XCTest
@testable import AppleCamCore

final class CaptureConfigurationTests: XCTestCase {
    func testDeviceRangesPreserveGapsAndFractionalRates() {
        let low = CameraCapability(width: 3840, height: 2160, minimumFPS: 24, maximumFPS: 30)
        let high = CameraCapability(width: 3840, height: 2160, minimumFPS: 60, maximumFPS: 60)
        XCTAssertTrue(low.supports(.init(width: 3840, height: 2160, fps: 29.97)))
        XCTAssertFalse(low.supports(.init(width: 1920, height: 1080, fps: 30)))
        XCTAssertFalse([low, high].contains { $0.supports(.init(width: 3840, height: 2160, fps: 48)) })
        XCTAssertTrue(low.choices.contains(.init(width: 3840, height: 2160, fps: 24)))
        XCTAssertTrue(low.choices.contains(.init(width: 3840, height: 2160, fps: 29.97)))
        XCTAssertEqual(high.choices, [.init(width: 3840, height: 2160, fps: 60)])
    }
    func testUnusualNativeEndpointsAndQuantizedNominalRates() {
        let custom = CameraCapability(width: 1232, height: 928, minimumFPS: 17.25, maximumFPS: 27.75)
        XCTAssertTrue(custom.choices.contains(.init(width: 1232, height: 928, fps: 17.25)))
        XCTAssertTrue(custom.choices.contains(.init(width: 1232, height: 928, fps: 27.75)))
        XCTAssertTrue(custom.supports(.init(width: 1232, height: 928, fps: 26.125)))
        let nominal = CameraCapability(width: 1920, height: 1080, minimumFPS: 30.00003, maximumFPS: 30.00003)
        XCTAssertEqual(nominal.choices, [CaptureConfiguration()])
        XCTAssertFalse(nominal.supports(.init(fps: 29.97)))
    }
    func testInvalidFormatsAndLabels() {
        for value in [CaptureConfiguration(width: 0), .init(fps: .nan), .init(fps: 0), .init(fps: .infinity), .init(fps: .leastNonzeroMagnitude)] {
            XCTAssertFalse(value.isValid)
        }
        XCTAssertEqual(CaptureConfiguration(fps: 30).rateLabel, "30 fps")
        XCTAssertEqual(CaptureConfiguration(fps: 29.97).rateLabel, "29.97 fps")
    }
    func testFrameGateUsesSelectedDimensionsWithoutRelaxingFreshness() throws {
        var gate = FrameGate(width: 3840, height: 2160)
        try gate.accept(timestamp: 100, now: 100.01, width: 3840, height: 2160, isBGRA: true)
        XCTAssertThrowsError(try gate.accept(timestamp: 101, now: 101.01, width: 1920, height: 1080, isBGRA: true))
        XCTAssertThrowsError(try gate.accept(timestamp: 101, now: 102, width: 3840, height: 2160, isBGRA: true))
    }
    func testOutputCadenceDoesNotHalveJitteryThirtyFPS() {
        var cadence = OutputCadence()
        let accepted = (0..<300).filter { index in
            cadence.shouldEmit(timestamp: Double(index) / 30 + (index % 2 == 0 ? 0.0005 : 0), inputFPS: 30, outputFPS: 30)
        }
        XCTAssertEqual(accepted.count, 300)
    }
    func testOutputCadenceNegotiatedReductionAndPauseRecovery() {
        var cadence = OutputCadence()
        let accepted = (0..<600).filter { index in
            cadence.shouldEmit(timestamp: Double(index) / 60 + (index % 2 == 0 ? 0.0005 : 0), inputFPS: 60, outputFPS: 24)
        }
        XCTAssertEqual(accepted.count, 240)
        XCTAssertTrue(cadence.shouldEmit(timestamp: 100, inputFPS: 60, outputFPS: 24))
        XCTAssertFalse(cadence.shouldEmit(timestamp: 100.001, inputFPS: 60, outputFPS: 24))
    }
}
