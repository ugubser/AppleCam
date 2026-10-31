import XCTest
import AVFoundation
import CoreImage
import AppleCamCore
@testable import AppleCamMedia

enum SceneTestMovie {
    static func make(at url: URL, duration: Int = 2) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32, kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for i in 0..<(30 * duration) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let buffer = try GreenScreenProcessor.makeBuffer(width: 64, height: 32)
            CVPixelBufferLockBaseAddress(buffer, []);
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<32 { for x in 0..<64 {
                let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                base[offset] = (i / 15).isMultiple(of: 2) ? 0 : 255
                base[offset + 1] = 0; base[offset + 2] = (i / 15).isMultiple(of: 2) ? 255 : 0; base[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30)) else { throw writer.error ?? CameraError.message("Synthetic movie encoding failed.") }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CameraError.message("Synthetic movie did not finish.") }
    }
}

final class ScenePlaybackTests: XCTestCase {
    @MainActor func testClipPausesWhileInactiveResumesAndLoopsSilently() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SceneTestMovie.make(at: url)
        let clip = try await ClipSceneSource(url: url)
        XCTAssertTrue(clip.player.isMuted); XCTAssertEqual(clip.player.volume, 0)
        try await clip.activate()
        var frame: CIImage?
        for _ in 0..<150 {
            frame = try clip.image(at: CMClockGetTime(CMClockGetHostTimeClock()))
            if frame != nil { break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(frame)
        try await Task.sleep(nanoseconds: 300_000_000)
        await clip.deactivate(); let paused = clip.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(clip.player.currentTime().seconds, paused, accuracy: 0.05)
        try await clip.activate(); try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(clip.player.currentTime().seconds, paused + 0.1)
        // Cross two movie ends while consuming actual decoded frames.
        var wraps = 0, previous = clip.player.currentTime().seconds
        for _ in 0..<125 {
            try await Task.sleep(nanoseconds: 40_000_000)
            XCTAssertNotNil(try clip.image(at: CMClockGetTime(CMClockGetHostTimeClock())))
            let now = clip.player.currentTime().seconds; if now + 0.1 < previous { wraps += 1 }; previous = now
        }
        XCTAssertGreaterThanOrEqual(wraps, 2)
        clip.togglePause(); XCTAssertTrue(clip.isPaused)
        await clip.deactivate()
    }
    @MainActor func testUndecodableClipIsRejected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }; try Data([1, 2, 3]).write(to: url)
        do { _ = try await ClipSceneSource(url: url); XCTFail("Invalid movie must be rejected") } catch {}
    }
    func testSceneSwitchPreservesTransportAndSourceFailureStopsDelivery() async throws {
        final class Receiver: FrameTransport {
            let lock = NSLock()
            var starts = 0, stops = 0, frames = 0
            var red = false, blue = false
            var last = -Double.infinity
            func start(configuration: CaptureConfiguration) throws { lock.lock(); defer { lock.unlock() }; starts += 1 }
            func stop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
            func send(_ sample: CMSampleBuffer) throws {
                lock.lock(); defer { lock.unlock() }
                XCTAssertGreaterThan(sample.presentationTimeStamp.seconds, last); last = sample.presentationTimeStamp.seconds
                let b = sample.imageBuffer!; CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
                let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
                if p[2] > 250 { red = true }; if p[0] > 250 { blue = true }; frames += 1
            }
            func snapshot() -> (Int, Int, Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (starts, frames, red, blue) }
        }
        let receiver = Receiver(), output = SceneOutput(transport: receiver)
        var red = CameraScene(name: "Red"); red.canvasRed = 1
        var blue = CameraScene(name: "Blue"); blue.canvasBlue = 1
        let plan = SceneRenderPlan(scene: red, sources: [:], key: KeySettings(), greenScreen: false, maskPreview: false)
        try await output.start(plan: plan, output: .init(width: 64, height: 32, fps: 30), cameraMode: .pattern, capture: .init(), publish: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        var next = plan; next.scene = blue; await output.update(next)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(receiver.snapshot().0, 1); XCTAssertTrue(receiver.snapshot().2); XCTAssertTrue(receiver.snapshot().3)
        let failed = expectation(description: "Source failure reported")
        output.onStatus = { _, active, _ in if !active { failed.fulfill() } }
        output.sourceFailed(CameraError.message("Injected source failure"))
        await fulfillment(of: [failed], timeout: 3)
        let count = receiver.snapshot().1
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(receiver.snapshot().1, count); await output.stop()
    }
    func testSharedCameraStartsAndProducesCompositedFrames() async throws {
        final class Receiver: FrameTransport {
            func start(configuration: CaptureConfiguration) throws {}
            func send(_ sample: CMSampleBuffer) throws {}
            func stop() {}
        }
        let output = SceneOutput(transport: Receiver())
        let preview = expectation(description: "Shared camera rendered"), lock = NSLock()
        var delivered = false
        output.onPreview = { image, _, _, _ in
            lock.lock(); defer { lock.unlock() }
            if !delivered { delivered = true; XCTAssertEqual(CVPixelBufferGetWidth(image), 128); XCTAssertEqual(CVPixelBufferGetHeight(image), 64); preview.fulfill() }
        }
        let plan = SceneRenderPlan(scene: CameraScene(name: "Camera", layers: [SceneLayer(name: "Me", source: .camera)]),
            sources: [:], key: KeySettings(), greenScreen: true, maskPreview: false)
        try await output.start(plan: plan, output: .init(width: 128, height: 64), cameraMode: .pattern, capture: .init(width: 128, height: 64), publish: false)
        await fulfillment(of: [preview], timeout: 5); await output.stop()
    }
    @MainActor func testSupersededPreparationKeepsTheCommittedSceneAndTransport() async throws {
        final class Receiver: FrameTransport {
            private let lock = NSLock()
            private var starts = 0
            func start(configuration: CaptureConfiguration) throws { lock.withLock { starts += 1 } }
            func send(_ sample: CMSampleBuffer) throws {}
            func stop() {}
            func count() -> Int { lock.withLock { starts } }
        }
        let receiver = Receiver(), output = SceneOutput(transport: receiver)
        let runtime = SceneRuntime(store: PreferencesStore(directory: FileManager.default.temporaryDirectory), output: output)
        let first = CameraScene(name: "First"), second = CameraScene(name: "Superseded")
        try await runtime.apply(scene: first, key: KeySettings(), greenScreen: false, mask: false,
            output: .init(width: 64, height: 32), cameraMode: .pattern, capture: .init(), publish: true)
        do {
            try await runtime.apply(scene: second, key: KeySettings(), greenScreen: false, mask: false,
                output: .init(width: 64, height: 32), cameraMode: .pattern, capture: .init(), publish: true, mayCommit: { false })
            XCTFail("Superseded preparation must not commit")
        } catch is ScenePreparationSuperseded {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(runtime.running); XCTAssertEqual(receiver.count(), 1); await runtime.stop()
    }
    @MainActor func testReturningToSceneReusesItsPausedClipPlayer() async throws {
        final class Receiver: FrameTransport {
            func start(configuration: CaptureConfiguration) throws {}
            func send(_ sample: CMSampleBuffer) throws {}
            func stop() {}
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("original.mov"); try await SceneTestMovie.make(at: movie)
        let store = PreferencesStore(directory: directory), asset = MediaAsset(name: "Fixture", fileExtension: "mov")
        let layer = SceneLayer(name: "Loop", source: .clip(asset)), output = SceneOutput(transport: Receiver())
        let runtime = SceneRuntime(store: store, output: output)
        var settings = SavedPreferences(); settings.scenes[0].layers = [layer]; settings.scenes[1].layers = []
        try store.importMedia(from: movie, asset: asset, settings: settings)
        func apply(_ scene: CameraScene) async throws {
            try await runtime.apply(scene: scene, key: KeySettings(), greenScreen: false, mask: false,
                output: .init(width: 64, height: 32), cameraMode: .pattern, capture: .init(), publish: false)
        }
        try await apply(settings.scenes[0]); try await Task.sleep(nanoseconds: 300_000_000)
        let clip = try XCTUnwrap(runtime.clip(layer.id))
        try await apply(settings.scenes[1]); let position = clip.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(clip.player.currentTime().seconds, position, accuracy: 0.05)
        try await apply(settings.scenes[0]); XCTAssertTrue(runtime.clip(layer.id) === clip)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(clip.player.currentTime().seconds, position + 0.05); await runtime.stop()
    }
    @MainActor func testPlacementAndVisibilityEditsUpdateInPlaceWithoutReopeningSources() async throws {
        final class Receiver: FrameTransport {
            private let lock = NSLock()
            private var starts = 0
            func start(configuration: CaptureConfiguration) throws { lock.withLock { starts += 1 } }
            func send(_ sample: CMSampleBuffer) throws {}
            func stop() {}
            func count() -> Int { lock.withLock { starts } }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("artifacts/fixtures/AppleCam-sample-background.png")
        let store = PreferencesStore(directory: directory)
        let first = MediaAsset(name: "One", fileExtension: "image"), second = MediaAsset(name: "Two", fileExtension: "image")
        var settings = SavedPreferences()
        settings.scenes[0].layers = [SceneLayer(name: "One", source: .image(first))]
        try store.importMedia(from: fixture, asset: first, settings: settings)
        settings.scenes[0].layers.append(SceneLayer(name: "Two", source: .image(second)))
        try store.importMedia(from: fixture, asset: second, settings: settings)
        let receiver = Receiver(), runtime = SceneRuntime(store: store, output: SceneOutput(transport: receiver))
        var scene = settings.scenes[0]; scene.layers[1].visible = false
        func apply(_ scene: CameraScene) async throws {
            try await runtime.apply(scene: scene, key: KeySettings(), greenScreen: false, mask: false,
                output: .init(width: 64, height: 32), cameraMode: .pattern, capture: .init(), publish: true)
        }
        XCTAssertFalse(runtime.canUpdateInPlace(scene, fps: 30), "Nothing is running yet")
        try await apply(scene)
        var moved = scene; moved.layers[0].placement.x = 0.25; moved.layers[0].placement.width = 0.5
        XCTAssertTrue(runtime.canUpdateInPlace(moved, fps: 30))
        XCTAssertFalse(runtime.canUpdateInPlace(moved, fps: 60), "A new canvas rate needs new sources")
        try await apply(moved)
        var hidden = moved; hidden.layers[0].visible = false
        XCTAssertTrue(runtime.canUpdateInPlace(hidden, fps: 30), "Hiding only retires a source")
        var shown = moved; shown.layers[1].visible = true
        XCTAssertFalse(runtime.canUpdateInPlace(shown, fps: 30), "A newly visible source must be opened and checked")
        try await apply(shown)
        XCTAssertTrue(runtime.canUpdateInPlace(shown, fps: 30))
        XCTAssertTrue(runtime.running); XCTAssertEqual(receiver.count(), 1, "Edits never restart the virtual-camera transport")
        await runtime.stop()
        XCTAssertFalse(runtime.canUpdateInPlace(shown, fps: 30))
    }
}
