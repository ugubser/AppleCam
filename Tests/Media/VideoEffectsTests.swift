import XCTest
import AppleCamCore
@testable import AppleCamMedia

final class VideoEffectsTests: XCTestCase {
    func testSummaryNamesWhatMacOSOffersAtTheSize() {
        let all = VideoEffects(reactions: true, portrait: true, studioLight: true, background: true)
        let none = VideoEffects(reactions: false, portrait: false, studioLight: false, background: false)
        let some = VideoEffects(reactions: true, portrait: false, studioLight: true, background: false)
        XCTAssertEqual(VideoEffects.summary(all, size: "1920 × 1080", unavailable: "-"), "All available at 1920 × 1080")
        XCTAssertEqual(VideoEffects.summary(none, size: "4096 × 2160", unavailable: "-"), "Not available at 4096 × 2160")
        XCTAssertEqual(VideoEffects.summary(some, size: "1280 × 720", unavailable: "-"), "Reactions, Studio Light at 1280 × 720")
        XCTAssertEqual(VideoEffects.summary(nil, size: "1920 × 1080", unavailable: "Install the camera extension to check"),
            "Install the camera extension to check")
        XCTAssertEqual(some.names, ["Reactions", "Studio Light"])
    }
    func testVirtualCameraReportsNothingForASizeItDoesNotOffer() {
        XCTAssertNil(VideoEffects.virtualCamera(width: 4092, height: 2160))
    }
    @MainActor func testTestPatternHasNoWebcamEffectsAndNoEffectsMenu() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = CameraModel(preferencesStore: PreferencesStore(directory: directory))
        model.selection = "pattern"
        XCTAssertNil(model.webcamEffects)
        XCTAssertFalse(model.canShowVideoEffects, "The Video Effects menu needs a running webcam scene")
    }
}
