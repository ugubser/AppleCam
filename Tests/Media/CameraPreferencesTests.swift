import XCTest
import AppKit
import AppleCamCore
@testable import AppleCamMedia

final class CameraPreferencesTests: XCTestCase {
    private func store() throws -> PreferencesStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return PreferencesStore(directory: directory)
    }
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("artifacts/fixtures/AppleCam-sample-background.png")
    }
    @MainActor func testSharedScenesAndCameraCalibrationSurviveCameraSwitchAndRestart() throws {
        let store = try store(), model = CameraModel(preferencesStore: store)
        model.selection = "camera-a"; model.key.protection = 0.81; model.setGreenScreen(true)
        model.captureConfiguration = .init(width: 3840, height: 2160, fps: 24); model.controlsExpanded = false
        model.outputConfiguration = .init(width: 1920, height: 1080, fps: 30)
        try model.importMedia(fixture); model.renameScene("Office")
        let imageID = try XCTUnwrap(model.selectedLayerID)
        model.updateLayer(imageID) { $0.placement.x = 0.2; $0.placement.width = 0.5; $0.name = "Logo" }
        model.selectScene(2); model.renameScene("Presentation")
        let scenes = model.scenes
        model.selection = "camera-b"
        XCTAssertEqual(model.scenes, scenes); XCTAssertEqual(model.selectedScene, 2)
        XCTAssertEqual(model.key, KeySettings()); XCTAssertFalse(model.useGreenScreen)
        model.key.spill = 0.25; model.captureConfiguration = .init(width: 1280, height: 720, fps: 60)
        model.selection = "camera-a"
        XCTAssertEqual(model.key.protection, 0.81); XCTAssertTrue(model.useGreenScreen); XCTAssertFalse(model.controlsExpanded)
        XCTAssertEqual(model.captureConfiguration, .init(width: 3840, height: 2160, fps: 24))
        XCTAssertEqual(model.outputConfiguration, .init(width: 1920, height: 1080, fps: 30))
        let restored = CameraModel(preferencesStore: PreferencesStore(directory: store.directory))
        XCTAssertEqual(restored.scenes, scenes); XCTAssertEqual(restored.selectedScene, 2)
        XCTAssertEqual(restored.key.protection, 0.81); XCTAssertFalse(restored.running); XCTAssertFalse(restored.publishing)
        restored.selection = "camera-b"; XCTAssertEqual(restored.key.spill, 0.25)
    }
    @MainActor func testImportedImageSurvivesOriginalRemoval() throws {
        let store = try store(); try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let original = store.directory.appendingPathComponent("original.png"); try FileManager.default.copyItem(at: fixture, to: original)
        let model = CameraModel(preferencesStore: store); try model.importMedia(original)
        let scenes = model.scenes
        try FileManager.default.removeItem(at: original)
        let restored = CameraModel(preferencesStore: store)
        XCTAssertEqual(restored.scenes, scenes)
        let asset = try XCTUnwrap(restored.activeScene.layers.first?.source.asset)
        XCTAssertNotNil(try StillSceneSource(url: store.mediaURL(asset)))
    }
    @MainActor func testLockedLayerRejectsPlacementAndDeletionButCanBeRenamedAndHidden() throws {
        let model = CameraModel(preferencesStore: try store()), id = try XCTUnwrap(model.selectedLayerID)
        model.updateLayer(id) { $0.locked = true }
        model.updateLayer(id) { $0.placement.x = 0.2 }
        XCTAssertEqual(model.selectedLayer?.placement.x, 0)
        model.deleteLayer(id); XCTAssertEqual(model.activeScene.layers.count, 1)
        model.updateLayer(id) { $0.name = "Me"; $0.visible = false }
        XCTAssertEqual(model.selectedLayer?.name, "Me"); XCTAssertEqual(model.selectedLayer?.visible, false)
    }
    @MainActor func testScenesHaveIndependentLayerState() throws {
        let model = CameraModel(preferencesStore: try store())
        let id = try XCTUnwrap(model.selectedLayerID)
        model.updateLayer(id) { $0.placement.width = 0.3; $0.locked = true }
        model.selectScene(1); XCTAssertEqual(model.selectedLayer?.placement.width, 1); XCTAssertEqual(model.selectedLayer?.locked, false)
        model.selectScene(0); XCTAssertEqual(model.selectedLayer?.placement.width, 0.3); XCTAssertEqual(model.selectedLayer?.locked, true)
    }
    @MainActor func testUnreadableSettingsRequireExplicitReplacement() throws {
        let store = try store(); try store.save(SavedPreferences())
        let invalid = Data("broken".utf8); try invalid.write(to: store.settingsURL)
        let model = CameraModel(preferencesStore: store)
        XCTAssertTrue(model.settingsError); XCTAssertTrue(model.restorationFailed)
        model.key.tolerance = 0.3; model.start(publish: false)
        XCTAssertFalse(model.busy); XCTAssertFalse(model.running); XCTAssertEqual(try Data(contentsOf: store.settingsURL), invalid)
        model.saveCurrentPreferences(); XCTAssertFalse(model.settingsError); XCTAssertFalse(model.restorationFailed)
        XCTAssertEqual(try store.load()?.key.tolerance, 0.3)
    }
    @MainActor func testSaveFailureIsVisibleWithoutClaimingSuccess() throws {
        let store = try store(); try Data([0]).write(to: store.directory)
        let model = CameraModel(preferencesStore: store); model.key.tolerance = 0.2
        XCTAssertTrue(model.settingsError); XCTAssertTrue(model.settingsMessage.contains("could not be saved"))
    }
    @MainActor func testQuitNotificationFlushesSceneAndCalibration() throws {
        let store = try store(), model = CameraModel(preferencesStore: store)
        model.scenes[1].name = "Quit fixture"; model.key.protection = 0.7
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(try store.load()?.scenes[1].name, "Quit fixture"); XCTAssertEqual(try store.load()?.key.protection, 0.7)
    }
    @MainActor func testNotRightNowHidesOnlyMissingLayerAndPreservesItsSourceAndPlacement() throws {
        let store = try store(), model = CameraModel(preferencesStore: store)
        let reference = WindowReference(windowID: 42, processID: 10, applicationID: "fixture", launchTime: 100, title: "Slides")
        var layer = SceneLayer(name: "Presentation window", source: .window(reference))
        layer.placement.x = 0.3; layer.placement.width = 0.4; layer.locked = true
        model.scenes[0].layers.append(layer)
        XCTAssertTrue(model.hideUnavailableLayer(layer.id))
        let hidden = try XCTUnwrap(model.activeScene.layers.last)
        XCTAssertFalse(hidden.visible); XCTAssertEqual(hidden.source, layer.source); XCTAssertEqual(hidden.placement, layer.placement)
        XCTAssertTrue(hidden.locked); XCTAssertTrue(model.activeScene.layers[0].visible)
        XCTAssertEqual(try store.load()?.scenes[0].layers.last, hidden)
    }
    @MainActor func testStopCancelsAnUnstartedSceneWorker() async throws {
        let model = CameraModel(preferencesStore: try store())
        model.start(publish: false); model.stop(); model.stop()
        for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(model.running); XCTAssertFalse(model.busy); XCTAssertFalse(model.scenePreparing); XCTAssertFalse(model.publishing)
        XCTAssertNil(model.image)
    }
}
