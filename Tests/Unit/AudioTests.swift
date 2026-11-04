import XCTest
@testable import AppleCamCore

final class AudioTests: XCTestCase {
    func testDecibelConversions() {
        XCTAssertEqual(AudioMath.gain(dB: 0), 1)
        XCTAssertEqual(AudioMath.gain(dB: -6), 0.501, accuracy: 0.001)
        XCTAssertEqual(AudioMath.gain(dB: 12), 3.981, accuracy: 0.001)
        XCTAssertEqual(AudioMath.gain(dB: -60), 0, "The bottom of the fader is silence")
        XCTAssertEqual(AudioMath.decibels(1), 0); XCTAssertEqual(AudioMath.decibels(0), -120)
        XCTAssertEqual(AudioMath.decibels(0.5), -6.02, accuracy: 0.01)
    }
    func testChannelMixValidationAndMute() {
        var mix = ChannelMix(); XCTAssertTrue(mix.isValid); XCTAssertEqual(mix.gain, 1)
        mix.muted = true; XCTAssertEqual(mix.gain, 0)
        mix = ChannelMix(); mix.volume = 13; XCTAssertFalse(mix.isValid)
        mix = ChannelMix(); mix.volume = .nan; XCTAssertFalse(mix.isValid)
        mix = ChannelMix(); mix.offsetMilliseconds = 301; XCTAssertFalse(mix.isValid)
        mix.offsetMilliseconds = -100; XCTAssertTrue(mix.isValid)
    }
    func testMeterMeasuresPeakAndRMSAndHoldsClipping() {
        var meter = LevelMeter()
        let sine = (0..<480).map { Float(sin(Double($0) / 480 * 2 * .pi * 10)) * 0.5 }
        sine.withUnsafeBufferPointer { meter.measure($0, at: 10) }
        XCTAssertEqual(meter.peak, 0.5, accuracy: 0.001); XCTAssertEqual(meter.rms, 0.5 / Float(2).squareRoot(), accuracy: 0.002)
        XCTAssertFalse(meter.clipping(at: 10))
        [Float](repeating: 1, count: 4).withUnsafeBufferPointer { meter.measure($0, at: 20) }
        XCTAssertTrue(meter.clipping(at: 21.9)); XCTAssertFalse(meter.clipping(at: 22.1), "Clipping is shown for two seconds")
        meter.silence(); XCTAssertEqual(meter.peakDB, -120)
    }
    private func stereo(_ frames: Int, value: (Int) -> Float) -> [Float] { (0..<frames).flatMap { [value($0), -value($0)] } }
    private func read(_ timeline: ChannelTimeline, from: Int64, count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count * 2)
        out.withUnsafeMutableBufferPointer { timeline.read(into: $0, from: from, count: count) }
        return out
    }
    func testTimelinePlacesBuffersByTimestampAndReadsGapsAsSilence() {
        let timeline = ChannelTimeline()
        stereo(100) { Float($0 + 1) }.withUnsafeBufferPointer { timeline.write($0, at: 50) }
        let out = read(timeline, from: 0, count: 200)
        XCTAssertEqual(out[0], 0); XCTAssertEqual(out[49 * 2], 0)
        XCTAssertEqual(out[50 * 2], 1); XCTAssertEqual(out[50 * 2 + 1], -1); XCTAssertEqual(out[149 * 2], 100)
        XCTAssertEqual(out[150 * 2], 0)
        XCTAssertEqual(read(timeline, from: 50, count: 1), [0, 0], "A range is read once")
    }
    func testLateBuffersAreDroppedNotMixedIntoThePast() {
        let timeline = ChannelTimeline()
        _ = read(timeline, from: 0, count: 1000)
        stereo(100) { _ in 1 }.withUnsafeBufferPointer { timeline.write($0, at: 950) }
        XCTAssertEqual(timeline.droppedLate, 50)
        let out = read(timeline, from: 1000, count: 50)
        XCTAssertTrue(out.enumerated().allSatisfy { $0.offset % 2 == 0 ? $0.element == 1 : $0.element == -1 })
    }
    /// A device whose clock runs 0.3 % fast delivers its 1024-frame buffers with timestamps that fall progressively
    /// behind; the timeline must stay within a few milliseconds of the timestamps without gaps or jumps.
    func testDriftIsSlewedWithoutGapsOrResync() {
        let timeline = ChannelTimeline(seconds: 30)
        let ppm = 3000.0, block = 1024
        var produced = 0
        for n in 0..<900 { // about 19 s
            let timestamp = Int64((Double(n * block) / (1 + ppm / 1_000_000)).rounded())
            stereo(block) { Float(produced + $0 + 1) }.withUnsafeBufferPointer { timeline.write($0, at: timestamp) }
            produced += block
        }
        XCTAssertEqual(timeline.resyncs, 0)
        let lastStamp = Int64((Double(899 * block) / (1 + ppm / 1_000_000)).rounded())
        let out = read(timeline, from: 0, count: Int(lastStamp) + block)
        // The written run is contiguous (no zero gaps) and ends near the last timestamp + one block.
        let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
        let end = left.lastIndex { $0 != 0 }!
        XCTAssertFalse(left[0...end].contains(0), "No gaps inside the run")
        XCTAssertEqual(Double(end + 1), Double(lastStamp) + Double(block), accuracy: Double(ChannelTimeline.slewThreshold) * 2)
    }
    func testLargeJumpReanchors() {
        let timeline = ChannelTimeline()
        stereo(10) { _ in 1 }.withUnsafeBufferPointer { timeline.write($0, at: 0) }
        stereo(10) { _ in 2 }.withUnsafeBufferPointer { timeline.write($0, at: 10_000) }
        XCTAssertEqual(timeline.resyncs, 1)
        XCTAssertEqual(read(timeline, from: 10_000, count: 1), [2, -2])
    }
    func testGainRampAndSum() {
        var samples: [Float] = [1, 1, 1, 1, 1, 1, 1, 1] // 4 stereo frames
        samples.withUnsafeMutableBufferPointer { MixMath.applyGain($0, from: 0, to: 1) }
        XCTAssertEqual(samples, [0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1], "The new gain is reached at the end of the block")
        var mix: [Float] = [1, 1, 1, 1, 1, 1, 1, 1]
        samples.withUnsafeBufferPointer { s in mix.withUnsafeMutableBufferPointer { MixMath.add(s, into: $0) } }
        XCTAssertEqual(mix[6], 2)
    }
    func testMonoIsCentredAndExtraChannelsDropped() {
        XCTAssertEqual(ChannelLayoutMath.stereo(from: [[1, 2]]), [1, 1, 2, 2])
        XCTAssertEqual(ChannelLayoutMath.stereo(from: [[1, 2], [3, 4], [9, 9]]), [1, 3, 2, 4])
    }
    func testRecordingPolicy() {
        XCTAssertEqual(Double(RecordingPolicy.videoBitRate(width: 1920, height: 1080, fps: 30)), 10_000_000, accuracy: 1)
        let uhd60 = RecordingPolicy.videoBitRate(width: 3840, height: 2160, fps: 60)
        XCTAssertTrue((40_000_000...50_000_000).contains(uhd60), "\(uhd60)")
        XCTAssertEqual(RecordingPolicy.videoBitRate(width: 320, height: 240, fps: 5), 2_000_000)
        XCTAssertEqual(RecordingPolicy.minimumFreeBytes(bytesPerSecond: 1_000_000), 2_000_000_000)
        XCTAssertEqual(RecordingPolicy.minimumFreeBytes(bytesPerSecond: 30_000_000), 3_600_000_000)
        let date = Date(timeIntervalSince1970: 1_793_789_551) // 2026-11-04 10:52:31 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RecordingPolicy.fileName(at: date, timeZone: utc) { _ in false }, "AppleCam 2026-11-04 at 10.52.31.mov")
        let taken: Set = ["AppleCam 2026-11-04 at 10.52.31.mov", "AppleCam 2026-11-04 at 10.52.31 2.mov"]
        XCTAssertEqual(RecordingPolicy.fileName(at: date, timeZone: utc) { taken.contains($0) }, "AppleCam 2026-11-04 at 10.52.31 3.mov")
        XCTAssertEqual(RecordingPolicy.durationLabel(125), "2:05"); XCTAssertEqual(RecordingPolicy.durationLabel(3723), "1:02:03")
    }
    func testAudioSettingsAreSavedAndOlderSettingsStillLoad() throws {
        var settings = SavedPreferences()
        settings.audio.microphones = [MicrophoneChannel(deviceID: "mic-1", name: "Yeti")]
        settings.scenes[0].layers.append({ var l = SceneLayer(name: "Page", source: .browser(BrowserSettings())); l.audio = LayerAudio(enabled: true); return l }())
        settings.recording.folderName = "Movies"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SavedPreferences.self, from: data)
        XCTAssertEqual(decoded, settings); XCTAssertTrue(decoded.scenes[0].layers.last!.hasAudio)
        // A build-21 file has neither key.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["audio"] = nil; object["recording"] = nil
        var scenes = try XCTUnwrap(object["scenes"] as? [[String: Any]])
        var layers = try XCTUnwrap(scenes[0]["layers"] as? [[String: Any]])
        layers[layers.count - 1]["audio"] = nil; scenes[0]["layers"] = layers; object["scenes"] = scenes
        let old = try JSONDecoder().decode(SavedPreferences.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.audio, AudioPreferences()); XCTAssertNil(old.recording.folderBookmark)
        XCTAssertFalse(old.scenes[0].layers.last!.hasAudio)
    }
    func testOnlySoundSourcesCanHaveAudioAndDuplicateMicrophonesAreInvalid() {
        var camera = SceneLayer(name: "Webcam", source: .camera); camera.audio = LayerAudio(enabled: true)
        XCTAssertFalse(camera.hasAudio)
        var prefs = AudioPreferences()
        prefs.microphones = [MicrophoneChannel(deviceID: "a", name: "A"), MicrophoneChannel(deviceID: "a", name: "A")]
        XCTAssertFalse(prefs.isValid)
    }
}
