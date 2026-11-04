#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

protocol SceneMediaSource: AnyObject {
    /// Called on the scene output queue. Nil means startup has not produced a frame yet.
    func image(at hostTime: CMTime) throws -> CIImage?
    @MainActor func activate() async throws
    @MainActor func deactivate() async
}

final class StillSceneSource: SceneMediaSource {
    private let picture: CIImage
    init(url: URL) throws { picture = CIImage(cgImage: try GreenScreenProcessor.loadBackground(url)) }
    func image(at hostTime: CMTime) throws -> CIImage? { picture }
    @MainActor func activate() async throws {}
    @MainActor func deactivate() async {}
}

/// A single player per clip layer survives scene changes. Inactive scenes pause it in place. The player's own output is
/// always silent; with Layer → Audio on, a processing tap copies the sound into the mix.
final class ClipSceneSource: SceneMediaSource, AudioCapableSource, @unchecked Sendable {
    let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastNewFrame: Double = 0
    private var active = false
    private var userPaused = false
    private var observer: NSObjectProtocol?
    @MainActor init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw CameraError.message("macOS cannot decode this video clip. Choose a supported, unprotected video file.")
        }
        item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        item.add(output)
        player = AVPlayer(playerItem: item); player.isMuted = true; player.volume = 0; player.actionAtItemEnd = .none
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self, finished else { return }
                self.lock.lock(); let play = self.active && !self.userPaused; self.lock.unlock()
                if play { self.player.play() }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; player.pause() }
    @MainActor func activate() async throws {
        let paused = lock.withLock { active = true; lastNewFrame = CMClockGetTime(CMClockGetHostTimeClock()).seconds; return userPaused }
        if !paused { player.play() }
    }
    @MainActor func deactivate() async {
        player.pause(); lock.withLock { active = false }
    }
    private var audioTap: ClipAudioTap?
    @MainActor func setAudioChannel(_ channel: MixChannel?, report: @escaping @MainActor (AudioReport) -> Void) {
        guard let channel else {
            audioTap?.input.attach(nil); audioTap = nil
            item.audioMix = nil; player.isMuted = true; player.volume = 0
            return
        }
        if let audioTap { audioTap.input.attach(channel); return }
        let tap = ClipAudioTap(item: item); tap.input.attach(channel); audioTap = tap
        Task { @MainActor in
            do {
                guard let track = try await item.asset.loadTracks(withMediaType: .audio).first else { report(.note("This clip has no sound.")); return }
                guard audioTap === tap else { return }
                item.audioMix = try tap.audioMix(for: track)
                // The tap silences what it passes on, so the player is unmuted only to make it deliver audio.
                player.isMuted = false; player.volume = 1
                report(.note(nil))
            } catch { report(.failure("The clip's sound cannot be read: \(error.localizedDescription)")) }
        }
    }
    @MainActor func togglePause() {
        lock.lock(); userPaused.toggle(); let play = active && !userPaused; lock.unlock()
        if play { player.play() } else { player.pause() }
    }
    @MainActor func restart() { player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return userPaused }
    func image(at hostTime: CMTime) throws -> CIImage? {
        if item.status == .failed { throw item.error ?? CameraError.message("Video decoding failed.") }
        let time = output.itemTime(forHostTime: hostTime.seconds)
        lock.lock(); defer { lock.unlock() }
        if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            latest = buffer; lastNewFrame = hostTime.seconds
        }
        if active && !userPaused && hostTime.seconds - lastNewFrame > 3 {
            throw CameraError.message("The video clip stopped decoding. Output stopped; restart or hide its layer.")
        }
        return latest.map { CIImage(cvPixelBuffer: $0) }
    }
}

/// One retained surface, not an accumulating capture queue. Error/status and pixels change atomically.
final class SourceFrameStore {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var failure: Error?
    private var enabled = false
    private var unavailableSince: Double?
    func begin() { lock.lock(); defer { lock.unlock() }; enabled = true; buffer = nil; failure = nil; unavailableSince = nil }
    func end() { lock.lock(); defer { lock.unlock() }; enabled = false; buffer = nil; failure = nil; unavailableSince = nil }
    func receive(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        guard sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else {
            failure = CameraError.message("Screen capture supplied an invalid frame."); return
        }
        switch status {
        case .complete:
            guard let image = sample.imageBuffer else { failure = CameraError.message("Screen capture supplied no image."); return }
            buffer = image; unavailableSince = nil
        case .idle, .started: break // A static, healthy page/window legitimately retains its last complete surface.
        case .blank, .suspended:
            // Never reuse a surface while the OS has suspended/blanked it. A transient state may recover.
            buffer = nil
            if unavailableSince == nil { unavailableSince = ProcessInfo.processInfo.systemUptime }
        case .stopped:
            failure = CameraError.message("Screen capture is unavailable (status \(status.rawValue)). Output stopped; choose the source again or hide its layer.")
        @unknown default: failure = CameraError.message("Screen capture reported an unsupported state.")
        }
    }
    func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; if enabled { failure = error } }
    func image() throws -> CIImage? {
        lock.lock(); defer { lock.unlock() }; if let failure { throw failure }
        if let since = unavailableSince, ProcessInfo.processInfo.systemUptime - since > 2 {
            throw CameraError.message("Screen capture remains suspended or blank. Output stopped; choose the source again or hide its layer.")
        }
        return buffer.map { CIImage(cvPixelBuffer: $0) }
    }
}

final class CaptureSceneSource: NSObject, SceneMediaSource, SCStreamOutput, SCStreamDelegate, AudioCapableSource {
    private let filter: SCContentFilter
    /// What a layer's sound is: a window layer's app (a muted Core Audio tap, `AppSoundTap`) or all sound on the screen
    /// (an audio-only ScreenCaptureKit stream, `AppAudioCapture`).
    enum Sound: Equatable { case application(pid: pid_t, bundleID: String), display }
    private let sound: Sound
    private var audio: LayerSoundCapture?
    private var audioReport: (@MainActor (AudioReport) -> Void)?
    private var isActive = false
    private let configuration: SCStreamConfiguration
    private let frames = SourceFrameStore()
    private var stream: SCStream?
    private let streamLock = NSLock()
    private let queue = DispatchQueue(label: "com.vanguardsignals.AppleCam.layer-capture", qos: .userInitiated)
    init(filter: SCContentFilter, fps: Double, audio: Sound, cursor: Bool = true) {
        self.filter = filter; sound = audio
        configuration = SCStreamConfiguration()
        // contentRect is in points; capture in pixels so Retina windows and screens stay sharp.
        let size = filter.contentRect.size, scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(2, Int((size.width * scale).rounded())); configuration.height = max(2, Int((size.height * scale).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000_000)
        configuration.queueDepth = 3
        configuration.capturesAudio = false; configuration.showsCursor = cursor
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureDynamicRange = .SDR
        super.init()
    }
    @MainActor func activate() async throws {
        if streamLock.withLock({ stream != nil }) { return }
        let next = SCStream(filter: filter, configuration: configuration, delegate: self)
        try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        streamLock.withLock { stream = next; frames.begin() }
        do { try await next.startCapture() }
        catch { streamLock.withLock { frames.end(); stream = nil }; throw error }
        isActive = true; await startAudio()
    }
    @MainActor func setAudioChannel(_ channel: MixChannel?, report: @escaping @MainActor (AudioReport) -> Void) {
        if let channel {
            let capture = audio ?? makeCapture()
            capture.input.attach(channel); audio = capture; audioReport = report
            capture.onNote = { note in report(.note(note)) }
            capture.onFailure = { message in report(.failure(message)) }
            if isActive { Task { await startAudio() } }
        } else if let old = audio {
            audio = nil; audioReport = nil; report(.note(nil)); old.input.attach(nil)
            Task { await old.stop() }
        }
    }
    @MainActor private func makeCapture() -> LayerSoundCapture {
        switch sound {
        case .application(let pid, let bundleID): return AppSoundTap(pid: pid, bundleID: bundleID)
        case .display: return AppAudioCapture(kind: .display)
        }
    }
    @MainActor private func startAudio() async {
        guard let audio else { return }
        do { try await audio.start() } catch { audioReport?(.failure("Sound capture could not start: \(error.localizedDescription)")) }
    }
    @MainActor func deactivate() async {
        isActive = false
        await audio?.stop()
        guard let old = streamLock.withLock({ () -> SCStream? in
            let old = stream; stream = nil; frames.end(); return old
        }) else { return }
        do { try await old.stopCapture() } catch { /* Already stopped; no replacement source is started. */ }
    }
    func image(at hostTime: CMTime) throws -> CIImage? { try frames.image() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        streamLock.withLock { if type == .screen && self.stream === stream { frames.receive(sampleBuffer) } }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamLock.withLock { if self.stream === stream { frames.fail(error) } }
    }
}
