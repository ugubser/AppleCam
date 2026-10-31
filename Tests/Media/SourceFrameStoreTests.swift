import XCTest
import CoreMedia
import CoreImage
import ScreenCaptureKit
import AppleCamCore
@testable import AppleCamMedia

final class SourceFrameStoreTests: XCTestCase {
    private func sample(_ status: SCFrameStatus) throws -> CMSampleBuffer {
        let image = try GreenScreenProcessor.makeBuffer(width: 16, height: 8)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        let array = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true)! as NSArray
        let info = array[0] as! NSMutableDictionary
        info[SCStreamFrameInfo.status.rawValue] = status.rawValue
        return result
    }
    func testIdleRetainsStaticContentButSuspensionNeverReplaysOldPixels() throws {
        let store = SourceFrameStore(); store.begin()
        store.receive(try sample(.complete)); XCTAssertNotNil(try store.image())
        store.receive(try sample(.idle)); XCTAssertNotNil(try store.image())
        store.receive(try sample(.suspended)); XCTAssertNil(try store.image())
        store.receive(try sample(.complete)); XCTAssertNotNil(try store.image())
        store.receive(try sample(.stopped)); XCTAssertThrowsError(try store.image())
    }
    func testStoppedCaptureIgnoresLateFramesAndErrors() throws {
        let store = SourceFrameStore(); store.begin(); store.end()
        store.receive(try sample(.complete)); store.fail(NSError(domain: "fixture", code: 1))
        XCTAssertNil(try store.image())
    }
    func testBrowserSnapshotsKeepRequestTimeAndRejectLateRepliesAfterStop() throws {
        let context = CIContext()
        let picture = try XCTUnwrap(context.createCGImage(CIImage(color: .red), from: CGRect(x: 0, y: 0, width: 16, height: 8)))
        let store = BrowserFrameStore(); store.begin(); store.set(picture, at: 1)
        XCTAssertNotNil(store.image(at: 1.1)); XCTAssertNil(store.image(at: 1.151))
        store.end(); store.set(picture, at: 2); XCTAssertNil(store.image(at: 2.01))
        store.begin(); XCTAssertNil(store.image(at: 2.01))
    }
}

final class SnapshotFailureWindowTests: XCTestCase {
    func testSingleFailuresAreTransientAndSuccessResetsTheWindow() {
        var window = SnapshotFailureWindow()
        XCTAssertFalse(window.failed(at: 10))
        XCTAssertFalse(window.failed(at: 11.9))
        window.succeeded()
        XCTAssertFalse(window.failed(at: 12.5), "A success restarts the two-second window")
        XCTAssertFalse(window.failed(at: 14.4))
    }
    func testPersistentFailureBecomesFatalAfterTwoSeconds() {
        var window = SnapshotFailureWindow()
        XCTAssertFalse(window.failed(at: 5))
        XCTAssertTrue(window.failed(at: 7))
    }
}

final class CaptureSelectionTests: XCTestCase {
    private let own: pid_t = 100
    private func window(layer: Int = 0, width: Double = 800, height: Double = 600, pid: pid_t? = 200, onScreen: Bool = true) -> WindowCandidate {
        WindowCandidate(layer: layer, width: width, height: height, processID: pid, onScreen: onScreen)
    }
    func testOrdinaryVisibleWindowsOfOtherAppsAreSelectable() {
        XCTAssertTrue(CaptureSelection.isSelectable(window(), ownProcess: own))
    }
    func testMenusOwnWindowsTinyAndHiddenWindowsAreExcluded() {
        XCTAssertFalse(CaptureSelection.isSelectable(window(layer: 25), ownProcess: own), "Menu bar / status items")
        XCTAssertFalse(CaptureSelection.isSelectable(window(pid: own), ownProcess: own), "AppleCam's own windows would recurse")
        XCTAssertFalse(CaptureSelection.isSelectable(window(pid: nil), ownProcess: own))
        XCTAssertFalse(CaptureSelection.isSelectable(window(width: 40), ownProcess: own))
        XCTAssertFalse(CaptureSelection.isSelectable(window(onScreen: false), ownProcess: own))
    }
    @MainActor func testCaptureLayersWithoutPermissionReportThePermissionStep() async throws {
        try XCTSkipIf(CaptureSelection.hasAccess, "This runner already has Screen Recording permission")
        let runtime = SceneRuntime(store: PreferencesStore(directory: FileManager.default.temporaryDirectory))
        let reference = WindowReference(windowID: 42, processID: 10, applicationID: "fixture", launchTime: 100, title: "Slides")
        let scene = CameraScene(name: "Capture", layers: [SceneLayer(name: "Slides", source: .window(reference))])
        do { _ = try await runtime.missingSource(in: scene); XCTFail("Missing permission must be reported") }
        catch { XCTAssertEqual(error.localizedDescription, CaptureSelection.permissionMessage) }
        let none = try await runtime.missingSource(in: CameraScene(name: "No capture", layers: [SceneLayer(name: "Me", source: .camera)]))
        XCTAssertNil(none, "Scenes without capture layers never need the permission")
    }
}
