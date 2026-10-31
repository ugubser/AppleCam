#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI

/// Sidebar (scenes and layers) · live canvas · inspector, so the output stays visible while editing.
struct ContentView: View {
    let model: CameraModel
    @SceneStorage("inspectorTab") private var tab = InspectorTab.layer
    @SceneStorage("inspectorShown") private var inspectorShown = true
    var body: some View {
        // The inspector spans the full window height, like Xcode and Keynote.
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: Self.sidebarMin, ideal: 250, max: 340)
        } detail: {
            CanvasPane(model: model)
        }
        .inspector(isPresented: $inspectorShown) {
            InspectorView(model: model, tab: $tab)
                .inspectorColumnWidth(min: Self.inspectorMin, ideal: 360, max: 480)
        }
        .navigationTitle("AppleCam")
        .navigationSubtitle("\(model.activeScene.name) · \(model.outputConfiguration.label)")
        .toolbar { OutputToolbar(model: model, inspectorShown: $inspectorShown) }
        .sheet(item: Binding(get: { model.captureRequest }, set: { if $0 == nil { model.finishCaptureChoice(nil) } })) { request in
            CaptureSourceSheet(model: model, request: request)
        }
        .sheet(item: Binding(get: { model.pendingPlate }, set: { if $0 == nil { model.discardBackgroundPicture() } })) { pending in
            BackgroundPictureReview(model: model, pending: pending)
        }
        // No extra window-level minimum frame: the split view derives the window minimum from its columns, and a
        // competing frame makes AppKit loop on constraint updates when the window reaches its minimum size.
    }
    static let sidebarMin: CGFloat = 210
    static let canvasMin: CGFloat = 380
    static let inspectorMin: CGFloat = 332
}

private struct OutputToolbar: ToolbarContent {
    let model: CameraModel
    @Binding var inspectorShown: Bool
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.start(publish: false) } label: { Label("Preview", systemImage: "play.rectangle") }
                .disabled(!model.canStartPreview).help("Compose the scene locally without sending it (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            Button { model.start(publish: true) } label: { Label("Send to AppleCam", systemImage: "video.badge.checkmark") }
                .disabled(!model.canSend).help("Send the scene to the AppleCam virtual camera (⇧⌘R)")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!model.canStop).help("Stop capture and sending (⌘.)")
                .keyboardShortcut(".", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorShown.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help(inspectorShown ? "Hide inspector" : "Show inspector")
        }
    }
}

private struct CanvasPane: View {
    let model: CameraModel
    var body: some View {
        VStack(spacing: 0) {
            SceneCanvas(model: model)
                .aspectRatio(model.previewAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 2)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(model: model)
        }
        .frame(minWidth: ContentView.canvasMin)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct StatusBar: View {
    let model: CameraModel
    private var state: (String, Color) {
        if model.running { return model.publishing ? ("Sending", .red) : ("Preview", .green) }
        return model.busy || model.scenePreparing ? ("Preparing", .orange) : ("Stopped", .secondary)
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label { Text(state.0).font(.callout.weight(.semibold)) } icon: {
                Circle().fill(state.1).frame(width: 8, height: 8)
            }.fixedSize()
            // Plain, single-line text: selectable (AppKit-backed) or wrapping text changes this split pane's minimum
            // size during layout, which makes AppKit abort with an endless constraint-update loop.
            Text(model.status).font(.callout).lineLimit(1).truncationMode(.tail)
                .help(model.status).frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { Button("Copy Status") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.status, forType: .string) } }
            if model.settingsError {
                Text(model.settingsMessage).font(.caption).foregroundStyle(.orange).lineLimit(1).help(model.settingsMessage)
                Button("Save Current Settings") { model.saveCurrentPreferences() }.controlSize(.small)
            }
            Text(String(format: "%.1f fps out · %.1f fps preview", model.captureFPS, model.previewFPS))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                .help("Output counts composed frames. Preview counts frames shown here, not monitor refresh or meeting output.")
            Text("DEVELOPMENT").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule()).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}
