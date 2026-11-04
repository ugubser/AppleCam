import XCTest
import AVFoundation
import AppleCamCore
@testable import AppleCamMedia

final class AudioMixerTests: XCTestCase {
    /// A mixer on a test clock: frame 0 is host time 100 s and blocks are mixed only when `run(until:)` asks.
    private func mixer(_ channels: [MixChannel], master: ChannelMix = ChannelMix()) -> (AudioMixer, () -> [Float]) {
        let mixer = AudioMixer()
        nonisolated(unsafe) var output: [Float] = []
        mixer.onMixBlock = { block in output.append(contentsOf: block) }
        mixer.setChannels(channels, master: master)
        mixer.start(at: 100, timer: false)
        mixer.queue.sync {}
        return (mixer, { mixer.queue.sync { output } })
    }
    private func run(_ mixer: AudioMixer, until seconds: Double) { mixer.queue.sync { mixer.tick(now: 100 + seconds + AudioFormat.latency) } }
    private func constant(_ value: Float, seconds: Double) -> [Float] { [Float](repeating: value, count: Int(AudioFormat.frames(seconds: seconds)) * 2) }
    private func write(_ samples: [Float], to channel: MixChannel, at seconds: Double) {
        samples.withUnsafeBufferPointer { channel.write($0, hostTime: 100 + seconds) }
    }

    func testChannelsAreSummedWithTheirVolumeAndMuteAndTheMixVolume() {
        var half = ChannelMix(); half.volume = -6.0206
        let a = MixChannel(id: "a", name: "A", mix: ChannelMix(), active: true)
        let b = MixChannel(id: "b", name: "B", mix: half, active: true)
        var muted = ChannelMix(); muted.muted = true
        let c = MixChannel(id: "c", name: "C", mix: muted, active: true)
        let (mixer, output) = mixer([a, b, c])
        write(constant(0.25, seconds: 0.5), to: a, at: 0)
        write(constant(0.5, seconds: 0.5), to: b, at: 0)
        write(constant(0.9, seconds: 0.5), to: c, at: 0)
        run(mixer, until: 0.4)
        let out = output()
        XCTAssertGreaterThan(out.count, 2 * 18_000)
        // After the first block's fade-in (new channels start from silence), A + half of B = 0.5.
        XCTAssertEqual(out[4096], 0.5, accuracy: 0.001)
        XCTAssertEqual(out.last!, 0.5, accuracy: 0.001, "The muted channel adds nothing")
    }
    func testOnlyChannelsOfTheLiveSceneAreHeard() {
        let live = MixChannel(id: "live", name: "Live", mix: ChannelMix(), active: true)
        let other = MixChannel(id: "other", name: "Other scene", mix: ChannelMix(), active: false)
        let (mixer, output) = mixer([live, other])
        write(constant(0.1, seconds: 0.3), to: live, at: 0); write(constant(0.7, seconds: 0.3), to: other, at: 0)
        run(mixer, until: 0.25)
        XCTAssertEqual(output().last!, 0.1, accuracy: 0.0001)
    }
    func testLevelsAreReportedPerChannelAndForTheMix() {
        let a = MixChannel(id: "a", name: "A", mix: ChannelMix(), active: true)
        let (mixer, _) = mixer([a])
        nonisolated(unsafe) var levels: ([String: ChannelLevel], ChannelLevel)?
        mixer.onLevels = { levels = ($0, $1) }
        write(constant(0.5, seconds: 0.5), to: a, at: 0)
        run(mixer, until: 0.4)
        let reported = mixer.queue.sync { levels }
        XCTAssertEqual(reported?.0["a"]?.peakDB ?? -120, -6.02, accuracy: 0.05)
        XCTAssertEqual(reported?.1.rmsDB ?? -120, -6.02, accuracy: 0.05)
        XCTAssertEqual(reported?.0["a"]?.clipping, false)
    }
    func testOffsetMovesAChannelOnTheTimeline() {
        var delayed = ChannelMix(); delayed.offsetMilliseconds = 100
        let a = MixChannel(id: "a", name: "A", mix: delayed, active: true)
        let (mixer, output) = mixer([a])
        write(constant(1, seconds: 0.05), to: a, at: 0.2) // a click at 0.2 s, delayed to 0.3 s
        run(mixer, until: 0.5)
        let left = stride(from: 0, to: output().count, by: 2).map { output()[$0] }
        let first = left.firstIndex { $0 > 0.5 }!
        XCTAssertEqual(Double(first) / AudioFormat.sampleRate, 0.3, accuracy: 0.001)
    }
    func testStoppedMixerIgnoresWritesAndReportsSilence() {
        let a = MixChannel(id: "a", name: "A", mix: ChannelMix(), active: true)
        let (mixer, _) = mixer([a])
        nonisolated(unsafe) var last: [String: ChannelLevel] = [:]
        mixer.onLevels = { levels, _ in last = levels }
        mixer.stop()
        write(constant(1, seconds: 0.1), to: a, at: 0)
        XCTAssertEqual(last["a"], .silent)
        XCTAssertNil(mixer.startTime)
    }
    func testConverterCentresMonoAndResamplesToTheMixFormat() throws {
        let a = MixChannel(id: "a", name: "A", mix: ChannelMix(), active: true)
        let (mixer, output) = mixer([a])
        let input = ChannelInput(); input.attach(a)
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 44_100))
        buffer.frameLength = 4_410
        // Ten consecutive 0.1 s buffers at 44.1 kHz, then silence.
        for n in 0..<10 {
            for i in 0..<4_410 { buffer.floatChannelData![0][i] = 0.4 }
            input.write(buffer, hostTime: 100 + Double(n) * 0.1)
        }
        run(mixer, until: 1.3)
        let out = output()
        XCTAssertEqual(out[20_000], 0.4, accuracy: 0.01); XCTAssertEqual(out[20_001], 0.4, accuracy: 0.01, "Mono reaches both sides")
        let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
        // The first block fades in from silence (new channels never start with a click).
        let start = left.firstIndex { $0 > 0.001 }!, end = left.lastIndex { $0 > 0.2 }!
        XCTAssertEqual(Double(start) / AudioFormat.sampleRate, 0, accuracy: 0.002)
        // The resampler keeps its last few milliseconds until more input arrives; everything before is in place.
        XCTAssertEqual(Double(end) / AudioFormat.sampleRate, 1.0, accuracy: 0.02, "One second at 44.1 kHz stays one second at 48 kHz")
        XCTAssertFalse(left[AudioFormat.blockFrames...(end - 2_000)].contains { $0 < 0.39 }, "No gaps between converted buffers")
        XCTAssertEqual(a.timeline.resyncs, 0)
    }
    @MainActor func testChannelListPutsMicrophonesFirstThenLayersWithAudio() {
        var audio = AudioPreferences(); audio.microphones = [MicrophoneChannel(deviceID: "yeti", name: "Yeti")]
        var scenes = CameraScene.defaults()
        var page = SceneLayer(name: "Page", source: .browser(BrowserSettings())); page.audio = LayerAudio(enabled: true)
        var page2 = SceneLayer(name: "Page 2", source: .browser(BrowserSettings())); page2.audio = LayerAudio(enabled: true)
        var quiet = SceneLayer(name: "Quiet", source: .display(nil)); quiet.audio = LayerAudio(enabled: false)
        var screen = SceneLayer(name: "Screen", source: .display(nil)); screen.audio = LayerAudio(enabled: true)
        scenes[1].layers += [page, quiet, screen]; scenes[2].layers.append(page2)
        let list = AudioRuntime.channelList(audio: audio, scenes: scenes)
        XCTAssertEqual(list.map(\.id), ["mic:yeti", screen.id.uuidString, "browser"])
        XCTAssertEqual(list.map(\.name), ["Yeti", "Screen", "Browser pages"], "All browser layers share one channel")
    }
}

final class MeetingExclusionTests: XCTestCase {
    private let own: pid_t = 100
    func testAppsAndTheirHelpersUsingAMicrophoneAreRecognised() {
        let users = [AudioInputUsers.Process(pid: 7, bundleID: "com.google.Chrome.helper")]
        XCTAssertTrue(AudioInputUsers.isUsingInput(pid: 3, bundleID: "com.google.Chrome", users: users, own: own), "A helper process counts for its app")
        XCTAssertFalse(AudioInputUsers.isUsingInput(pid: 4, bundleID: "com.google.ChromeCanary", users: users, own: own), "Only helpers below the app's identifier")
        XCTAssertTrue(AudioInputUsers.isUsingInput(pid: 7, bundleID: "", users: users, own: own), "Matched by process when there is no identifier")
        XCTAssertFalse(AudioInputUsers.isUsingInput(pid: own, bundleID: "com.vanguardsignals.AppleCam",
            users: [.init(pid: own, bundleID: "com.vanguardsignals.AppleCam")], own: own), "AppleCam's own microphones never exclude it")
    }
    func testMicrophoneUsersWithoutACapturableAppAreReported() {
        let users: [AudioInputUsers.Process] = [.init(pid: 1, bundleID: "com.apple.replayd"), .init(pid: 2, bundleID: "us.zoom.xos"),
                                                .init(pid: 3, bundleID: "com.example.hidden"), .init(pid: own, bundleID: "com.vanguardsignals.AppleCam")]
        let unmatched = AudioInputUsers.unmatched(users, apps: [(2, "us.zoom.xos")], own: own)
        XCTAssertEqual(unmatched.map(\.bundleID), ["com.example.hidden"], "Apple services, filterable apps and AppleCam itself are not reported")
    }
}

final class CameraDelayTests: XCTestCase {
    func testOnlyMicrophonesAreDelayedByTheCameraPictureAge() {
        let mic = MixChannel(id: "mic", name: "Mic", mix: ChannelMix(), active: true, followsCamera: true)
        let clip = MixChannel(id: "clip", name: "Clip", mix: ChannelMix(), active: true)
        let mixer = AudioMixer()
        nonisolated(unsafe) var output: [Float] = []
        mixer.onMixBlock = { output.append(contentsOf: $0) }
        mixer.setChannels([mic, clip], master: ChannelMix())
        mixer.start(at: 100, timer: false)
        mixer.setVideoDelay(0.05)
        mixer.queue.sync {}
        let click = [Float](repeating: 0.5, count: 480 * 2) // 10 ms
        click.withUnsafeBufferPointer { mic.write($0, hostTime: 100.2); clip.write($0, hostTime: 100.4) }
        mixer.queue.sync { mixer.tick(now: 100 + 0.8 + AudioFormat.latency) }
        let left = stride(from: 0, to: output.count, by: 2).map { output[$0] }
        let onsets = left.indices.filter { $0 > 0 && left[$0] > 0.25 && left[$0 - 1] <= 0.25 }.map { Double($0) / AudioFormat.sampleRate }
        XCTAssertEqual(onsets.count, 2)
        XCTAssertEqual(onsets[0], 0.25, accuracy: 0.001, "The microphone is delayed by the 50 ms picture age")
        XCTAssertEqual(onsets[1], 0.40, accuracy: 0.001, "Layer sound is not")
    }
}
