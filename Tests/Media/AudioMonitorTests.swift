import XCTest
import AppleCamCore
@testable import AppleCamMedia

final class AudioMonitorTests: XCTestCase {
    func testRingDeinterleavesKeepsOrderAndPlaysSilenceWhenEmpty() {
        let ring = MonitorRing(seconds: 0.001) // 48 frames
        let frames: [Float] = (0..<20).flatMap { [Float($0), -Float($0)] }
        frames.withUnsafeBufferPointer { ring.push($0) }
        var left = [Float](repeating: 9, count: 30), right = left
        let got = left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in ring.pull(left: l.baseAddress!, right: r.baseAddress!, frames: 30) } }
        XCTAssertEqual(got, 20)
        XCTAssertEqual(Array(left[0..<3]), [0, 1, 2]); XCTAssertEqual(Array(right[0..<3]), [0, -1, -2])
        XCTAssertEqual(left[25], 0, "Underflow plays silence")
    }
    func testOverflowDropsTheOldestFrames() {
        let ring = MonitorRing(seconds: 0.001) // 48 frames
        let frames: [Float] = (0..<60).flatMap { [Float($0), Float($0)] }
        frames.withUnsafeBufferPointer { ring.push($0) }
        var left = [Float](repeating: 0, count: 48), right = left
        _ = left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in ring.pull(left: l.baseAddress!, right: r.baseAddress!, frames: 48) } }
        XCTAssertEqual(left.first, 12); XCTAssertEqual(left.last, 59)
    }
    /// Starts the real output engine with silence only, so nothing is heard.
    func testMonitorStartsOnTheSystemOutputAndRejectsAMissingDevice() throws {
        let monitor = AudioMonitor()
        try monitor.start(deviceUID: nil)
        XCTAssertTrue(monitor.isRunning)
        [Float](repeating: 0, count: 2048).withUnsafeBufferPointer { monitor.push($0) }
        monitor.stop(); XCTAssertFalse(monitor.isRunning)
        XCTAssertThrowsError(try monitor.start(deviceUID: "no-such-device")) { XCTAssertTrue($0.localizedDescription.contains("not connected")) }
        XCTAssertFalse(AudioOutputDevice.all().isEmpty, "This Mac lists at least one output")
    }
}
