#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AVFoundation
import CoreAudio
import os

struct AudioOutputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
    var id: String { uid }
    /// Devices with at least one output stream.
    static func all() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(uid: uid, name: name, deviceID: id)
        }
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Interleaved stereo frames from the mixer queue to the output's render thread. Overflow drops the oldest frames;
/// underflow plays silence. The lock is held only to copy samples.
final class MonitorRing: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var storage: [Float]
    private let capacity: Int
    private var read = 0, count = 0
    init(seconds: Double = 0.5) { capacity = Int(AudioFormat.frames(seconds: seconds)); storage = Array(repeating: 0, count: capacity * 2) }
    func push(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        let frames = samples.count / 2
        for f in 0..<frames {
            if count == capacity { read = (read + 1) % capacity; count -= 1 }
            let slot = (read + count) % capacity
            storage[slot * 2] = samples[f * 2]; storage[slot * 2 + 1] = samples[f * 2 + 1]; count += 1
        }
    }
    /// Fills `left` and `right` with up to `frames` frames, then silence; returns the frames that had data.
    @discardableResult func pull(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let available = min(frames, count)
        for f in 0..<available {
            let slot = (read + f) % capacity
            left[f] = storage[slot * 2]; right[f] = storage[slot * 2 + 1]
        }
        for f in available..<frames { left[f] = 0; right[f] = 0 }
        read = (read + available) % capacity; count -= available
        return available
    }
}

/// Plays the mix on one output device, about 0.2 s behind the picture (the mixer waits for late sources).
final class AudioMonitor {
    private let engine = AVAudioEngine()
    private let ring = MonitorRing()
    private var node: AVAudioSourceNode?
    private(set) var deviceUID: String?
    var isRunning: Bool { engine.isRunning }
    func push(_ samples: UnsafeBufferPointer<Float>) { ring.push(samples) }
    func start(deviceUID: String?) throws {
        if engine.isRunning && deviceUID == self.deviceUID { return }
        stop()
        if let deviceUID {
            guard let device = AudioOutputDevice.all().first(where: { $0.uid == deviceUID }) else {
                throw CameraError.message("The monitor output is not connected. Choose another output for Monitor.")
            }
            try engine.outputNode.auAudioUnit.setDeviceID(device.deviceID)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioFormat.sampleRate, channels: 2)!
        let ring = ring
        let node = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.pull(left: left, right: right, frames: Int(frames))
            return noErr
        }
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        self.node = node; self.deviceUID = deviceUID
        do { try engine.start() } catch { stop(); throw error }
    }
    func stop() {
        engine.stop()
        if let node { engine.detach(node) }; node = nil; deviceUID = nil
    }
}
