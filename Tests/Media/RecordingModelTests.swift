import XCTest
import AVFoundation
import AppleCamCore
@testable import AppleCamMedia

@MainActor final class RecordingModelTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func wait(_ timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func model() throws -> (CameraModel, URL) {
        let model = CameraModel(preferencesStore: PreferencesStore(directory: directory()))
        model.selection = "pattern"
        let folder = directory()
        try model.setRecordingFolder(folder)
        return (model, folder)
    }

    func testRecordStartsAPreviewWritesAFileAndStopSavesIt() async throws {
        let (model, folder) = try model()
        XCTAssertFalse(model.running); XCTAssertTrue(model.canRecord)
        model.startRecording()
        try await wait { model.recording != nil }
        XCTAssertTrue(model.running); XCTAssertFalse(model.publishing, "Record starts a local preview, never sending")
        XCTAssertFalse(model.canChangeChannels, "Tracks are fixed while recording")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        model.updateRecordingProgress()
        XCTAssertGreaterThan(model.recording?.bytes ?? 0, 0)
        model.stopRecording()
        try await wait { model.recording == nil && model.lastRecording != nil }
        XCTAssertTrue(model.running, "Stopping the recording leaves the preview running")
        let file = try XCTUnwrap(model.lastRecording)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(file.lastPathComponent.hasPrefix("AppleCam ")); XCTAssertEqual(file.pathExtension, "mov")
        XCTAssertTrue(model.status.contains("Recording saved"))
        let duration = try await AVURLAsset(url: file).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.8)
        model.stop()
    }
    func testStopEndsRecordingAndPreviewTogether() async throws {
        let (model, _) = try model()
        model.startRecording()
        try await wait { model.recording != nil }
        try await Task.sleep(nanoseconds: 500_000_000)
        model.stop()
        try await wait { model.recording == nil && model.lastRecording != nil }
        XCTAssertFalse(model.running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.lastRecording!.path))
    }
    func testAFailingChannelStopsTheRecordingWithAnExplanation() async throws {
        let (model, _) = try model()
        model.startRecording()
        try await wait { model.recording != nil }
        try await Task.sleep(nanoseconds: 500_000_000)
        model.audioChannelFailed("mic:test", message: "Yeti was disconnected.")
        try await wait { model.recording == nil }
        XCTAssertTrue(model.status.contains("Yeti was disconnected."), model.status)
        XCTAssertTrue(model.status.contains("keeps everything up to that point"), model.status)
        XCTAssertEqual(model.channelFailures["mic:test"], "Yeti was disconnected.")
        model.stop()
    }
    func testMissingFolderIsExplained() throws {
        let model = CameraModel(preferencesStore: PreferencesStore(directory: directory()))
        let gone = directory().appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try model.setRecordingFolder(gone)
        try FileManager.default.removeItem(at: gone)
        XCTAssertNil(model.openRecordingFolder())
        XCTAssertTrue(model.status.contains("no longer exists"), model.status)
    }
    func testFolderAndAudioSettingsAreSaved() throws {
        let store = PreferencesStore(directory: directory())
        let model = CameraModel(preferencesStore: store)
        let folder = directory()
        try model.setRecordingFolder(folder)
        model.audio.master.volume = -3
        model.saveCurrentPreferences()
        let restored = CameraModel(preferencesStore: PreferencesStore(directory: store.directory))
        XCTAssertEqual(restored.recordingFolderName, folder.lastPathComponent)
        XCTAssertEqual(restored.audio.master.volume, -3)
        XCTAssertEqual(restored.openRecordingFolder()?.standardizedFileURL.path, folder.standardizedFileURL.path)
    }
    func testLayerAudioAndVolumeEditsAreValidated() throws {
        let model = CameraModel(preferencesStore: PreferencesStore(directory: directory()))
        let layer = SceneLayer(name: "Clip", source: .clip(MediaAsset(name: "Clip", fileExtension: "mov")))
        let page = SceneLayer(name: "Page", source: .browser(BrowserSettings()))
        model.scenes[0].layers += [layer, page]
        model.setLayerAudio(layer.id, enabled: true); model.setLayerAudio(page.id, enabled: true)
        XCTAssertTrue(model.scenes[0].layers.first { $0.id == layer.id }!.hasAudio)
        XCTAssertEqual(model.mixerRows.map(\.name), ["Clip", "Browser pages"], "Browser layers share one channel")
        XCTAssertEqual(model.recordedChannels().map(\.id), [layer.id.uuidString, "browser"])
        model.setMix("browser") { $0.muted = true }
        XCTAssertTrue(model.audio.browser.muted)
        model.setMix(layer.id.uuidString) { $0.volume = -12 }
        XCTAssertEqual(model.scenes[0].layers.first { $0.id == layer.id }!.audio?.mix.volume, -12)
        model.setMix(layer.id.uuidString) { $0.volume = 40 }
        XCTAssertEqual(model.scenes[0].layers.first { $0.id == layer.id }!.audio?.mix.volume, -12, "An invalid volume is rejected")
        let webcam = try XCTUnwrap(model.scenes[0].layers.first { $0.source == .camera })
        model.setLayerAudio(webcam.id, enabled: true)
        XCTAssertFalse(model.scenes[0].layers.first { $0.id == webcam.id }!.hasAudio, "The webcam picture has no sound")
    }
}
