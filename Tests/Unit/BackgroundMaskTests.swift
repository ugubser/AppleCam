import XCTest
@testable import AppleCamCore

final class BackgroundMaskTests: XCTestCase {
    func testSettingsRanges() {
        XCTAssertTrue(DifferenceKeySettings().isValid)
        var settings = DifferenceKeySettings(); settings.threshold = 0.6; XCTAssertFalse(settings.isValid)
        settings = DifferenceKeySettings(); settings.softness = 0; XCTAssertFalse(settings.isValid)
        settings = DifferenceKeySettings(); settings.lighting = .nan; XCTAssertFalse(settings.isValid)
        settings = DifferenceKeySettings(); settings.cleanup = 1.1; XCTAssertFalse(settings.isValid)
    }
    func testMatchingColourIsRemovedAndDifferentColourKept() {
        let settings = DifferenceKeySettings(), wall = SIMD3<Float>(0.62, 0.58, 0.50)
        XCTAssertEqual(DifferenceKey.alpha(wall, plate: wall, settings: settings), 0)
        XCTAssertEqual(DifferenceKey.alpha(SIMD3(0.2, 0.3, 0.7), plate: wall, settings: settings), 1)
        // Inside the softness range the result is partly transparent.
        let partial = DifferenceKey.alpha(wall + SIMD3(0.12, -0.02, -0.02), plate: wall, settings: settings)
        XCTAssertGreaterThan(partial, 0.05); XCTAssertLessThan(partial, 0.95)
    }
    func testLightingSettingSeparatesBrightnessFromColour() {
        var settings = DifferenceKeySettings()
        let wall = SIMD3<Float>(0.5, 0.5, 0.5), shadow = SIMD3<Float>(0.3, 0.3, 0.3), red = SIMD3<Float>(0.70, 0.40, 0.40)
        settings.lighting = 0
        XCTAssertEqual(DifferenceKey.alpha(shadow, plate: wall, settings: settings), 1, "A brightness change counts fully")
        settings.lighting = 1
        XCTAssertEqual(DifferenceKey.alpha(shadow, plate: wall, settings: settings), 0, "A pure brightness change is ignored")
        XCTAssertEqual(DifferenceKey.alpha(red, plate: wall, settings: settings), 1, "Colour changes still count")
        XCTAssertEqual(DifferenceKey.distance(shadow, wall, lighting: 0.5), 0.1, accuracy: 1e-5)
    }
    func testCleanupFillsEnclosedHolesAndClearsIsolatedSpecks() {
        XCTAssertEqual(DifferenceKey.clean(alpha: 0, ringMinimum: 1, ringMaximum: 1, strength: 1), 1)
        XCTAssertEqual(DifferenceKey.clean(alpha: 1, ringMinimum: 0, ringMaximum: 0, strength: 1), 0)
        XCTAssertEqual(DifferenceKey.clean(alpha: 0.7, ringMinimum: 0.2, ringMaximum: 0.9, strength: 1), 0.7, "Edges are left alone")
        XCTAssertEqual(DifferenceKey.clean(alpha: 1, ringMinimum: 0, ringMaximum: 0, strength: 0), 1)
        XCTAssertEqual(DifferenceKey.clean(alpha: 1, ringMinimum: 0, ringMaximum: 0, strength: 0.5), 0.5, accuracy: 1e-6)
    }
    func testPictureOnlyMatchesItsOwnFrameSize() {
        let plate = BackgroundPlate(width: 1920, height: 1080)
        XCTAssertNil(plate.mismatch(width: 1920, height: 1080))
        let message = try? XCTUnwrap(plate.mismatch(width: 1280, height: 720))
        XCTAssertTrue(message?.contains("1920 × 1080") == true && message?.contains("1280 × 720") == true)
        XCTAssertFalse(BackgroundPlate(width: 0, height: 1080).isValid)
    }
    func testProfileAllowsOnlyOneKeyingModeAndNeedsAPicture() {
        var profile = CameraProfile()
        XCTAssertTrue(profile.isValid); XCTAssertFalse(profile.mask.enabled)
        profile.mask.enabled = true
        XCTAssertFalse(profile.isValid, "Background mask without a picture")
        profile.mask.plate = BackgroundPlate(width: 64, height: 32)
        XCTAssertTrue(profile.isValid)
        profile.greenScreen = true
        XCTAssertFalse(profile.isValid, "Green screen and background mask together")
    }
    func testSettingsFromEarlierVersionsDecodeWithoutBackgroundMask() throws {
        var profile = CameraProfile(); profile.cameraName = "Old"
        let data = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("backgroundMask"))
        let decoded = try JSONDecoder().decode(CameraProfile.self, from: data)
        XCTAssertNil(decoded.backgroundMask); XCTAssertEqual(decoded.mask, BackgroundMaskProfile())
    }
    func testPicturesAreReferencedAndReplacedPicturesRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PreferencesStore(directory: directory)
        var settings = SavedPreferences(); settings.cameraID = "camera-a"
        let first = BackgroundPlate(width: 4, height: 2)
        settings.profile.mask.plate = first; settings.profile.mask.enabled = true
        XCTAssertTrue(settings.mediaReferences.contains(first.asset))
        try store.importPlate(Data([1, 2, 3]), plate: first, settings: settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaURL(first.asset).path))
        let reloaded = try XCTUnwrap(store.load())
        XCTAssertEqual(reloaded.profile.mask.plate, first); XCTAssertTrue(reloaded.profile.mask.enabled)
        let second = BackgroundPlate(width: 4, height: 2)
        settings.profile.mask.plate = second
        try store.importPlate(Data([4, 5, 6]), plate: second, settings: settings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(first.asset).path), "The replaced picture is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaURL(second.asset).path))
        // A picture the settings do not refer to is rejected before anything is written.
        XCTAssertThrowsError(try store.importPlate(Data([7]), plate: BackgroundPlate(width: 4, height: 2), settings: settings))
    }
}
