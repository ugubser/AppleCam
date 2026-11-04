#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import AVFoundation

/// A row in the mixer strip.
struct MixerRow: Identifiable, Equatable {
    enum Kind: Equatable { case microphone, layer(LayerSource) }
    let id: String
    let name: String
    let kind: Kind
    let mix: ChannelMix
    /// False for a layer whose scene is not live: its sound is not in the mix right now.
    let live: Bool
    /// What one channel actually contains, when that is more than the layer itself.
    let scope: String?
}

/// Audio channels, volumes and the mixer strip. Channels follow the live scene; microphones are heard in every scene.
extension CameraModel {
    /// Channels recorded as their own tracks, in order (the mix is always the first track).
    func recordedChannels() -> [(id: String, name: String)] { AudioRuntime.channelList(audio: audio, scenes: scenes) }

    var mixerRows: [MixerRow] {
        let live = Set(activeScene.layers.filter(\.visible).map(\.id))
        let layers = scenes.flatMap(\.layers).filter(\.hasAudio)
        var rows = audio.microphones.map { MixerRow(id: AudioChannelID.microphone($0.deviceID), name: $0.name, kind: .microphone, mix: $0.mix, live: true, scope: nil) }
        rows += layers.filter { !$0.source.isBrowser }.map {
            MixerRow(id: AudioChannelID.layer($0.id), name: $0.name, kind: .layer($0.source), mix: $0.audio?.mix ?? ChannelMix(),
                     live: live.contains($0.id), scope: Self.audioScope($0.source))
        }
        // WebKit plays every page through one audio process, so all browser layers share one channel.
        let pages = layers.filter(\.source.isBrowser)
        if let first = pages.first {
            rows.append(MixerRow(id: AudioChannelID.browser, name: AudioChannelID.browserName, kind: .layer(first.source), mix: audio.browser,
                                 live: pages.contains { live.contains($0.id) },
                                 scope: "Pages with Audio on: " + pages.map(\.name).joined(separator: ", ") + "."))
        }
        return rows
    }
    static func audioScope(_ source: LayerSource) -> String? {
        switch source {
        case .window(let reference): return "All sound of \(reference.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.localizedName } ?? "the window's app"), not only this window."
        case .display: return "All sound on this Mac except AppleCam and apps using a microphone."
        default: return nil
        }
    }
    /// Channels can be added or removed only while not recording: a recording's tracks are fixed when it starts.
    var canChangeChannels: Bool { recording == nil && !recordingPending }

    func refreshMicrophones() { availableMicrophones = AudioInputDevice.all() }
    var monitorOutputName: String {
        guard let uid = audio.monitorDeviceUID else { return "the system output" }
        return AudioOutputDevice.all().first { $0.uid == uid }?.name ?? "a disconnected output"
    }
    /// Adds a microphone to the mix, asking for microphone permission the first time.
    func addMicrophone(_ device: AudioInputDevice) {
        guard canChangeChannels, !audio.microphones.contains(where: { $0.deviceID == device.uid }) else { return }
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    status = "Microphone access was denied. Allow AppleCam in System Settings → Privacy & Security → Microphone."; return
                }
            }
            channelFailures[AudioChannelID.microphone(device.uid)] = nil
            audio.microphones.append(MicrophoneChannel(deviceID: device.uid, name: device.name))
        }
    }
    func removeMicrophone(_ id: String) {
        guard canChangeChannels else { return }
        audio.microphones.removeAll { AudioChannelID.microphone($0.deviceID) == id }; channelFailures[id] = nil
    }
    /// Turns a layer's sound on or off.
    func setLayerAudio(_ layerID: UUID, enabled: Bool) {
        guard canChangeChannels else { return }
        editAudioLayer(layerID) { layer in
            var audio = layer.audio ?? LayerAudio(); audio.enabled = enabled && layer.source.canHaveAudio; layer.audio = audio
        }
        channelFailures[AudioChannelID.layer(layerID)] = nil
    }
    /// Volume, mute or offset of a channel (`AudioChannelID`), or of the whole mix for "mix".
    func setMix(_ id: String, _ change: (inout ChannelMix) -> Void) {
        if id == "mix" { var m = audio.master; change(&m); if m.isValid { audio.master = m }; return }
        if id == AudioChannelID.browser { var m = audio.browser; change(&m); if m.isValid { audio.browser = m }; return }
        if let index = audio.microphones.firstIndex(where: { AudioChannelID.microphone($0.deviceID) == id }) {
            var m = audio.microphones[index].mix; change(&m); if m.isValid { audio.microphones[index].mix = m }; return
        }
        guard let layerID = UUID(uuidString: id) else { return }
        editAudioLayer(layerID) { layer in
            var audio = layer.audio ?? LayerAudio(); var m = audio.mix; change(&m)
            if m.isValid { audio.mix = m; layer.audio = audio }
        }
    }
    private func editAudioLayer(_ id: UUID, _ change: (inout SceneLayer) -> Void) {
        guard let s = scenes.firstIndex(where: { $0.layers.contains { $0.id == id } }),
              let l = scenes[s].layers.firstIndex(where: { $0.id == id }) else { return }
        var layer = scenes[s].layers[l]; change(&layer)
        guard layer != scenes[s].layers[l] else { return }
        scenes[s].layers[l] = layer
    }
    /// The microphone mode the person chose for AppleCam in Control Center.
    var microphoneModeLabel: String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: return "Voice Isolation"
        case .wideSpectrum: return "Wide Spectrum"
        default: return "Standard"
        }
    }

    /// Pushes the current channels to the running mixer; called after every audio or scene change.
    func audioConfigurationChanged() {
        guard let audioRuntime else { return }
        guard running else { audioRuntime.stop(); return }
        audioRuntime.configure(audio: audio, scenes: scenes, live: activeScene) { [runtime] id in runtime.source(id) }
    }
    /// A channel failed. During a recording this stops the recording (owner decision: no silent fallback).
    func audioChannelFailed(_ id: String, message: String) {
        // Monitoring is local listening only; it never stops a recording.
        if id == "monitor" { audio.monitor = false; status = message; return }
        channelFailures[id] = message
        if recording != nil { stopRecording(reason: CameraError.message(message)) } else { status = message }
    }
}
