#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI

/// Scenes and the ordered layers of the selected scene. Selection here drives the inspector.
struct SidebarView: View {
    @Bindable var model: CameraModel
    var body: some View {
        VStack(spacing: 0) {
            SceneGrid(model: model).padding(10)
            Divider()
            List(selection: $model.selectedLayerID) {
                Section {
                    ForEach(model.activeScene.layers) { layer in
                        LayerRow(model: model, layer: layer).tag(layer.id as UUID?)
                            .contextMenu { LayerMenu(model: model, layer: layer) }
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        let id = model.activeScene.layers[from].id
                        model.moveLayer(id, to: destination > from ? destination - 1 : destination)
                    }
                } header: {
                    Text("Layers · front at top")
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { if let id = model.selectedLayerID { model.deleteLayer(id) } }
            .overlay {
                if model.activeScene.layers.isEmpty {
                    ContentUnavailableView("No Layers", systemImage: "square.3.layers.3d", description: Text("Add a webcam, image, video, browser, window or screen."))
                }
            }
            Divider()
            HStack {
                AddLayerMenu(model: model)
                Spacer()
                Button { if let id = model.selectedLayerID { model.deleteLayer(id) } } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).help("Delete selected layer")
                    .disabled(model.selectedLayer == nil || model.selectedLayer?.locked == true)
                    .accessibilityLabel("Delete selected layer")
            }.padding(8)
        }
    }
}

private struct SceneGrid: View {
    let model: CameraModel
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Array(model.scenes.enumerated()), id: \.element.id) { index, scene in
                SceneTile(model: model, scene: scene, index: index)
            }
        }
    }
}

private struct SceneTile: View {
    let model: CameraModel
    let scene: CameraScene
    let index: Int
    private var selected: Bool { model.selectedScene == index }
    var body: some View {
        Button { model.selectScene(index) } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.85))
                    if let image = model.sceneThumbnails[scene.id] { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                    else { Image(systemName: "square.3.layers.3d").foregroundStyle(.white.opacity(0.6)) }
                }
                .frame(height: 64) // Fixed, not width-derived: see StatusBar.
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(scene.name).font(.caption).lineLimit(1).foregroundStyle(selected ? .primary : .secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(model.busy)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .help("\(scene.name) (⌘\(index + 1))")
        .accessibilityLabel("Scene \(index + 1): \(scene.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LayerRow: View {
    let model: CameraModel
    let layer: SceneLayer
    var body: some View {
        HStack(spacing: 8) {
            Button { model.updateLayer(layer.id) { $0.visible.toggle() } } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash").frame(width: 18)
            }
            .buttonStyle(.borderless).foregroundStyle(layer.visible ? .primary : .secondary)
            .help(layer.visible ? "Hide layer" : "Show layer").accessibilityLabel("Toggle visibility for \(layer.name)")
            Image(systemName: layer.source.symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name).lineLimit(1)
                Text(layer.source.label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { model.updateLayer(layer.id) { $0.locked.toggle() } } label: {
                Image(systemName: layer.locked ? "lock.fill" : "lock.open")
            }
            .buttonStyle(.borderless).foregroundStyle(layer.locked ? .primary : .tertiary)
            .help(layer.locked ? "Unlock placement" : "Lock placement").accessibilityLabel("Toggle placement lock for \(layer.name)")
        }
        .opacity(layer.visible ? 1 : 0.6)
    }
}

struct LayerMenu: View {
    let model: CameraModel
    let layer: SceneLayer
    var body: some View {
        Button(layer.visible ? "Hide" : "Show") { model.updateLayer(layer.id) { $0.visible.toggle() } }
        Button(layer.locked ? "Unlock Placement" : "Lock Placement") { model.updateLayer(layer.id) { $0.locked.toggle() } }
        Divider()
        Button("Delete Layer", role: .destructive) { model.deleteLayer(layer.id) }.disabled(layer.locked)
    }
}

struct AddLayerMenu: View {
    let model: CameraModel
    var body: some View {
        Menu {
            Button("Webcam") { model.addCameraLayer() }
            Button("Image…") { model.chooseMedia(clip: false) }
            Button("Repeating Video…") { model.chooseMedia(clip: true) }
            Button("Browser Page") { model.addBrowserLayer() }
            Button("Window…") { model.addCaptureLayer(display: false) }
            Button("Screen…") { model.addCaptureLayer(display: true) }
        } label: { Label("Add Layer", systemImage: "plus") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Add a layer to the front of this scene")
    }
}

extension LayerSource {
    var symbol: String {
        switch self {
        case .camera: return "web.camera"
        case .image: return "photo"
        case .clip: return "film"
        case .browser: return "globe"
        case .window: return "macwindow"
        case .display: return "display"
        }
    }
}
