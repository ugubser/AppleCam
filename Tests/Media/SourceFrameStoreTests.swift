import XCTest
import CoreMedia
import CoreImage
import ScreenCaptureKit
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
