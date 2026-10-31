import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main
struct AppleCamApp: App {
    @StateObject private var model: CameraModel
    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--test-preferences-directory"), arguments.indices.contains(index + 1) {
            _model = StateObject(wrappedValue: CameraModel(preferencesStore: PreferencesStore(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))))
        } else { _model = StateObject(wrappedValue: CameraModel()) }
        #else
        _model = StateObject(wrappedValue: CameraModel())
        #endif
    }
    var body: some Scene {
        Window("AppleCam — Development Preview", id: "controls") {
            CameraControls(model: model)
        }.defaultSize(width: 1000, height: 1100)
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
    @ObservedObject var model: CameraModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Open AppleCam") { openWindow(id: "controls"); NSApp.activate(ignoringOtherApps: true) }
        Button("Stop camera") { model.stop() }.disabled(!model.running)
        Divider()
        Button("Quit AppleCam") { model.stop(); NSApp.terminate(nil) }
    }
}

private struct CameraControls: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image("AppIcon").resizable().scaledToFit()
                    .frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text("AppleCam").font(.largeTitle.bold())
                    Text(model.outputConfiguration.label).foregroundStyle(.secondary)
                }
                Spacer()
                Text("DEVELOPMENT").font(.caption.bold()).padding(8).background(.orange.opacity(0.15), in: Capsule())
            }
            SceneCanvas(model: model)
                .aspectRatio(model.previewAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
            Text(String(format: "Scene output %.1f fps   ·   Preview updates %.1f fps", model.captureFPS, model.previewFPS))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .help("Scene output counts composed frames. Preview updates counts frames handed to the interface, not monitor refresh or Teams output.")
            Picker("Camera", selection: $model.selection) {
                Text("Labelled test pattern (no webcam)").tag("pattern")
                if model.selectedCameraUnavailable { Text(model.unavailableCameraName).tag(model.selection) }
                ForEach(model.cameras, id: \.uniqueID) { camera in
                    Text(camera.localizedName).tag(camera.uniqueID)
                }
            }.disabled(model.running || model.busy)
            CaptureFormatControls(model: model)
            HStack {
                Button("Preview locally") { model.start(publish: false) }.disabled(model.busy || (model.scenePreparing && !model.running) || (model.running && !model.publishing))
                Button("Send to AppleCam") { model.start(publish: true) }.disabled(model.busy || (model.scenePreparing && !model.running) || (model.running && model.publishing))
                Button("Stop", role: .destructive) { model.stop() }.disabled(!model.running && !model.busy)
                Spacer()
                Button("Refresh cameras") { model.refresh() }.disabled(model.running || model.busy)
            }
            SceneEditor(model: model)
            DisclosureGroup("Green screen", isExpanded: $model.controlsExpanded) {
                GreenScreenControls(model: model)
            }
            if !model.useGreenScreen {
                Text("Green screen is off. The picture includes your surroundings unless Apple Video Effects changes them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text(model.settingsMessage).font(.caption).foregroundStyle(model.settingsError ? Color.orange : Color.secondary)
                if model.settingsError { Button("Save current settings") { model.saveCurrentPreferences() } }
            }
            Text(model.status).font(.callout).textSelection(.enabled).frame(minHeight: 35, alignment: .topLeading)
            Divider()
            ExtensionControls(manager: model.extensionManager)

        }.padding(24)
        }.frame(minWidth: 700, minHeight: 680)
    }
}

private struct CaptureFormatControls: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Resolution", selection: Binding(get: { model.captureConfiguration.resolution }, set: { model.selectResolution($0) })) {
                    if !model.resolutions.contains(where: { $0.resolution == model.captureConfiguration.resolution }) {
                        Text("\(model.captureConfiguration.resolution) (unavailable)").tag(model.captureConfiguration.resolution)
                    }
                    ForEach(model.resolutions, id: \.resolution) { Text($0.resolution).tag($0.resolution) }
                }
                Picker("Frame rate", selection: $model.captureConfiguration) {
                    if !model.ratesForResolution.contains(model.captureConfiguration) {
                        Text(model.captureConfiguration.rateLabel).tag(model.captureConfiguration)
                    }
                    ForEach(model.ratesForResolution, id: \.self) { Text($0.rateLabel).tag($0) }
                }
                TextField("Custom fps", value: $model.captureConfiguration.fps, format: .number)
                    .frame(width: 80).help("You can enter any frame rate inside a range reported by this camera.")
            }.disabled(model.running || model.busy)
            if !model.formatAvailable {
                Text("This camera does not offer the selected format. Choose a supported combination.").font(.caption).foregroundStyle(.orange)
            }
            if model.selection != "pattern" {
                Text(model.capabilities.filter { $0.width == model.captureConfiguration.width && $0.height == model.captureConfiguration.height }.map {
                    String(format: "%.3f–%.3f fps", $0.minimumFPS, $0.maximumFPS)
                }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Canvas output")
                TextField("Width", value: $model.outputConfiguration.width, format: .number).frame(width: 80)
                Text("×")
                TextField("Height", value: $model.outputConfiguration.height, format: .number).frame(width: 80)
                TextField("fps", value: $model.outputConfiguration.fps, format: .number).frame(width: 70)
                Text("fps · shared by all four scenes").font(.caption)
            }.disabled(model.running || model.busy)
            Text("Stop capture to change camera or format. Your meeting app may request a smaller output format.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct GreenScreenControls: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("Green screen", isOn: Binding(get: { model.useGreenScreen }, set: { model.setGreenScreen($0) })).disabled(model.busy)
                    Spacer()
                    Text("Calibration belongs to the selected physical camera.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.sampling ? "Cancel colour pick" : "Replace samples") { model.beginSample(append: false) }
                        .disabled(!model.running || model.busy || model.samplePending)
                    Button("Add screen sample") { model.beginSample(append: true) }
                        .disabled(!model.running || model.busy || model.sampling || model.samplePending || model.key.colors.count >= KeySettings.maximumSamples)
                    Text("\(model.key.colors.count) of 6 samples").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    ForEach(Array(model.key.colors.enumerated()), id: \.offset) { index, color in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
                                .frame(width: 24, height: 22).accessibilityLabel("Screen sample \(index + 1)")
                            Button { model.removeSample(index) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).accessibilityLabel("Remove sample \(index + 1)")
                                .disabled(model.key.colors.count == 1 || model.sampling || model.samplePending)
                        }
                    }
                }
                Text(model.sampling ? "Click only on the screen, away from hair and chair. Sampling reads the original camera colour even in Mask view." : "Replace starts a new selection. Add samples from leftover green patches before increasing tolerance.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Local preview", selection: $model.previewMode) {
                    ForEach(KeyPreview.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented).disabled(!model.useGreenScreen)
                Text(model.previewMode == .mask ? "White = kept · Black = removed · Grey = partly transparent. Mask is local only; meetings receive Picture." : "Local preview only. Meetings always receive the finished picture.")
                    .font(.caption).foregroundStyle(.secondary)
                keySlider("Tolerance", value: $model.key.tolerance, range: 0...0.5)
                keySlider("Colour softness", value: $model.key.softness, range: 0.005...0.5)
                Text("Colour softness widens the range made partly transparent. Start low to preserve hair.").font(.caption).foregroundStyle(.secondary)
                keySlider("Protect foreground", value: $model.key.protection, range: 0...1)
                Text("Keeps dark and neutral detail. Too much can leave dim or pale green screen visible.").font(.caption).foregroundStyle(.secondary)
                keySlider("Fill small holes", value: $model.key.fillHoles, range: 0...1)
                Text("Fills tiny holes surrounded by solid foreground. Use sparingly: real mesh openings may also close.").font(.caption).foregroundStyle(.secondary)
                keySlider("Green spill", value: $model.key.spill, range: 0...1)
                Text("Changes apply live to every webcam layer in this scene. Switching Green screen off deliberately includes your surroundings. Scene layers and calibration save automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private func keySlider(_ name: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack {
            Text(name).frame(width: 135, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(name)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 40)
        }
    }
}

private struct ExtensionControls: View {
    @ObservedObject var manager: ExtensionManager
    var body: some View {
        HStack(alignment: .top) {
            Button("Install camera extension") { manager.activate() }.disabled(manager.pending)
            Text(manager.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
