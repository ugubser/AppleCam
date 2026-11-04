#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import CoreAudio
import ScreenCaptureKit

/// Processes that are currently recording from a microphone, from Core Audio's public process objects.
/// A meeting app (or a browser in a call) is one of them; its sound is never captured.
enum AudioInputUsers {
    struct Process: Equatable { let pid: pid_t; let bundleID: String }
    static func current() -> [Process] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var running: UInt32 = 0, pid: pid_t = 0
            guard read(object, kAudioProcessPropertyIsRunningInput, &running), running != 0, read(object, kAudioProcessPropertyPID, &pid) else { return nil }
            return Process(pid: pid, bundleID: bundleID(object) ?? "")
        }
    }
    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
    /// True when the app, or one of its helper processes (bundle IDs below the app's), is using a microphone.
    static func isUsingInput(pid: pid_t, bundleID: String, users: [Process], own: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard pid != own else { return false }
        return users.contains { user in
            user.pid != own && (user.pid == pid || (!bundleID.isEmpty && (user.bundleID == bundleID || user.bundleID.hasPrefix(bundleID + "."))))
        }
    }
}

/// Audio of one app, of the whole screen, or of AppleCam's own browser pages, through an audio-only ScreenCaptureKit stream.
final class AppAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Kind: Equatable {
        /// The app owning a window layer.
        case application(pid: pid_t)
        /// All sound except AppleCam and apps using a microphone.
        case display
        /// AppleCam's own WebKit pages (browser layers).
        case ownPages
    }
    let kind: Kind
    let input = ChannelInput()
    private var stream: SCStream?
    private var monitorTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.vanguardsignals.AppleCam.app-audio", qos: .userInteractive)
    private let lock = NSLock()
    private var blocked = false
    private var excluded: Set<pid_t> = []
    /// Called on the main actor: the explanation when the source is left out (in a call) or failed, nil when it is fine again.
    var onNote: ((String?) -> Void)?
    var onFailure: ((String) -> Void)?
    init(kind: Kind) { self.kind = kind }

    @MainActor func start() async throws {
        guard stream == nil else { return }
        try CaptureSelection.requireAccess()
        let (filter, note) = try await Self.filter(kind)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(AudioFormat.sampleRate); configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = kind != .ownPages
        // Audio only: the smallest picture at the lowest rate; no screen output is attached.
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        let next = SCStream(filter: filter, configuration: configuration, delegate: self)
        try next.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await next.startCapture()
        stream = next
        setNote(note)
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }
    /// Stops the stream; the channel stays attached so the next start (scene live again) resumes into it.
    @MainActor func stop() async {
        monitorTask?.cancel(); monitorTask = nil
        guard let old = stream else { return }
        stream = nil
        try? await old.stopCapture()
    }
    /// Re-checks which apps are in a call and updates the filter (screen) or the left-out state (one app).
    @MainActor private func refresh() async {
        guard let stream else { return }
        do {
            let (filter, note) = try await Self.filter(kind)
            let excludedNow = Self.excludedPIDs(kind)
            if excludedNow != lock.withLock({ excluded }) {
                lock.withLock { excluded = excludedNow }
                if kind == .display { try await stream.updateContentFilter(filter) }
            }
            setNote(note)
        } catch { onFailure?(error.localizedDescription) }
    }
    /// A single app in a call is left out entirely; for the screen, the filter already leaves those apps out.
    @MainActor private func setNote(_ note: String?) {
        lock.withLock { blocked = kind != .display && note != nil }
        onNote?(note)
    }
    private static func excludedPIDs(_ kind: Kind) -> Set<pid_t> {
        Set(AudioInputUsers.current().map(\.pid))
    }
    /// The capture filter and, when a source is left out because it is in a call, the explanation.
    @MainActor private static func filter(_ kind: Kind) async throws -> (SCContentFilter, String?) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CameraError.message("No display is available for audio capture.") }
        let users = AudioInputUsers.current(), own = ProcessInfo.processInfo.processIdentifier
        let inCall = content.applications.filter { AudioInputUsers.isUsingInput(pid: $0.processID, bundleID: $0.bundleIdentifier, users: users) }
        switch kind {
        case .application(let pid):
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw CameraError.message("The window's app is no longer running.")
            }
            let note = inCall.contains(where: { $0.processID == pid }) ?
                "\(app.applicationName) is using a microphone (probably a call), so its sound is left out." : nil
            return (SCContentFilter(display: display, including: [app], exceptingWindows: []), note)
        case .display:
            let ours = content.applications.filter { $0.processID == own }
            let note = inCall.isEmpty ? nil : "Left out while using a microphone: " + inCall.map(\.applicationName).joined(separator: ", ") + "."
            return (SCContentFilter(display: display, excludingApplications: ours + inCall, exceptingWindows: []), note)
        case .ownPages:
            guard let ours = content.applications.first(where: { $0.processID == own }) else {
                throw CameraError.message("AppleCam's browser pages cannot be captured.")
            }
            return (SCContentFilter(display: display, including: [ours], exceptingWindows: []), nil)
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, !lock.withLock({ blocked }) else { return }
        // ScreenCaptureKit stamps audio with host time.
        input.write(sampleBuffer, hostTime: sampleBuffer.presentationTimeStamp.seconds)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = "Audio capture stopped: \(error.localizedDescription)"
        Task { @MainActor [weak self] in self?.onFailure?(message) }
    }
}
