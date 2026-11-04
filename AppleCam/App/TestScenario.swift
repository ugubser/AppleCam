#if DEBUG
import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Debug builds only: `--test-audio-scenario <folder>` runs an unattended end-to-end recording for verification.
/// The folder (inside the app container) holds `page-url.txt` and optionally `clip.mov`; the app builds Scene 1 with the
/// test-pattern webcam, the main screen, the page and the clip (all with audio on), records `seconds.txt` seconds
/// (default 6) into `<folder>/out`, writes `<folder>/result.json`, and quits.
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
#endif
