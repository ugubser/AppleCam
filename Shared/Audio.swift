import Foundation

/// Every channel is converted to this format before mixing: 48 kHz, 32-bit float, interleaved stereo.
public enum AudioFormat {
    public static let sampleRate: Double = 48_000
    public static let channels = 2
    /// Frames per mixing block (about 21 ms).
    public static let blockFrames = 1024
    /// The mixer runs this far behind real time so late-arriving buffers (Bluetooth, screen capture) still land in place.
    public static let latency: Double = 0.15
    public static func frames(seconds: Double) -> Int64 { Int64((seconds * sampleRate).rounded()) }
}

public enum AudioMath {
    public static let minimumDB: Float = -60
    public static let maximumDB: Float = 12
    /// Linear gain for a fader value in dB; the bottom of the fader is silence.
    public static func gain(dB: Float) -> Float { dB <= minimumDB ? 0 : powf(10, dB / 20) }
    /// dBFS of a linear amplitude, floored at -120 dB.
    public static func decibels(_ amplitude: Float) -> Float { amplitude <= 0.000001 ? -120 : 20 * log10f(amplitude) }
}

/// Volume, mute and timing of one channel (or of the whole mix). Never serialized with running state.
public struct ChannelMix: Codable, Equatable, Sendable {
    /// Fader position in dB (−60 … +12); −60 is silence.
    public var volume: Float = 0
    public var muted = false
    /// Positive values delay this channel, negative values advance it (to line up a late Bluetooth microphone).
    public var offsetMilliseconds: Double = 0
    public init() {}
    public static let offsetRange: ClosedRange<Double> = -100...300
    public var isValid: Bool {
        volume.isFinite && (AudioMath.minimumDB...AudioMath.maximumDB).contains(volume) &&
        offsetMilliseconds.isFinite && Self.offsetRange.contains(offsetMilliseconds)
    }
    public var gain: Float { muted ? 0 : AudioMath.gain(dB: volume) }
}

/// Audio of a browser, window, screen or clip layer.
public struct LayerAudio: Codable, Equatable, Sendable {
    public var enabled = false
    public var mix = ChannelMix()
    public init(enabled: Bool = false) { self.enabled = enabled }
}

public struct MicrophoneChannel: Codable, Equatable, Sendable, Identifiable {
    public var deviceID: String
    public var name: String
    public var mix = ChannelMix()
    public var id: String { deviceID }
    public init(deviceID: String, name: String) { self.deviceID = deviceID; self.name = name }
    public var isValid: Bool { !deviceID.isEmpty && !name.isEmpty && mix.isValid }
}

public struct AudioPreferences: Codable, Equatable, Sendable {
    /// Microphones in the mix, heard in every scene.
    public var microphones: [MicrophoneChannel] = []
    public var master = ChannelMix()
    /// Plays the mix on `monitorDeviceUID` (nil: the system output).
    public var monitor = false
    public var monitorDeviceUID: String?
    /// All browser layers share one channel: WebKit plays every page through one audio process.
    public var browser = ChannelMix()
    public init() {}
    public var isValid: Bool {
        microphones.allSatisfy(\.isValid) && Set(microphones.map(\.deviceID)).count == microphones.count && master.isValid && browser.isValid
    }
    private enum CodingKeys: String, CodingKey { case microphones, master, monitor, monitorDeviceUID, browser }
    /// Settings saved before a field existed keep their other values; the missing field takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        microphones = try c.decodeIfPresent([MicrophoneChannel].self, forKey: .microphones) ?? []
        master = try c.decodeIfPresent(ChannelMix.self, forKey: .master) ?? ChannelMix()
        monitor = try c.decodeIfPresent(Bool.self, forKey: .monitor) ?? false
        monitorDeviceUID = try c.decodeIfPresent(String.self, forKey: .monitorDeviceUID)
        browser = try c.decodeIfPresent(ChannelMix.self, forKey: .browser) ?? ChannelMix()
    }
}

/// Peak and RMS of a block, with a clipping indicator that stays lit for `clipHold` seconds.
public struct LevelMeter: Equatable, Sendable {
    public static let clipHold: Double = 2
    public private(set) var peak: Float = 0
    public private(set) var rms: Float = 0
    public private(set) var clippedAt: Double?
    public init() {}
    public mutating func measure(_ samples: UnsafeBufferPointer<Float>, at time: Double) {
        var peak: Float = 0, sum: Float = 0
        for s in samples { let a = abs(s); if a > peak { peak = a }; sum += s * s }
        self.peak = peak; rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
        if peak >= 0.999 { clippedAt = time }
    }
    public mutating func silence() { peak = 0; rms = 0 }
    public func clipping(at time: Double) -> Bool { clippedAt.map { time - $0 < Self.clipHold } ?? false }
    public var peakDB: Float { AudioMath.decibels(peak) }
    public var rmsDB: Float { AudioMath.decibels(rms) }
}

/// One channel's samples placed on the shared mix timeline (absolute frame positions at 48 kHz from the session start).
/// Sources write by timestamp; the mixer reads each range once and clears it, so gaps read as silence.
///
/// Every device runs on its own clock. Consecutive buffers are written back to back and gently pulled toward their
/// timestamps by inserting or dropping one frame per buffer when they drift more than `slewThreshold`, which corrects
/// several thousand ppm without audible jumps. Only a jump larger than `resyncThreshold` (a real dropout) re-anchors.
///
/// A channel can have several streams (each frame of a web page plays its own): each stream keeps its own position
/// and the streams are summed.
public final class ChannelTimeline: @unchecked Sendable {
    public static let slewThreshold: Int64 = 48       // 1 ms
    public static let resyncThreshold: Int64 = 4_800  // 100 ms
    private let lock = NSLock()
    private var storage: [Float]
    private let capacity: Int64
    private var readHead: Int64 = 0
    private var next: [Int: Int64] = [:]
    public private(set) var droppedLate = 0
    public private(set) var resyncs = 0
    public init(seconds: Double = 4) {
        capacity = AudioFormat.frames(seconds: seconds)
        storage = Array(repeating: 0, count: Int(capacity) * AudioFormat.channels)
    }
    /// Adds interleaved stereo frames of `stream` whose first frame belongs at `position`.
    public func write(_ samples: UnsafeBufferPointer<Float>, at position: Int64, stream: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        let c = AudioFormat.channels, count = samples.count / c
        guard count > 0 else { return }
        var start = position, written = count
        if let expected = next[stream] {
            let drift = position - expected
            if abs(drift) <= Self.resyncThreshold {
                start = expected
                if drift > Self.slewThreshold { written = count + 1 }                  // falling behind: repeat the last frame
                else if drift < -Self.slewThreshold, count > 1 { written = count - 1 } // running ahead: drop the last frame
            } else { resyncs += 1 }
        }
        next[stream] = start + Int64(written)
        for i in 0..<written {
            let at = start + Int64(i), source = min(i, count - 1)
            guard at >= readHead else { droppedLate += 1; continue }
            guard at < readHead + capacity else { continue }
            let slot = Int(at % capacity) * c
            for k in 0..<c { storage[slot + k] += samples[source * c + k] }
        }
    }
    /// Copies frames [position, position + count) into `out` (interleaved stereo) and clears them.
    public func read(into out: UnsafeMutableBufferPointer<Float>, from position: Int64, count: Int) {
        lock.lock(); defer { lock.unlock() }
        let c = AudioFormat.channels
        for i in 0..<count {
            let at = position + Int64(i)
            for k in 0..<c { out[i * c + k] = 0 }
            guard at >= readHead, at < readHead + capacity else { continue }
            let slot = Int(at % capacity) * c
            for k in 0..<c { out[i * c + k] = storage[slot + k]; storage[slot + k] = 0 }
        }
        readHead = max(readHead, position + Int64(count))
    }
    /// Starts a new run (after a source restarts): the next buffer of every stream anchors at its own timestamp.
    public func restart() { lock.lock(); next = [:]; lock.unlock() }
    /// Forgets a stream that ended (its frame went away).
    public func forget(stream: Int) { lock.lock(); next[stream] = nil; lock.unlock() }
    public var streamCount: Int { lock.lock(); defer { lock.unlock() }; return next.count }
}

/// Applies per-channel gain (ramped across the block so fader moves never click) and sums channels into the mix.
public enum MixMath {
    /// Multiplies interleaved stereo `samples` by a gain moving linearly from `from` to `to` across the block.
    public static func applyGain(_ samples: UnsafeMutableBufferPointer<Float>, from: Float, to: Float) {
        let c = AudioFormat.channels, frames = samples.count / c
        guard frames > 0 else { return }
        if from == to { for i in samples.indices { samples[i] *= to }; return }
        for f in 0..<frames {
            let g = from + (to - from) * Float(f + 1) / Float(frames)
            for k in 0..<c { samples[f * c + k] *= g }
        }
    }
    public static func add(_ source: UnsafeBufferPointer<Float>, into mix: UnsafeMutableBufferPointer<Float>) {
        for i in 0..<min(source.count, mix.count) { mix[i] += source[i] }
    }
}

/// Mono or multichannel input is reduced to the stereo mix format: mono is centred, extra channels are dropped.
public enum ChannelLayoutMath {
    public static func stereo(from input: [[Float]]) -> [Float] {
        guard let first = input.first else { return [] }
        let right = input.count > 1 ? input[1] : first
        var out = [Float](repeating: 0, count: first.count * 2)
        for i in 0..<first.count { out[2 * i] = first[i]; out[2 * i + 1] = right[i] }
        return out
    }
}

/// Finding AppleCam's WebKit audio process: AppleCam plays a quiet, high tone at a frequency chosen at random for each
/// search in a page of its own, listens briefly to every WebKit audio process and keeps the one that carries the tone.
/// There is no public API that names the app a WebKit process plays for, and another app's WebKit process must never be
/// muted, so the search succeeds only when exactly one process carries the tone.
public enum WebKitAudioSignature {
    /// The tone's candidate frequencies: above most program material and most adults' hearing, below 20 kHz.
    public static let frequencies: [Double] = stride(from: 17_000.0, through: 19_000.0, by: 50).map { $0 }
    /// The tone's amplitude (−40 dBFS): quiet, and short, but far above the detector's floor.
    public static let amplitude = 0.01
    public static let seconds = 1.5
    /// A process carries the tone when it is at least this loud and this far above its neighbours.
    public static let minimumDB = -70.0
    public static let contrastDB = 20.0
    /// Neighbouring frequencies compared with the tone (any other sound is broad, the tone is one line).
    public static let neighbourOffsets = [-450.0, -300.0, 300.0, 450.0]

    /// Interleaved 16-bit mono WAV of the tone, with 20 ms fades so it never clicks.
    public static func wav(frequency: Double, sampleRate: Double = AudioFormat.sampleRate) -> Data {
        let frames = Int(seconds * sampleRate), fade = Int(0.02 * sampleRate)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        for i in 0..<frames {
            let envelope = min(1, Double(i) / Double(fade), Double(frames - 1 - i) / Double(fade))
            append(Int16((amplitude * envelope * sin(2 * .pi * frequency * Double(i) / sampleRate) * 32767).rounded()))
        }
        return data
    }
    /// Amplitude of `frequency` in dBFS (a full-scale sine reads 0 dB).
    public static func level(_ samples: [Float], frequency: Double, sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return -120 }
        let w = 2 * Double.pi * frequency / sampleRate, c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples { let s0 = Double(x) + c * s1 - s2; s2 = s1; s1 = s0 }
        let amplitude = 2 * sqrt(max(s1 * s1 + s2 * s2 - c * s1 * s2, 0)) / Double(samples.count)
        return amplitude > 1e-6 ? 20 * log10(amplitude) : -120
    }
    /// Whether `samples` (one channel) carry the tone.
    public static func carries(_ samples: [Float], frequency: Double, sampleRate: Double) -> Bool {
        let tone = level(samples, frequency: frequency, sampleRate: sampleRate)
        let around = neighbourOffsets.map { level(samples, frequency: frequency + $0, sampleRate: sampleRate) }.max() ?? -120
        return tone >= minimumDB && tone - around >= contrastDB
    }
    public enum Outcome: Equatable { case found(Int32), none, several([Int32]) }
    /// The one process that carried the tone; none or several is a failure, never a guess.
    public static func choose(_ carried: [Int32: Bool]) -> Outcome {
        let matches = carried.filter(\.value).map(\.key).sorted()
        switch matches.count { case 1: return .found(matches[0]); case 0: return .none; default: return .several(matches) }
    }
}
