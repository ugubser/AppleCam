import XCTest
@testable import AppleCamCore

final class SceneTests: XCTestCase {
    func testFillAndFitMapSamplingThroughCropAndLetterbox() {
        var placement = LayerPlacement(); placement.x = 0.25; placement.y = 0.25; placement.width = 0.5; placement.height = 0.5
        let canvas = CGSize(width: 200, height: 100), source = CGSize(width: 100, height: 100)
        XCTAssertEqual(placement.contentRect(source: source, canvas: canvas), CGRect(x: 50, y: 0, width: 100, height: 100))
        let fillPoint = placement.sourcePoint(canvasPoint: CGPoint(x: 100, y: 25), source: source, canvas: canvas)
        XCTAssertEqual(fillPoint, CGPoint(x: 0.5, y: 0.25))
        placement.sizing = .fit
        XCTAssertEqual(placement.contentRect(source: source, canvas: canvas), CGRect(x: 75, y: 25, width: 50, height: 50))
        XCTAssertNil(placement.sourcePoint(canvasPoint: CGPoint(x: 60, y: 50), source: source, canvas: canvas))
        XCTAssertEqual(placement.sourcePoint(canvasPoint: CGPoint(x: 100, y: 50), source: source, canvas: canvas), CGPoint(x: 0.5, y: 0.5))
    }
    func testReorderingCannotMoveOrCrossLockedRows() {
        var scene = CameraScene(name: "Fixture", layers: (0..<4).map { SceneLayer(name: "\($0)", source: .camera) })
        let id = scene.layers[3].id
        XCTAssertTrue(scene.move(id, to: 0)); XCTAssertEqual(scene.layers.map(\.name), ["3", "0", "1", "2"])
        scene.layers[1].locked = true
        XCTAssertFalse(scene.move(id, to: 2)); XCTAssertFalse(scene.move(scene.layers[1].id, to: 0))
        XCTAssertTrue(scene.move(scene.layers[3].id, to: 2))
    }
    func testSceneValidationRejectsDuplicateIDsInvalidTransformsAndUnsafeAssetNames() throws {
        var settings = SavedPreferences()
        settings.scenes[0].layers.append(settings.scenes[0].layers[0]); XCTAssertThrowsError(try settings.validate())
        settings = SavedPreferences(); settings.scenes[0].layers[0].placement.width = .nan; XCTAssertThrowsError(try settings.validate())
        settings = SavedPreferences(); settings.scenes[0].layers[0].source = .image(MediaAsset(name: "bad", fileExtension: "../mov")); XCTAssertThrowsError(try settings.validate())
        XCTAssertFalse(BrowserSettings(url: "file:///etc/passwd").isValid)
        XCTAssertFalse(BrowserSettings(url: "https://name:password@example.com").isValid)
        XCTAssertTrue(BrowserSettings(url: "https://www.youtube.com/watch?v=fixture").isValid)
    }
    func testHiddenMissingWindowIsValidAndDoesNotRequireCamera() throws {
        var layer = SceneLayer(name: "Unavailable", source: .window(nil)); layer.visible = false
        let scene = CameraScene(name: "Screen", layers: [layer]); XCTAssertTrue(scene.isValid); XCTAssertFalse(scene.needsCamera)
        XCTAssertEqual(try JSONDecoder().decode(CameraScene.self, from: JSONEncoder().encode(scene)), scene)
    }
    func testWindowIdentityNeverGuessesByTitleOrReusedProcessID() {
        let original = WindowReference(windowID: 1, processID: 2, applicationID: "fixture", launchTime: 10, title: "Slides")
        var renamed = original; renamed.title = "New slide"
        XCTAssertTrue(original.identifiesSameWindow(as: renamed))
        var reopened = original; reopened.windowID = 3
        XCTAssertFalse(original.identifiesSameWindow(as: reopened))
        var recycled = original; recycled.launchTime = 20
        XCTAssertFalse(original.identifiesSameWindow(as: recycled))
    }
    func testVersionTwoMigratesFourScenesAndPreservesOtherCameraAssets() throws {
        let one = SavedBackground(name: "One.png"), two = SavedBackground(name: "Two.png"), extra = SavedBackground(name: "Unsaved slot.png")
        var a = CameraProfile(); a.cameraName = "A"; a.key.protection = 0.8; a.greenScreen = true
        a.backgrounds = [one, nil, two, nil]; a.background = two
        var b = CameraProfile(); b.cameraName = "B"; b.backgrounds[1] = extra
        struct Legacy: Encodable { var version = 2; var cameraID = "a"; var profiles: [String: CameraProfile] }
        let data = try JSONEncoder().encode(Legacy(profiles: ["a": a, "b": b]))
        let migrated = try JSONDecoder().decode(SavedPreferences.self, from: data)
        XCTAssertEqual(migrated.selectedScene, 2); XCTAssertEqual(migrated.scenes.count, 4)
        XCTAssertEqual(migrated.scenes[0].layers.last?.source.asset?.id, one.id)
        XCTAssertEqual(migrated.scenes[1].layers.last?.source.asset?.id, extra.id)
        XCTAssertEqual(migrated.scenes[1].layers.last?.visible, false)
        XCTAssertEqual(migrated.key.protection, 0.8); XCTAssertTrue(migrated.greenScreen)
        XCTAssertEqual(migrated.mediaReferences.count, 3)
        XCTAssertEqual(try JSONDecoder().decode(SavedPreferences.self, from: JSONEncoder().encode(migrated)), migrated)
    }
    func testActiveBackgroundOutsideButtonsSurvivesMigrationAndBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var profile = CameraProfile(); let image = SavedBackground(name: "Active.png"); profile.background = image; profile.greenScreen = true
        struct Legacy: Encodable { var version = 2; var cameraID = "a"; var profiles: [String: CameraProfile] }
        let data = try JSONEncoder().encode(Legacy(profiles: ["a": profile]))
        let store = PreferencesStore(directory: directory)
        try data.write(to: store.settingsURL); try Data([1]).write(to: store.backgroundURL(image))
        let migrated = try XCTUnwrap(store.load()); try store.save(migrated)
        XCTAssertEqual(migrated.scenes[0].layers[1].source.asset?.id, image.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backgroundURL(image).path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("preferences-v2-before-scenes.json")), data)
    }
    func testMalformedLegacyButtonCountIsRejectedBeforeMigration() throws {
        var profile = CameraProfile(); profile.backgrounds = Array(repeating: SavedBackground(name: "Overflow"), count: 5)
        struct Legacy: Encodable { var version = 2; var cameraID = "a"; var profiles: [String: CameraProfile] }
        XCTAssertThrowsError(try JSONDecoder().decode(SavedPreferences.self, from: JSONEncoder().encode(Legacy(profiles: ["a": profile]))))
    }
    func testMediaCopiesAreRetainedAcrossScenesAndRemovedOnlyAfterLastReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("source.mov"); try Data([1, 2, 3]).write(to: original)
        let store = PreferencesStore(directory: directory), asset = MediaAsset(name: "Clip.mov", fileExtension: "mov")
        var settings = SavedPreferences()
        settings.scenes[0].layers.append(SceneLayer(name: "Clip", source: .clip(asset)))
        settings.scenes[1].layers.append(SceneLayer(name: "Same clip", source: .clip(asset)))
        try store.importMedia(from: original, asset: asset, settings: settings)
        settings.scenes[0].layers.removeLast(); try store.save(settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaURL(asset).path))
        settings.scenes[1].layers.removeLast(); try store.save(settings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(asset).path))
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3]))
    }
    func testFailedMediaImportRollsBackCopiedAsset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("source.mov"); try Data([1]).write(to: original)
        let store = PreferencesStore(directory: directory), asset = MediaAsset(name: "Clip.mov", fileExtension: "mov")
        try FileManager.default.createDirectory(at: store.settingsURL, withIntermediateDirectories: true)
        var settings = SavedPreferences(); settings.scenes[0].layers.append(SceneLayer(name: "Clip", source: .clip(asset)))
        XCTAssertThrowsError(try store.importMedia(from: original, asset: asset, settings: settings))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(asset).path)); XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testLiveRemovalDefersDeletingMediaUntilReadersDetach() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("source.mov"); try Data([1]).write(to: original)
        let store = PreferencesStore(directory: directory), asset = MediaAsset(name: "Clip.mov", fileExtension: "mov")
        var settings = SavedPreferences(); settings.scenes[0].layers.append(SceneLayer(name: "Clip", source: .clip(asset)))
        try store.importMedia(from: original, asset: asset, settings: settings)
        settings.scenes[0].layers.removeLast(); try store.save(settings, deferCleanup: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaURL(asset).path))
        store.cleanupUnusedMedia()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(asset).path))
    }
}
