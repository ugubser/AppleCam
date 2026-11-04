import SwiftUI

/// Quitting during a recording first completes the movie file.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: CameraModel?
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.recording != nil else { return .terminateNow }
        var replied = false
        let reply = { if !replied { replied = true; sender.reply(toApplicationShouldTerminate: true) } }
        model.finishRecordingBeforeQuit(reply)
        // The fragmented movie is readable even if completion stalls; never block quitting indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { reply() }
        return .terminateLater
    }
}

@main
struct AppleCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: CameraModel
    init() {
        let model: CameraModel
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--test-preferences-directory"), arguments.indices.contains(index + 1) {
            model = CameraModel(preferencesStore: PreferencesStore(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true)))
        } else { model = CameraModel() }
        #else
        model = CameraModel()
        #endif
        _model = State(initialValue: model)
        AppDelegate.model = model
        #if DEBUG
        TestScenario.runIfRequested(model)
        #endif
    }
    var body: some Scene {
        Window("AppleCam", id: "controls") {
            ContentView(model: model)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AppleCam") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: "Simple virtual camera for green screens")
                    ])
                }
            }
        }
        MenuBarExtra("AppleCam", systemImage: "video.badge.waveform") {
            MenuActions(model: model)
        }
    }
}

private struct MenuActions: View {
    let model: CameraModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Open AppleCam") { openWindow(id: "controls"); NSApp.activate(ignoringOtherApps: true) }
        Button(model.recording == nil ? "Record" : "Stop Recording") { model.toggleRecording() }
            .disabled(model.recording == nil && !model.canRecord)
        Button("Stop camera") { model.stop() }.disabled(!model.running)
        Divider()
        Button("Quit AppleCam") { model.stop(); NSApp.terminate(nil) }
    }
}
