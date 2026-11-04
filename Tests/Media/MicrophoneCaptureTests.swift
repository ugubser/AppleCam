import XCTest
import AVFoundation
import AppleCamCore
@testable import AppleCamMedia

/// Uses a real microphone, so it runs only when APPLECAM_MICROPHONE_TEST names a device (or "default") and the
/// test runner's terminal has microphone access. Verifies delivery, timing and level through the real capture path.
final class MicrophoneCaptureTests: XCTestCase {
    func testRealMicrophoneDeliversTimedAudioIntoItsChannel() async throws {
        guard let wanted = ProcessInfo.processInfo.environment["APPLECAM_MICROPHONE_TEST"] else { throw XCTSkip("Set APPLECAM_MICROPHONE_TEST to run.") }
        let devices = AudioInputDevice.all()
        let device = try XCTUnwrap(wanted == "default" ? devices.first : devices.first { $0.name.contains(wanted) }, "Microphones: \(devices.map(\.name))")
        let channel = MixChannel(id: "mic", name: device.name, mix: ChannelMix(), active: true)
        let mixer = AudioMixer()
        nonisolated(unsafe) var samples = 0
        nonisolated(unsafe) var peak: Float = -120
        mixer.onMixBlock = { _ in samples += AudioFormat.blockFrames }
        mixer.onLevels = { levels, _ in peak = max(peak, levels["mic"]?.peakDB ?? -120) }
        mixer.setChannels([channel], master: ChannelMix())
        mixer.start()
        let capture = MicrophoneCapture(uid: device.uid)
        try capture.start(); capture.input.attach(channel)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        capture.stop(); mixer.stop()
        let (mixed, loudest) = mixer.queue.sync { (samples, peak) }
        print("\(device.name): mixed \(mixed) frames, loudest \(loudest) dBFS, late frames \(channel.timeline.droppedLate), resyncs \(channel.timeline.resyncs)")
        XCTAssertGreaterThan(mixed, 48_000 * 2, "About 2.85 s of mix after the 150 ms delay")
        XCTAssertGreaterThan(loudest, -100, "A live microphone has at least room noise")
        XCTAssertEqual(channel.timeline.droppedLate, 0, "Microphone audio arrives within the mixer's 150 ms window")
        XCTAssertLessThanOrEqual(channel.timeline.resyncs, 1)
    }
}
