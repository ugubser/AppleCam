#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AVFoundation

/// Converts any linear-PCM input (any rate, mono or stereo, interleaved or not) to the mix format and writes it
/// into a channel. One instance per source stream; called from that stream's delivery thread only.
final class ChannelInput: @unchecked Sendable {
    /// Which of the channel's streams this input writes (see `ChannelTimeline`).
    let stream: Int
    init(stream: Int = 0) { self.stream = stream }
    private let lock = NSLock()
    private var channel: MixChannel?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    /// Frames fed to and produced by the converter since it was created. A resampler holds back part of each buffer
    /// until more arrives; the held amount tells how far before this buffer's timestamp its first output frame belongs.
    private var convertedIn: Double = 0
    private var convertedOut: Double = 0
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate, channels: 2, interleaved: true)!
    func attach(_ channel: MixChannel?) { lock.withLock { self.channel = channel } }
    var isAttached: Bool { lock.withLock { channel != nil } }

    /// Writes a Core Media audio sample whose first frame was captured at `hostTime`.
    func write(_ sample: CMSampleBuffer, hostTime: Double) {
        guard isAttached, let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: [asbd]) else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        write(buffer, hostTime: hostTime)
    }
    /// Writes a PCM buffer whose first frame was captured at `hostTime`.
    func write(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        guard let channel = lock.withLock({ self.channel }), buffer.frameLength > 0 else { return }
        let format = buffer.format
        if format.commonFormat == .pcmFormatFloat32, format.sampleRate == AudioFormat.sampleRate, format.channelCount == 2,
           format.isInterleaved, let data = buffer.floatChannelData {
            channel.write(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength) * 2), hostTime: hostTime, stream: stream); return
        }
        if inputFormat != format {
            inputFormat = format; converter = AVAudioConverter(from: format, to: target); convertedIn = 0; convertedOut = 0
            // Mono sources are centred rather than sent to the left channel only.
            if format.channelCount == 1 { converter?.channelMap = [0, 0] }
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * AudioFormat.sampleRate / format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        let held = convertedIn * AudioFormat.sampleRate / format.sampleRate - convertedOut
        convertedIn += Double(buffer.frameLength); convertedOut += Double(out.frameLength)
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
        channel.write(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength) * 2), hostTime: hostTime - held / AudioFormat.sampleRate, stream: stream)
    }
}

struct AudioInputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
    static func all() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            .map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }
}

/// One microphone in its own capture session, delivering into one channel.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let uid: String
    let input = ChannelInput()
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.vanguardsignals.AppleCam.microphone", qos: .userInteractive)
    private var observers: [NSObjectProtocol] = []
    /// Called once on the main actor when the microphone stops delivering (disconnect or session error).
    var onFailure: ((String) -> Void)?
    init(uid: String) { self.uid = uid; super.init() }
    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CameraError.message("Microphone access is needed. Allow AppleCam in System Settings → Privacy & Security → Microphone.")
        }
        guard let device = AVCaptureDevice(uniqueID: uid) else { throw CameraError.message("The microphone is not connected.") }
        session.beginConfiguration()
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { session.commitConfiguration(); throw CameraError.message("\(device.localizedName) cannot be opened.") }
        session.addInput(deviceInput)
        let output = AVCaptureAudioDataOutput()
        // Delivered already in the mix format, so no conversion runs on most microphones.
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioFormat.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw CameraError.message("\(device.localizedName) cannot deliver audio.") }
        session.addOutput(output)
        session.commitConfiguration()
        let name = device.localizedName
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onFailure?("\(name) stopped: \(error?.localizedDescription ?? "the audio session failed").")
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
            self?.onFailure?("\(name) was disconnected.")
        })
        session.startRunning()
    }
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        input.attach(nil); session.stopRunning()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let time = try? CaptureFrameTiming.hostTimestamp(sampleBuffer.presentationTimeStamp, from: session.synchronizationClock) else { return }
        input.write(sampleBuffer, hostTime: time.seconds)
    }
}

/// What a layer's sound source reports to the mixer strip.
enum AudioReport {
    /// Why the source is (partly) left out, or nil when it is captured normally.
    case note(String?)
    /// The source stopped delivering.
    case failure(String)
}

/// Sources that can contribute a layer's sound to the mix.
protocol AudioCapableSource: AnyObject {
    /// Starts (non-nil) or stops delivering this layer's sound into `channel`.
    @MainActor func setAudioChannel(_ channel: MixChannel?, report: @escaping @MainActor (AudioReport) -> Void)
}

/// Keeps the mixer's channels in step with the saved audio settings and the live scene. Main actor only.
@MainActor final class AudioRuntime {
    let mixer: AudioMixer
    let monitor = AudioMonitor()
    private var channels: [String: MixChannel] = [:]
    private var microphones: [String: MicrophoneCapture] = [:]
    private var attached: [UUID: ObjectIdentifier] = [:]
    /// Browser layers' sound, shared by all of them; pages are audible only once it is muted on the speakers.
    private var browserCapture: BrowserAudioCapture?
    private var browserReady = false
    /// Whether browser layers' sound is being captured (and kept off the speakers).
    var browserSoundReady: Bool { browserReady }
    private var browserLayers: [UUID: Bool] = [:]
    private var lookup: ((UUID) -> SceneMediaSource?)?
    /// A channel stopped (channel ID, explanation).
    var onFailure: ((String, String) -> Void)?
    /// A channel's note changed (channel ID, explanation or nil).
    var onNote: ((String, String?) -> Void)?
    init(mixer: AudioMixer) {
        self.mixer = mixer
        let monitor = monitor
        mixer.onMixBlock = { monitor.push($0) }
    }

    /// Channel IDs and names in track order: microphones, layers with audio (browser layers share one channel).
    static func channelList(audio: AudioPreferences, scenes: [CameraScene]) -> [(id: String, name: String)] {
        let layers = scenes.flatMap(\.layers).filter(\.hasAudio)
        var list = audio.microphones.map { (id: AudioChannelID.microphone($0.deviceID), name: $0.name) }
        list += layers.filter { !$0.source.isBrowser }.map { (id: AudioChannelID.layer($0.id), name: $0.name) }
        if layers.contains(where: \.source.isBrowser) { list.append((AudioChannelID.browser, AudioChannelID.browserName)) }
        return list
    }
    /// Applies settings while a scene runs; `source(id)` returns the layer's running source when it has one.
    func configure(audio: AudioPreferences, scenes: [CameraScene], live: CameraScene, source: @escaping (UUID) -> SceneMediaSource?) {
        var next: [MixChannel] = []
        var wantedMics = Set<String>()
        for mic in audio.microphones {
            let id = AudioChannelID.microphone(mic.deviceID)
            let channel = channel(id: id, name: mic.name, followsCamera: true); channel.update(mix: mic.mix, active: true); next.append(channel)
            wantedMics.insert(mic.deviceID)
            if microphones[mic.deviceID] == nil {
                let capture = MicrophoneCapture(uid: mic.deviceID)
                capture.onFailure = { [weak self, weak capture] message in
                    guard let self, let capture, self.microphones[mic.deviceID] === capture else { return }
                    capture.stop(); self.microphones[mic.deviceID] = nil; self.onFailure?(id, message)
                }
                do { try capture.start(); capture.input.attach(channel); microphones[mic.deviceID] = capture }
                catch { onFailure?(id, error.localizedDescription) }
            }
        }
        for (uid, capture) in microphones where !wantedMics.contains(uid) { capture.stop(); microphones[uid] = nil }
        let liveLayers = Set(live.layers.filter(\.visible).map(\.id))
        var attachedNow: [UUID: ObjectIdentifier] = [:]
        let all = scenes.flatMap(\.layers)
        for layer in all where layer.hasAudio && !layer.source.isBrowser {
            let id = AudioChannelID.layer(layer.id)
            let channel = channel(id: id, name: layer.name)
            channel.update(mix: layer.audio?.mix ?? ChannelMix(), active: liveLayers.contains(layer.id)); next.append(channel)
            if let capable = source(layer.id) as? AudioCapableSource {
                if attached[layer.id] != ObjectIdentifier(capable) {
                    capable.setAudioChannel(channel) { [weak self] report in self?.forward(report, id: id) }
                }
                attachedNow[layer.id] = ObjectIdentifier(capable)
            }
        }
        for layer in all where !layer.hasAudio && attached[layer.id] != nil {
            (source(layer.id) as? AudioCapableSource)?.setAudioChannel(nil) { _ in }
        }
        attached = attachedNow
        // Browser layers: one capture of AppleCam's WebKit sound; each layer's switch decides whether its page sounds.
        lookup = source
        browserLayers = Dictionary(uniqueKeysWithValues: all.filter(\.source.isBrowser).map { ($0.id, $0.hasAudio) })
        let audible = all.filter { $0.hasAudio && $0.source.isBrowser }
        if !audible.isEmpty {
            let channel = channel(id: AudioChannelID.browser, name: AudioChannelID.browserName)
            channel.update(mix: audio.browser, active: audible.contains { liveLayers.contains($0.id) }); next.append(channel)
            startBrowserCapture(into: channel, layers: audible.map(\.id))
        } else { stopBrowserCapture() }
        applyPageSound()
        channels = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        mixer.setChannels(next, master: audio.master)
        if audio.monitor {
            do { try monitor.start(deviceUID: audio.monitorDeviceUID) } catch { monitor.stop(); onFailure?("monitor", error.localizedDescription) }
        } else { monitor.stop() }
    }
    private func startBrowserCapture(into channel: MixChannel, layers: [UUID]) {
        // The sound waits for the slowest page picture among the audible layers.
        let ages = layers.compactMap { lookup?($0) as? BrowserSceneSource }
        if let browserCapture {
            browserCapture.input.attach(channel)
            browserCapture.delay = { min(ages.map(\.pictureAge).max() ?? 0, AudioFormat.latency * 0.8) }
            return
        }
        let capture = BrowserAudioCapture()
        capture.input.attach(channel)
        capture.delay = { min(ages.map(\.pictureAge).max() ?? 0, AudioFormat.latency * 0.8) }
        capture.onFailure = { [weak self, weak capture] message in
            guard let self, let capture, self.browserCapture === capture else { return }
            self.stopBrowserCapture(); self.onFailure?(AudioChannelID.browser, message)
        }
        browserCapture = capture
        Task {
            do {
                try await capture.start()
                guard browserCapture === capture else { return }
                browserReady = true; applyPageSound()
            } catch {
                guard browserCapture === capture else { return }
                stopBrowserCapture(); onFailure?(AudioChannelID.browser, error.localizedDescription)
            }
        }
    }
    private func stopBrowserCapture() {
        guard let capture = browserCapture else { return }
        browserCapture = nil; browserReady = false
        applyPageSound()
        capture.input.attach(nil); capture.stop()
    }
    /// A page sounds only while its layer's Audio is on and AppleCam's WebKit sound is muted on the speakers.
    private func applyPageSound() {
        for (id, enabled) in browserLayers { (lookup?(id) as? BrowserSceneSource)?.setSound(enabled && browserReady) }
    }
    private func forward(_ report: AudioReport, id: String) {
        switch report {
        case .note(let note): onNote?(id, note)
        case .failure(let message): onFailure?(id, message)
        }
    }
    /// Stops every microphone and clears the mix (the scene stopped).
    func stop() {
        stopBrowserCapture(); browserLayers = [:]; lookup = nil
        microphones.values.forEach { $0.stop() }; microphones = [:]; attached = [:]; channels = [:]; monitor.stop()
        mixer.setChannels([], master: ChannelMix())
    }
    private func channel(id: String, name: String, followsCamera: Bool = false) -> MixChannel {
        channels[id] ?? MixChannel(id: id, name: name, mix: ChannelMix(), active: false, followsCamera: followsCamera)
    }
}
