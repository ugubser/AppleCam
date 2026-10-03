import XCTest
import AppleCamCore
@testable import AppleCamMedia

final class CameraPreferencesTests: XCTestCase {
    private func store() throws -> PreferencesStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PreferencesStore(directory: directory)
    }
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("artifacts/fixtures/AppleCam-sample-background.png")
    }
    @MainActor func testModelAutomaticallySavesAndRestoresWithoutStartingCapture() throws {
        let store = try store()
        let model = CameraModel(preferencesStore: store)
        model.selection = "missing-brio-fixture"
        try model.importBackground(fixture)
        model.setGreenScreen(true); model.previewMode = .mask
        var key = model.key
        try key.sample(SIMD3(0.1, 0.8, 0.1), append: false)
        try key.sample(SIMD3(0.1, 0.6, 0.1), append: true)
        key.tolerance = 0.22; key.softness = 0.03; key.protection = 0.8; key.fillHoles = 0.15; key.spill = 0.9
        model.key = key
        let restored = CameraModel(preferencesStore: PreferencesStore(directory: store.directory))
        XCTAssertEqual(restored.key, key); XCTAssertEqual(restored.selection, model.selection)
        XCTAssertTrue(restored.selectedCameraUnavailable)
        XCTAssertEqual(restored.backgroundName, fixture.lastPathComponent)
        XCTAssertTrue(restored.useGreenScreen); XCTAssertEqual(restored.previewMode, .mask)
        XCTAssertFalse(restored.running); XCTAssertFalse(restored.publishing); XCTAssertFalse(restored.busy)
        XCTAssertFalse(restored.settingsError)
        restored.setGreenScreen(false)
        let again = CameraModel(preferencesStore: PreferencesStore(directory: store.directory))
        XCTAssertFalse(again.useGreenScreen); XCTAssertEqual(again.previewMode, .composite)
        XCTAssertEqual(again.key, key)
    }
    @MainActor func testImportedBackgroundSurvivesOriginalRemoval() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let original = store.directory.appendingPathComponent("original.png")
        try FileManager.default.copyItem(at: fixture, to: original)
        let model = CameraModel(preferencesStore: store)
        try model.importBackground(original); model.setGreenScreen(true)
        try FileManager.default.removeItem(at: original)
        let restored = CameraModel(preferencesStore: PreferencesStore(directory: store.directory))
        XCTAssertTrue(restored.status.contains("Settings restored"))
        XCTAssertTrue(restored.useGreenScreen)
    }
    @MainActor func testMissingSavedBackgroundCannotStartUnprocessedInstead() throws {
        let store = try store()
        // Build a valid saved request whose managed image is missing.
        var settings = SavedPreferences()
        settings.background = SavedBackground(name: "Missing.png"); settings.greenScreen = true
        try store.save(settings)
        let restored = CameraModel(preferencesStore: store)
        XCTAssertTrue(restored.useGreenScreen)
        restored.start(publish: true)
        XCTAssertFalse(restored.running); XCTAssertFalse(restored.busy); XCTAssertFalse(restored.publishing)
        XCTAssertTrue(restored.status.contains("Choose a background"))
    }
    @MainActor func testUnreadableSettingsRequireExplicitReplacement() throws {
        let store = try store(); try store.save(SavedPreferences())
        let invalid = Data("broken".utf8); try invalid.write(to: store.settingsURL)
        let model = CameraModel(preferencesStore: store)
        XCTAssertTrue(model.settingsError); XCTAssertTrue(model.restorationFailed)
        model.key.tolerance = 0.3
        model.start(publish: false)
        XCTAssertFalse(model.busy); XCTAssertFalse(model.running)
        XCTAssertEqual(try Data(contentsOf: store.settingsURL), invalid)
        model.saveCurrentPreferences()
        XCTAssertFalse(model.settingsError); XCTAssertFalse(model.restorationFailed)
        XCTAssertEqual(try store.load()?.key.tolerance, 0.3)
    }
    @MainActor func testSaveFailureIsVisibleWithoutClaimingSuccess() throws {
        let store = try store()
        try Data([0]).write(to: store.directory)
        let model = CameraModel(preferencesStore: store)
        model.key.tolerance = 0.2
        XCTAssertTrue(model.settingsError)
        XCTAssertTrue(model.settingsMessage.contains("could not be saved"))
    }
}
