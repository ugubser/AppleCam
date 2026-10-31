#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import ScreenCaptureKit

struct ScenePreparationSuperseded: Error {}

struct MissingSceneSource: Error {
    let layer: SceneLayer
}

@MainActor final class SceneRuntime {
    let output: SceneOutput
    private(set) var eventID = UUID()
    func invalidateEvents() { eventID = UUID() }
    private let store: PreferencesStore
    private struct Cached {
        let descriptor: LayerSource
        let fps: Double
        let source: SceneMediaSource
    }
    private var cache: [UUID: Cached] = [:]
    private var active: [UUID: SceneMediaSource] = [:]
    private var activeScene: CameraScene?
    private var monitor: Task<Void, Never>?
    private(set) var running = false
    var pickedFilters: [UUID: SCContentFilter] = [:]
    init(store: PreferencesStore, output: SceneOutput = SceneOutput()) { self.store = store; self.output = output }
    func missingSource(in scene: CameraScene) async throws -> SceneLayer? {
        let captures = scene.layers.filter { layer in
            guard layer.visible else { return false }
            switch layer.source { case .window, .display: return true; default: return false }
        }
        guard !captures.isEmpty else { return nil }
        if let unconfigured = captures.first(where: { $0.source == .window(nil) || $0.source == .display(nil) }) { return unconfigured }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return captures.first { layer in
            switch layer.source {
            case .window(let ref):
                guard let ref else { return true }
                return !content.windows.contains { CaptureSelection.matches($0, ref) }
            case .display(let ref):
                guard let ref else { return true }
                return !content.displays.contains { CaptureSelection.displayUUID($0.displayID) == ref.uuid }
            default: return false
            }
        }
    }
    private func filter(for layer: SceneLayer) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        switch layer.source {
        case .window(let reference):
            guard let reference, let window = content.windows.first(where: { CaptureSelection.matches($0, reference) }) else { throw MissingSceneSource(layer: layer) }
            return pickedFilters[layer.id] ?? SCContentFilter(desktopIndependentWindow: window)
        case .display(let reference):
            guard let reference, let display = content.displays.first(where: { CaptureSelection.displayUUID($0.displayID) == reference.uuid }) else { throw MissingSceneSource(layer: layer) }
            // Exclude the controls and browser source windows from whole-screen capture to avoid recursive previews.
            let ours = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            return SCContentFilter(display: display, excludingWindows: ours)
        default: throw CameraError.message("This layer is not a capture source.")
        }
    }
    private func source(for layer: SceneLayer, fps: Double) async throws -> SceneMediaSource {
        if let existing = cache[layer.id], existing.descriptor == layer.source, existing.fps == fps {
            // Window identity must still be checked on every return to the scene.
            switch layer.source { case .window, .display: _ = try await filter(for: layer); default: break }
            return existing.source
        }
        let source: SceneMediaSource
        switch layer.source {
        case .image(let asset): source = try StillSceneSource(url: store.mediaURL(asset))
        case .clip(let asset): source = try await ClipSceneSource(url: store.mediaURL(asset))
        case .browser(let settings): source = try await BrowserSceneSource(settings: settings, name: layer.name, fps: fps)
        case .window, .display: source = CaptureSceneSource(filter: try await filter(for: layer), fps: fps)
        case .camera: throw CameraError.message("Webcam frames belong to the shared camera session.")
        }
        if let old = cache[layer.id]?.source, active[layer.id] !== old {
            await old.deactivate(); (old as? BrowserSceneSource)?.close()
        }
        cache[layer.id] = Cached(descriptor: layer.source, fps: fps, source: source)
        return source
    }
    func apply(scene: CameraScene, key: KeySettings, greenScreen: Bool, mask: Bool,
               output configuration: CaptureConfiguration, cameraMode: FrameProducer.Mode, capture: CaptureConfiguration,
               publish: Bool, mayCommit: () -> Bool = { true }) async throws {
        guard scene.isValid, key.isValid, configuration.isValid, !scene.needsCamera || capture.isValid else {
            throw CameraError.message("The scene, calibration or output format is invalid. Review its settings before starting.")
        }
        var next: [UUID: SceneMediaSource] = [:]
        do {
            for layer in scene.layers where layer.visible && layer.source != .camera {
                try Task.checkCancellation()
                let source = try await source(for: layer, fps: configuration.fps)
                next[layer.id] = source
                if active[layer.id] !== source { try await source.activate() }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while true {
                try Task.checkCancellation()
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                var waiting = false
                for source in next.values { if try source.image(at: now) == nil { waiting = true } }
                if !waiting { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CameraError.message("A scene source did not produce its first frame. Output stopped; check the layer or hide it.") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard mayCommit() else { throw ScenePreparationSuperseded() }
            let plan = SceneRenderPlan(scene: scene, sources: next, key: key, greenScreen: greenScreen, maskPreview: mask)
            if running { await output.update(plan) }
            else { try await output.start(plan: plan, output: configuration, cameraMode: cameraMode, capture: capture, publish: publish, eventID: eventID); running = true }
            let previous = active; active = next; activeScene = scene
            for (id, source) in previous where next[id] !== source {
                await source.deactivate()
                if cache[id]?.source !== source { (source as? BrowserSceneSource)?.close() }
            }
            startMonitor()
        } catch {
            // Failure never enables a substitute scene. Release everything prepared by this attempt.
            for (id, source) in next where active[id] !== source { await source.deactivate() }
            throw error
        }
    }
    func prune(scenes: [CameraScene]) async {
        let kept = Dictionary(uniqueKeysWithValues: scenes.flatMap(\.layers).map { ($0.id, $0.source) })
        for id in Array(cache.keys) where kept[id] != cache[id]?.descriptor {
            if let old = cache.removeValue(forKey: id)?.source {
                await old.deactivate(); (old as? BrowserSceneSource)?.close()
            }
            pickedFilters.removeValue(forKey: id)
        }
    }
    func stop() async {
        monitor?.cancel(); monitor = nil
        await output.stop(); running = false
        let previous = active; active = [:]; activeScene = nil
        for (id, source) in previous {
            await source.deactivate(); if cache[id]?.source !== source { (source as? BrowserSceneSource)?.close() }
        }
    }
    func clip(_ id: UUID) -> ClipSceneSource? { cache[id]?.source as? ClipSceneSource }
    func browser(_ id: UUID) -> BrowserSceneSource? { cache[id]?.source as? BrowserSceneSource }
    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, let scene = self.activeScene else { return }
                    if let missing = try await self.missingSource(in: scene) {
                        self.output.sourceFailed(CameraError.message("\(missing.name) is no longer available. Choose it again or hide its layer.")); return
                    }
                } catch is CancellationError { return }
                catch { self?.output.sourceFailed(error); return }
            }
        }
    }
}
