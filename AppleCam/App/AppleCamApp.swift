import SwiftUI

@main
struct AppleCamApp: App {
    @State private var model: CameraModel
    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--test-preferences-directory"), arguments.indices.contains(index + 1) {
            _model = State(initialValue: CameraModel(preferencesStore: PreferencesStore(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))))
        } else { _model = State(initialValue: CameraModel()) }
        #else
        _model = State(initialValue: CameraModel())
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
        Button("Stop camera") { model.stop() }.disabled(!model.running)
        Divider()
        Button("Quit AppleCam") { model.stop(); NSApp.terminate(nil) }
    }
}
