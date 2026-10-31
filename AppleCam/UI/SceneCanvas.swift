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
            .overlay { PlateCountdownOverlay(model: model).allowsHitTesting(false) }
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
                // The selected layer sits above the others so its frame and handles stay reachable even when a
                // larger layer covers it.
                LayerCanvasOverlay(model: model, layer: layer, canvas: canvas)
                    .zIndex(model.selectedLayerID == layer.id ? 1 : 0)
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
    private var selected: Bool { model.selectedLayerID == layer.id }
    var body: some View {
        // Only the on-canvas part is drawn and clickable, so frames of full-size or oversized layers stay visible.
        let visible = LayerGeometry.visibleRect(layer.placement, canvas: canvas)
        if let visible {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .overlay { if selected { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                .onTapGesture { location in
                    // The overlay's origin is the visible rectangle's origin on the canvas.
                    let point = CGPoint(x: visible.minX + location.x, y: visible.minY + location.y)
                    model.selectedLayerID = LayerGeometry.layer(at: point, in: model.activeScene.layers, canvas: canvas,
                        selected: model.selectedLayerID) ?? layer.id
                }
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(SceneCanvas.space))
                    .updating($dragStart) { value, start, _ in
                        guard !layer.locked else { return }
                        if start == nil { start = layer.placement; model.selectedLayerID = layer.id }
                        guard let origin = start else { return }
                        model.updateLayer(layer.id) {
                            $0.placement = LayerGeometry.moved(origin, by: value.translation, canvas: canvas)
                        }
                    })
                .help(selected ? "Drag to move. Click again to select the layer underneath." : "Click to select \(layer.name).")
                .overlay {
                    if selected && !layer.locked {
                        ForEach(LayerCorner.allCases, id: \.self) { corner in
                            ResizeHandle(model: model, layer: layer, canvas: canvas, corner: corner)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if selected && layer.locked {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.white)
                            .padding(5).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4)).padding(6)
                            .help("\(layer.name) is locked. Unlock it in the sidebar to move or resize it.")
                    }
                }
                .frame(width: visible.width, height: visible.height).position(x: visible.midX, y: visible.midY)
                .allowsHitTesting(!model.sampling)
        }
    }
}

/// A corner handle; the opposite corner stays fixed while dragging.
private struct ResizeHandle: View {
    let model: CameraModel
    let layer: SceneLayer
    let canvas: CGSize
    let corner: LayerCorner
    @GestureState private var resizeStart: LayerPlacement?
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 12, height: 12)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 1))
            .padding(1)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: corner.resizePosition))
            .accessibilityLabel("Resize \(layer.name)")
            .help("Drag to resize")
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(SceneCanvas.space))
                .updating($resizeStart) { value, start, _ in
                    if start == nil { start = layer.placement }
                    guard let origin = start else { return }
                    model.updateLayer(layer.id) {
                        $0.placement = LayerGeometry.resized(origin, by: value.translation, canvas: canvas, from: corner)
                    }
                })
    }
}

enum LayerCorner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    var trailing: Bool { self == .topTrailing || self == .bottomTrailing }
    var bottom: Bool { self == .bottomLeading || self == .bottomTrailing }
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
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
    /// Resizes by dragging `corner`; the opposite corner stays where it was.
    static func resized(_ start: LayerPlacement, by translation: CGSize, canvas: CGSize,
                        from corner: LayerCorner = .bottomTrailing) -> LayerPlacement {
        let dx = corner.trailing ? translation.width : -translation.width
        let dy = corner.bottom ? translation.height : -translation.height
        var next = start
        let w = clampSize(start.width + dx / canvas.width)
        let h = clampSize(start.height + dy / canvas.height)
        if start.aspectLocked {
            let factor = abs(dx) > abs(dy) ? w / start.width : h / start.height
            next.width = clampSize(start.width * factor); next.height = clampSize(start.height * factor)
        } else { next.width = w; next.height = h }
        if !corner.trailing { next.x = max(-10, min(10, start.x + start.width - next.width)) }
        if !corner.bottom { next.y = max(-10, min(10, start.y + start.height - next.height)) }
        return next
    }
    /// The part of a layer that lies on the canvas, or nil when the layer is entirely off it.
    static func visibleRect(_ placement: LayerPlacement, canvas: CGSize) -> CGRect? {
        let visible = placement.viewport(canvas: canvas).intersection(CGRect(origin: .zero, size: canvas))
        return visible.isNull || visible.width < 1 || visible.height < 1 ? nil : visible
    }
    /// The layer a click selects: the topmost visible layer under the pointer, or, when the selected layer is under
    /// it, the next one below (cycling back to the top), so layers covered by a larger one can still be picked.
    /// `layers` is ordered top first.
    static func layer(at point: CGPoint, in layers: [SceneLayer], canvas: CGSize, selected: UUID?) -> UUID? {
        let hits = layers.filter { $0.visible && $0.placement.viewport(canvas: canvas).contains(point) }.map(\.id)
        guard let first = hits.first else { return nil }
        guard let selected, let index = hits.firstIndex(of: selected) else { return first }
        return hits[(index + 1) % hits.count]
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
