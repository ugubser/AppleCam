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
    /// Each frame of a web page is its own stream: streams keep their own positions and are summed.
    func testStreamsAreSummedAndKeepTheirOwnPositions() {
        let timeline = ChannelTimeline()
        stereo(100) { _ in 1 }.withUnsafeBufferPointer { timeline.write($0, at: 0, stream: 0) }
        stereo(100) { _ in 0.5 }.withUnsafeBufferPointer { timeline.write($0, at: 50, stream: 1) }
        // Stream 1 continues where it left off although stream 0 is elsewhere: no drift is inferred between streams.
        stereo(100) { _ in 0.25 }.withUnsafeBufferPointer { timeline.write($0, at: 150, stream: 1) }
        XCTAssertEqual(timeline.streamCount, 2); XCTAssertEqual(timeline.resyncs, 0)
        let out = read(timeline, from: 0, count: 300)
        XCTAssertEqual(out[10 * 2], 1); XCTAssertEqual(out[60 * 2], 1.5); XCTAssertEqual(out[60 * 2 + 1], -1.5)
        XCTAssertEqual(out[120 * 2], 0.5); XCTAssertEqual(out[200 * 2], 0.25); XCTAssertEqual(out[260 * 2], 0)
        timeline.forget(stream: 1); XCTAssertEqual(timeline.streamCount, 1)
        timeline.restart(); XCTAssertEqual(timeline.streamCount, 0)
    }
    // MARK: Finding AppleCam's WebKit audio process

    private func wavSamples(_ data: Data) -> [Float] {
        data.dropFirst(44).withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32767 } }
    }
    private func sine(_ frequency: Double, amplitude: Double, count: Int = 24_000, rate: Double = 48_000) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }
    func testSignatureToneIsAQuietHighWavWithFades() {
        let data = WebKitAudioSignature.wav(frequency: 18_000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        let samples = wavSamples(data)
        XCTAssertEqual(samples.count, Int(WebKitAudioSignature.seconds * 48_000))
        XCTAssertEqual(samples.first ?? 1, 0, accuracy: 1e-4, "Fades in, so it never clicks")
        XCTAssertEqual(Double(samples.map(abs).max() ?? 0), WebKitAudioSignature.amplitude, accuracy: 0.001)
        XCTAssertEqual(WebKitAudioSignature.level(samples, frequency: 18_000, sampleRate: 48_000), -40, accuracy: 0.5)
        XCTAssertTrue(WebKitAudioSignature.frequencies.allSatisfy { (17_000...19_000).contains($0) })
    }
    func testSignatureIsFoundOnlyAsAClearLineAtItsFrequency() {
        let tone = sine(17_550, amplitude: 0.01)
        XCTAssertTrue(WebKitAudioSignature.carries(tone, frequency: 17_550, sampleRate: 48_000))
        XCTAssertFalse(WebKitAudioSignature.carries(tone, frequency: 18_550, sampleRate: 48_000), "Another search's frequency")
        // Under loud program material (music, speech) at other frequencies, the line is still found.
        let music = zip(sine(440, amplitude: 0.5), sine(3_000, amplitude: 0.3)).map { $0 + $1 }
        XCTAssertTrue(WebKitAudioSignature.carries(zip(music, tone).map { $0 + $1 }, frequency: 17_550, sampleRate: 48_000))
        // Broadband noise is not a line, however loud.
        var seed: UInt64 = 1
        let noise = (0..<24_000).map { _ -> Float in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 1) % 1000) / 2000 }
        XCTAssertFalse(WebKitAudioSignature.carries(noise, frequency: 17_550, sampleRate: 48_000))
        XCTAssertFalse(WebKitAudioSignature.carries(sine(17_550, amplitude: 0.00001), frequency: 17_550, sampleRate: 48_000), "Too quiet")
        XCTAssertFalse(WebKitAudioSignature.carries([], frequency: 17_550, sampleRate: 48_000), "A process that delivered nothing")
    }
    func testOnlyAUniqueMatchIsAccepted() {
        XCTAssertEqual(WebKitAudioSignature.choose([10: false, 20: true, 30: false]), .found(20))
        XCTAssertEqual(WebKitAudioSignature.choose([10: false]), .none)
        XCTAssertEqual(WebKitAudioSignature.choose([:]), .none)
        XCTAssertEqual(WebKitAudioSignature.choose([30: true, 10: true]), .several([10, 30]), "Never a guess between two")
    }
    func testAudioSettingsWithoutTheBrowserChannelStillLoad() throws {
        var saved = AudioPreferences(); saved.master.volume = -6; saved.monitor = true; saved.browser.muted = true
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        XCTAssertNotNil(json["browser"])
        json["browser"] = nil
        let loaded = try JSONDecoder().decode(AudioPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.master.volume, -6); XCTAssertTrue(loaded.monitor); XCTAssertEqual(loaded.browser, ChannelMix())
        XCTAssertEqual(try JSONDecoder().decode(AudioPreferences.self, from: JSONEncoder().encode(saved)), saved)
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
