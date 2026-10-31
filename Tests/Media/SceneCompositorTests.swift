import XCTest
import CoreImage
import CoreMedia
import AppleCamCore
@testable import AppleCamMedia

final class SceneCompositorTests: XCTestCase {
    private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return [base[offset + 2], base[offset + 1], base[offset], base[offset + 3]]
    }
    func testFrontToBackOrderAndHiddenLayersUseActualOutputPixels() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 64, height: 32))
        var front = SceneLayer(name: "Red", source: .camera), back = SceneLayer(name: "Blue", source: .camera)
        front.placement.width = 0.5
        let images: [UUID: CIImage] = [front.id: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)),
            back.id: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))]
        var scene = CameraScene(name: "Fixture", layers: [front, back])
        let output = try XCTUnwrap(compositor.compose(scene: scene, images: images))
        XCTAssertEqual(pixel(output, x: 8, y: 16), [255, 0, 0, 255]); XCTAssertEqual(pixel(output, x: 48, y: 16), [0, 0, 255, 255])
        scene.layers[0].visible = false
        let hidden = try XCTUnwrap(compositor.compose(scene: scene, images: [back.id: images[back.id]!]))
        XCTAssertEqual(pixel(hidden, x: 8, y: 16), [0, 0, 255, 255])
    }
    func testTransparencyAndCanvasAreCompositedInLinearLight() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 32, height: 16))
        let front = SceneLayer(name: "Translucent", source: .camera), back = SceneLayer(name: "Blue", source: .camera)
        let scene = CameraScene(name: "Fixture", layers: [front, back])
        let output = try XCTUnwrap(compositor.compose(scene: scene, images: [
            front.id: CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16)),
            back.id: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))]))
        let p = pixel(output, x: 10, y: 8)
        XCTAssertEqual(Int(p[0]), 188, accuracy: 2); XCTAssertEqual(Int(p[2]), 188, accuracy: 2); XCTAssertEqual(p[3], 255)
    }
    func testPlacementUsesTopLeftCanvasCoordinates() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 64, height: 32))
        var layer = SceneLayer(name: "Patch", source: .camera)
        layer.placement.x = 0.5; layer.placement.y = 0; layer.placement.width = 0.5; layer.placement.height = 0.5
        let output = try XCTUnwrap(compositor.compose(scene: CameraScene(name: "Fixture", layers: [layer]), images: [layer.id:
            CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))]))
        XCTAssertEqual(pixel(output, x: 48, y: 8), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, x: 48, y: 24), [0, 0, 0, 255]); XCTAssertEqual(pixel(output, x: 8, y: 8), [0, 0, 0, 255])
    }
    func testVisibleMissingSourceFailsRatherThanSilentlyOmittingIt() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 32, height: 16))
        let scene = CameraScene(name: "Fixture", layers: [SceneLayer(name: "Missing", source: .window(nil))])
        XCTAssertThrowsError(try compositor.compose(scene: scene, images: [:]))
    }
    func testKeyerReturnsAlphaForLayerComposition() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 32, height: 16))
        let input = try GreenScreenProcessor.makeBuffer(width: 32, height: 16)
        compositor.context.render(CIImage(color: .green), to: input, bounds: CGRect(x: 0, y: 0, width: 32, height: 16), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var key = KeySettings(); key.color = SIMD3(0, 1, 0)
        let (keyed, mask) = try compositor.cameraImage(input, key: key, enabled: true, mask: true)
        let layer = SceneLayer(name: "Me", source: .camera)
        var scene = CameraScene(name: "Fixture", layers: [layer]); scene.canvasBlue = 1
        let output = try XCTUnwrap(compositor.compose(scene: scene, images: [layer.id: keyed]))
        XCTAssertEqual(pixel(output, x: 8, y: 8), [0, 0, 255, 255]); XCTAssertNotNil(mask)
    }
    func testFractionalKeyedEdgesMatchTheExistingLinearLightReference() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 32, height: 16))
        let input = try GreenScreenProcessor.makeBuffer(width: 32, height: 16)
        let rgb = SIMD3<Float>(0.2, 0.8, 0.2)
        compositor.context.render(CIImage(color: CIColor(red: 0.2, green: 0.8, blue: 0.2)), to: input,
            bounds: CGRect(x: 0, y: 0, width: 32, height: 16), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var key = KeySettings(); key.color = SIMD3(0, 1, 0); key.tolerance = 0.36; key.softness = 0.1; key.protection = 0
        let alpha = ChromaKey.alpha(rgb, settings: key)
        XCTAssertGreaterThan(alpha, 0.2); XCTAssertLessThan(alpha, 0.8)
        let (keyed, _) = try compositor.cameraImage(input, key: key, enabled: true, mask: false)
        let layer = SceneLayer(name: "Glass fixture", source: .camera)
        var scene = CameraScene(name: "Fixture", layers: [layer]); scene.canvasBlue = 1
        let output = try XCTUnwrap(compositor.compose(scene: scene, images: [layer.id: keyed]))
        let actual = pixel(output, x: 8, y: 8), expected = ChromaKey.composite(rgb, background: SIMD3(0, 0, 1), settings: key)
        for channel in 0..<3 { XCTAssertEqual(Int(actual[channel]), Int((expected[channel] * 255).rounded()), accuracy: 3) }
        XCTAssertEqual(actual[3], 255)
    }
    func testFreshCanvasTimestampCannotRescueExpiredCameraFrames() throws {
        var gate = SceneCameraFreshness()
        XCTAssertTrue(try gate.accept(timestamp: 1, now: 1.1))
        XCTAssertFalse(try gate.accept(timestamp: 1, now: 1.2))
        XCTAssertFalse(try gate.accept(timestamp: 1, now: 2))
        XCTAssertThrowsError(try gate.accept(timestamp: 1, now: 3.21))
        XCTAssertTrue(try gate.accept(timestamp: 4, now: 4.01))
        XCTAssertThrowsError(try gate.accept(timestamp: 6, now: 5))
    }
    func testLocalPreviewIsDownscaledButPublishedFrameKeepsFullResolution() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 3840, height: 2160, fps: 60))
        let layer = SceneLayer(name: "Red", source: .camera)
        let output = try XCTUnwrap(compositor.compose(scene: CameraScene(name: "UHD", layers: [layer]),
            images: [layer.id: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 3840, height: 2160))]))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 3840); XCTAssertEqual(CVPixelBufferGetHeight(output), 2160)
        let preview = try XCTUnwrap(compositor.previewBuffer(CIImage(cvPixelBuffer: output)))
        XCTAssertEqual(CVPixelBufferGetWidth(preview), 1920); XCTAssertEqual(CVPixelBufferGetHeight(preview), 1080)
        XCTAssertEqual(pixel(preview, x: 960, y: 540), [255, 0, 0, 255], "The downscaled preview keeps the picture")
        let thumbnail = try compositor.thumbnail(CIImage(cvPixelBuffer: output))
        XCTAssertEqual(thumbnail.width, 320); XCTAssertEqual(thumbnail.height, 180)
        let small = try SceneCompositor(configuration: .init(width: 1280, height: 720))
        let unscaled = try XCTUnwrap(small.previewBuffer(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))))
        XCTAssertEqual(CVPixelBufferGetWidth(unscaled), 1280)
    }
    func testPreviewFramesAreBoundedWhileTheDisplayHoldsThem() throws {
        let compositor = try SceneCompositor(configuration: .init(width: 64, height: 32))
        let image = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        var held: [CVPixelBuffer] = []
        for _ in 0..<12 { if let buffer = try compositor.previewBuffer(image) { held.append(buffer) } }
        XCTAssertLessThan(held.count, 12, "Preview frames are skipped instead of allocating without limit")
        XCTAssertFalse(held.isEmpty)
        let sample = try PreviewDisplay.sample(held[0])
        XCTAssertTrue(sample.isValid); XCTAssertTrue(sample.imageBuffer === held[0])
    }
}
