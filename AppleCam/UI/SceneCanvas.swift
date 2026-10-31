#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI

/// Live scene preview with direct-manipulation handles for the visible layers.
struct SceneCanvas: View {
    let model: CameraModel
    /// Drag translations are measured here, not in the moving layer frame. A local coordinate space moves
    /// with the layer being dragged, which feeds back into the translation and makes the layer jitter.
    static let space = "scene-canvas"
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black
                PreviewImage(model: model, size: geometry.size)
                LayerOverlays(model: model, canvas: geometry.size)
            }
            .coordinateSpace(.named(Self.space))
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                if model.sampling { model.sample(x: tap.location.x / geometry.size.width, y: tap.location.y / geometry.size.height) }
            })
            .overlay(alignment: .top) {
                if model.sampling {
                    Label("Click the green screen to sample its colour", systemImage: "eyedropper")
                        .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule()).padding(10)
                }
            }
        }
    }
}

/// The display layer stays in the hierarchy; only the placeholder depends on observed state.
private struct PreviewImage: View {
    let model: CameraModel
    let size: CGSize
    var body: some View {
        PreviewLayerView(display: model.previewDisplay)
            .frame(width: size.width, height: size.height)
            .overlay {
                if !model.showingPreview {
                    ZStack {
                        Color.black
                        VStack(spacing: 12) {
                            Image(systemName: "square.3.layers.3d").font(.largeTitle)
                            Text(model.busy ? "Preparing scene…" : "Scene stopped").font(.headline)
                            Text("Click Preview to arrange layers on the live picture.").font(.caption)
                        }.foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
    }
}

private struct LayerOverlays: View {
    let model: CameraModel
    let canvas: CGSize
    var body: some View {
        if model.running && !model.isMaskPreview {
            ForEach(model.activeScene.layers.reversed().filter(\.visible)) { layer in
                LayerCanvasOverlay(model: model, layer: layer, canvas: canvas)
            }
        }
    }
}

private struct LayerCanvasOverlay: View {
    let model: CameraModel
    let layer: SceneLayer
    let canvas: CGSize
    /// Gesture state resets automatically if a drag is cancelled, so a later drag never starts from a stale placement.
    @GestureState private var dragStart: LayerPlacement?
    @GestureState private var resizeStart: LayerPlacement?
    private var selected: Bool { model.selectedLayerID == layer.id }
    var body: some View {
        let rect = layer.placement.viewport(canvas: canvas)
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .overlay(Rectangle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                .onTapGesture { model.selectedLayerID = layer.id }
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(SceneCanvas.space))
                    .updating($dragStart) { value, start, _ in
                        guard !layer.locked else { return }
                        if start == nil { start = layer.placement; model.selectedLayerID = layer.id }
                        guard let origin = start else { return }
                        model.updateLayer(layer.id) {
                            $0.placement = LayerGeometry.moved(origin, by: value.translation, canvas: canvas)
                        }
                    })
            if selected && !layer.locked {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 1))
                    .accessibilityLabel("Resize \(layer.name)")
                    .help("Drag to resize")
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(SceneCanvas.space))
                        .updating($resizeStart) { value, start, _ in
                            if start == nil { start = layer.placement }
                            guard let origin = start else { return }
                            model.updateLayer(layer.id) {
                                $0.placement = LayerGeometry.resized(origin, by: value.translation, canvas: canvas)
                            }
                        })
            }
        }.frame(width: max(1, rect.width), height: max(1, rect.height)).position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(!model.sampling)
    }
}

/// Pure placement arithmetic for canvas gestures, in normalized canvas units.
enum LayerGeometry {
    static func moved(_ start: LayerPlacement, by translation: CGSize, canvas: CGSize) -> LayerPlacement {
        var next = start
        next.x = max(-10, min(10, start.x + translation.width / canvas.width))
        next.y = max(-10, min(10, start.y + translation.height / canvas.height))
        return next
    }
    static func resized(_ start: LayerPlacement, by translation: CGSize, canvas: CGSize) -> LayerPlacement {
        var next = start
        let w = clampSize(start.width + translation.width / canvas.width)
        let h = clampSize(start.height + translation.height / canvas.height)
        if start.aspectLocked {
            let factor = abs(translation.width) > abs(translation.height) ? w / start.width : h / start.height
            next.width = clampSize(start.width * factor); next.height = clampSize(start.height * factor)
        } else { next.width = w; next.height = h }
        return next
    }
    /// Sets one dimension from the inspector, keeping the aspect ratio when it is locked.
    static func sized(_ start: LayerPlacement, width: Double? = nil, height: Double? = nil) -> LayerPlacement {
        var next = start
        if let width { next.width = width; if start.aspectLocked { next.height = start.height * width / start.width } }
        if let height { next.height = height; if start.aspectLocked { next.width = start.width * height / start.height } }
        return next
    }
    private static func clampSize(_ value: Double) -> Double { max(0.001, min(10, value)) }
}
