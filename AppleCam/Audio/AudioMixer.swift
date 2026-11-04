#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AVFoundation

/// Channel identifiers: microphones are "mic:<device UID>", layers are their layer UUID.
enum AudioChannelID {
    static func microphone(_ uid: String) -> String { "mic:" + uid }
    static func layer(_ id: UUID) -> String { id.uuidString }
}

/// One source's samples on the mix timeline, with its volume, mute and whether its scene is live.
/// Sources write from their own threads; the mixer reads on its queue.
final class MixChannel: @unchecked Sendable {
    let id: String
    let name: String
    let timeline = ChannelTimeline()
    private let lock = NSLock()
    private var mix: ChannelMix
    private var active: Bool
    private var epoch: Double?
    private var extraDelay: Double = 0
    fileprivate var appliedGain: Float = 0
    fileprivate var meter = LevelMeter()
    /// Microphones belong with the webcam picture, which is older than the frame it is composed into; only they are
    /// delayed by that age. Layer sound belongs with its own layer's picture.
    let followsCamera: Bool
    init(id: String, name: String, mix: ChannelMix, active: Bool, followsCamera: Bool = false) {
        self.id = id; self.name = name; self.mix = mix; self.active = active; self.followsCamera = followsCamera
    }
    func update(mix: ChannelMix, active: Bool) { lock.withLock { self.mix = mix; self.active = active } }
    fileprivate func begin(epoch: Double) { lock.withLock { self.epoch = epoch }; timeline.restart() }
    fileprivate func end() { lock.withLock { epoch = nil } }
    /// Delay added to every source sample so sound lines up with the (older) camera picture in the same frame.
    fileprivate func setVideoDelay(_ seconds: Double) { lock.withLock { extraDelay = followsCamera ? seconds : 0 } }
    fileprivate var targetGain: Float { lock.withLock { active ? mix.gain : 0 } }
    /// Interleaved stereo float frames of `stream` captured at `hostTime` (seconds on the host clock).
    func write(_ samples: UnsafeBufferPointer<Float>, hostTime: Double, stream: Int = 0) {
        let state = lock.withLock { () -> (Double, Double)? in epoch.map { ($0, mix.offsetMilliseconds / 1000 + extraDelay) } }
        guard let (epoch, delay) = state, hostTime.isFinite else { return }
        timeline.write(samples, at: AudioFormat.frames(seconds: hostTime + delay - epoch), stream: stream)
    }
}

struct ChannelLevel: Equatable {
    var peakDB: Float
    var rmsDB: Float
    var clipping: Bool
    static let silent = ChannelLevel(peakDB: -120, rmsDB: -120, clipping: false)
}

/// Mixes all channels in fixed blocks, `AudioFormat.latency` behind real time. Everything runs on `queue`.
final class AudioMixer: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.vanguardsignals.AppleCam.audio-mixer", qos: .userInteractive)
    private var channels: [MixChannel] = []
    private var buffers: [[Float]] = []
    private var mixBuffer = [Float](repeating: 0, count: AudioFormat.blockFrames * 2)
    private var master = ChannelMix()
    private var masterGain: Float = 1
    private var masterMeter = LevelMeter()
    private var epoch: Double?
    private var position: Int64 = 0
    private var timer: DispatchSourceTimer?
    private var recorder: SceneRecorder?
    private var recordedChannels: [String] = []
    private var lastMeters: Double = 0
    /// Levels per channel ID and for the mix, about 15 times a second (on the mixer queue).
    var onLevels: (([String: ChannelLevel], ChannelLevel) -> Void)?
    /// The recorder failed while appending audio (on the mixer queue).
    var onRecorderFailure: ((Error) -> Void)?
    /// Each finished mix block (interleaved stereo) for local monitoring.
    var onMixBlock: ((UnsafeBufferPointer<Float>) -> Void)?

    /// Host time of frame 0; nil while stopped.
    var startTime: Double? { queue.sync { epoch } }
    /// Starts the timeline at host time `at` (now by default); `timer: false` leaves ticking to the caller (tests).
    func start(at: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds, timer startTimer: Bool = true) {
        queue.async { [self] in
            guard epoch == nil else { return }
            let now = at
            epoch = now; position = 0
            guard startTimer else { channels.forEach { $0.begin(epoch: now) }; return }
            channels.forEach { $0.begin(epoch: now) }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil; epoch = nil; recorder = nil; lastMeters = 0
            channels.forEach { $0.end() }
            onLevels?(Dictionary(uniqueKeysWithValues: channels.map { ($0.id, .silent) }), .silent)
        }
    }
    /// Replaces the channel set, keeping existing channels (and their buffered samples) by ID.
    func setChannels(_ next: [MixChannel], master: ChannelMix) {
        queue.async { [self] in
            self.master = master
            let old = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
            for channel in next where old[channel.id] !== channel { if let epoch { channel.begin(epoch: epoch) }; channel.setVideoDelay(videoDelay) }
            for channel in channels where !next.contains(where: { $0 === channel }) { channel.end() }
            channels = next
            buffers = next.map { _ in [Float](repeating: 0, count: AudioFormat.blockFrames * 2) }
        }
    }
    private var videoDelay: Double = 0
    func setVideoDelay(_ seconds: Double) {
        let clamped = min(max(seconds, 0), AudioFormat.latency * 0.8)
        queue.async { [self] in videoDelay = clamped; channels.forEach { $0.setVideoDelay(clamped) } }
    }
    /// Starts sending the mix and the given channels (in that order) to `recorder`.
    func attach(_ recorder: SceneRecorder, channels ids: [String]) { queue.async { [self] in self.recorder = recorder; recordedChannels = ids } }
    func detach() { queue.async { [self] in recorder = nil; recordedChannels = [] } }
    /// Mixes any blocks that are due; called by the timer and by tests.
    func tick(now: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds) {
        guard let epoch else { return }
        let due = AudioFormat.frames(seconds: now - epoch - AudioFormat.latency)
        var mixed = false
        while position + Int64(AudioFormat.blockFrames) <= due { mixBlock(epoch: epoch, now: now); mixed = true }
        // Levels describe the newest block, about 15 times a second.
        if mixed && now - lastMeters >= 1.0 / 15 {
            lastMeters = now
            onLevels?(Dictionary(uniqueKeysWithValues: channels.map { ($0.id, ChannelLevel(peakDB: $0.meter.peakDB, rmsDB: $0.meter.rmsDB, clipping: $0.meter.clipping(at: now))) }),
                      ChannelLevel(peakDB: masterMeter.peakDB, rmsDB: masterMeter.rmsDB, clipping: masterMeter.clipping(at: now)))
        }
    }
    private func mixBlock(epoch: Double, now: Double) {
        let frames = AudioFormat.blockFrames
        for i in mixBuffer.indices { mixBuffer[i] = 0 }
        for (index, channel) in channels.enumerated() {
            buffers[index].withUnsafeMutableBufferPointer { block in
                channel.timeline.read(into: block, from: position, count: frames)
                let target = channel.targetGain
                MixMath.applyGain(block, from: channel.appliedGain, to: target); channel.appliedGain = target
                channel.meter.measure(UnsafeBufferPointer(block), at: now)
                mixBuffer.withUnsafeMutableBufferPointer { MixMath.add(UnsafeBufferPointer(block), into: $0) }
            }
        }
        let target = master.gain
        mixBuffer.withUnsafeMutableBufferPointer { mix in
            MixMath.applyGain(mix, from: masterGain, to: target)
            masterMeter.measure(UnsafeBufferPointer(mix), at: now)
            onMixBlock?(UnsafeBufferPointer(mix))
        }
        masterGain = target
        if let recorder {
            let time = CMTimeAdd(CMTime(seconds: epoch, preferredTimescale: 1_000_000_000), CMTime(value: position, timescale: Int32(AudioFormat.sampleRate)))
            do {
                try withTrackPointers { tracks in try recorder.appendAudio(tracks, frames: frames, at: time) }
            } catch { self.recorder = nil; recordedChannels = []; onRecorderFailure?(error) }
        }
        position += Int64(frames)
    }
    /// The mix followed by each recorded channel's block (a channel that left the mix records silence).
    private func withTrackPointers(_ body: ([UnsafeBufferPointer<Float>]) throws -> Void) throws {
        var arrays: [[Float]] = [mixBuffer]
        let silent = [Float](repeating: 0, count: AudioFormat.blockFrames * 2)
        for id in recordedChannels { arrays.append(channels.firstIndex { $0.id == id }.map { buffers[$0] } ?? silent) }
        try withPointers(arrays, [], body)
    }
    private func withPointers(_ arrays: ArraySlice<[Float]>, _ done: [UnsafeBufferPointer<Float>], _ body: ([UnsafeBufferPointer<Float>]) throws -> Void) throws {
        guard let first = arrays.first else { try body(done); return }
        try first.withUnsafeBufferPointer { try withPointers(arrays.dropFirst(), done + [$0], body) }
    }
    private func withPointers(_ arrays: [[Float]], _ done: [UnsafeBufferPointer<Float>], _ body: ([UnsafeBufferPointer<Float>]) throws -> Void) throws {
        try withPointers(arrays[...], done, body)
    }
}
