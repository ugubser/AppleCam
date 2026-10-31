import XCTest
import CoreImage
import CoreMedia
import AppleCamCore
@testable import AppleCamMedia

/// Exercises the real Core Image/pixel-buffer capture source without camera permissions.
/// Keying, composition and publication are covered by the scene output tests.
final class FrameProducerTests: XCTestCase {
    func testPatternDeliversSelectedFormatsWithIncreasingHostTimestamps() {
        for configuration in [CaptureConfiguration(width: 1280, height: 720, fps: 24), .init(width: 3840, height: 2160, fps: 30)] {
            let producer = FrameProducer()
            let frames = expectation(description: configuration.label)
            var count = 0, last = -Double.infinity
            producer.onCameraFrame = { buffer, time in
                guard count < 3 else { return }
                XCTAssertEqual(CVPixelBufferGetWidth(buffer), configuration.width)
                XCTAssertEqual(CVPixelBufferGetHeight(buffer), configuration.height)
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
                XCTAssertGreaterThan(time.seconds, last); last = time.seconds
                XCTAssertLessThanOrEqual(time.seconds, CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                count += 1; if count == 3 { frames.fulfill() }
            }
            producer.onFailure = { XCTFail("Unexpected failure: \($0)") }
            producer.start(mode: .pattern, configuration: configuration)
            wait(for: [frames], timeout: 10)
            producer.stop(); producer.queue.sync {}
        }
    }
    func testStopEndsFrameDelivery() {
        let producer = FrameProducer()
        let first = expectation(description: "Synthetic frame")
        var seen = false
        producer.onCameraFrame = { _, _ in if !seen { seen = true; first.fulfill() } }
        producer.start(mode: .pattern)
        wait(for: [first], timeout: 10)
        producer.stop()
        let quiet = expectation(description: "No frames after stop"); quiet.isInverted = true
        producer.queue.sync { producer.onCameraFrame = { _, _ in quiet.fulfill() } }
        wait(for: [quiet], timeout: 0.25)
    }
    func testMissingCameraFailsWithoutSubstitutingPattern() {
        let producer = FrameProducer()
        let failure = expectation(description: "Specific camera error")
        let frame = expectation(description: "No substituted output"); frame.isInverted = true
        producer.onCameraFrame = { _, _ in frame.fulfill() }
        producer.onFailure = { error in XCTAssertFalse(error.localizedDescription.isEmpty); failure.fulfill() }
        producer.start(mode: .camera("nonexistent-test-camera"))
        wait(for: [failure, frame], timeout: 0.5)
    }
    func testInvalidFormatFailsWithoutFrames() {
        let producer = FrameProducer()
        let failure = expectation(description: "Invalid format error")
        let frame = expectation(description: "No output"); frame.isInverted = true
        producer.onCameraFrame = { _, _ in frame.fulfill() }
        producer.onFailure = { error in XCTAssertTrue(error.localizedDescription.contains("Invalid")); failure.fulfill() }
        producer.start(mode: .pattern, configuration: CaptureConfiguration(width: 0, height: 1080, fps: 30))
        wait(for: [failure, frame], timeout: 0.5)
    }
    func testRepeatedPatternStartStopReleasesProducer() {
        weak var reference: FrameProducer?
        for _ in 0..<5 {
            let producer = FrameProducer()
            reference = producer
            let active = expectation(description: "Started")
            var started = false
            producer.onCameraFrame = { _, _ in if !started { started = true; active.fulfill() } }
            producer.start(mode: .pattern)
            wait(for: [active], timeout: 5)
            producer.stop(); producer.queue.sync {}
        }
        XCTAssertNil(reference)
    }
}
