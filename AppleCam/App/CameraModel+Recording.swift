#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import AVFoundation

struct RecordingState: Equatable {
    let url: URL
    let started: Date
    var bytes: Int64 = 0
    var name: String { url.lastPathComponent }
}

/// Recording: the composed canvas plus the audio mix, to a folder the person chose. Never started automatically.
extension CameraModel {
    var canRecord: Bool { recording == nil && !recordingPending && !restorationFailed && (running || canStartPreview) }
    var recordingFolderName: String? { recordingPreferences.folderBookmark == nil ? nil : recordingPreferences.folderName }
    /// Approximate size of one hour of recording at the current canvas and channels.
    var recordingHourlyBytes: Double {
        RecordingPolicy.bytesPerSecond(width: outputConfiguration.width, height: outputConfiguration.height,
            fps: outputConfiguration.fps, audioTracks: 1 + recordedChannels().count) * 3600
    }

    func toggleRecording() { if recording != nil { stopRecording() } else { startRecording() } }

    /// Starts recording; asks for a folder the first time and starts a local preview when nothing is running.
    func startRecording() {
        guard canRecord else { return }
        guard let folder = openRecordingFolder() ?? (chooseRecordingFolder() ? openRecordingFolder() : nil) else { return }
        recordingFolderAccess = folder
        if running { beginRecording() } else { recordingPending = true; start(publish: false) }
    }
    func stopRecording(reason: Error? = nil) { runtime.output.stopRecording(reason) }

    /// Called once the scene is running.
    func beginRecording() {
        guard let folder = recordingFolderAccess, recording == nil else { return }
        let name = RecordingPolicy.fileName(at: Date()) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let url = folder.appendingPathComponent(name)
        let channels = recordedChannels()
        Task {
            do {
                let recorder = try SceneRecorder(url: url, configuration: outputConfiguration, audioTracks: ["Mix"] + channels.map(\.name))
                try await runtime.output.startRecording(recorder, channels: channels.map(\.id))
                recording = RecordingState(url: url, started: Date())
                status = "Recording to “\(name)”."
                startRecordingTimer()
            } catch {
                try? FileManager.default.removeItem(at: url)
                releaseRecordingFolder()
                status = "Recording could not start: \(error.localizedDescription)"
            }
        }
    }
    /// Reported by the scene output when the file is complete (on any thread).
    func recordingEnded(url: URL, reason: Error?) {
        let kept = FileManager.default.fileExists(atPath: url.path)
        recording = nil; recordingTimer?.invalidate(); recordingTimer = nil
        if kept { lastRecording = url }
        let saved = kept ? "Recording saved as “\(url.lastPathComponent)”." : ""
        if let reason {
            status = kept ? "\(reason.localizedDescription) Recording stopped; the file keeps everything up to that point (“\(url.lastPathComponent)”)."
                : "Recording stopped: \(reason.localizedDescription)"
        } else { status = saved }
        releaseRecordingFolder()
        if let quit = quitAfterRecording { quitAfterRecording = nil; quit() }
    }
    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRecordingProgress() }
        }
    }
    func updateRecordingProgress() {
        guard var current = recording else { return }
        current.bytes = ((try? FileManager.default.attributesOfItem(atPath: current.url.path))?[.size] as? NSNumber)?.int64Value ?? current.bytes
        recording = current
        let free = (try? current.url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let rate = recordingHourlyBytes / 3600
        if let free, free < RecordingPolicy.minimumFreeBytes(bytesPerSecond: rate) {
            stopRecording(reason: CameraError.message("Less than \(ByteCountFormatter.string(fromByteCount: RecordingPolicy.minimumFreeBytes(bytesPerSecond: rate), countStyle: .file)) is free on the recording disk."))
        }
    }

    // MARK: Folder

    /// Shows an open panel for the recording folder (suggesting Movies). Returns false when cancelled.
    @discardableResult func chooseRecordingFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        panel.message = "Choose the folder where AppleCam saves recordings. A folder named AppleCam inside Movies works well."
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try setRecordingFolder(url); return true }
        catch { status = "That folder cannot be used for recordings: \(error.localizedDescription)"; return false }
    }
    func setRecordingFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var next = recordingPreferences; next.folderBookmark = bookmark; next.folderName = url.lastPathComponent
        recordingPreferences = next
    }
    /// Resolves the saved folder and opens its sandbox access, or explains why it is unavailable.
    func openRecordingFolder() -> URL? {
        guard let bookmark = recordingPreferences.folderBookmark else { return nil }
        do {
            var stale = false
            let name = recordingPreferences.folderName ?? "recording folder"
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                throw CameraError.message("The folder “\(name)” no longer exists or was moved.")
            }
            _ = url.startAccessingSecurityScopedResource()
            if stale { try setRecordingFolder(url) }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                url.stopAccessingSecurityScopedResource()
                throw CameraError.message("The folder “\(name)” no longer exists or was moved.")
            }
            return url
        } catch {
            status = "The recording folder is unavailable: \(error.localizedDescription) Choose a folder again."
            return nil
        }
    }
    func releaseRecordingFolder() { recordingFolderAccess?.stopAccessingSecurityScopedResource(); recordingFolderAccess = nil }
    func revealLastRecording() { if let lastRecording { NSWorkspace.shared.activateFileViewerSelecting([lastRecording]) } }

    /// Quitting while recording finishes the file first; `done` runs when it is complete.
    func finishRecordingBeforeQuit(_ done: @escaping () -> Void) {
        guard recording != nil else { done(); return }
        quitAfterRecording = done; stopRecording()
    }
}
