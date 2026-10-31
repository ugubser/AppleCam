#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import ScreenCaptureKit

struct CaptureRequest: Identifiable, Equatable {
    let id = UUID()
    let display: Bool
}

/// A window or display offered by the in-app source chooser.
struct CaptureOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let processID: pid_t?
    let source: LayerSource
    let filter: SCContentFilter
}

/// Lightweight window description so selection rules can be unit tested without ScreenCaptureKit objects.
struct WindowCandidate: Equatable {
    var layer: Int
    var width: Double
    var height: Double
    var processID: pid_t?
    var onScreen: Bool
}

/// Window and display capture uses the macOS Screen Recording permission. With it, AppleCam lists sources itself,
/// remembers them across launches and re-identifies them strictly (window ID, process and launch time; display UUID).
@MainActor enum CaptureSelection {
    static let permissionMessage = "Window and screen layers need Screen Recording permission. Allow AppleCam in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen AppleCam."
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system permission prompt the first time; returns whether access is already granted.
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }
    static func requireAccess() throws { guard hasAccess else { throw CameraError.message(permissionMessage) } }

    /// Ordinary, visible app windows of other processes, large enough to be useful.
    nonisolated static func isSelectable(_ window: WindowCandidate, ownProcess: pid_t) -> Bool {
        window.layer == 0 && window.onScreen && window.width >= 80 && window.height >= 60 &&
            window.processID != nil && window.processID != ownProcess
    }
    static func options(display: Bool) async throws -> [CaptureOption] {
        try requireAccess()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let own = ProcessInfo.processInfo.processIdentifier
        if display {
            let ours = content.windows.filter { $0.owningApplication?.processID == own }
            return content.displays.compactMap { screen in
                guard let uuid = displayUUID(screen.displayID) else { return nil }
                let name = displayName(screen.displayID)
                return CaptureOption(id: uuid, title: name, subtitle: "\(screen.width) × \(screen.height) points", processID: nil,
                    source: .display(DisplayReference(uuid: uuid, name: name)),
                    // Exclude AppleCam's own windows, including browser rendering windows, to avoid recursive previews.
                    filter: SCContentFilter(display: screen, excludingWindows: ours))
            }
        }
        return content.windows.compactMap { window in
            let candidate = WindowCandidate(layer: window.windowLayer, width: window.frame.width, height: window.frame.height,
                processID: window.owningApplication?.processID, onScreen: window.isOnScreen)
            guard isSelectable(candidate, ownProcess: own), let reference = reference(window) else { return nil }
            let app = window.owningApplication?.applicationName ?? reference.applicationID
            let title = (window.title ?? "").isEmpty ? app : window.title!
            return CaptureOption(id: "\(window.windowID)", title: title, subtitle: app, processID: reference.processID,
                source: .window(reference), filter: SCContentFilter(desktopIndependentWindow: window))
        }
        .sorted { ($0.subtitle.localizedLowercase, $0.title.localizedLowercase) < ($1.subtitle.localizedLowercase, $1.title.localizedLowercase) }
    }
    /// A small still image so similar windows can be told apart.
    static func thumbnail(_ option: CaptureOption, maxWidth: CGFloat = 320) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        let size = option.filter.contentRect.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxWidth / size.width)
        configuration.width = max(2, Int(size.width * scale)); configuration.height = max(2, Int(size.height * scale))
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: option.filter, configuration: configuration)
    }
    static func displayName(_ id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? "Display \(id)"
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
    nonisolated static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
