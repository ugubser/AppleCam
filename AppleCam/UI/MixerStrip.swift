#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI

/// Collapsible audio mixer under the canvas: level, volume and mute per channel, always in view while editing.
struct MixerStrip: View {
    let model: CameraModel
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                    Label("Audio", systemImage: expanded ? "chevron.down" : "chevron.right").font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain).help(expanded ? "Hide the mixer" : "Show the mixer")
                .accessibilityLabel(expanded ? "Hide audio mixer" : "Show audio mixer")
                LevelMeterView(level: model.mixLevel).frame(maxWidth: 200)
                    .help("The mix: what is recorded as the first audio track.")
                if model.recording != nil {
                    Label("Recording \(1 + model.recordedChannels().count) audio tracks", systemImage: "record.circle")
                        .font(.caption).foregroundStyle(.red).labelStyle(.titleAndIcon)
                }
                Spacer()
                MonitorControl(model: model)
                AddMicrophoneMenu(model: model)
            }
            if expanded {
                let rows = model.mixerRows
                if rows.isEmpty {
                    Text("No sound sources yet. Add a microphone, or turn on Audio for a browser, window, screen or video layer in the Layer tab.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 4) {
                            ForEach(rows) { row in ChannelRowView(model: model, row: row) }
                            ChannelRowView(model: model, row: MixerRow(id: "mix", name: "Mix", kind: .microphone, mix: model.audio.master, live: true, scope: nil), isMaster: true)
                        }
                    }
                    .frame(maxHeight: 180).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct AddMicrophoneMenu: View {
    let model: CameraModel
    var body: some View {
        Menu {
            let used = Set(model.audio.microphones.map(\.deviceID))
            let devices = model.availableMicrophones.filter { !used.contains($0.uid) }
            if devices.isEmpty { Text("No other microphones") }
            ForEach(devices) { device in Button(device.name) { model.addMicrophone(device) } }
        } label: { Label("Add Microphone", systemImage: "plus") }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(!model.canChangeChannels)
        .help(model.canChangeChannels ? "Add a microphone to the mix. It is heard in every scene." : "Stop recording to add or remove channels.")
        .onAppear { model.refreshMicrophones() }
    }
}

private struct MonitorControl: View {
    let model: CameraModel
    var body: some View {
        HStack(spacing: 2) {
            Toggle(isOn: Binding(get: { model.audio.monitor }, set: { model.audio.monitor = $0 })) {
                Label("Monitor", systemImage: "headphones")
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Play the mix on \(model.monitorOutputName), about 0.2 s behind. Use headphones: speakers feed back into microphones.")
            Menu {
                Picker("Monitor output", selection: Binding(get: { model.audio.monitorDeviceUID }, set: { model.audio.monitorDeviceUID = $0 })) {
                    Text("System Output").tag(String?.none)
                    ForEach(AudioOutputDevice.all()) { Text($0.name).tag(Optional($0.uid)) }
                }.pickerStyle(.inline)
            } label: { Text("") }
            .menuStyle(.borderlessButton).fixedSize().help("Choose the monitor output")
            .accessibilityLabel("Monitor output")
        }
    }
}

struct ChannelRowView: View {
    let model: CameraModel
    let row: MixerRow
    var isMaster = false
    private var level: ChannelLevel { isMaster ? model.mixLevel : (model.audioLevels[row.id] ?? .silent) }
    private var symbol: String {
        if isMaster { return "slider.horizontal.3" }
        switch row.kind { case .microphone: return "mic"; case .layer(let source): return source.symbol }
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).font(isMaster ? .callout.weight(.semibold) : .callout).lineLimit(1)
                if let failure = model.channelFailures[row.id] {
                    Text(failure).font(.caption2).foregroundStyle(.orange).lineLimit(1).help(failure)
                } else if let note = model.channelNotes[row.id] {
                    Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(1).help(note)
                } else if !row.live {
                    Text("Other scene — not in the mix now").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if case .microphone = row.kind, !isMaster {
                    Text("Mic mode: \(model.microphoneModeLabel)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 150, alignment: .leading)
            .help(row.scope ?? row.name)
            LevelMeterView(level: row.live ? level : .silent).frame(minWidth: 80)
            Slider(value: Binding(get: { Double(row.mix.volume) }, set: { v in model.setMix(row.id) { $0.volume = Float(v) } }),
                   in: Double(AudioMath.minimumDB)...Double(AudioMath.maximumDB))
                .frame(width: 120).controlSize(.small).accessibilityLabel("\(row.name) volume")
            Text(row.mix.volume <= AudioMath.minimumDB ? "−∞ dB" : String(format: "%+.0f dB", row.mix.volume))
                .font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing).foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { row.mix.muted }, set: { m in model.setMix(row.id) { $0.muted = m } })) {
                Image(systemName: row.mix.muted ? "speaker.slash.fill" : "speaker.wave.2")
            }
            .toggleStyle(.button).controlSize(.small).help(row.mix.muted ? "Unmute" : "Mute")
            .accessibilityLabel(row.mix.muted ? "Unmute \(row.name)" : "Mute \(row.name)")
            if !isMaster { OffsetButton(model: model, row: row) }
            if !isMaster, case .microphone = row.kind {
                Button { model.removeMicrophone(row.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(!model.canChangeChannels).help("Remove this microphone from the mix")
                    .accessibilityLabel("Remove \(row.name)")
            }
            if model.recording != nil && !isMaster {
                Image(systemName: "record.circle").foregroundStyle(.red).help("Recorded as its own track")
            }
        }
    }
}

/// Moves a channel in time, for example to line up a Bluetooth microphone that arrives late.
private struct OffsetButton: View {
    let model: CameraModel
    let row: MixerRow
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: row.mix.offsetMilliseconds == 0 ? "clock" : "clock.badge.exclamationmark")
        }
        .buttonStyle(.borderless).help(row.mix.offsetMilliseconds == 0 ? "Timing" : String(format: "Timing: %+.0f ms", row.mix.offsetMilliseconds))
        .accessibilityLabel("\(row.name) timing")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Timing of \(row.name)").font(.headline)
                HStack {
                    Slider(value: Binding(get: { row.mix.offsetMilliseconds }, set: { v in model.setMix(row.id) { $0.offsetMilliseconds = v.rounded() } }),
                           in: ChannelMix.offsetRange, step: 5).frame(width: 220)
                    Text(String(format: "%+.0f ms", row.mix.offsetMilliseconds)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                Text("Positive delays this sound; negative plays it earlier. Use it when a channel is out of step with the picture, for example a Bluetooth microphone. Microphones already follow the webcam picture's delay automatically.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Button("Reset") { model.setMix(row.id) { $0.offsetMilliseconds = 0 } }.disabled(row.mix.offsetMilliseconds == 0)
            }
            .padding(14)
        }
    }
}

/// Horizontal meter from −60 to 0 dBFS: RMS as the bar, peak as a tick, a red end when the signal clipped recently.
struct LevelMeterView: View {
    let level: ChannelLevel
    private func fraction(_ db: Float) -> CGFloat { CGFloat(min(max((db + 60) / 60, 0), 1)) }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.75),
                                                      .init(color: .yellow, location: 0.9), .init(color: .red, location: 1)],
                                              startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: width * fraction(level.rmsDB)) }
                Rectangle().fill(.primary.opacity(0.7)).frame(width: 2).offset(x: max(0, width * fraction(level.peakDB) - 2))
                    .opacity(level.peakDB > -60 ? 1 : 0)
                if level.clipping { Circle().fill(.red).frame(width: 7, height: 7).offset(x: width - 7) }
            }
        }
        .frame(height: 7)
        .accessibilityElement().accessibilityLabel("Level")
        .accessibilityValue(level.peakDB <= -60 ? "Silent" : String(format: "Peak %.0f dB%@", level.peakDB, level.clipping ? ", clipping" : ""))
    }
}

/// Layer tab: whether this layer's sound goes into the mix, and what that sound covers.
struct LayerAudioSection: View {
    let model: CameraModel
    let layer: SceneLayer
    var body: some View {
        Section {
            Toggle("Capture audio", isOn: Binding(get: { layer.hasAudio }, set: { model.setLayerAudio(layer.id, enabled: $0) }))
                .disabled(!model.canChangeChannels)
        } header: {
            Text("Audio")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let scope = CameraModel.audioScope(layer.source) { Text(scope) }
                Text(Self.note(layer.source))
                if !model.canChangeChannels { Text("Stop recording to turn audio on or off.").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    static func note(_ source: LayerSource) -> String {
        switch source {
        case .clip: return "The clip's sound goes into the mix only; it is not played through your speakers. Use Monitor to listen."
        case .browser: return "The page's video and audio players go into the mix only; they are not played through your speakers. Use Monitor to listen. Pages that make sound with Web Audio (games, synthesizers) stay silent."
        case .window, .display: return "Needs Screen Recording permission. The app keeps playing through your speakers as usual. Apps that are using a microphone (for example a meeting) are left out so other participants are never recorded."
        default: return ""
        }
    }
}

/// Output tab: where recordings go and what a recording contains.
struct RecordingSection: View {
    let model: CameraModel
    var body: some View {
        Section {
            LabeledContent("Save to") { Text(model.recordingFolderName ?? "Not chosen yet") }
            HStack {
                Button("Choose Folder…") { model.chooseRecordingFolder() }.disabled(model.recording != nil)
                Spacer()
                Button("Show Last Recording") { model.revealLastRecording() }.disabled(model.lastRecording == nil)
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("HEVC QuickTime movie at the canvas size (\(model.outputConfiguration.label)), about \(ByteCountFormatter.string(fromByteCount: Int64(model.recordingHourlyBytes), countStyle: .file)) per hour. The first audio track is the mix; each channel is also its own track for editing. Record starts a local preview when nothing is running.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
