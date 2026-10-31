#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import SwiftUI

/// In-app chooser for window and screen layers, listing what Screen Recording permission makes visible.
struct CaptureSourceSheet: View {
    let model: CameraModel
    let request: CaptureRequest
    @State private var options: [CaptureOption] = []
    @State private var thumbnails: [String: CGImage] = [:]
    @State private var selection: String?
    @State private var loading = true
    @State private var failure: String?
    private var noun: String { request.display ? "Screen" : "Window" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a \(noun)").font(.title3.bold())
                Text(request.display ? "The whole screen is captured; AppleCam's own windows are left out." :
                    "Only this window is captured, even when other windows cover it.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            Group {
                if loading { ProgressView("Looking for \(noun.lowercased())s…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let failure {
                    ContentUnavailableView("Cannot List \(noun)s", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if options.isEmpty {
                    ContentUnavailableView("No \(noun)s Available", systemImage: request.display ? "display" : "macwindow",
                        description: Text(request.display ? "No screen is connected." : "Open the window you want to show, then click Refresh."))
                } else {
                    List(options, selection: $selection) { option in
                        OptionRow(option: option, thumbnail: thumbnails[option.id]).tag(option.id)
                    }
                    .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                        if let id = ids.first { choose(id) }
                    }
                }
            }.frame(minHeight: 320)
            Divider()
            HStack {
                Button("Refresh") { Task { await load() } }.disabled(loading)
                Spacer()
                Button("Cancel", role: .cancel) { model.finishCaptureChoice(nil) }.keyboardShortcut(.cancelAction)
                Button("Add \(noun)") { if let selection { choose(selection) } }
                    .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }.padding(12)
        }
        .frame(width: 560, height: 520)
        .task { await load() }
    }
    private func choose(_ id: String) { model.finishCaptureChoice(options.first { $0.id == id }) }
    private func load() async {
        loading = true; failure = nil; thumbnails = [:]
        do {
            options = try await CaptureSelection.options(display: request.display)
            if selection == nil || !options.contains(where: { $0.id == selection }) { selection = options.first?.id }
        } catch { options = []; failure = error.localizedDescription }
        loading = false
        for option in options {
            if Task.isCancelled { return }
            if let image = await CaptureSelection.thumbnail(option) { thumbnails[option.id] = image }
        }
    }
}

private struct OptionRow: View {
    let option: CaptureOption
    let thumbnail: CGImage?
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() }
            }.frame(width: 112, height: 63).clipShape(RoundedRectangle(cornerRadius: 4))
            if let pid = option.processID, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "display").frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title).lineLimit(1)
                Text(option.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 2)
    }
}
