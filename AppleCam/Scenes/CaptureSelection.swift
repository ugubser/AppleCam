#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import ScreenCaptureKit

@MainActor final class CaptureSelection: NSObject, SCContentSharingPickerObserver {
    private var pending: CheckedContinuation<LayerSource?, Error>?
    private var display = false
    private var pickedFilter: SCContentFilter?
    func choose(display: Bool) async throws -> (LayerSource, SCContentFilter)? {
        guard pending == nil else { throw CameraError.message("Finish the open source picker first.") }
        self.display = display; pickedFilter = nil
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = display ? [.singleDisplay] : [.singleWindow]
        configuration.excludedWindowIDs = NSApp.windows.map(\.windowNumber)
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self); picker.isActive = true
        defer { picker.remove(self); picker.isActive = false }
        let source: LayerSource? = try await withCheckedThrowingContinuation { continuation in
            pending = continuation; picker.present(using: display ? .display : .window)
        }
        guard let source, let pickedFilter else { return nil }
        return (source, pickedFilter)
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard let pending = self.pending else { return }; self.pending = nil
            self.pickedFilter = filter
            if self.display, let screen = filter.includedDisplays.first, let uuid = Self.displayUUID(screen.displayID) {
                pending.resume(returning: .display(DisplayReference(uuid: uuid, name: "Display \(screen.displayID)")))
            } else if !self.display, let window = filter.includedWindows.first, let reference = Self.reference(window) {
                pending.resume(returning: .window(reference))
            } else { pending.resume(throwing: CameraError.message("The selected capture source could not be identified. Choose it again.")) }
        }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in let continuation = self.pending; self.pending = nil; continuation?.resume(returning: nil) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in let continuation = self.pending; self.pending = nil; continuation?.resume(throwing: error) }
    }
    static func reference(_ window: SCWindow) -> WindowReference? {
        guard let owner = window.owningApplication, let running = NSRunningApplication(processIdentifier: owner.processID),
              let date = running.launchDate else { return nil }
        return WindowReference(windowID: window.windowID, processID: owner.processID, applicationID: owner.bundleIdentifier,
            launchTime: date.timeIntervalSince1970, title: window.title ?? owner.applicationName)
    }
    static func matches(_ window: SCWindow, _ reference: WindowReference) -> Bool {
        guard let current = Self.reference(window) else { return false }
        return current.identifiesSameWindow(as: reference)
    }
    static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
