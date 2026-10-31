#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ScreenCaptureKit

@MainActor final class CameraModel: ObservableObject {
    @Published var status = "Configure your four scenes, then start a local preview or send to AppleCam."
    @Published var running = false
    @Published var busy = false
    @Published var publishing = false
    @Published var image: CGImage?
    @Published var captureFPS: Double = 0
    @Published var previewFPS: Double = 0
    @Published var selection = "pattern" { didSet { switchProfile(from: oldValue) } }
    @Published var cameras: [AVCaptureDevice] = []
    @Published var captureConfiguration = CaptureConfiguration() { didSet { savePreferences() } }
    @Published var outputConfiguration = CaptureConfiguration() { didSet { savePreferences() } }
    @Published var availableConfigurations: [CaptureConfiguration] = []
    @Published var capabilities: [CameraCapability] = []
    @Published var controlsExpanded = true { didSet { savePreferences() } }
    @Published var scenes = CameraScene.defaults() { didSet { savePreferences(); requestLiveUpdate() } }
    @Published private(set) var selectedScene = 0
    @Published var selectedLayerID: UUID?
    @Published var sceneThumbnails: [UUID: CGImage] = [:]
    @Published var useGreenScreen = false {
        didSet {
            if !useGreenScreen { previewMode = .composite }
            sampling = false; savePreferences(); requestLiveUpdate()
        }
    }
    @Published var previewMode = KeyPreview.composite { didSet { savePreferences(); requestLiveUpdate() } }
    @Published var key = KeySettings() { didSet { savePreferences(); requestLiveUpdate() } }
    @Published var sampling = false
    @Published var samplePending = false
    @Published var settingsMessage = "Settings save automatically."
    @Published var settingsError = false
    @Published var scenePreparing = false
    private(set) var restorationFailed = false
    let extensionManager = ExtensionManager()
    private let preferencesStore: PreferencesStore
    private var preferences = SavedPreferences()
    private let runtime: SceneRuntime
    private let picker = CaptureSelection()
    private var restoring = true
    private var savedCameraName = "Saved camera"
    private var appendSample = false
    private var requestID = 0
    private var revision = 0
    private var sceneTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var requestedPublish = false
    private struct PreviewFrame {
        let image: CGImage
        let picture: CGImage
        let scene: UUID
        let event: UUID
    }
    private let previewMailbox = LatestFrameMailbox<PreviewFrame>()
    private var previewRate = FrameRateCounter()
    private var rateTimer: Timer?
    var activeScene: CameraScene { scenes[selectedScene] }
    var selectedLayer: SceneLayer? { activeScene.layers.first { $0.id == selectedLayerID } }
    var isMaskPreview: Bool { previewMode == .mask && useGreenScreen && activeScene.needsCamera }
    var previewAspect: Double {
        let c = isMaskPreview ? captureConfiguration : outputConfiguration
        return Double(c.width) / Double(c.height)
    }
    var selectedCameraUnavailable: Bool { selection != "pattern" && !cameras.contains { $0.uniqueID == selection } }
    var unavailableCameraName: String { "\(savedCameraName) (disconnected)" }
    var formatAvailable: Bool { selection == "pattern" ? captureConfiguration.isValid : capabilities.contains { $0.supports(captureConfiguration) } }
    var resolutions: [CaptureConfiguration] {
        var seen = Set<String>(); return availableConfigurations.filter { seen.insert($0.resolution).inserted }
    }
    var ratesForResolution: [CaptureConfiguration] {
        availableConfigurations.filter { $0.width == captureConfiguration.width && $0.height == captureConfiguration.height }
    }
    init(preferencesStore: PreferencesStore = PreferencesStore()) {
        self.preferencesStore = preferencesStore; runtime = SceneRuntime(store: preferencesStore)
        runtime.output.onPublishing = { [weak self] enabled, event in
            Task { @MainActor in guard let self, event == self.runtime.eventID else { return }; self.publishing = enabled }
        }
        runtime.output.onStatus = { [weak self] text, active, event in
            Task { @MainActor in
                guard let self, event == self.runtime.eventID else { return }
                self.status = text; self.running = active; self.busy = false
                if !active {
                    self.image = nil; self.sampling = false; self.samplePending = false
                    self.previewMailbox.invalidate(); self.stopRateTimer()
                    self.requestID += 1; self.runtime.invalidateEvents()
                    let request = self.requestID, previous = self.sceneTask
                    previous?.cancel(); self.sceneTask = nil; self.scenePreparing = false; self.busy = true
                    await self.stopRuntime(after: previous)
                    guard request == self.requestID else { return }; self.busy = false
                    if let missing = try? await self.runtime.missingSource(in: self.activeScene), request == self.requestID {
                        if await self.resolveMissing(missing), request == self.requestID { self.start(publish: self.requestedPublish) }
                    }
                }
            }
        }
        let mailbox = previewMailbox
        runtime.output.onPreview = { [weak self] image, picture, sceneID, event in
            guard let ticket = mailbox.offer(PreviewFrame(image: image, picture: picture, scene: sceneID, event: event)) else { return }
            Task { @MainActor in
                guard let self, let newest = mailbox.take(ticket: ticket), newest.event == self.runtime.eventID, self.running || self.busy else { return }
                self.sceneThumbnails[newest.scene] = newest.picture
                guard newest.scene == self.activeScene.id else { return }
                self.image = newest.image; self.previewRate.record()
            }
        }
        runtime.output.onRate = { [weak self] rate, event in
            Task { @MainActor in guard let self, event == self.runtime.eventID else { return }; self.captureFPS = rate }
        }
        runtime.output.onSample = { [weak self] result, event in
            Task { @MainActor in
                guard let self, event == self.runtime.eventID else { return }; self.sampling = false; self.samplePending = false
                guard self.running else { return }
                do {
                    var updated = self.key; try updated.sample(result.get(), append: self.appendSample); self.key = updated
                    self.status = "Screen sample updated. Mask is local only; meetings receive the complete scene."
                } catch { self.status = error.localizedDescription }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(flushPreferences), name: NSApplication.willTerminateNotification, object: nil)
        refresh(); restorePreferences()
        selectedLayerID = activeScene.layers.first?.id
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc func flushPreferences() { savePreferences() }
    private func currentProfile(cameraID: String) -> CameraProfile {
        var profile = CameraProfile()
        profile.cameraName = cameraID == "pattern" ? "Labelled test pattern (no webcam)" :
            (cameras.first { $0.uniqueID == cameraID }?.localizedName ?? savedCameraName)
        profile.greenScreen = useGreenScreen; profile.preview = previewMode; profile.key = key
        profile.controlsExpanded = controlsExpanded; profile.capture = captureConfiguration
        return profile
    }
    private func snapshot() -> SavedPreferences {
        var settings = preferences
        settings.cameraID = selection; settings.profile = currentProfile(cameraID: selection)
        settings.scenes = scenes; settings.selectedScene = selectedScene; settings.output = outputConfiguration
        return settings
    }
    private func applyProfile(_ profile: CameraProfile) {
        savedCameraName = profile.cameraName; key = profile.key; useGreenScreen = profile.greenScreen
        previewMode = profile.preview; controlsExpanded = profile.controlsExpanded
        updateCapabilities()
        captureConfiguration = profile.capture ?? (availableConfigurations.first(where: { $0 == CaptureConfiguration() }) ?? availableConfigurations.first ?? CaptureConfiguration())
    }
    private func switchProfile(from oldID: String) {
        guard !restoring, oldID != selection else { return }
        preferences.profiles[oldID] = currentProfile(cameraID: oldID); preferences.cameraID = selection
        restoring = true; applyProfile(preferences.profile); restoring = false; savePreferences()
    }
    private func restorePreferences() {
        defer { restoring = false }
        do {
            if let settings = try preferencesStore.load() {
                preferences = settings; selection = settings.cameraID
                scenes = settings.scenes; selectedScene = settings.selectedScene; outputConfiguration = settings.output
                applyProfile(settings.profile); try preferencesStore.save(snapshot())
                status = "Settings restored. Start a scene preview or send when ready."
            } else { updateCapabilities() }
        } catch {
            restorationFailed = true; settingsError = true
            settingsMessage = "Saved settings could not be loaded: \(error.localizedDescription) Review the controls, then choose Save current settings to replace them."
            status = "Saved settings need attention before starting."
        }
    }
    private func savePreferences() {
        guard !restoring, !restorationFailed else { return }
        do { let next = snapshot(); try preferencesStore.save(next, deferCleanup: running || busy); preferences = next; settingsError = false; settingsMessage = "Settings saved automatically." }
        catch { settingsError = true; settingsMessage = "Settings could not be saved: \(error.localizedDescription)" }
    }
    func saveCurrentPreferences() {
        do {
            let next = snapshot(); try preferencesStore.save(next); preferences = next
            restorationFailed = false; settingsError = false; settingsMessage = "Settings saved automatically."
        } catch { settingsError = true; settingsMessage = "Settings could not be saved: \(error.localizedDescription)" }
    }
    func selectResolution(_ resolution: String) {
        guard !running, !busy, let option = availableConfigurations.first(where: { $0.resolution == resolution && $0.fps == captureConfiguration.fps }) ?? availableConfigurations.first(where: { $0.resolution == resolution }) else { return }
        captureConfiguration = option
    }
    private func updateCapabilities() {
        if selection == "pattern" {
            capabilities = []; availableConfigurations = [CaptureConfiguration(), .init(width: 1280, height: 720, fps: 24), .init(width: 3840, height: 2160, fps: 30)]
        } else if let device = cameras.first(where: { $0.uniqueID == selection }) {
            capabilities = CameraCapabilities.ranges(for: device); availableConfigurations = CameraCapabilities.configurations(for: device)
        } else { capabilities = []; availableConfigurations = [] }
    }
    func refresh() { cameras = FrameProducer.cameras(); updateCapabilities() }
    func selectScene(_ index: Int) {
        guard scenes.indices.contains(index), !busy else { return }
        selectedScene = index; selectedLayerID = activeScene.layers.first?.id; sampling = false
        savePreferences()
        if running || scenePreparing { requestLiveUpdate() }
        else {
            let request = requestID, sceneID = activeScene.id
            Task {
                do {
                    if let missing = try await runtime.missingSource(in: activeScene), requestID == request, activeScene.id == sceneID { _ = await resolveMissing(missing) }
                } catch { status = error.localizedDescription }
            }
        }
    }
    func renameScene(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        scenes[selectedScene].name = name
    }
    func updateLayer(_ id: UUID, _ change: (inout SceneLayer) -> Void) {
        guard let index = activeScene.layers.firstIndex(where: { $0.id == id }) else { return }
        var layer = activeScene.layers[index]; change(&layer)
        guard !layer.name.isEmpty, layer.source.isValid, layer.placement.isValid,
              !activeScene.layers[index].locked || layer.placement == activeScene.layers[index].placement else { return }
        scenes[selectedScene].layers[index] = layer
    }
    func moveLayer(_ id: UUID, to index: Int) { var next = activeScene; if next.move(id, to: index) { scenes[selectedScene] = next } }
    func deleteLayer(_ id: UUID) {
        guard let layer = activeScene.layers.first(where: { $0.id == id }), !layer.locked else { return }
        scenes[selectedScene].layers.removeAll { $0.id == id }; selectedLayerID = activeScene.layers.first?.id
        if !running && !busy { Task { await runtime.prune(scenes: scenes); preferencesStore.cleanupUnusedMedia() } }
    }
    func addCameraLayer() {
        let layer = SceneLayer(name: "Webcam", source: .camera)
        scenes[selectedScene].layers.insert(layer, at: 0); selectedLayerID = layer.id
    }
    func addBrowserLayer() {
        let layer = SceneLayer(name: "Browser", source: .browser(BrowserSettings()))
        scenes[selectedScene].layers.insert(layer, at: 0); selectedLayerID = layer.id
    }
    func addCaptureLayer(display: Bool) {
        let sceneID = activeScene.id
        Task {
            do {
                guard let (source, filter) = try await picker.choose(display: display) else { return }
                let layer = SceneLayer(name: source.label, source: source)
                guard let scene = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
                runtime.pickedFilters[layer.id] = filter
                scenes[scene].layers.insert(layer, at: 0); if scene == selectedScene { selectedLayerID = layer.id }
            } catch { status = error.localizedDescription }
        }
    }
    func replaceCapture(_ id: UUID) {
        guard let layer = activeScene.layers.first(where: { $0.id == id }) else { return }
        let display: Bool; if case .display = layer.source { display = true } else { display = false }
        Task {
            do {
                guard let (source, filter) = try await picker.choose(display: display) else { return }
                setCaptureSource(id, source: source, filter: filter)
            } catch { status = error.localizedDescription }
        }
    }
    func chooseMedia(clip: Bool, replacing id: UUID? = nil) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = clip ? [.movie, .video, .data] : [.png, .jpeg]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = clip ? "Choose a video macOS can decode. AppleCam copies it privately, loops it and keeps it silent." : "Choose a PNG or JPEG. Transparent areas reveal lower layers."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sceneID = activeScene.id
        Task {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                if clip {
                    let asset = AVURLAsset(url: url)
                    guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw CameraError.message("macOS cannot decode this video file.") }
                }
                try importMedia(url, clip: clip, replacing: id, sceneID: sceneID)
            } catch { status = error.localizedDescription }
        }
    }
    func importMedia(_ url: URL, clip: Bool = false, replacing id: UUID? = nil, sceneID: UUID? = nil) throws {
        guard !restorationFailed else { throw CameraError.message("Save current settings before importing media.") }
        if !clip { _ = try GreenScreenProcessor.loadBackground(url) }
        guard let scene = scenes.firstIndex(where: { $0.id == (sceneID ?? activeScene.id) }) else { return }
        let asset = MediaAsset(name: url.lastPathComponent, fileExtension: clip ? url.pathExtension.lowercased() : "image")
        var next = snapshot()
        let source: LayerSource = clip ? .clip(asset) : .image(asset)
        let layerID: UUID
        if let id, let i = next.scenes[scene].layers.firstIndex(where: { $0.id == id }) {
            next.scenes[scene].layers[i].source = source; layerID = id
        } else {
            let layer = SceneLayer(name: url.lastPathComponent, source: source); layerID = layer.id
            next.scenes[scene].layers.insert(layer, at: 0)
        }
        try preferencesStore.importMedia(from: url, asset: asset, settings: next, deferCleanup: running || busy)
        preferences = next; restoring = true; scenes = next.scenes; restoring = false
        if scene == selectedScene { selectedLayerID = layerID }; settingsError = false; settingsMessage = "Media imported and settings saved."
        requestLiveUpdate()
    }
    func setGreenScreen(_ enabled: Bool) { useGreenScreen = enabled }
    func beginSample(append: Bool) { guard !samplePending else { return }; if sampling { sampling = false; return }; appendSample = append; sampling = true }
    func removeSample(_ index: Int) {
        guard !samplePending, key.colors.indices.contains(index), key.colors.count > 1 else { return }
        var next = key
        if index == 0 { next.color = next.additionalColors.removeFirst() } else { next.additionalColors.remove(at: index - 1) }
        key = next
    }
    func sample(x: Double, y: Double) {
        guard sampling, !samplePending else { return }; samplePending = true
        let layer = selectedLayer?.source == .camera ? selectedLayer : activeScene.layers.first { $0.visible && $0.source == .camera }
        runtime.output.sample(x: x, y: y, layer: layer, canvas: CGSize(width: outputConfiguration.width, height: outputConfiguration.height), mask: previewMode == .mask)
    }
    func showBrowser(_ id: UUID) { runtime.browser(id)?.show() }
    func reloadBrowser(_ id: UUID) { runtime.browser(id)?.reload() }
    func browserAvailable(_ id: UUID) -> Bool { runtime.browser(id) != nil }
    func browserCanGoBack(_ id: UUID) -> Bool { runtime.browser(id)?.webView.canGoBack ?? false }
    func browserCanGoForward(_ id: UUID) -> Bool { runtime.browser(id)?.webView.canGoForward ?? false }
    func navigateBrowser(_ id: UUID, forward: Bool) {
        guard let browser = runtime.browser(id) else { return }
        if forward { browser.webView.goForward() } else { browser.webView.goBack() }
    }
    func toggleClip(_ id: UUID) { runtime.clip(id)?.togglePause(); objectWillChange.send() }
    func restartClip(_ id: UUID) { runtime.clip(id)?.restart() }
    func clipPaused(_ id: UUID) -> Bool { runtime.clip(id)?.isPaused ?? false }
    private func requestLiveUpdate() {
        guard !restoring, running || busy || scenePreparing else { return }; revision += 1
        launchSceneWorker()
    }
    private func launchSceneWorker() {
        guard sceneTask == nil else { return }
        let request = requestID
        sceneTask = Task {
            guard requestID == request, !Task.isCancelled else { return }
            scenePreparing = true
            defer { if requestID == request { sceneTask = nil; scenePreparing = false } }
            var applied = -1
            while applied != revision && !Task.isCancelled {
                applied = revision
                do {
                    let target = activeScene
                    let missing = try await runtime.missingSource(in: target)
                    guard applied == revision else { continue }
                    if let missing {
                        await runtime.stop(); running = false
                        guard await resolveMissing(missing) else { busy = false; return }
                    }
                    let scene = activeScene
                    guard outputConfiguration.isValid else { throw CameraError.message("Choose a valid canvas resolution and frame rate.") }
                    if scene.needsCamera {
                        guard formatAvailable else { throw CameraError.message("This camera does not offer the saved format. Choose an available camera format.") }
                        if selection != "pattern", AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.message("Camera access was denied. Enable AppleCam in System Settings → Privacy & Security → Camera.") }
                        }
                    }
                    try Task.checkCancellation()
                    try await runtime.apply(scene: scene, key: key, greenScreen: useGreenScreen, mask: previewMode == .mask,
                        output: outputConfiguration, cameraMode: selection == "pattern" ? .pattern : .camera(selection), capture: captureConfiguration, publish: requestedPublish, mayCommit: { self.requestID == request && applied == self.revision && !Task.isCancelled })
                    try Task.checkCancellation()
                    guard requestID == request else { return }
                    running = true; busy = false
                    await runtime.prune(scenes: scenes); preferencesStore.cleanupUnusedMedia()
                } catch is CancellationError { return }
                catch is ScenePreparationSuperseded { continue }
                catch {
                    if applied != revision { continue }
                    await runtime.stop(); preferencesStore.cleanupUnusedMedia(); running = false; busy = false; image = nil; stopRateTimer()
                    if let missing = error as? MissingSceneSource {
                        if await resolveMissing(missing.layer) { revision += 1; continue }
                    }
                    status = error.localizedDescription; return
                }
            }
        }
    }
    private func resolveMissing(_ layer: SceneLayer) async -> Bool {
        guard scenes.contains(where: { $0.layers.contains { $0.id == layer.id } }) else { return false }
        let alert = NSAlert(); alert.messageText = "\(layer.name) is no longer available"
        alert.informativeText = "Choose its source again, or choose Not right now to hide this layer and continue with the scene. Its placement and settings will be kept."
        let display: Bool; if case .display = layer.source { display = true } else { display = false }
        alert.addButton(withTitle: display ? "Choose screen…" : "Choose window…"); alert.addButton(withTitle: "Not right now")
        if alert.runModal() == .alertSecondButtonReturn {
            return hideUnavailableLayer(layer.id)
        }
        do {
            guard let (source, filter) = try await picker.choose(display: display) else { return false }
            setCaptureSource(layer.id, source: source, filter: filter); return true
        } catch { status = error.localizedDescription; return false }
    }
    private func setCaptureSource(_ id: UUID, source: LayerSource, filter: ScreenCaptureKit.SCContentFilter) {
        guard let scene = scenes.firstIndex(where: { $0.layers.contains { $0.id == id } }),
              let index = scenes[scene].layers.firstIndex(where: { $0.id == id }) else { return }
        runtime.pickedFilters[id] = filter
        scenes[scene].layers[index].source = source; scenes[scene].layers[index].visible = true
    }
    @discardableResult func hideUnavailableLayer(_ id: UUID) -> Bool {
        guard let scene = scenes.firstIndex(where: { $0.layers.contains { $0.id == id } }),
              let index = scenes[scene].layers.firstIndex(where: { $0.id == id }) else { return false }
        switch scenes[scene].layers[index].source { case .window, .display: break; default: return false }
        scenes[scene].layers[index].visible = false; return true
    }
    func start(publish: Bool) {
        guard !busy, (!scenePreparing || running), !restorationFailed else { if restorationFailed { status = "Review and save your settings before starting." }; return }
        requestedPublish = publish
        if running { runtime.output.setPublishing(publish); return }
        busy = true; requestID += 1; runtime.invalidateEvents(); revision += 1; previewMailbox.invalidate()
        previewRate.reset(at: ProcessInfo.processInfo.systemUptime); stopRateTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.previewFPS = self.previewRate.sample(at: ProcessInfo.processInfo.systemUptime) }
        }
        rateTimer = timer; RunLoop.main.add(timer, forMode: .common)
        launchSceneWorker()
    }
    private func stopRuntime(after worker: Task<Void, Never>?) async {
        let previousCleanup = cleanupTask
        let next = Task { @MainActor in
            await previousCleanup?.value; await worker?.value
            await runtime.stop(); preferencesStore.cleanupUnusedMedia()
        }
        cleanupTask = next; await next.value
    }
    private func stopRateTimer() { rateTimer?.invalidate(); rateTimer = nil; captureFPS = 0; previewFPS = 0 }
    func stop() {
        savePreferences(); requestID += 1; runtime.invalidateEvents(); let previous = sceneTask; previous?.cancel(); sceneTask = nil
        running = false; busy = true; scenePreparing = false; previewMailbox.invalidate(); image = nil; stopRateTimer()
        let request = requestID
        Task {
            await stopRuntime(after: previous)
            guard requestID == request else { return }
            busy = false; publishing = false; status = "Stopped — no new frames sent."
        }
    }
}
