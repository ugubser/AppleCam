import XCTest
import CoreMedia
import CoreImage
import AppleCamCore
@testable import AppleCamMedia

final class VideoOutputConverterTests: XCTestCase {
    private func sample() throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 80, 40, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CIContext().render(CIImage(color: .red), to: image)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: 123, timescale: 1), decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &output), noErr)
        return try XCTUnwrap(output)
    }
    func testConversionPreservesTimestampAndAspectRatioWithLetterboxing() throws {
        let original = try sample(), converter = try VideoOutputConverter()
        let result = try converter.convert(original, to: .init(width: 40, height: 40, fps: 30))
        XCTAssertEqual(result.presentationTimeStamp, original.presentationTimeStamp)
        XCTAssertEqual(result.duration.seconds, 1 / 30, accuracy: 0.00000001)
        let buffer = try XCTUnwrap(result.imageBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 40); XCTAssertEqual(CVPixelBufferGetHeight(buffer), 40)
        let image = CIImage(cvPixelBuffer: buffer), context = CIContext()
        func pixel(y: Int) -> [UInt8] {
            var value = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &value, rowBytes: 4, bounds: CGRect(x: 20, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return value
        }
        XCTAssertGreaterThan(pixel(y: 20)[0], 252)
        XCTAssertLessThan(pixel(y: 2)[0], 3); XCTAssertLessThan(pixel(y: 38)[0], 3)
    }
    func testMatchingDimensionsReuseBufferAndInvalidTargetFails() throws {
        let original = try sample(), converter = try VideoOutputConverter()
        let result = try converter.convert(original, to: .init(width: 80, height: 40, fps: 60))
        XCTAssertTrue(result === original)
        XCTAssertThrowsError(try converter.convert(original, to: .init(width: 0)))
    }
}

extension VideoOutputConverterTests {
    func testNegotiatedLowerRateUpdatesDurationWithoutCopyingPixelsOrTimestamp() throws {
        let original = try sample(), converter = try VideoOutputConverter()
        let result = try converter.convert(original, to: .init(width: 80, height: 40, fps: 24))
        XCTAssertTrue(result.imageBuffer === original.imageBuffer)
        XCTAssertEqual(result.presentationTimeStamp, original.presentationTimeStamp)
        XCTAssertEqual(result.duration.seconds, 1 / 24, accuracy: 0.00000001)
    }
}
