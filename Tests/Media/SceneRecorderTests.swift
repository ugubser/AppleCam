import XCTest
import AVFoundation
import AppleCamCore
@testable import AppleCamMedia

final class SceneRecorderTests: XCTestCase {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func frame(_ width: Int, _ height: Int, gray: UInt8) throws -> CVPixelBuffer {
        let buffer = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        memset(CVPixelBufferGetBaseAddress(buffer)!, Int32(gray), CVPixelBufferGetBytesPerRow(buffer) * height)
        return buffer
    }
    private func finish(_ recorder: SceneRecorder, at end: CMTime) async throws {
        let error: Error? = await withCheckedContinuation { continuation in recorder.finish(at: end) { continuation.resume(returning: $0) } }
        if let error { throw error }
    }
    private func trackName(_ track: AVAssetTrack) async throws -> String? {
        let items = try await track.load(.metadata)
        return try await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeUserDataTrackName).first?.load(.stringValue)
    }

    func testMovieHasVideoMixAndChannelTracksWithNamesAndOnlyTheMixEnabled() async throws {
        let url = folder().appendingPathComponent("test.mov")
        let config = CaptureConfiguration(width: 320, height: 240, fps: 30)
        let recorder = try SceneRecorder(url: url, configuration: config, audioTracks: ["Mix", "Yeti", "Browser"])
        let start = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
        for n in 0..<60 { try recorder.appendVideo(frame(320, 240, gray: UInt8(n * 4)), at: start + CMTime(value: Int64(n), timescale: 30)) }
        let block = AudioFormat.blockFrames
        let tone = (0..<block).flatMap { i -> [Float] in let v = Float(sin(Double(i) * 0.05)) * 0.3; return [v, v] }
        let silence = [Float](repeating: 0, count: block * 2)
        var position: Int64 = 0
        while position < 96_000 {
            let time = start + CMTime(value: position, timescale: 48_000)
            try tone.withUnsafeBufferPointer { t in try silence.withUnsafeBufferPointer { s in
                try recorder.appendAudio([t, t, s], frames: block, at: time)
            } }
            position += Int64(block)
        }
        try await finish(recorder, at: start + CMTime(value: 2, timescale: 1))
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video), audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 3)
        let size = try await videoTracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
        let codec = try await videoTracks[0].load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        XCTAssertEqual(codec, kCMVideoCodecType_HEVC)
        let enabled = try await audioTracks.asyncMap { try await $0.load(.isEnabled) }
        XCTAssertEqual(enabled, [true, false, false], "Players play only the mix")
        let names = try await audioTracks.asyncMap { try await self.trackName($0) }
        XCTAssertEqual(names, ["Mix", "Yeti", "Browser"])
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        let audioDuration = try await audioTracks[0].load(.timeRange).duration.seconds
        XCTAssertEqual(audioDuration, 2, accuracy: 0.1)
    }
    func testVideoOnlyRecordingAndAudioBeforeTheFirstFrameIsLeftOut() async throws {
        let url = folder().appendingPathComponent("video.mov")
        let recorder = try SceneRecorder(url: url, configuration: .init(width: 320, height: 240, fps: 30), audioTracks: [])
        let start = CMTime(seconds: 5, preferredTimescale: 600)
        // Paced like the scene output; a real-time writer skips frames offered faster than it can encode.
        for n in 0..<15 { try recorder.appendVideo(frame(320, 240, gray: 128), at: start + CMTime(value: Int64(n), timescale: 30)); usleep(33_000) }
        try await finish(recorder, at: start + CMTime(value: 1, timescale: 2))
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertEqual(recorder.videoFrames, 15)
        XCTAssertGreaterThan(recorder.bytesWritten, 0)
        // Audio appended before any video frame is ignored, not an error.
        let early = try SceneRecorder(url: folder().appendingPathComponent("early.mov"), configuration: .init(width: 320, height: 240, fps: 30), audioTracks: ["Mix"])
        try [Float](repeating: 0, count: 2048).withUnsafeBufferPointer { try early.appendAudio([$0], frames: 1024, at: .zero) }
        XCTAssertEqual(early.audioFrames, 0)
    }
    func testStoppingBeforeAnyFrameKeepsNoFile() async throws {
        let url = folder().appendingPathComponent("empty.mov")
        let recorder = try SceneRecorder(url: url, configuration: .init(width: 320, height: 240, fps: 30), audioTracks: ["Mix"])
        do { try await finish(recorder, at: .zero); XCTFail("Expected an explanation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("before the first frame")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testRunningSceneRecordsEveryComposedFrameAndReportsTheFile() async throws {
        final class Receiver: FrameTransport {
            func start(configuration: CaptureConfiguration) throws {}
            func send(_ sample: CMSampleBuffer) throws {}
            func stop() {}
        }
        let output = SceneOutput(transport: Receiver())
        let url = folder().appendingPathComponent("scene.mov")
        let config = CaptureConfiguration(width: 640, height: 360, fps: 30)
        let ended = expectation(description: "recording ended")
        nonisolated(unsafe) var report: (URL, Error?)?
        output.onRecordingEnded = { url, error, _ in report = (url, error); ended.fulfill() }
        let plan = SceneRenderPlan(scene: CameraScene(name: "Camera", layers: [SceneLayer(name: "Me", source: .camera)]),
            sources: [:], keying: .off, maskPreview: false)
        try await output.start(plan: plan, output: config, cameraMode: .pattern, capture: .init(width: 640, height: 360, fps: 30), publish: false)
        try await output.startRecording(SceneRecorder(url: url, configuration: config, audioTracks: ["Mix"]), channels: [])
        let second = await thrownError { try await output.startRecording(SceneRecorder(url: url.deletingLastPathComponent().appendingPathComponent("b.mov"), configuration: config, audioTracks: []), channels: []) }
        XCTAssertEqual(second?.localizedDescription, "A recording is already running.")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        output.stopRecording()
        await fulfillment(of: [ended], timeout: 5)
        await output.stop()
        XCTAssertEqual(report?.0, url); XCTAssertNil(report?.1)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.4)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "The mix track is present even when no channel makes sound")
    }
}

private func thrownError(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); return nil } catch { return error }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []; for element in self { result.append(try await transform(element)) }; return result
    }
}
