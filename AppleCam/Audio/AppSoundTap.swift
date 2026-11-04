#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import AVFoundation
import CoreAudio

/// The sound of a window layer's app, captured with a Core Audio tap that is muted while it runs: the app's sound goes
/// into the mix and not through the speakers. The tap covers the app and its helper processes
/// (`CoreAudioProcess.playing`) and is rebuilt when they change (Chrome starts an audio helper when playback begins) or
/// when the output device changes; a new tap starts before the old one stops, so the app never briefly sounds.
/// While the app uses a microphone (a call), it is not tapped and its sound is left out, so other participants are
/// never recorded.
@MainActor final class AppSoundTap: LayerSoundCapture {
    let input = ChannelInput()
    var onNote: ((String?) -> Void)?
    var onFailure: ((String) -> Void)?
    private let pid: pid_t
    private let bundleID: String
    private let name: String
    private var tap: ProcessTap?
    private var tapped: [AudioObjectID] = []
    /// Only the current tap writes; a replaced tap's last buffers are dropped.
    private let current = TapGeneration()
    private var watchers: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var monitor: Task<Void, Never>?
    private var running = false
    private var note: String?
    private var updating = false
    private var pending: Bool?

    /// How many processes the current tap covers (0 when nothing of the app is tapped).
    var tappedProcessCount: Int { tap == nil ? 0 : tapped.count }
    init(pid: pid_t, bundleID: String) {
        self.pid = pid; self.bundleID = bundleID
        name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "The window's app"
    }
    func start() async throws {
        guard !running else { return }
        guard NSRunningApplication(processIdentifier: pid) != nil else { throw CameraError.message("The window's app is no longer running.") }
        running = true
        do { try await AudioTapPermission.request() } catch { running = false; throw error }
        guard running else { return }
        watch()
        updating = true
        do { try await refresh(force: true) } catch { updating = false; await stop(); throw error }
        updating = false
        if let again = pending { pending = nil; await update(force: again) }
        guard running else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.update(force: false)
            }
        }
    }
    func stop() async {
        running = false
        monitor?.cancel(); monitor = nil
        for (address, block) in watchers { var a = address; AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block) }
        watchers = []
        current.set(0); tap?.stop(); tap = nil; tapped = []
    }
    private func watch() {
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { Task { await self?.update(force: selector == kAudioHardwarePropertyDefaultOutputDevice) } }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr { watchers.append((address, block)) }
        }
    }
    /// One update at a time; a request that arrives meanwhile runs after it (forced if any request was).
    private func update(force: Bool) async {
        if updating { pending = (pending ?? false) || force; return }
        updating = true; defer { updating = false }
        var force = force
        while true {
            do { try await refresh(force: force) }
            catch { guard running else { return }; pending = nil; await stop(); onFailure?(error.localizedDescription); return }
            guard let again = pending else { return }
            pending = nil; force = again
        }
    }
    /// Re-checks the call rule and which processes play the app's sound, and taps them.
    private func refresh(force: Bool) async throws {
        guard running else { return }
        guard NSRunningApplication(processIdentifier: pid) != nil else { throw CameraError.message("\(name) is no longer running, so its sound stopped.") }
        let inCall = AudioInputUsers.isUsingInput(pid: pid, bundleID: bundleID, users: AudioInputUsers.current())
        setNote(inCall ? "\(name) is using a microphone (probably a call), so its sound is left out." : nil)
        let wanted = inCall ? [] : CoreAudioProcess.playing(for: pid, bundleID: bundleID, in: CoreAudioProcess.all())
        guard force || wanted != tapped else { return }
        guard !wanted.isEmpty else { current.set(0); tap?.stop(); tap = nil; tapped = []; return }
        let generation = current.next()
        let input = input, current = current
        input.restart()
        let next = try await Task.detached {
            try ProcessTap(processes: wanted, muted: true) { buffer, host in
                if current.value == generation { input.write(buffer, hostTime: host) }
            }
        }.value
        guard running, current.value == generation else { next.stop(); return }
        tap?.stop(); tap = next; tapped = wanted
    }
    private func setNote(_ next: String?) {
        guard next != note else { return }
        note = next; onNote?(next)
    }
}

/// Which tap may write, read on Core Audio's thread.
private final class TapGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private var active = 0
    var value: Int { lock.withLock { active } }
    func next() -> Int { lock.withLock { counter += 1; active = counter; return counter } }
    func set(_ value: Int) { lock.withLock { active = value } }
}
