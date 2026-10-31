import XCTest
import CoreImage
import CoreMedia
import ImageIO
import AppleCamCore
@testable import AppleCamMedia

final class BackgroundMaskProcessorTests: XCTestCase {
    private func buffer(_ width: Int, _ height: Int, colorAt: (Int, Int) -> SIMD3<Float>) throws -> CVPixelBuffer {
        let buffer = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let c = colorAt(x, y), offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                base[offset] = UInt8((c.z * 255).rounded()); base[offset + 1] = UInt8((c.y * 255).rounded())
                base[offset + 2] = UInt8((c.x * 255).rounded()); base[offset + 3] = 255
            }
        }
        return buffer
    }
    /// A background picture made the same way the app makes one: averaged frames encoded as PNG, then decoded.
    private func plate(from frame: CVPixelBuffer) throws -> CGImage {
        var averager = try PlateAverager(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        try averager.add(frame)
        let png = try averager.result().png
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func alpha(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return Float(base[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4 + 3]) / 255
    }
    private func quantized(_ c: SIMD3<Float>) -> SIMD3<Float> { (c * 255).rounded(.toNearestOrEven) / 255 }

    func testGPUMatchesReferenceAwayFromColourBoundaries() throws {
        let width = 48, height = 24
        let wall = SIMD3<Float>(0.62, 0.58, 0.50), shelf = SIMD3<Float>(0.30, 0.22, 0.18)
        let background = try buffer(width, height) { x, _ in x < 24 ? wall : shelf }
        let keyer = try BackgroundMaskProcessor(plate: plate(from: background), id: UUID())
        // Left: the unchanged wall, a darker wall (shadow) and a soft-edge colour; right: a person in front of the shelf.
        let shadow = wall * 0.8, soft = wall + SIMD3(0.12, -0.02, -0.02), shirt = SIMD3<Float>(0.2, 0.3, 0.7)
        let camera = try buffer(width, height) { x, y in
            x >= 24 ? shirt : (y < 8 ? wall : (y < 16 ? shadow : soft))
        }
        let output = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        for lighting: Float in [0, 0.4, 1] {
            var settings = DifferenceKeySettings(); settings.cleanup = 0; settings.lighting = lighting
            try keyer.render(camera, into: output, settings: settings)
            // Rows 3–4 and 11–12 and 19–20 are at least 3 px away from every colour boundary.
            for (y, colour) in [(3, wall), (12, shadow), (20, soft)] {
                let expected = DifferenceKey.alpha(quantized(colour), plate: quantized(wall), settings: settings)
                XCTAssertEqual(alpha(output, 10, y), expected, accuracy: 2.0 / 255, "row \(y), lighting \(lighting)")
            }
            XCTAssertEqual(alpha(output, 36, 12), 1, "A different colour in front of the shelf is kept")
        }
    }
    func testPictureSavedAsPNGStillMatchesTheCameraExactly() throws {
        // Busy noise-like content: any colour conversion in the save/load round trip would show up as kept pixels.
        let frame = try buffer(32, 16) { x, y in
            SIMD3(Float((x * 37 + y * 11) % 256) / 255, Float((x * 13 + y * 71) % 256) / 255, Float((x * 101 + y * 7) % 256) / 255)
        }
        let keyer = try BackgroundMaskProcessor(plate: plate(from: frame), id: UUID())
        let output = try GreenScreenProcessor.makeBuffer(width: 32, height: 16)
        var settings = DifferenceKeySettings(); settings.threshold = 0.004; settings.softness = 0.005; settings.cleanup = 0
        let mask = try XCTUnwrap(keyer.render(frame, into: output, settings: settings, maskPreview: true))
        for y in 0..<16 { for x in 0..<32 { XCTAssertEqual(alpha(output, x, y), 0, "pixel \(x),\(y)") } }
        XCTAssertEqual(CVPixelBufferGetWidth(mask), 32)
    }
    func testCleanupClearsSpecksAndFillsHoles() throws {
        let gray = SIMD3<Float>(0.5, 0.5, 0.5), red = SIMD3<Float>(1, 0, 0)
        let keyer = try BackgroundMaskProcessor(plate: plate(from: buffer(32, 24) { _, _ in gray }), id: UUID())
        let output = try GreenScreenProcessor.makeBuffer(width: 32, height: 24)
        var settings = DifferenceKeySettings(); settings.lighting = 0
        // A 2×2 speck that differs from the background.
        let speck = try buffer(32, 24) { x, y in (10...11).contains(x) && (8...9).contains(y) ? red : gray }
        settings.cleanup = 0; try keyer.render(speck, into: output, settings: settings)
        XCTAssertGreaterThan(alpha(output, 10, 8), 0.9)
        settings.cleanup = 1; try keyer.render(speck, into: output, settings: settings)
        XCTAssertLessThan(alpha(output, 10, 8), 0.05, "An isolated speck is removed")
        // A 4×4 hole inside the foreground that happens to match the background.
        let hole = try buffer(32, 24) { x, y in (10...13).contains(x) && (8...11).contains(y) ? gray : red }
        settings.cleanup = 0; try keyer.render(hole, into: output, settings: settings)
        XCTAssertLessThan(alpha(output, 11, 9), 0.05)
        settings.cleanup = 1; try keyer.render(hole, into: output, settings: settings)
        XCTAssertGreaterThan(alpha(output, 11, 9), 0.95, "A small enclosed hole is filled")
    }
    func testFramesOfAnotherSizeStopWithAnExplanation() throws {
        let keyer = try BackgroundMaskProcessor(plate: plate(from: buffer(32, 16) { _, _ in SIMD3(0.5, 0.5, 0.5) }), id: UUID())
        let small = try buffer(16, 16) { _, _ in SIMD3(0.5, 0.5, 0.5) }
        XCTAssertThrowsError(try keyer.render(small, into: small, settings: DifferenceKeySettings())) { error in
            XCTAssertTrue(error.localizedDescription.contains("Retake the background picture"))
        }
    }
    func testCompositorShowsLowerLayersWhereTheBackgroundMatches() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 32, height: 16))
        let wall = SIMD3<Float>(0.6, 0.6, 0.55)
        let plate = LoadedPlate(id: UUID(), image: try plate(from: buffer(32, 16) { _, _ in wall }))
        let camera = try buffer(32, 16) { x, _ in x < 16 ? wall : SIMD3(1, 0, 0) }
        var settings = DifferenceKeySettings(); settings.cleanup = 0
        let (keyed, mask) = try compositor.cameraImage(camera, keying: .backgroundMask(settings, plate), mask: true)
        XCTAssertNotNil(mask)
        let layer = SceneLayer(name: "Me", source: .camera)
        var scene = CameraScene(name: "Fixture", layers: [layer]); scene.canvasBlue = 1
        let output = try XCTUnwrap(compositor.compose(scene: scene, images: [layer.id: keyed]))
        CVPixelBufferLockBaseAddress(output, .readOnly); defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(output)
        XCTAssertEqual([base[8 * row + 4 * 4], base[8 * row + 4 * 4 + 1], base[8 * row + 4 * 4 + 2]], [255, 0, 0], "Canvas blue shows through")
        XCTAssertEqual([base[8 * row + 28 * 4], base[8 * row + 28 * 4 + 1], base[8 * row + 28 * 4 + 2]], [0, 0, 255], "The red foreground is kept")
    }
    func testAveragingReducesNoiseAndRejectsChangedFrameSize() throws {
        var averager = try PlateAverager(width: 4, height: 2)
        try averager.add(buffer(4, 2) { _, _ in SIMD3(repeating: 10 / 255) })
        try averager.add(buffer(4, 2) { _, _ in SIMD3(repeating: 21 / 255) })
        let result = try averager.result()
        XCTAssertEqual(result.width, 4); XCTAssertEqual(result.height, 2)
        let data = try XCTUnwrap(result.image.dataProvider?.data) as Data
        XCTAssertEqual(data[0], 16, "(10 + 21) / 2 rounds to 16"); XCTAssertEqual(data[3], 255)
        XCTAssertThrowsError(try averager.add(buffer(2, 2) { _, _ in SIMD3(repeating: 0) }))
    }
    func testRunningSceneTakesAPictureFromRawCameraFrames() async throws {
        final class Receiver: FrameTransport {
            func start(configuration: CaptureConfiguration) throws {}
            func send(_ sample: CMSampleBuffer) throws {}
            func stop() {}
        }
        let output = SceneOutput(transport: Receiver())
        let plan = SceneRenderPlan(scene: CameraScene(name: "Camera", layers: [SceneLayer(name: "Me", source: .camera)]),
            sources: [:], keying: .off, maskPreview: false)
        try await output.start(plan: plan, output: .init(width: 128, height: 64), cameraMode: .pattern, capture: .init(width: 96, height: 48), publish: false)
        let capture = try await output.capturePlate(frames: 3)
        await output.stop()
        XCTAssertEqual(capture.width, 96); XCTAssertEqual(capture.height, 48, "The picture has the camera's size, not the canvas size")
        XCTAssertFalse(capture.png.isEmpty)
    }
    func testNoPictureWithoutCameraFrames() async throws {
        let output = SceneOutput(transport: SinkTransport())
        do { _ = try await output.capturePlate(frames: 2, timeout: 0.2); XCTFail("Expected a timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not deliver enough frames")) }
    }
}
