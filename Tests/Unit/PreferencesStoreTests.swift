import XCTest
@testable import AppleCamCore

final class PreferencesStoreTests: XCTestCase {
    private func store() throws -> PreferencesStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PreferencesStore(directory: directory)
    }
    func testNewStoreHasNoSavedSettings() throws { XCTAssertNil(try store().load()) }
    func testAllPreferencesRoundTripIncludingSixSamples() throws {
        let store = try store()
        var settings = SavedPreferences()
        settings.cameraID = "brio-fixture"; settings.cameraName = "BRIO"
        settings.key.color = SIMD3(0.1, 0.9, 0.1)
        settings.key.additionalColors = (1...5).map { SIMD3(Float($0) / 100, 0.8, 0.1) }
        settings.key.tolerance = 0.23; settings.key.softness = 0.07
        settings.key.protection = 0.8; settings.key.fillHoles = 0.2; settings.key.spill = 0.95
        settings.preview = .mask
        settings = try store.importBackground(Data([1, 2, 3]), name: "Fixture.png", settings: settings)
        settings.greenScreen = true
        try store.save(settings)
        let reopened = PreferencesStore(directory: store.directory)
        XCTAssertEqual(try reopened.load(), settings)
        XCTAssertEqual(try Data(contentsOf: reopened.backgroundURL(try XCTUnwrap(settings.background))), Data([1, 2, 3]))
        let text = try String(contentsOf: store.settingsURL, encoding: .utf8)
        XCTAssertFalse(text.contains("publishing")); XCTAssertFalse(text.contains("running"))
    }
    func testInvalidSettingsDoNotReplaceLastValidSnapshot() throws {
        let store = try store(); let valid = SavedPreferences()
        try store.save(valid)
        var invalid = valid; invalid.key.softness = 0
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load(), valid)
        invalid = valid; invalid.greenScreen = true
        XCTAssertThrowsError(try store.save(invalid))
    }
    func testCorruptAndFutureSettingsAreReportedWithoutRewriting() throws {
        let store = try store(); try store.save(SavedPreferences())
        let invalid = Data("broken".utf8)
        try invalid.write(to: store.settingsURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.settingsURL), invalid)
        var future = SavedPreferences(); future.version = 99
        try JSONEncoder().encode(future).write(to: store.settingsURL)
        XCTAssertThrowsError(try store.load())
    }
    func testReplacingBackgroundRemovesOnlyPreviousManagedCopy() throws {
        let store = try store()
        let first = try store.importBackground(Data([1]), name: "../original.png", settings: SavedPreferences())
        let oldURL = store.backgroundURL(try XCTUnwrap(first.background))
        XCTAssertEqual(oldURL.deletingLastPathComponent().path, store.directory.path)
        let next = try store.importBackground(Data([2]), name: "next.png", settings: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try Data(contentsOf: store.backgroundURL(try XCTUnwrap(next.background))), Data([2]))
    }
    func testFailedSettingsCommitDoesNotLeaveNewBackground() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.settingsURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.importBackground(Data([1]), name: "Fixture.png", settings: SavedPreferences()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), ["preferences.json"])
    }
}
