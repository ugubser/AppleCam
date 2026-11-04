import AppKit
import CoreMedia

/// Window-layer sound: taps a stand-in app (`TonePlayer`, pid and bundle ID as arguments) through `AppSoundTap` and
/// checks that its sound reaches the channel at its level, that a helper process started later is added, and that
/// nothing is captured before the tap or after it stops. Prints "PHASE <name> <time>" lines so the script can match
/// microphone levels (speakers silent while tapped). Needs System Audio Recording permission for this harness.
@MainActor final class WindowSoundHarness: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); print("Window sound capture (app, later helper, muted while tapped) passed."); exit(0) }
            catch { print("Window sound integration failed: \(error)"); exit(1) }
        }
    }
    func phase(_ name: String) { print(String(format: "PHASE %@ %.2f", name, Date().timeIntervalSince1970)); fflush(stdout) }
    func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, let pid = pid_t(arguments[1]) else { throw CameraError.message("Usage: <pid> <bundle ID>") }
        let bundleID = arguments[2]
        let mixer = AudioMixer(), collected = Collected()
        let channel = MixChannel(id: "window", name: "Tone player", mix: ChannelMix(), active: true)
        mixer.onMixBlock = { collected.append($0) }
        mixer.setChannels([channel], master: ChannelMix()); mixer.start()
        defer { mixer.stop() }
        phase("untapped")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let capture = AppSoundTap(pid: pid, bundleID: bundleID)
        capture.input.attach(channel)
        var notes: [String?] = []
        capture.onNote = { notes.append($0) }
        capture.onFailure = { print("Failure: \($0)") }
        try await capture.start()
        phase("tapped")
        try await Task.sleep(nanoseconds: 1_000_000_000); _ = collected.take(seconds: 1)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let app = collected.take(seconds: 1)
        let first = (Goertzel.level(app, 880), Goertzel.level(app, 1_320)), firstCount = capture.tappedProcessCount
        print(String(format: "Tapped %d process(es): 880 Hz %.1f dB, 1320 Hz %.1f dB", firstCount, first.0, first.1))
        guard abs(first.0 + 26) < 1, first.1 < -60, firstCount >= 1 else { throw CameraError.message("The app's sound was not captured at its level.") }
        // The helper starts later and must be added to the tap.
        let deadline = Date().addingTimeInterval(20)
        while capture.tappedProcessCount <= firstCount, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        phase("helper")
        try await Task.sleep(nanoseconds: 1_000_000_000); _ = collected.take(seconds: 1)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let both = collected.take(seconds: 1)
        let second = (Goertzel.level(both, 880), Goertzel.level(both, 1_320))
        print(String(format: "With the helper, tapped %d process(es): 880 Hz %.1f dB, 1320 Hz %.1f dB; notes %@; late frames %d",
                     capture.tappedProcessCount, second.0, second.1, notes.description, channel.timeline.droppedLate))
        let helperOK = capture.tappedProcessCount > firstCount && abs(second.0 + 26) < 1 && abs(second.1 + 26) < 1
        await capture.stop()
        phase("stopped")
        try await Task.sleep(nanoseconds: 1_000_000_000); _ = collected.take(seconds: 1)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let after = collected.take(seconds: 1)
        guard Goertzel.level(after, 880) < -60, Goertzel.level(after, 1_320) < -60 else { throw CameraError.message("Sound was still captured after the tap stopped.") }
        guard helperOK else { throw CameraError.message("The helper started later was not added to the tap.") }
        phase("end")
    }
}

/// The newest mix blocks (left channel), collected on the mixer queue.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ block: UnsafeBufferPointer<Float>) { lock.withLock { samples += block; if samples.count > 480_000 { samples.removeFirst(samples.count - 480_000) } } }
    func take(seconds: Double) -> [Float] {
        lock.withLock {
            let frames = min(samples.count / 2, Int(seconds * AudioFormat.sampleRate))
            let left = stride(from: samples.count - frames * 2, to: samples.count, by: 2).map { samples[$0] }
            samples = []; return left
        }
    }
}

enum Goertzel {
    static func level(_ samples: [Float], _ frequency: Double) -> Double {
        WebKitAudioSignature.level(samples, frequency: frequency, sampleRate: AudioFormat.sampleRate)
    }
}

@main struct WindowSoundMain {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = WindowSoundHarness()
        app.setActivationPolicy(.accessory); app.delegate = delegate
        app.run(); withExtendedLifetime(delegate) {}
    }
}
