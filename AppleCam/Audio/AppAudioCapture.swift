#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import CoreAudio
import ScreenCaptureKit
import os

private let log = Logger(subsystem: "com.vanguardsignals.AppleCam", category: "audio")

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
    /// Microphone users that no capturable app accounts for. Apple's own services are ignored: ScreenCaptureKit's
    /// capture service itself reports audio input while capturing, and system listeners are not meeting apps.
    static func unmatched(_ users: [Process], apps: [(pid: pid_t, bundleID: String)], own: pid_t = ProcessInfo.processInfo.processIdentifier) -> [Process] {
        users.filter { user in
            user.pid != own && !user.bundleID.hasPrefix("com.apple.") &&
                !apps.contains { isUsingInput(pid: $0.pid, bundleID: $0.bundleID, users: [user], own: own) }
        }
    }
    /// True when the app, or one of its helper processes (bundle IDs below the app's), is using a microphone.
    static func isUsingInput(pid: pid_t, bundleID: String, users: [Process], own: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard pid != own else { return false }
        return users.contains { user in
            user.pid != own && (user.pid == pid || (!bundleID.isEmpty && (user.bundleID == bundleID || user.bundleID.hasPrefix(bundleID + "."))))
        }
    }
}

/// Audio of one app or of the whole screen, through an audio-only ScreenCaptureKit stream.
final class AppAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Kind: Equatable {
        /// The app owning a window layer.
        case application(pid: pid_t)
        /// All sound except AppleCam and apps using a microphone.
        case display
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
        let (filter, note, block) = try await Self.filter(kind)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(AudioFormat.sampleRate); configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        // Audio only: the smallest picture at the lowest rate; no screen output is attached.
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        let next = SCStream(filter: filter, configuration: configuration, delegate: self)
        try next.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Decide what is left out before the first sample can arrive.
        setNote(note, block: block)
        try await next.startCapture()
        stream = next
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
            let (filter, note, block) = try await Self.filter(kind)
            let excludedNow = Self.excludedPIDs(kind)
            if excludedNow != lock.withLock({ excluded }) {
                lock.withLock { excluded = excludedNow }
                if kind == .display { try await stream.updateContentFilter(filter) }
            }
            setNote(note, block: block)
        } catch { onFailure?(error.localizedDescription) }
    }
    /// `block` drops all sound (an app in a call that the filter cannot leave out); otherwise the filter handles it.
    @MainActor private func setNote(_ note: String?, block: Bool) {
        lock.withLock { blocked = block }
        onNote?(note)
    }
    private static func excludedPIDs(_ kind: Kind) -> Set<pid_t> {
        Set(AudioInputUsers.current().map(\.pid))
    }
    /// The capture filter; when something is left out because it is in a call, the explanation; and whether all of
    /// this source's sound must be dropped.
    @MainActor private static func filter(_ kind: Kind) async throws -> (SCContentFilter, String?, Bool) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CameraError.message("No display is available for audio capture.") }
        let users = AudioInputUsers.current(), own = ProcessInfo.processInfo.processIdentifier
        let inCall = content.applications.filter { AudioInputUsers.isUsingInput(pid: $0.processID, bundleID: $0.bundleIdentifier, users: users) }
        log.notice("Audio filter \(String(describing: kind), privacy: .public): microphone users \(users.map { "\($0.bundleID)(\($0.pid))" }.joined(separator: ", "), privacy: .public); in a call: \(inCall.map(\.bundleIdentifier).joined(separator: ", "), privacy: .public)")
        switch kind {
        case .application(let pid):
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw CameraError.message("The window's app is no longer running.")
            }
            let inUse = inCall.contains(where: { $0.processID == pid })
            let note = inUse ? "\(app.applicationName) is using a microphone (probably a call), so its sound is left out." : nil
            return (SCContentFilter(display: display, including: [app], exceptingWindows: []), note, inUse)
        case .display:
            let ours = content.applications.filter { $0.processID == own }
            let hidden = AudioInputUsers.unmatched(users, apps: content.applications.map { ($0.processID, $0.bundleIdentifier) })
            if !hidden.isEmpty {
                // Fail closed: a process that records a microphone but cannot be filtered out could be a call.
                let names = hidden.map { $0.bundleID.isEmpty ? "process \($0.pid)" : $0.bundleID }.joined(separator: ", ")
                return (SCContentFilter(display: display, excludingApplications: ours + inCall, exceptingWindows: []),
                        "Screen sound is paused: \(names) is using a microphone and cannot be left out on its own.", true)
            }
            let note = inCall.isEmpty ? nil : "Left out while using a microphone: " + inCall.map(\.applicationName).joined(separator: ", ") + "."
            return (SCContentFilter(display: display, excludingApplications: ours + inCall, exceptingWindows: []), note, false)
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
