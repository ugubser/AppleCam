#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI
import AVFoundation
import Observation
import UniformTypeIdentifiers
import ScreenCaptureKit

/// Observation tracks each property separately. Preview frames go straight to `previewDisplay` and are not observed.
@MainActor @Observable final class CameraModel {
    var status = "Configure your four scenes, then start a local preview or send to AppleCam."
    var running = false
    var busy = false
    var publishing = false
    /// True while preview frames are being shown; changes only on start and stop, never per frame.
    var showingPreview = false
    @ObservationIgnored let previewDisplay = PreviewDisplay()
    var captureFPS: Double = 0
    var previewFPS: Double = 0
    var selection = "pattern" { didSet { switchProfile(from: oldValue) } }
    var cameras: [AVCaptureDevice] = []
    var captureConfiguration = CaptureConfiguration() { didSet { savePreferences() } }
    var outputConfiguration = CaptureConfiguration() { didSet { savePreferences() } }
    var availableConfigurations: [CaptureConfiguration] = []
    var capabilities: [CameraCapability] = []
    var scenes = CameraScene.defaults() { didSet { savePreferences(); requestLiveUpdate() } }
    private(set) var selectedScene = 0
    var selectedLayerID: UUID?
    var sceneThumbnails: [UUID: CGImage] = [:]
    var useGreenScreen = false {
        didSet {
            if !useGreenScreen && !useBackgroundMask { previewMode = .composite }
            sampling = false; savePreferences(); requestLiveUpdate()
        }
    }
    /// Separates webcam layers from a picture of the empty background. Exclusive with `useGreenScreen`.
    var useBackgroundMask = false {
        didSet {
            if !useGreenScreen && !useBackgroundMask { previewMode = .composite }
            savePreferences(); requestLiveUpdate()
        }
    }
    var difference = DifferenceKeySettings() { didSet { savePreferences(); requestLiveUpdate() } }
    /// The accepted background picture of the selected camera.
    private(set) var backgroundPlate: BackgroundPlate?
    /// A decoded copy of `backgroundPlate` for the inspector; loaded on demand.
    private(set) var backgroundPlateImage: CGImage?
    /// Seconds left before the background picture is taken; nil when no countdown runs.
    private(set) var plateCountdown: Int?
    private(set) var capturingPlate = false
    /// A new picture waiting for review. The review sheet completes it with `acceptBackgroundPicture` or `discardBackgroundPicture`.
    var pendingPlate: PendingPlate?
    static let plateCountdownSeconds = 2
    var previewMode = KeyPreview.composite { didSet { savePreferences(); requestLiveUpdate() } }
    var key = KeySettings() { didSet { savePreferences(); requestLiveUpdate() } }
    var sampling = false
    var samplePending = false
    var settingsMessage = "Settings save automatically."
    var settingsError = false
    var scenePreparing = false
    /// Changes when clip or browser runtime state changes; read by views that show that state.
    private(set) var sourceRevision = 0
    private(set) var restorationFailed = false
    let extensionManager = ExtensionManager()
    @ObservationIgnored private let preferencesStore: PreferencesStore
    @ObservationIgnored private var preferences = SavedPreferences()
    @ObservationIgnored private let runtime: SceneRuntime
    /// An open in-app window/screen chooser. The sheet completes it with `finishCaptureChoice`.
    var captureRequest: CaptureRequest?
    @ObservationIgnored private var captureContinuation: CheckedContinuation<CaptureOption?, Never>?
    @ObservationIgnored private var restoring = true
    @ObservationIgnored private var savedCameraName = "Saved camera"
    @ObservationIgnored private var appendSample = false
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var sceneTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var requestedPublish = false
    @ObservationIgnored private var plateTask: Task<Void, Never>?
    private struct PreviewFrame {
        let buffer: CVPixelBuffer
        let thumbnail: CGImage?
        let scene: UUID
        let event: UUID
    }
    @ObservationIgnored private let previewMailbox = LatestFrameMailbox<PreviewFrame>()
    @ObservationIgnored private var previewRate = FrameRateCounter()
    @ObservationIgnored private var rateTimer: Timer?
    /// Continuous edits (dragging, sliders, typing) are coalesced into one write after this pause.
    static let saveDelay: UInt64 = 400_000_000
    var activeScene: CameraScene { scenes[selectedScene] }
    var selectedLayer: SceneLayer? { activeScene.layers.first { $0.id == selectedLayerID } }
    var isMaskPreview: Bool { previewMode == .mask && (useGreenScreen || useBackgroundMask) && activeScene.needsCamera }
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
    /// Start/stop controls are locked while a start or stop is in progress.
    var canStartPreview: Bool { !busy && !(scenePreparing && !running) && !(running && !publishing) }
    var canSend: Bool { !busy && !(scenePreparing && !running) && !(running && publishing) }
    var canStop: Bool { running || busy }
    init(preferencesStore: PreferencesStore = PreferencesStore()) {
        self.preferencesStore = preferencesStore; runtime = SceneRuntime(store: preferencesStore)
        runtime.onSourceStateChange = { [weak self] in self?.sourceRevision += 1 }
        runtime.output.onPublishing = { [weak self] enabled, event in
            Task { @MainActor in guard let self, event == self.runtime.eventID else { return }; self.publishing = enabled }
        }
        runtime.output.onStatus = { [weak self] text, active, event in
            Task { @MainActor in
                guard let self, event == self.runtime.eventID else { return }
                self.status = text; self.running = active; self.busy = false
                if !active {
                    self.clearPreview(); self.sampling = false; self.samplePending = false
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
        runtime.output.onPreview = { [weak self] buffer, thumbnail, sceneID, event in
            // The mailbox keeps only the newest frame; a skipped frame's thumbnail is simply refreshed next interval.
            guard let ticket = mailbox.offer(PreviewFrame(buffer: buffer, thumbnail: thumbnail, scene: sceneID, event: event)) else { return }
            Task { @MainActor in
                guard let self, let newest = mailbox.take(ticket: ticket), newest.event == self.runtime.eventID, self.running || self.busy else { return }
                if let thumbnail = newest.thumbnail { self.sceneThumbnails[newest.scene] = thumbnail }
                guard newest.scene == self.activeScene.id else { return }
                do { try self.previewDisplay.show(newest.buffer) } catch { self.status = error.localizedDescription; return }
                if !self.showingPreview { self.showingPreview = true }
                self.previewRate.record()
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
    private func clearPreview() { showingPreview = false; previewDisplay.clear() }
    private func currentProfile(cameraID: String) -> CameraProfile {
        var profile = CameraProfile()
        profile.cameraName = cameraID == "pattern" ? "Labelled test pattern (no webcam)" :
            (cameras.first { $0.uniqueID == cameraID }?.localizedName ?? savedCameraName)
        profile.greenScreen = useGreenScreen; profile.preview = previewMode; profile.key = key
        var mask = BackgroundMaskProfile(); mask.enabled = useBackgroundMask; mask.plate = backgroundPlate; mask.settings = difference
        profile.backgroundMask = mask
        profile.capture = captureConfiguration
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
        useBackgroundMask = profile.mask.enabled; difference = profile.mask.settings; setPlate(profile.mask.plate)
        previewMode = profile.preview
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
    /// Schedules one coalesced write. `flushPreferences()` writes immediately (quit, stop, tests).
    private func savePreferences() {
        guard !restoring, !restorationFailed else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.writePreferences()
        }
    }
    @objc func flushPreferences() {
        guard saveTask != nil else { return }
        writePreferences()
    }
    private func writePreferences() {
        saveTask?.cancel(); saveTask = nil
        guard !restoring, !restorationFailed else { return }
        do { let next = snapshot(); try preferencesStore.save(next, deferCleanup: running || busy); preferences = next; settingsError = false; settingsMessage = "Settings saved automatically." }
        catch { settingsError = true; settingsMessage = "Settings could not be saved: \(error.localizedDescription)" }
    }
    func saveCurrentPreferences() {
        saveTask?.cancel(); saveTask = nil
        do {
            let next = snapshot(); try preferencesStore.save(next); preferences = next
            restorationFailed = false; settingsError = false; settingsMessage = "Settings saved automatically."
        } catch { settingsError = true; settingsMessage = "Settings could not be saved: \(error.localizedDescription)" }
    }
    func selectResolution(_ resolution: String) {
        guard !running, !busy, let option = availableConfigurations.first(where: { $0.resolution == resolution && $0.fps == captureConfiguration.fps }) ?? availableConfigurations.first(where: { $0.resolution == resolution }) else { return }
        captureConfiguration = option
    }
    /// Applies a typed capture frame rate. Returns false (leaving the format unchanged) for an invalid value.
    @discardableResult func setCaptureFPS(_ fps: Double) -> Bool {
        var next = captureConfiguration; next.fps = fps
        guard !running, !busy, next.isValid else { return false }
        captureConfiguration = next; return true
    }
    /// Applies a typed canvas size or rate. Returns false (leaving the format unchanged) for an invalid value.
    @discardableResult func setOutput(width: Int? = nil, height: Int? = nil, fps: Double? = nil) -> Bool {
        var next = outputConfiguration
        if let width { next.width = width }; if let height { next.height = height }; if let fps { next.fps = fps }
        guard !running, !busy, next.isValid else { return false }
        outputConfiguration = next; return true
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
        guard scenes.indices.contains(index), !busy, index != selectedScene else { return }
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
    /// Returns false for a blank name; the scene keeps its previous name.
    @discardableResult func renameScene(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if scenes[selectedScene].name != trimmed { scenes[selectedScene].name = trimmed }
        return true
    }
    /// Applies a change to one layer of the active scene. Invalid results and placement changes to a locked layer
    /// are rejected as a whole, leaving the layer unchanged; the return value tells the editor which happened.
    @discardableResult func updateLayer(_ id: UUID, _ change: (inout SceneLayer) -> Void) -> Bool {
        guard let index = activeScene.layers.firstIndex(where: { $0.id == id }) else { return false }
        let current = activeScene.layers[index]
        var layer = current; change(&layer)
        guard !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, layer.source.isValid, layer.placement.isValid,
              !current.locked || layer.placement == current.placement else { return false }
        if layer != current { scenes[selectedScene].layers[index] = layer }
        return true
    }
    func setCanvasColor(red: Double, green: Double, blue: Double) {
        guard [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        var scene = activeScene; scene.canvasRed = red; scene.canvasGreen = green; scene.canvasBlue = blue
        if scene != activeScene { scenes[selectedScene] = scene }
    }
    func moveLayer(_ id: UUID, to index: Int) { var next = activeScene; if next.move(id, to: index) { scenes[selectedScene] = next } }
    func deleteLayer(_ id: UUID) {
        guard let layer = activeScene.layers.first(where: { $0.id == id }), !layer.locked else { return }
        scenes[selectedScene].layers.removeAll { $0.id == id }; selectedLayerID = activeScene.layers.first?.id
        if !running && !busy { Task { await runtime.prune(scenes: scenes); preferencesStore.cleanupUnusedMedia(); sourceRevision += 1 } }
    }
    func addCameraLayer() { insertLayer(SceneLayer(name: "Webcam", source: .camera)) }
    func addBrowserLayer() { insertLayer(SceneLayer(name: "Browser", source: .browser(BrowserSettings()))) }
    private func insertLayer(_ layer: SceneLayer) {
        scenes[selectedScene].layers.insert(layer, at: 0); selectedLayerID = layer.id
    }
    func addCaptureLayer(display: Bool) {
        let sceneID = activeScene.id
        Task {
            do {
                guard let choice = try await chooseCaptureSource(display: display) else { return }
                let layer = SceneLayer(name: choice.title, source: choice.source)
                guard let scene = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
                runtime.pickedFilters[layer.id] = choice.filter
                scenes[scene].layers.insert(layer, at: 0); if scene == selectedScene { selectedLayerID = layer.id }
            } catch { status = error.localizedDescription }
        }
    }
    func replaceCapture(_ id: UUID) {
        guard let layer = activeScene.layers.first(where: { $0.id == id }) else { return }
        let display: Bool; if case .display = layer.source { display = true } else { display = false }
        Task {
            do {
                guard let choice = try await chooseCaptureSource(display: display) else { return }
                setCaptureSource(id, source: choice.source, filter: choice.filter)
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
        saveTask?.cancel(); saveTask = nil
        preferences = next; restoring = true; scenes = next.scenes; restoring = false
        if scene == selectedScene { selectedLayerID = layerID }; settingsError = false; settingsMessage = "Media imported and settings saved."
        requestLiveUpdate()
    }
    func setGreenScreen(_ enabled: Bool) {
        if enabled { useBackgroundMask = false }
        useGreenScreen = enabled
    }
    /// Turning the background mask on needs an accepted background picture and turns the green screen off.
    func setBackgroundMask(_ enabled: Bool) {
        guard !enabled || backgroundPlate != nil else { status = "Take a background picture first."; return }
        if enabled { useGreenScreen = false }
        useBackgroundMask = enabled
    }
    var canTakeBackgroundPicture: Bool {
        running && !busy && plateCountdown == nil && !capturingPlate && pendingPlate == nil &&
            activeScene.layers.contains { $0.visible && $0.source == .camera }
    }
    /// Counts down, then averages a few raw webcam frames and offers the picture for review.
    func takeBackgroundPicture() {
        guard canTakeBackgroundPicture else { return }
        let event = runtime.eventID
        plateTask = Task {
            defer { plateCountdown = nil; capturingPlate = false; plateTask = nil }
            for remaining in stride(from: Self.plateCountdownSeconds, through: 1, by: -1) {
                plateCountdown = remaining
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            guard event == runtime.eventID, running else { return }
            plateCountdown = nil; capturingPlate = true
            do {
                let capture = try await runtime.output.capturePlate()
                guard !Task.isCancelled, event == runtime.eventID else { return }
                pendingPlate = PendingPlate(capture: capture)
                status = "Check the background picture, then use it or take it again."
            } catch { status = error.localizedDescription }
        }
    }
    func cancelBackgroundPicture() { plateTask?.cancel() }
    func discardBackgroundPicture() { pendingPlate = nil }
    /// Stores the reviewed picture for the selected camera and switches its webcam layers to the background mask.
    func acceptBackgroundPicture() {
        guard let pending = pendingPlate else { return }
        pendingPlate = nil
        guard !restorationFailed else { status = "Save current settings before taking a background picture."; return }
        let plate = BackgroundPlate(width: pending.capture.width, height: pending.capture.height)
        var next = snapshot()
        var mask = next.profile.mask; mask.plate = plate; mask.enabled = true; next.profile.backgroundMask = mask
        next.profile.greenScreen = false
        do {
            try preferencesStore.importPlate(pending.capture.png, plate: plate, settings: next, deferCleanup: running || busy)
        } catch { status = "The background picture could not be saved: \(error.localizedDescription)"; return }
        saveTask?.cancel(); saveTask = nil; preferences = next
        restoring = true
        setPlate(plate, image: pending.capture.image); useGreenScreen = false; useBackgroundMask = true
        restoring = false
        settingsError = false; settingsMessage = "Background picture saved."
        status = "Background mask on. Step back into view to check the result."
        requestLiveUpdate()
    }
    private func setPlate(_ plate: BackgroundPlate?, image: CGImage? = nil) {
        guard plate != backgroundPlate || image != nil else { return }
        backgroundPlate = plate
        backgroundPlateImage = image ?? plate.flatMap { try? runtime.loadPlate($0).image }
    }
    /// The keying sent to the scene. A background mask without a matching picture stops the scene with an explanation.
    func cameraKeying(for scene: CameraScene) throws -> CameraKeying {
        if useGreenScreen { return .greenScreen(key) }
        guard useBackgroundMask else { return .off }
        guard let plate = backgroundPlate else { throw CameraError.message("Take a background picture before using the background mask.") }
        if scene.needsCamera, let mismatch = plate.mismatch(width: captureConfiguration.width, height: captureConfiguration.height) {
            throw CameraError.message(mismatch)
        }
        return .backgroundMask(difference, try runtime.loadPlate(plate))
    }
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
    func browserAvailable(_ id: UUID) -> Bool { _ = sourceRevision; return runtime.browser(id) != nil }
    func browserCanGoBack(_ id: UUID) -> Bool { _ = sourceRevision; return runtime.browser(id)?.webView.canGoBack ?? false }
    func browserCanGoForward(_ id: UUID) -> Bool { _ = sourceRevision; return runtime.browser(id)?.webView.canGoForward ?? false }
    func navigateBrowser(_ id: UUID, forward: Bool) {
        guard let browser = runtime.browser(id) else { return }
        if forward { browser.webView.goForward() } else { browser.webView.goBack() }
    }
    func toggleClip(_ id: UUID) { runtime.clip(id)?.togglePause(); sourceRevision += 1 }
    func restartClip(_ id: UUID) { runtime.clip(id)?.restart() }
    func clipPaused(_ id: UUID) -> Bool { _ = sourceRevision; return runtime.clip(id)?.isPaused ?? false }
    private func requestLiveUpdate() {
        guard !restoring, running || busy || scenePreparing else { return }; revision += 1
        launchSceneWorker()
    }
    private func launchSceneWorker() {
        guard sceneTask == nil else { return }
        let request = requestID
        sceneTask = Task {
            guard requestID == request, !Task.isCancelled else { return }
            defer { if requestID == request { sceneTask = nil; scenePreparing = false } }
            var applied = -1
            while applied != revision && !Task.isCancelled {
                applied = revision
                do {
                    let target = activeScene
                    // Placement, order and calibration edits swap the render plan between frames; only new or
                    // changed sources need the slower identity checks and the visible "Preparing…" state.
                    let inPlace = runtime.canUpdateInPlace(target, fps: outputConfiguration.fps)
                    if !inPlace { scenePreparing = true }
                    let missing = inPlace ? nil : try await runtime.missingSource(in: target)
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
                    try await runtime.apply(scene: scene, keying: try cameraKeying(for: scene), mask: previewMode == .mask,
                        output: outputConfiguration, cameraMode: selection == "pattern" ? .pattern : .camera(selection), capture: captureConfiguration, publish: requestedPublish, mayCommit: { self.requestID == request && applied == self.revision && !Task.isCancelled })
                    try Task.checkCancellation()
                    guard requestID == request else { return }
                    running = true; busy = false
                    if !inPlace { await runtime.prune(scenes: scenes); preferencesStore.cleanupUnusedMedia(); sourceRevision += 1 }
                } catch is CancellationError { return }
                catch is ScenePreparationSuperseded { continue }
                catch {
                    if applied != revision { continue }
                    await runtime.stop(); preferencesStore.cleanupUnusedMedia(); running = false; busy = false; clearPreview(); stopRateTimer()
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
            guard let choice = try await chooseCaptureSource(display: display) else { return false }
            setCaptureSource(layer.id, source: choice.source, filter: choice.filter); return true
        } catch { status = error.localizedDescription; return false }
    }
    /// Asks for Screen Recording permission when needed, then opens the in-app chooser and waits for its result.
    /// Returns nil when the person cancels or permission is not granted yet.
    func chooseCaptureSource(display: Bool) async throws -> CaptureOption? {
        guard captureContinuation == nil else { throw CameraError.message("Finish the open source chooser first.") }
        guard CaptureSelection.hasAccess || CaptureSelection.requestAccess() else {
            status = CaptureSelection.permissionMessage
            let alert = NSAlert(); alert.messageText = "Allow Screen Recording for AppleCam"
            alert.informativeText = "Window and screen layers need Screen Recording permission. Turn on AppleCam in Screen & System Audio Recording, then quit and reopen AppleCam. AppleCam only captures the windows and screens you add as layers."
            alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(CaptureSelection.settingsURL) }
            return nil
        }
        return await withCheckedContinuation { continuation in
            captureContinuation = continuation; captureRequest = CaptureRequest(display: display)
        }
    }
    /// Completes the open chooser. Safe to call more than once (selection, then sheet dismissal).
    func finishCaptureChoice(_ choice: CaptureOption?) {
        captureRequest = nil
        let continuation = captureContinuation; captureContinuation = nil
        continuation?.resume(returning: choice)
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
        flushPreferences(); plateTask?.cancel(); requestID += 1; runtime.invalidateEvents(); let previous = sceneTask; previous?.cancel(); sceneTask = nil
        running = false; busy = true; scenePreparing = false; previewMailbox.invalidate(); clearPreview(); stopRateTimer()
        let request = requestID
        Task {
            await stopRuntime(after: previous)
            guard requestID == request else { return }
            busy = false; publishing = false; status = "Stopped — no new frames sent."
        }
    }
}

/// A background picture waiting for review.
struct PendingPlate: Identifiable {
    let id = UUID()
    let capture: PlateCapture
}
