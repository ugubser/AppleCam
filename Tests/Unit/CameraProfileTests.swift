import XCTest
@testable import AppleCamCore

final class CameraProfileTests: XCTestCase {
    func testLegacySettingsMigrateAllCalibrationToOriginalCameraAndFirstButton() throws {
        var key = KeySettings(); key.additionalColors = [SIMD3(0.2, 0.7, 0.1)]; key.protection = 0.8
        let background = SavedBackground(name: "Original.png")
        struct Legacy: Encodable {
            let version = 1, cameraID = "old-camera", cameraName = "Original camera", greenScreen = true
            let preview = KeyPreview.mask
            let key: KeySettings
            let background: SavedBackground
        }
        let migrated = try JSONDecoder().decode(SavedPreferences.self, from: JSONEncoder().encode(Legacy(key: key, background: background)))
        XCTAssertEqual(migrated.version, 2); XCTAssertEqual(migrated.profiles.count, 1)
        XCTAssertEqual(migrated.cameraID, "old-camera"); XCTAssertEqual(migrated.key, key)
        XCTAssertEqual(migrated.profile.backgrounds, [background, nil, nil, nil])
        XCTAssertEqual(migrated.profile.capture, CaptureConfiguration())
        XCTAssertTrue(migrated.greenScreen); XCTAssertEqual(migrated.preview, .mask)
        XCTAssertEqual(try JSONDecoder().decode(SavedPreferences.self, from: JSONEncoder().encode(migrated)), migrated)
    }
    func testImageCleanupRetainsButtonsAndOtherCameraProfiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PreferencesStore(directory: directory)
        var settings = SavedPreferences(); settings.cameraID = "first"
        settings = try store.importBackground(Data([1]), name: "One.png", settings: settings, slot: 0)
        let first = try XCTUnwrap(settings.background)
        settings = try store.importBackground(Data([2]), name: "Two.png", settings: settings, slot: 1)
        let second = try XCTUnwrap(settings.background)
        settings.cameraID = "second"
        settings = try store.importBackground(Data([3]), name: "Three.png", settings: settings, slot: 3)
        settings.profile.capture = .init(width: 3840, height: 2160, fps: 24)
        settings.profile.controlsExpanded = false
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        XCTAssertEqual(try Data(contentsOf: store.backgroundURL(first)), Data([1]))
        XCTAssertEqual(try Data(contentsOf: store.backgroundURL(second)), Data([2]))
        settings.cameraID = "first"
        settings.profile.backgrounds[0] = nil
        try store.save(settings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backgroundURL(first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backgroundURL(second).path))
        let third = try XCTUnwrap(settings.profiles["second"]?.background)
        XCTAssertEqual(try Data(contentsOf: store.backgroundURL(third)), Data([3]))
    }
    func testMalformedButtonCountIsRejected() throws {
        var settings = SavedPreferences(); settings.profile.backgrounds = []
        XCTAssertThrowsError(try settings.validate())
        XCTAssertThrowsError(try JSONDecoder().decode(SavedPreferences.self, from: JSONEncoder().encode(settings)))
    }
}
