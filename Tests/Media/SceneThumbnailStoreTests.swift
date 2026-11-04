import XCTest
import CoreGraphics
import AppleCamCore
@testable import AppleCamMedia

final class SceneThumbnailStoreTests: XCTestCase {
    private func directory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory
    }
    /// A 32 × 18 picture, left half red and right half blue.
    private func picture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 16, height: 18))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); context.fill(CGRect(x: 16, y: 0, width: 16, height: 18))
        return try XCTUnwrap(context.makeImage())
    }

    func testPicturesSurviveAndOnlyCurrentScenesAreKept() throws {
        let store = SceneThumbnailStore(directory: directory())
        let kept = UUID(), removed = UUID()
        try store.save(picture(), scene: kept); try store.save(picture(), scene: removed)
        try Data("not a picture".utf8).write(to: store.url(for: UUID()))
        let loaded = store.load(scenes: [kept, UUID()])
        XCTAssertEqual(Array(loaded.keys), [kept])
        XCTAssertEqual(loaded[kept]?.width, 32); XCTAssertEqual(loaded[kept]?.height, 18)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(files, ["\(kept.uuidString).jpg"], "Pictures of deleted scenes and unreadable files are removed")
    }
    func testSavingReplacesTheEarlierPicture() throws {
        let store = SceneThumbnailStore(directory: directory()), scene = UUID()
        try store.save(picture(), scene: scene)
        let small = try XCTUnwrap(picture().cropping(to: CGRect(x: 0, y: 0, width: 8, height: 8)))
        try store.save(small, scene: scene)
        XCTAssertEqual(store.load(scenes: [scene])[scene]?.width, 8)
    }
    func testNoFolderMeansNoPictures() {
        XCTAssertTrue(SceneThumbnailStore(directory: directory()).load(scenes: [UUID()]).isEmpty)
    }
    @MainActor func testScenePicturesAreRestoredAfterRestart() throws {
        let preferences = PreferencesStore(directory: directory())
        let model = CameraModel(preferencesStore: preferences)
        model.saveCurrentPreferences()
        let scene = model.scenes[2].id
        model.sceneThumbnails[scene] = try picture(); model.thumbnailArrived(scene)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SceneThumbnailStore(preferences: preferences).url(for: scene).path),
            "The first picture of a scene is written straight away")
        let restarted = CameraModel(preferencesStore: PreferencesStore(directory: preferences.directory))
        XCTAssertEqual(restarted.scenes[2].id, scene)
        XCTAssertEqual(restarted.sceneThumbnails[scene]?.width, 32)
        XCTAssertNil(restarted.sceneThumbnails[restarted.scenes[0].id])
    }
    @MainActor func testLaterPicturesAreWrittenOnStop() throws {
        let preferences = PreferencesStore(directory: directory())
        let model = CameraModel(preferencesStore: preferences)
        model.saveCurrentPreferences()
        let scene = model.scenes[0].id, file = SceneThumbnailStore(preferences: preferences).url(for: scene)
        model.sceneThumbnails[scene] = try picture(); model.thumbnailArrived(scene)
        // A newer picture within the save interval waits; stopping writes it.
        let newer = try XCTUnwrap(picture().cropping(to: CGRect(x: 0, y: 0, width: 10, height: 10)))
        model.sceneThumbnails[scene] = newer; model.thumbnailArrived(scene)
        XCTAssertEqual(SceneThumbnailStore(preferences: preferences).load(scenes: [scene])[scene]?.width, 32)
        model.stop()
        XCTAssertEqual(SceneThumbnailStore(preferences: preferences).load(scenes: [scene])[scene]?.width, 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
