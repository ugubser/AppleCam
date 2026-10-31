#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI
import UniformTypeIdentifiers

struct SceneCanvas: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black
                if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "square.3.layers.3d").font(.largeTitle)
                        Text(model.busy ? "Preparing scene…" : "Scene stopped").font(.headline)
                        Text("Start Preview locally to arrange layers.").font(.caption)
                    }.foregroundStyle(.white.opacity(0.7)).frame(width: geometry.size.width, height: geometry.size.height)
                }
                if model.image != nil && !model.isMaskPreview {
                    ForEach(model.activeScene.layers.reversed().filter(\.visible)) { layer in
                        LayerCanvasOverlay(model: model, layer: layer, canvas: geometry.size)
                    }
                }
            }.contentShape(Rectangle())
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    if model.sampling { model.sample(x: tap.location.x / geometry.size.width, y: tap.location.y / geometry.size.height) }
                })
        }
    }
}

private struct LayerCanvasOverlay: View {
    @ObservedObject var model: CameraModel
    let layer: SceneLayer
    let canvas: CGSize
    @State private var dragStart: LayerPlacement?
    @State private var resizeStart: LayerPlacement?
    private var selected: Bool { model.selectedLayerID == layer.id }
    var body: some View {
        let rect = layer.placement.viewport(canvas: canvas)
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .overlay(Rectangle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                .onTapGesture { model.selectedLayerID = layer.id }
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    guard !layer.locked else { return }
                    model.selectedLayerID = layer.id
                    if dragStart == nil { dragStart = layer.placement }
                    guard let start = dragStart else { return }
                    model.updateLayer(layer.id) {
                        $0.placement.x = max(-10, min(10, start.x + value.translation.width / canvas.width))
                        $0.placement.y = max(-10, min(10, start.y + value.translation.height / canvas.height))
                    }
                }.onEnded { _ in dragStart = nil })
            if selected && !layer.locked {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 15, height: 15)
                    .accessibilityLabel("Resize \(layer.name)")
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        if resizeStart == nil { resizeStart = layer.placement }
                        guard let start = resizeStart else { return }
                        model.updateLayer(layer.id) {
                            let w = max(0.001, min(10, start.width + value.translation.width / canvas.width))
                            let h = max(0.001, min(10, start.height + value.translation.height / canvas.height))
                            if start.aspectLocked {
                                let factor = abs(value.translation.width) > abs(value.translation.height) ? w / start.width : h / start.height
                                $0.placement.width = max(0.001, min(10, start.width * factor))
                                $0.placement.height = max(0.001, min(10, start.height * factor))
                            } else { $0.placement.width = w; $0.placement.height = h }
                        }
                    }.onEnded { _ in resizeStart = nil })
            }
        }.frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(!model.sampling)
    }
}

struct SceneEditor: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Array(model.scenes.enumerated()), id: \.element.id) { index, scene in
                    Button { model.selectScene(index) } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.8))
                                if let image = model.sceneThumbnails[scene.id] { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                                else { Image(systemName: "square.3.layers.3d").font(.title2).foregroundStyle(.white.opacity(0.6)) }
                            }.frame(height: 60).clipped()
                            Text(scene.name).font(.caption).lineLimit(1)
                        }.frame(maxWidth: .infinity).padding(6)
                            .background(model.selectedScene == index ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(model.busy)
                        .accessibilityLabel("Scene \(index + 1): \(scene.name)")
                }
            }
            HStack {
                TextField("Scene name", text: Binding(get: { model.activeScene.name }, set: { model.renameScene($0) })).font(.headline)
                if model.scenePreparing { ProgressView().controlSize(.small); Text("Preparing…").font(.caption) }
                Menu("Add layer") {
                    Button("Webcam") { model.addCameraLayer() }
                    Button("Image…") { model.chooseMedia(clip: false) }
                    Button("Repeating video…") { model.chooseMedia(clip: true) }
                    Button("Browser page") { model.addBrowserLayer() }
                    Button("Window…") { model.addCaptureLayer(display: false) }
                    Button("Screen…") { model.addCaptureLayer(display: true) }
                }.fixedSize()
            }
            Text("Front at the top · Drag rows to reorder · Changes are live").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(model.activeScene.layers.enumerated()), id: \.element.id) { index, layer in
                            layerRow(layer, index: index)
                        }
                        if model.activeScene.layers.isEmpty { Text("Add a layer to this scene.").foregroundStyle(.secondary).padding() }
                    }
                }.frame(width: 260, height: 230)
                Divider()
                if let layer = model.selectedLayer { LayerInspector(model: model, layer: layer) }
                else { Text("Select a layer to edit it.").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            ColorPicker("Canvas colour", selection: Binding(get: {
                Color(.sRGB, red: model.activeScene.canvasRed, green: model.activeScene.canvasGreen, blue: model.activeScene.canvasBlue)
            }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                var scenes = model.scenes
                scenes[model.selectedScene].canvasRed = rgb.redComponent
                scenes[model.selectedScene].canvasGreen = rgb.greenComponent
                scenes[model.selectedScene].canvasBlue = rgb.blueComponent
                model.scenes = scenes
            }), supportsOpacity: false)
        }
    }
    private func layerRow(_ layer: SceneLayer, index: Int) -> some View {
        HStack(spacing: 6) {
            Button { model.updateLayer(layer.id) { $0.visible.toggle() } } label: { Image(systemName: layer.visible ? "eye" : "eye.slash") }
                .help(layer.visible ? "Hide layer" : "Show layer").accessibilityLabel("Toggle visibility for \(layer.name)")
            Button { model.selectedLayerID = layer.id } label: {
                VStack(alignment: .leading) { Text(layer.name).lineLimit(1); Text(layer.source.label).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { model.updateLayer(layer.id) { $0.locked.toggle() } } label: { Image(systemName: layer.locked ? "lock.fill" : "lock.open") }
                .help(layer.locked ? "Unlock placement" : "Lock placement").accessibilityLabel("Toggle placement lock for \(layer.name)")
        }.buttonStyle(.plain).padding(8)
            .background(model.selectedLayerID == layer.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onDrag { NSItemProvider(object: layer.id.uuidString as NSString) }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, let id = UUID(uuidString: text) else { return }
                    Task { @MainActor in model.moveLayer(id, to: index) }
                }
                return true
            }
    }
}

private struct LayerInspector: View {
    @ObservedObject var model: CameraModel
    let layer: SceneLayer
    @State private var browserURL = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Layer name", text: Binding(get: { current.name }, set: { name in edit { $0.name = name } }))
            HStack {
                number("X", get: { current.placement.x }, set: { v in edit { $0.placement.x = v } })
                number("Y", get: { current.placement.y }, set: { v in edit { $0.placement.y = v } })
                number("W", get: { current.placement.width }, set: { v in resize(width: v) })
                number("H", get: { current.placement.height }, set: { v in resize(height: v) })
            }.disabled(current.locked)
            Text("Position and size in % of canvas").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Picker("Content", selection: Binding(get: { current.placement.sizing }, set: { sizing in edit { $0.placement.sizing = sizing } })) {
                    ForEach(LayerSizing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("Reset") { edit { $0.placement = LayerPlacement() } }
            }.disabled(current.locked)
            Toggle("Keep aspect ratio", isOn: Binding(get: { current.placement.aspectLocked }, set: { locked in edit { $0.placement.aspectLocked = locked } })).disabled(current.locked)
            sourceControls
            HStack {
                Spacer()
                Button("Delete layer", role: .destructive) { model.deleteLayer(layer.id) }.disabled(current.locked)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var current: SceneLayer { model.activeScene.layers.first { $0.id == layer.id } ?? layer }
    private func edit(_ change: (inout SceneLayer) -> Void) { model.updateLayer(layer.id, change) }
    private func resize(width: Double? = nil, height: Double? = nil) {
        let old = current.placement
        edit {
            if let width { $0.placement.width = width; if old.aspectLocked { $0.placement.height = old.height * width / old.width } }
            if let height { $0.placement.height = height; if old.aspectLocked { $0.placement.width = old.width * height / old.height } }
        }
    }
    private func number(_ name: String, get: @escaping () -> Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption)
            TextField(name, value: Binding(get: { get() * 100 }, set: { set($0 / 100) }), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Layer \(name) percent")
        }
    }
    @ViewBuilder private var sourceControls: some View {
        switch current.source {
        case .camera: Text("Uses the selected webcam and its saved calibration.").font(.caption).foregroundStyle(.secondary)
        case .image(let asset):
            Text(asset.name).font(.caption).lineLimit(1)
            Button("Replace image…") { model.chooseMedia(clip: false, replacing: layer.id) }
        case .clip(let asset):
            Text("\(asset.name) · silent · repeating").font(.caption).lineLimit(1)
            HStack {
                Button(model.clipPaused(layer.id) ? "Play" : "Pause") { model.toggleClip(layer.id) }.disabled(!model.running)
                Button("Restart") { model.restartClip(layer.id) }.disabled(!model.running)
                Button("Replace…") { model.chooseMedia(clip: true, replacing: layer.id) }
            }
        case .browser(let settings):
            HStack {
                TextField("https://…", text: $browserURL).onSubmit { navigate(settings) }
                    .onAppear { browserURL = settings.url }.onChange(of: layer.id) { _, _ in browserURL = settings.url }
                Button("Go") { navigate(settings) }
            }
            HStack {
                Button("Back") { model.navigateBrowser(layer.id, forward: false) }.disabled(!model.running || !model.browserCanGoBack(layer.id))
                Button("Forward") { model.navigateBrowser(layer.id, forward: true) }.disabled(!model.running || !model.browserCanGoForward(layer.id))
                Button("Interact with page") { model.showBrowser(layer.id) }.disabled(!model.running || !current.visible)
                Button("Reload") { model.reloadBrowser(layer.id) }.disabled(!model.browserAvailable(layer.id))
            }
            HStack {
                Text("Browser viewport")
                TextField("Width", value: Binding(get: { settings.width }, set: { v in var b = settings; b.width = v; edit { $0.source = .browser(b) } }), format: .number).frame(width: 60)
                Text("×")
                TextField("Height", value: Binding(get: { settings.height }, set: { v in var b = settings; b.height = v; edit { $0.source = .browser(b) } }), format: .number).frame(width: 60)
            }.font(.caption)
            Text("Silent WebKit surface. Its source window stays rendered while active; use AppleCam controls to arrange the layer.").font(.caption2).foregroundStyle(.secondary)
        case .window(let ref):
            Text(ref?.title ?? "No window selected").font(.caption).lineLimit(1)
            Button("Choose window…") { model.replaceCapture(layer.id) }
        case .display(let ref):
            Text(ref?.name ?? "No screen selected").font(.caption).lineLimit(1)
            Button("Choose screen…") { model.replaceCapture(layer.id) }
        }
    }
    private func navigate(_ settings: BrowserSettings) { var next = settings; next.url = browserURL; edit { $0.source = .browser(next) } }
}
