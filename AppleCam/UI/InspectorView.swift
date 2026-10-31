#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case layer = "Layer", key = "Green Screen", backgroundMask = "Background Mask", output = "Output"
    var id: Self { self }
}

/// Trailing inspector: settings for the selection, keying and formats, beside an always-visible canvas.
struct InspectorView: View {
    let model: CameraModel
    @Binding var tab: InspectorTab
    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(10)
            Divider()
            switch tab {
            case .layer: LayerInspector(model: model)
            case .key: GreenScreenInspector(model: model)
            case .backgroundMask: BackgroundMaskInspector(model: model)
            case .output: OutputInspector(model: model)
            }
        }
    }
}

// MARK: - Scene and layer

private struct LayerInspector: View {
    let model: CameraModel
    var body: some View {
        Form {
            Section("Scene") {
                DraftTextField("Name", value: model.activeScene.name) { model.renameScene($0) }
                    .id(model.activeScene.id)
                ColorPicker("Canvas colour", selection: Binding(get: {
                    Color(.sRGB, red: model.activeScene.canvasRed, green: model.activeScene.canvasGreen, blue: model.activeScene.canvasBlue)
                }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    model.setCanvasColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                }), supportsOpacity: false)
            }
            if let layer = model.selectedLayer {
                LayerSections(model: model, layer: layer).id(layer.id)
            } else {
                Section {
                    Text("Select a layer in the sidebar or on the canvas to edit it.").foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}

private struct LayerSections: View {
    let model: CameraModel
    let layer: SceneLayer
    private func edit(_ change: (inout SceneLayer) -> Void) -> Bool { model.updateLayer(layer.id, change) }
    var body: some View {
        Section("Layer") {
            DraftTextField("Name", value: layer.name) { name in edit { $0.name = name } }
            LabeledContent("Source") { Label(layer.source.label, systemImage: layer.source.symbol) }
            Toggle("Visible", isOn: Binding(get: { layer.visible }, set: { v in _ = edit { $0.visible = v } }))
            Toggle("Lock placement", isOn: Binding(get: { layer.locked }, set: { v in _ = edit { $0.locked = v } }))
        }
        Section {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    percentField("X", layer.placement.x) { v in edit { $0.placement.x = v } }
                    percentField("Y", layer.placement.y) { v in edit { $0.placement.y = v } }
                }
                GridRow {
                    percentField("Width", layer.placement.width) { v in edit { $0.placement = LayerGeometry.sized($0.placement, width: v) } }
                    percentField("Height", layer.placement.height) { v in edit { $0.placement = LayerGeometry.sized($0.placement, height: v) } }
                }
            }
            Picker("Content", selection: Binding(get: { layer.placement.sizing }, set: { s in _ = edit { $0.placement.sizing = s } })) {
                ForEach(LayerSizing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Keep aspect ratio", isOn: Binding(get: { layer.placement.aspectLocked }, set: { v in _ = edit { $0.placement.aspectLocked = v } }))
            Button("Reset to full canvas") { _ = edit { $0.placement = LayerPlacement() } }
        } header: {
            Text("Position and size")
        } footer: {
            Text(layer.locked ? "Unlock placement to move or resize this layer." : "Percent of the canvas. Drag the layer or its corner handles on the canvas.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(layer.locked)
        Section("Source") { SourceControls(model: model, layer: layer) }
        Section {
            Button("Delete Layer", role: .destructive) { model.deleteLayer(layer.id) }.disabled(layer.locked)
        }
    }
    private func percentField(_ name: String, _ value: Double, commit: @escaping (Double) -> Bool) -> some View {
        HStack(spacing: 4) {
            Text(name).frame(width: 42, alignment: .leading)
            DraftNumberField(name, value: value * 100) { commit($0 / 100) }
                .labelsHidden().frame(minWidth: 44).accessibilityLabel("Layer \(name) percent")
            Text("%").foregroundStyle(.secondary)
        }
    }
}

private struct SourceControls: View {
    let model: CameraModel
    let layer: SceneLayer
    var body: some View {
        switch layer.source {
        case .camera:
            Text("Uses the selected webcam and its saved green-screen calibration.").font(.caption).foregroundStyle(.secondary)
        case .image(let asset):
            LabeledContent("File", value: asset.name)
            Button("Replace Image…") { model.chooseMedia(clip: false, replacing: layer.id) }
        case .clip(let asset):
            LabeledContent("File", value: asset.name)
            Text("Silent and repeating.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.clipPaused(layer.id) ? "Play" : "Pause") { model.toggleClip(layer.id) }.disabled(!model.running)
                Button("Restart") { model.restartClip(layer.id) }.disabled(!model.running)
                Spacer()
                Button("Replace…") { model.chooseMedia(clip: true, replacing: layer.id) }
            }
        case .browser(let settings):
            BrowserControls(model: model, layer: layer, settings: settings)
        case .window(let ref):
            LabeledContent("Window", value: ref?.title ?? "None selected")
            Button("Choose Window…") { model.replaceCapture(layer.id) }
        case .display(let ref):
            LabeledContent("Screen", value: ref?.name ?? "None selected")
            Button("Choose Screen…") { model.replaceCapture(layer.id) }
        }
    }
}

private struct BrowserControls: View {
    let model: CameraModel
    let layer: SceneLayer
    let settings: BrowserSettings
    private func update(_ change: (inout BrowserSettings) -> Void) -> Bool {
        var next = settings; change(&next)
        return model.updateLayer(layer.id) { $0.source = .browser(next) }
    }
    var body: some View {
        DraftTextField("Address", value: settings.url) { url in update { $0.url = url } }
        Text("Press Return to load. Only http and https addresses are accepted.").font(.caption).foregroundStyle(.secondary)
        HStack {
            Button { model.navigateBrowser(layer.id, forward: false) } label: { Image(systemName: "chevron.backward") }
                .help("Back").disabled(!model.running || !model.browserCanGoBack(layer.id))
            Button { model.navigateBrowser(layer.id, forward: true) } label: { Image(systemName: "chevron.forward") }
                .help("Forward").disabled(!model.running || !model.browserCanGoForward(layer.id))
            Button { model.reloadBrowser(layer.id) } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload").disabled(!model.browserAvailable(layer.id))
            Spacer()
            Button("Interact with Page") { model.showBrowser(layer.id) }.disabled(!model.running || !layer.visible)
        }
        LabeledContent("Viewport") {
            HStack(spacing: 4) {
                DraftNumberField("Width", integer: settings.width) { w in update { $0.width = w } }.labelsHidden().frame(width: 64).accessibilityLabel("Browser viewport width")
                Text("×")
                DraftNumberField("Height", integer: settings.height) { h in update { $0.height = h } }.labelsHidden().frame(width: 64).accessibilityLabel("Browser viewport height")
            }
        }
        Text("Silent WebKit page, 200–4096 px. Its rendering window stays open while the layer is active; do not minimise it.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Green screen

private struct GreenScreenInspector: View {
    @Bindable var model: CameraModel
    var body: some View {
        Form {
            Section {
                Toggle("Green screen", isOn: Binding(get: { model.useGreenScreen }, set: { model.setGreenScreen($0) })).disabled(model.busy)
            } footer: {
                Text(model.useGreenScreen ? "Changes apply live to every webcam layer. Calibration belongs to the selected camera. Turning this on turns the background mask off." :
                    "Off: webcam layers include your surroundings unless Apple Video Effects changes them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Section {
                    HStack(spacing: 6) {
                        ForEach(Array(model.key.colors.enumerated()), id: \.offset) { index, color in
                            Swatch(color: color, index: index, removable: model.key.colors.count > 1 && !model.sampling && !model.samplePending) {
                                model.removeSample(index)
                            }
                        }
                        Spacer()
                        Text("\(model.key.colors.count) of \(KeySettings.maximumSamples)").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(model.sampling ? "Cancel" : "Replace Samples") { model.beginSample(append: false) }
                            .disabled(!model.running || model.busy || model.samplePending)
                        Button("Add Sample") { model.beginSample(append: true) }
                            .disabled(!model.running || model.busy || model.sampling || model.samplePending || model.key.colors.count >= KeySettings.maximumSamples)
                    }
                } header: {
                    Text("Screen colour")
                } footer: {
                    Text(model.sampling ? "Click only on the screen, away from hair and chair. Sampling reads the original camera colour, even in Mask view." :
                        model.running ? "Replace starts a new selection. Add samples from leftover green patches before raising tolerance." :
                        "Start a preview to sample the screen colour.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Preview", selection: $model.previewMode) {
                        ForEach(KeyPreview.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                } footer: {
                    Text(model.previewMode == .mask ? "White = kept · black = removed · grey = partly transparent. Local only; meetings receive the picture." :
                        "Local preview only. Meetings always receive the finished picture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Adjustments") {
                    KeySlider(name: "Tolerance", value: $model.key.tolerance, range: 0...0.5,
                              hint: "How far a colour may differ from the samples and still be removed.")
                    KeySlider(name: "Colour softness", value: $model.key.softness, range: 0.005...0.5,
                              hint: "Widens the partly transparent range. Start low to preserve hair.")
                    KeySlider(name: "Protect foreground", value: $model.key.protection, range: 0...1,
                              hint: "Keeps dark and neutral detail. Too much can leave dim or pale screen visible.")
                    KeySlider(name: "Fill small holes", value: $model.key.fillHoles, range: 0...1,
                              hint: "Fills tiny holes surrounded by solid foreground. Real mesh openings may also close.")
                    KeySlider(name: "Green spill", value: $model.key.spill, range: 0...1,
                              hint: "Removes green light reflected onto you.")
                }
            }.disabled(!model.useGreenScreen)
        }.formStyle(.grouped)
    }
}

// MARK: - Background mask

private struct BackgroundMaskInspector: View {
    @Bindable var model: CameraModel
    var body: some View {
        Form {
            Section {
                Toggle("Background mask", isOn: Binding(get: { model.useBackgroundMask }, set: { model.setBackgroundMask($0) }))
                    .disabled(model.busy || model.backgroundPlate == nil)
            } footer: {
                Text(model.backgroundPlate == nil ? "No green screen? Take a picture of the empty background; AppleCam then removes everything that still looks like it." :
                    model.useBackgroundMask ? "Changes apply live to every webcam layer. Turning this on turns the green screen off." :
                    "Off: webcam layers include your surroundings unless the green screen is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                PlatePicture(model: model)
                HStack {
                    if model.plateCountdown != nil {
                        Button("Cancel") { model.cancelBackgroundPicture() }
                    } else {
                        Button(model.backgroundPlate == nil ? "Take Background Picture" : "Retake Background Picture") { model.takeBackgroundPicture() }
                            .disabled(!model.canTakeBackgroundPicture)
                    }
                    if model.capturingPlate { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Background picture")
            } footer: {
                Text(model.running ? "After you click, step out of view. The picture is taken \(CameraModel.plateCountdownSeconds) seconds later. Keep the camera, lighting and furniture as they are afterwards." :
                    "Start a preview with a webcam layer to take the picture.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Section {
                    Picker("Preview", selection: $model.previewMode) {
                        ForEach(KeyPreview.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                } footer: {
                    Text(model.previewMode == .mask ? "White = kept · black = removed · grey = partly transparent. Local only; meetings receive the picture." :
                        "Local preview only. Meetings always receive the finished picture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Adjustments") {
                    KeySlider(name: "Threshold", value: $model.difference.threshold, range: 0...0.5,
                              hint: "How different from the background picture a pixel must be to stay. Raise it if background shows through.")
                    KeySlider(name: "Softness", value: $model.difference.softness, range: 0.005...0.5,
                              hint: "Widens the partly transparent range at edges.")
                    KeySlider(name: "Ignore lighting", value: $model.difference.lighting, range: 0...1,
                              hint: "Ignores brightness changes such as shadows and camera exposure, comparing colour more than brightness. Too much can remove clothing in the wall's colour.")
                    KeySlider(name: "Clean up", value: $model.difference.cleanup, range: 0...1,
                              hint: "Removes small background specks and fills small holes in you.")
                }
            }.disabled(!model.useBackgroundMask)
        }.formStyle(.grouped)
    }
}

private struct PlatePicture: View {
    let model: CameraModel
    var body: some View {
        if let plate = model.backgroundPlate {
            VStack(alignment: .leading, spacing: 4) {
                if let image = model.backgroundPlateImage {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityLabel("Background picture")
                }
                Text("\(String(plate.width)) × \(String(plate.height)) · \(plate.taken.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No background picture yet.").foregroundStyle(.secondary)
        }
    }
}

private struct Swatch: View {
    let color: SIMD3<Float>
    let index: Int
    let removable: Bool
    let remove: () -> Void
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
            .frame(width: 26, height: 22)
            .overlay(alignment: .topTrailing) {
                if removable {
                    Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.caption2) }
                        .buttonStyle(.plain).foregroundStyle(.white, .black.opacity(0.6)).offset(x: 5, y: -5)
                        .accessibilityLabel("Remove sample \(index + 1)")
                }
            }
            .accessibilityLabel("Screen sample \(index + 1)")
    }
}

private struct KeySlider: View {
    let name: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let hint: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                HStack {
                    Slider(value: $value, in: range).labelsHidden().accessibilityLabel(name)
                    Text(String(format: "%.2f", value)).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            } label: { Text(name) }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Camera and output

private struct OutputInspector: View {
    @Bindable var model: CameraModel
    private var locked: Bool { model.running || model.busy }
    var body: some View {
        Form {
            Section {
                Picker("Camera", selection: $model.selection) {
                    Text("Test pattern (no webcam)").tag("pattern")
                    if model.selectedCameraUnavailable { Text(model.unavailableCameraName).tag(model.selection) }
                    ForEach(model.cameras, id: \.uniqueID) { camera in Text(camera.localizedName).tag(camera.uniqueID) }
                }
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
                LabeledContent("Custom rate") {
                    HStack(spacing: 4) {
                        DraftNumberField("Custom fps", value: model.captureConfiguration.fps, fractionDigits: 0...3) { model.setCaptureFPS($0) }
                            .labelsHidden().frame(width: 70)
                        Text("fps").foregroundStyle(.secondary)
                    }
                }
                Button("Refresh Cameras") { model.refresh() }
            } header: {
                Text("Camera")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.formatAvailable {
                        Text("This camera does not offer the selected format. Choose a supported combination.").foregroundStyle(.orange)
                    }
                    if model.selection != "pattern" {
                        Text("Supported: " + model.capabilities.filter { $0.width == model.captureConfiguration.width && $0.height == model.captureConfiguration.height }
                            .map { String(format: "%.3f–%.3f fps", $0.minimumFPS, $0.maximumFPS) }.joined(separator: " · "))
                    }
                    if locked { Text("Stop capture to change the camera or its format.") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            .disabled(locked)
            Section {
                LabeledContent("Size") {
                    HStack(spacing: 4) {
                        DraftNumberField("Width", integer: model.outputConfiguration.width) { model.setOutput(width: $0) }.labelsHidden().frame(width: 64).accessibilityLabel("Canvas width")
                        Text("×")
                        DraftNumberField("Height", integer: model.outputConfiguration.height) { model.setOutput(height: $0) }.labelsHidden().frame(width: 64).accessibilityLabel("Canvas height")
                    }
                }
                LabeledContent("Frame rate") {
                    HStack(spacing: 4) {
                        DraftNumberField("Canvas fps", value: model.outputConfiguration.fps, fractionDigits: 0...3) { model.setOutput(fps: $0) }
                            .labelsHidden().frame(width: 70)
                        Text("fps").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Canvas output")
            } footer: {
                Text("Shared by all four scenes. Your meeting app may request a smaller format; the whole picture is kept with letterboxing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(locked)
            Section {
                Button("Install Camera Extension") { model.extensionManager.activate() }.disabled(model.extensionManager.pending)
            } header: {
                Text("Virtual camera")
            } footer: {
                Text(model.extensionManager.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.formStyle(.grouped)
    }
}
