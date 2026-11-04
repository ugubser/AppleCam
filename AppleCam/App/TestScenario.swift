#if DEBUG
import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Debug builds only: `--test-audio-scenario <folder>` runs an unattended end-to-end recording for verification.
/// The folder (inside the app container) holds `page-url.txt` and optionally `clip.mov`; the app builds Scene 1 with the
/// test-pattern webcam, the main screen, the page and the clip (all with audio on), records `seconds.txt` seconds
/// (default 6) into `<folder>/out`, writes `<folder>/result.json`, and quits. It also listens to AppleCam's own output
/// (including its WebKit processes) to show that page and clip sound never reach the speakers; `control.wav` (if present)
/// is played at 0.1 % volume first to prove that this listener hears AppleCam.
@MainActor enum TestScenario {
    static func runIfRequested(_ model: CameraModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--test-audio-scenario"), arguments.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task { await run(model, folder: folder) }
    }
    private static func run(_ model: CameraModel, folder: URL) async {
        var result: [String: Any] = [:]
        var peaks: [String: Float] = [:]
        do {
            let out = folder.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try model.setRecordingFolder(out)
            model.selection = "pattern"
            var layers: [SceneLayer] = []
            if let uuid = CaptureSelection.displayUUID(CGMainDisplayID()) {
                var screen = SceneLayer(name: "Screen", source: .display(DisplayReference(uuid: uuid, name: "Main screen")))
                screen.audio = LayerAudio(enabled: true); screen.visible = true; layers.append(screen)
            }
            if let url = try? String(contentsOf: folder.appendingPathComponent("page-url.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                var settings = BrowserSettings(); settings.url = url
                var page = SceneLayer(name: "Tone page", source: .browser(settings)); page.audio = LayerAudio(enabled: true); layers.append(page)
            }
            let clip = folder.appendingPathComponent("clip.mov")
            if FileManager.default.fileExists(atPath: clip.path) {
                let asset = MediaAsset(name: "Tone clip", fileExtension: "mov")
                try? FileManager.default.removeItem(at: model.preferencesStore.mediaURL(asset))
                try FileManager.default.copyItem(at: clip, to: model.preferencesStore.mediaURL(asset))
                var layer = SceneLayer(name: "Tone clip", source: .clip(asset)); layer.audio = LayerAudio(enabled: true); layers.append(layer)
            }
            // Layers run front to back: the sources side by side in front, the full-canvas webcam behind them.
            for i in layers.indices {
                var placement = LayerPlacement(); placement.x = 0.05 + Double(i) * 0.3; placement.y = 0.6
                placement.width = 0.28; placement.height = 0.3; layers[i].placement = placement
            }
            layers.append(SceneLayer(name: "Webcam", source: .camera))
            var scene = model.scenes[0]; scene.layers = layers; model.scenes[0] = scene
            model.selectScene(0)
            let seconds = (try? String(contentsOf: folder.appendingPathComponent("seconds.txt"), encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 6
            let own = OwnOutputMeter()
            try await own.start()
            if let control = NSSound(contentsOf: folder.appendingPathComponent("control.wav"), byReference: true) {
                control.volume = 0.001; control.play()
                try await Task.sleep(nanoseconds: 1_500_000_000); control.stop()
                result["ownOutputControlPeak"] = Double(own.takePeakDB())
            }
            // Browser sound starts after macOS's permission prompt (answered whenever the person sees it) and the search.
            // The scene runs first (a preview), so the browser capture starts and the recording begins only once it is ready.
            if layers.contains(where: \.source.isBrowser) {
                model.start(publish: false)
                let asked = Date(), deadline = Date().addingTimeInterval(300)
                while model.audioRuntime?.browserSoundReady != true, model.channelFailures[AudioChannelID.browser] == nil, Date() < deadline {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                result["browserSoundReadyAfter"] = Date().timeIntervalSince(asked)
                result["browserSearch"] = WebKitAudioFinder.lastReport
            }
            model.startRecording()
            let deadline = Date().addingTimeInterval(20)
            while model.recording == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            guard model.recording != nil else { throw CameraError.message("Recording did not start: \(model.status)") }
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, model.recording != nil {
                try await Task.sleep(nanoseconds: 100_000_000)
                for (id, level) in model.audioLevels { peaks[id] = max(peaks[id] ?? -120, level.peakDB) }
                peaks["mix"] = max(peaks["mix"] ?? -120, model.mixLevel.peakDB)
            }
            result["ownOutputPeakWhileRecording"] = Double(own.takePeakDB())
            await own.stop()
            result["notes"] = model.channelNotes
            result["microphoneUsers"] = AudioInputUsers.current().map { "\($0.bundleID) (\($0.pid))" }
            if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
                result["applications"] = content.applications.filter { !$0.bundleIdentifier.hasPrefix("com.apple.") }.map { "\($0.bundleIdentifier) (\($0.processID))" }
            }
            model.stopRecording()
            while model.recording != nil { try await Task.sleep(nanoseconds: 50_000_000) }
            result["file"] = model.lastRecording?.path ?? ""
            result["tracks"] = ["Mix"] + model.recordedChannels().map(\.name)
        } catch { result["error"] = error.localizedDescription }
        result["status"] = model.status
        result["failures"] = model.channelFailures
        result["peaks"] = peaks.mapValues { Double($0) }
        result["channels"] = model.mixerRows.map { ["id": $0.id, "name": $0.name] }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("result.json"))
        }
        model.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }
}

/// Peak level of everything AppleCam (and its WebKit helpers) plays, from ScreenCaptureKit.
private final class OwnOutputMeter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var stream: SCStream?
    @MainActor func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first,
              let ours = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
            throw CameraError.message("AppleCam's own output cannot be measured.")
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000; configuration.channelCount = 2
        configuration.width = 2; configuration.height = 2; configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let next = SCStream(filter: SCContentFilter(display: display, including: [ours], exceptingWindows: []), configuration: configuration, delegate: nil)
        try next.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "own-output"))
        try await next.startCapture(); stream = next
    }
    func stop() async { try? await stream?.stopCapture(); stream = nil }
    /// The peak since the last call, in dBFS.
    func takePeakDB() -> Float { lock.withLock { defer { peak = 0 }; return AudioMath.decibels(peak) } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            var local: Float = 0
            for buffer in list { if let data = buffer.mData { let samples = data.assumingMemoryBound(to: Float.self); for i in 0..<Int(buffer.mDataByteSize) / 4 { local = max(local, abs(samples[i])) } } }
            lock.withLock { peak = max(peak, local) }
        }
    }
}
#endif
