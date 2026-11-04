#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import AVFoundation
import CoreAudio
import WebKit

/// WebKit plays page sound from a helper process that Core Audio does not attribute to AppleCam, and WebKit has no
/// public mute. A Core Audio process tap on that helper captures it and, muted while tapped, keeps it off the speakers.
/// `WebKitAudioFinder` identifies AppleCam's helper among every app's WebKit helpers; `ProcessTap` taps it.
enum CoreAudioProcess {
    struct Info: Equatable { let object: AudioObjectID; let pid: pid_t; let bundleID: String; let runningOutput: Bool }
    static let webKitAudioBundleID = "com.apple.WebKit.GPU"
    static func all() -> [Info] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var pid: pid_t = 0, running: UInt32 = 0
            guard read(object, kAudioProcessPropertyPID, &pid) else { return nil }
            _ = read(object, kAudioProcessPropertyIsRunningOutput, &running)
            return Info(object: object, pid: pid, bundleID: string(object, kAudioProcessPropertyBundleID) ?? "", runningOutput: running != 0)
        }
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}

/// The first tap makes macOS ask for System Audio Recording permission and waits for the answer, which can take a
/// while. It runs before any search or capture and off the main thread, so the window stays responsive.
enum AudioTapPermission {
    static func request() async throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        try await Task.detached { try ProcessTap(description: description) { _, _ in }.stop() }.value
    }
}

extension CoreAudioProcess {
    /// The process objects that play an app's sound: the app itself and its helpers, whose bundle IDs sit below the
    /// app's (for example `com.google.Chrome.helper`). AppleCam is never included. WebKit's shared audio processes
    /// (`com.apple.WebKit.GPU`) belong to no app this way, so apps that play through WebKit (Safari, Mail) match nothing.
    static func playing(for pid: pid_t, bundleID: String, in processes: [Info], own: pid_t = ProcessInfo.processInfo.processIdentifier) -> [AudioObjectID] {
        processes.filter { process in
            process.pid != own && (process.pid == pid || (!bundleID.isEmpty && (process.bundleID == bundleID || process.bundleID.hasPrefix(bundleID + "."))))
        }.map(\.object).sorted()
    }
}

/// A private Core Audio tap on one process, read through a private aggregate device. Buffers arrive on Core Audio's
/// IO thread with the host time of their first frame.
final class ProcessTap: @unchecked Sendable {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    let format: AVAudioFormat
    /// `muted`: the process is silent on the speakers for as long as the tap runs, and audible again when it stops
    /// (also if AppleCam quits or crashes).
    convenience init(process: AudioObjectID, muted: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) throws {
        try self.init(processes: [process], muted: muted, onBuffer: onBuffer)
    }
    convenience init(processes: [AudioObjectID], muted: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.isPrivate = true; description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
        try self.init(description: description, onBuffer: onBuffer)
    }
    init(description: CATapDescription, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) throws {
        description.name = "AppleCam layer sound"
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            throw CameraError.message("Sound cannot be captured: macOS refused the audio tap. Allow AppleCam under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.")
        }
        var asbd = AudioStreamBasicDescription()
        guard let uid = CoreAudioProcess.string(tap, kAudioTapPropertyUID), CoreAudioProcess.read(tap, kAudioTapPropertyFormat, &asbd),
              let format = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyProcessTap(tap); throw CameraError.message("Sound cannot be captured: the audio tap has no format.")
        }
        self.format = format
        // The aggregate device is clocked by the current output device, which the tapped process plays to.
        var output = AudioObjectID(kAudioObjectUnknown)
        guard CoreAudioProcess.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &output),
              let outputUID = CoreAudioProcess.string(output, kAudioDevicePropertyDeviceUID) else {
            AudioHardwareDestroyProcessTap(tap); throw CameraError.message("Sound cannot be captured: there is no sound output device.")
        }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppleCam browser sound", kAudioAggregateDeviceUIDKey: "com.vanguardsignals.AppleCam.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]]]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &device) == noErr else {
            AudioHardwareDestroyProcessTap(tap); throw CameraError.message("Sound cannot be captured: the audio device for the tap could not be created.")
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil), buffer.frameLength > 0 else { return }
            let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : mach_absolute_time()
            onBuffer(buffer, Double(AudioConvertHostTimeToNanos(host)) / 1e9)
        }
        guard status == noErr, let proc, AudioDeviceStart(device, proc) == noErr else {
            stop(); throw CameraError.message("Sound cannot be captured: the audio tap did not start.")
        }
    }
    func stop() {
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }
    deinit { stop() }
}

/// Finds AppleCam's WebKit audio process (see `WebKitAudioSignature`). The tone plays in a page of its own that is
/// never a browser layer, and the other apps' WebKit processes are only measured for the tone, never recorded.
@MainActor enum WebKitAudioFinder {
    /// What the last search measured, per process: tone level, loudest neighbour and the number of samples heard.
    static var lastReport = ""
    static let notFound = "Browser sound cannot be captured: AppleCam could not find its WebKit audio process. Check that AppleCam is allowed under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then turn the layer's Audio off and on again."
    static func find() async throws -> CoreAudioProcess.Info {
        let frequency = WebKitAudioSignature.frequencies.randomElement()!
        let tone = TonePage(wav: WebKitAudioSignature.wav(frequency: frequency))
        defer { tone.close() }
        let start = Date()
        try await tone.play()
        let played = Date().timeIntervalSince(start)
        // WebKit helpers that play while the tone plays; AppleCam's is one of them.
        let candidates = CoreAudioProcess.all().filter { $0.bundleID == CoreAudioProcess.webKitAudioBundleID && $0.runningOutput }
        let listeners = try await Task.detached { () throws -> [(CoreAudioProcess.Info, ToneListener)] in
            var started: [(CoreAudioProcess.Info, ToneListener)] = []
            do {
                for candidate in candidates {
                    let listener = ToneListener()
                    listener.tap = try ProcessTap(process: candidate.object, muted: false) { buffer, _ in listener.append(buffer) }
                    started.append((candidate, listener))
                }
            } catch { started.forEach { $0.1.tap?.stop() }; throw error }
            return started
        }.value
        let tapped = Date().timeIntervalSince(start)
        // Measure 0.5 s from each tap, waiting up to 2 s for taps to start delivering.
        for _ in 0..<40 where listeners.contains(where: { $0.1.samples().count < Int($0.1.sampleRate / 2) }) { try await Task.sleep(nanoseconds: 50_000_000) }
        var carried: [Int32: Bool] = [:]
        var report: [String] = [String(format: "played after %.2f s, tapped after %.2f s, measured after %.2f s", played, tapped, Date().timeIntervalSince(start))]
        for (candidate, listener) in listeners {
            listener.tap?.stop()
            let samples = listener.samples(), rate = listener.sampleRate
            carried[candidate.pid] = WebKitAudioSignature.carries(samples, frequency: frequency, sampleRate: rate)
            let around = WebKitAudioSignature.neighbourOffsets.map { WebKitAudioSignature.level(samples, frequency: frequency + $0, sampleRate: rate) }.max() ?? -120
            report.append(String(format: "%d: tone %.1f dB, neighbours %.1f dB, %d samples", candidate.pid, WebKitAudioSignature.level(samples, frequency: frequency, sampleRate: rate), around, samples.count))
        }
        lastReport = "\(Int(frequency)) Hz; " + report.joined(separator: "; ")
        switch WebKitAudioSignature.choose(carried) {
        case .found(let pid): return candidates.first { $0.pid == pid }!
        case .none: throw CameraError.message(notFound)
        case .several: throw CameraError.message("Browser sound cannot be captured: more than one WebKit audio process played AppleCam's test tone. Turn the layer's Audio off and on again.")
        }
    }
}

/// The sound of every browser layer (AppleCam's WebKit audio process), muted on the speakers and written into one
/// channel. If WebKit replaces that process the search runs again; if the output device changes the tap is rebuilt.
@MainActor final class BrowserAudioCapture {
    let input = ChannelInput()
    /// The capture stopped and could not be restored.
    var onFailure: ((String) -> Void)?
    /// Extra delay for the sound, so it lines up with the page pictures (read on Core Audio's thread).
    var delay: @Sendable () -> Double = { 0 }
    private var tap: ProcessTap?
    private(set) var process: CoreAudioProcess.Info?
    private var watchers: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var recovering = false
    private var stopped = false

    func start() async throws {
        try await AudioTapPermission.request()
        guard !stopped else { return }
        let found = try await WebKitAudioFinder.find()
        guard !stopped else { return }
        try await tapProcess(found)
        watch()
    }
    func stop() {
        stopped = true
        for (address, block) in watchers { var a = address; AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block) }
        watchers = []; tap?.stop(); tap = nil; process = nil
    }
    private func tapProcess(_ found: CoreAudioProcess.Info) async throws {
        let input = input, delay = delay
        let next = try await Task.detached { try ProcessTap(process: found.object, muted: true) { buffer, host in input.write(buffer, hostTime: host + delay()) } }.value
        guard !stopped else { next.stop(); return }
        tap?.stop(); input.restart(); tap = next; process = found
    }
    private func watch() {
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed(selector) }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr { watchers.append((address, block)) }
        }
    }
    private func changed(_ selector: AudioObjectPropertySelector) {
        guard !stopped, !recovering, let process else { return }
        let gone = !CoreAudioProcess.all().contains { $0.object == process.object && $0.pid == process.pid }
        guard gone || selector == kAudioHardwarePropertyDefaultOutputDevice else { return }
        recovering = true
        Task {
            defer { recovering = false }
            do { try await tapProcess(gone ? WebKitAudioFinder.find() : process) }
            catch { guard !stopped else { return }; stop(); onFailure?(error.localizedDescription) }
        }
    }
}

/// Collects the left channel of a tap, measured for the tone only.
private final class ToneListener: @unchecked Sendable {
    var tap: ProcessTap?
    private let lock = NSLock()
    private var collected: [Float] = []
    private(set) var sampleRate: Double = AudioFormat.sampleRate
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let left = (0..<Int(buffer.frameLength)).map { data[0][$0 * stride] }
        lock.withLock { sampleRate = buffer.format.sampleRate; if collected.count < 96_000 { collected += left } }
    }
    func samples() -> [Float] { lock.withLock { collected } }
}

/// A hidden page that plays the search tone through AppleCam's WebKit audio process.
@MainActor private final class TonePage {
    private let webView: WKWebView
    private let window: NSWindow
    init(wav: Data) {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true; window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = webView; window.orderBack(nil)
        webView.loadHTMLString("<!doctype html><audio id=tone loop src=\"data:audio/wav;base64,\(wav.base64EncodedString())\"></audio>", baseURL: nil)
    }
    /// Starts the tone and waits until WebKit is playing it.
    func play() async throws {
        for _ in 0..<60 {
            let state = try? await webView.evaluateJavaScript("(()=>{const t=document.getElementById('tone'); if(!t) return 0; if(t.paused) t.play().catch(()=>{}); return t.currentTime})()") as? Double
            if let state, state > 0.15 { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CameraError.message("Browser sound cannot be captured: AppleCam's test tone did not play.")
    }
    func close() {
        webView.evaluateJavaScript("document.getElementById('tone')?.pause()", completionHandler: nil)
        window.orderOut(nil); window.close()
    }
}
