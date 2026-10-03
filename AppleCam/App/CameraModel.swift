#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class CameraModel: ObservableObject {
    @Published var status = "Choose your camera and a background image to set up the green screen."
    @Published var running = false
    @Published var busy = false
    @Published var publishing = false
    @Published var image: CGImage?
    @Published var captureFPS: Double = 0
    @Published var previewFPS: Double = 0
    private let previewMailbox = LatestFrameMailbox<CGImage>()
    private var previewRate = FrameRateCounter()
    private var rateTimer: Timer?
    @Published var selection = "pattern" { didSet { switchProfile(from: oldValue) } }
    @Published var cameras: [AVCaptureDevice] = []
    @Published var captureConfiguration = CaptureConfiguration() { didSet { savePreferences() } }
    @Published var availableConfigurations: [CaptureConfiguration] = []
    @Published var capabilities: [CameraCapability] = []
    @Published var controlsExpanded = true { didSet { savePreferences() } }
    @Published var backgroundSlots: [SavedBackground?] = Array(repeating: nil, count: 4)
    @Published var backgroundThumbnails: [CGImage?] = Array(repeating: nil, count: 4)
    var previewAspect: Double { Double(captureConfiguration.width) / Double(captureConfiguration.height) }
    var formatAvailable: Bool {
        selection == "pattern" ? captureConfiguration.isValid : capabilities.contains { $0.supports(captureConfiguration) }
    }
    var resolutions: [CaptureConfiguration] {
        var seen = Set<String>()
        return availableConfigurations.filter { seen.insert($0.resolution).inserted }
    }
    var ratesForResolution: [CaptureConfiguration] {
        availableConfigurations.filter { $0.width == captureConfiguration.width && $0.height == captureConfiguration.height }
    }
    func selectResolution(_ resolution: String) {
        guard !running, !busy, let option = availableConfigurations.first(where: { $0.resolution == resolution && $0.fps == captureConfiguration.fps }) ?? availableConfigurations.first(where: { $0.resolution == resolution }) else { return }
        captureConfiguration = option
    }
    @Published var useGreenScreen = false {
        didSet {
            if !useGreenScreen { previewMode = .composite }
            sampling = false
            if running { producer.setGreenScreen(background: useGreenScreen ? background : nil, settings: key) }
            savePreferences()
        }
    }
    @Published var previewMode = KeyPreview.composite { didSet { producer.setPreviewMode(previewMode); savePreferences() } }
    @Published var key = KeySettings() { didSet { producer.updateKey(key); savePreferences() } }
    @Published var sampling = false
    @Published var samplePending = false
    private var appendSample = false
    @Published var backgroundName = "No background selected"
    private var background: CGImage?
    let extensionManager = ExtensionManager()
    private let producer = FrameProducer()
    private var requestID = 0
    private let preferencesStore: PreferencesStore
    private var preferences = SavedPreferences()
    private var restoring = true
    private var savedBackground: SavedBackground?
    private var savedCameraName = "Saved camera"
    @Published var settingsMessage = "Settings save automatically."
    @Published var settingsError = false
    private(set) var restorationFailed = false
    var selectedCameraUnavailable: Bool { selection != "pattern" && !cameras.contains { $0.uniqueID == selection } }
    var unavailableCameraName: String { "\(savedCameraName) (disconnected)" }
    init(preferencesStore: PreferencesStore = PreferencesStore()) {
        self.preferencesStore = preferencesStore
        producer.onState = { [weak self] publishing, _ in
            DispatchQueue.main.async { self?.publishing = publishing }
        }
        producer.onStatus = { [weak self] text, active in
            DispatchQueue.main.async {
                self?.status = text; self?.running = active; self?.busy = false
                if !active {
                    self?.sampling = false; self?.samplePending = false
                    self?.image = nil
                    self?.previewMailbox.invalidate()
                    self?.rateTimer?.invalidate(); self?.rateTimer = nil
                    self?.captureFPS = 0; self?.previewFPS = 0
                }
            }
        }
        producer.onPreview = { [weak self] image in
            guard let self, let ticket = self.previewMailbox.offer(image) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let newest = self.previewMailbox.take(ticket: ticket),
                      self.running, !self.busy else { return }
                self.image = newest
                self.previewRate.record()
            }
        }
        producer.onCaptureRate = { [weak self] rate, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, !self.busy else { return }
                self.captureFPS = rate
            }
        }
        producer.onSample = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false; self.samplePending = false
                guard self.running else { return }
                switch result {
                case .success(let color):
                    do {
                        var updated = self.key
                        try updated.sample(color, append: self.appendSample)
                        self.key = updated
                        self.status = "Screen sample updated. Use Mask view to check hair and chair detail; the meeting still receives Picture."
                    } catch { self.status = error.localizedDescription }
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(flushPreferences), name: NSApplication.willTerminateNotification, object: nil)
        refresh()
        restorePreferences()
    }
    @objc func flushPreferences() { savePreferences() }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func currentProfile(cameraID: String) -> CameraProfile {
        var profile = CameraProfile()
        profile.cameraName = cameraID == "pattern" ? "Labelled test pattern (no webcam)" :
            (cameras.first { $0.uniqueID == cameraID }?.localizedName ?? savedCameraName)
        profile.greenScreen = useGreenScreen; profile.preview = previewMode
        profile.key = key; profile.background = savedBackground; profile.backgrounds = backgroundSlots
        profile.controlsExpanded = controlsExpanded; profile.capture = captureConfiguration
        return profile
    }
    private func snapshot() -> SavedPreferences {
        var settings = preferences
        settings.cameraID = selection; settings.profile = currentProfile(cameraID: selection)
        return settings
    }
    private func updateCapabilities() {
        if selection == "pattern" {
            capabilities = []
            availableConfigurations = [CaptureConfiguration(), CaptureConfiguration(width: 1280, height: 720, fps: 24), CaptureConfiguration(width: 3840, height: 2160, fps: 30)]
        } else if let device = cameras.first(where: { $0.uniqueID == selection }) {
            capabilities = CameraCapabilities.ranges(for: device)
            availableConfigurations = CameraCapabilities.configurations(for: device)
        } else { capabilities = []; availableConfigurations = [] }
    }
    private func applyProfile(_ profile: CameraProfile) {
        savedCameraName = profile.cameraName
        key = profile.key; useGreenScreen = profile.greenScreen; previewMode = profile.preview
        controlsExpanded = profile.controlsExpanded
        updateCapabilities()
        // Defaults apply only to a new camera profile. Never replace an unavailable saved choice.
        captureConfiguration = profile.capture ?? (availableConfigurations.first(where: { $0 == CaptureConfiguration() }) ?? availableConfigurations.first ?? CaptureConfiguration())
        savedBackground = profile.background; backgroundSlots = profile.backgrounds
        background = nil; backgroundName = profile.background?.name ?? "No background selected"
        backgroundThumbnails = backgroundSlots.map { reference in
            guard let reference else { return nil }
            return try? GreenScreenProcessor.loadBackground(preferencesStore.backgroundURL(reference), maximumDimension: 256)
        }
        if let reference = profile.background {
            do { background = try GreenScreenProcessor.loadBackground(preferencesStore.backgroundURL(reference)) }
            catch { status = "Saved background could not be opened. Choose the background again before using Green screen."; return }
        }
        status = "Settings restored for this camera. Start a preview or send when ready."
    }
    private func switchProfile(from oldID: String) {
        guard !restoring, oldID != selection else { return }
        // The camera picker is disabled during capture, so a profile switch cannot change a live source.
        preferences.profiles[oldID] = currentProfile(cameraID: oldID)
        preferences.cameraID = selection
        restoring = true
        applyProfile(preferences.profile)
        restoring = false
        savePreferences()
    }
    private func restorePreferences() {
        defer { restoring = false }
        do {
            if let settings = try preferencesStore.load() {
                preferences = settings; selection = settings.cameraID
                applyProfile(settings.profile)
                // Persist a successfully decoded v1 migration in the v2 schema.
                try preferencesStore.save(snapshot())
            } else { updateCapabilities() }
        } catch {
            restorationFailed = true; settingsError = true
            settingsMessage = "Saved settings could not be loaded: \(error.localizedDescription) Review the controls, then choose Save current settings to replace them."
            status = "Saved settings need attention before starting."
        }
    }
    private func savePreferences() {
        guard !restoring, !restorationFailed else { return }
        do {
            let next = snapshot(); try preferencesStore.save(next); preferences = next
            settingsError = false; settingsMessage = "Settings saved automatically."
        } catch {
            settingsError = true; settingsMessage = "Settings could not be saved: \(error.localizedDescription)"
        }
    }
    func saveCurrentPreferences() {
        // An explicit action is required to replace an unreadable saved configuration.
        do {
            let next = snapshot(); try preferencesStore.save(next); preferences = next
            restorationFailed = false; settingsError = false
            settingsMessage = "Settings saved automatically."
        } catch { settingsError = true; settingsMessage = "Settings could not be saved: \(error.localizedDescription)" }
    }
    /// Import only the selected background, never camera frames. Committed before changing the live picture.
    func importBackground(_ url: URL, slot: Int? = nil) throws {
        guard !restorationFailed else { throw CameraError.message("Save current settings before replacing the background.") }
        let image = try GreenScreenProcessor.loadBackground(url)
        let thumbnail = try slot.map { _ in try GreenScreenProcessor.loadBackground(url, maximumDimension: 256) }
        let next = try preferencesStore.importBackground(Data(contentsOf: url), name: url.lastPathComponent, settings: snapshot(), slot: slot)
        preferences = next; backgroundSlots = next.profile.backgrounds
        if let slot { backgroundThumbnails[slot] = thumbnail }
        savedBackground = next.background; background = image; backgroundName = url.lastPathComponent
        settingsError = false; settingsMessage = "Settings saved automatically."
        if running && useGreenScreen { producer.setGreenScreen(background: image, settings: key) }
        else { status = "Background saved. Switch Green screen on whenever you want to use it." }
    }
    func setGreenScreen(_ enabled: Bool) {
        if enabled && background == nil { chooseBackground() }
        guard !enabled || background != nil else { return }
        useGreenScreen = enabled
    }
    func selectBackgroundSlot(_ slot: Int) {
        guard (0..<4).contains(slot), !busy else { return }
        guard let reference = backgroundSlots[slot] else { chooseBackground(slot: slot); return }
        do {
            let image = try GreenScreenProcessor.loadBackground(preferencesStore.backgroundURL(reference))
            savedBackground = reference; background = image; backgroundName = reference.name
            savePreferences()
            if running && useGreenScreen { producer.setGreenScreen(background: image, settings: key) }
            else { status = "Background selected: \(reference.name)." }
        } catch { status = "This saved background cannot be opened. Use Replace image on its button to select it again." }
    }
    func clearBackgroundSlot(_ slot: Int) {
        guard (0..<4).contains(slot) else { return }
        backgroundSlots[slot] = nil; backgroundThumbnails[slot] = nil
        savePreferences()
    }
    func isActiveBackgroundSlot(_ slot: Int) -> Bool { backgroundSlots[slot]?.id == savedBackground?.id && savedBackground != nil }
    func chooseBackground(slot: Int? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose an opaque PNG or JPEG. It will fill the camera frame with centred cropping."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try importBackground(url, slot: slot)
        } catch { status = error.localizedDescription }
    }
    func beginSample(append: Bool) {
        guard !samplePending else { return }
        if sampling { sampling = false; return }
        appendSample = append; sampling = true
    }
    func removeSample(_ index: Int) {
        guard !samplePending else { return }
        var updated = key
        if index == 0 {
            guard !updated.additionalColors.isEmpty else { return }
            updated.color = updated.additionalColors.removeFirst()
        } else { updated.additionalColors.remove(at: index - 1) }
        key = updated
    }
    func sample(x: Double, y: Double) {
        guard sampling, !samplePending else { return }
        samplePending = true
        producer.sample(x: x, y: y)
    }
    func refresh() { cameras = FrameProducer.cameras(); updateCapabilities() }
    func start(publish: Bool) {
        guard !busy else { return }
        guard !restorationFailed else { status = "Review and save your settings before starting."; return }
        if running { busy = true; producer.setPublishing(publish); return }
        guard !useGreenScreen || background != nil else {
            status = "Choose a background image before enabling green-screen processing."; return
        }
        guard formatAvailable else { status = "This camera does not offer the saved format. Choose an available resolution and frame rate."; return }
        busy = true; requestID += 1
        previewMailbox.invalidate()
        previewRate.reset(at: ProcessInfo.processInfo.systemUptime)
        captureFPS = 0; previewFPS = 0
        rateTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.previewFPS = self.previewRate.sample(at: ProcessInfo.processInfo.systemUptime)
        }
        rateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        let request = requestID
        let selected = selection
        let backdrop = useGreenScreen ? background : nil
        let settings = key
        let configuration = captureConfiguration
        if selected == "pattern" { producer.start(mode: .pattern, publish: publish, background: backdrop, settings: settings, configuration: configuration); return }
        status = "Opening camera. If macOS asks for camera access, allow AppleCam to continue."
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.requestID == request else { return }
                guard granted else {
                    self.busy = false
                    self.rateTimer?.invalidate(); self.rateTimer = nil
                    self.status = "Camera access was denied. Enable AppleCam in System Settings → Privacy & Security → Camera."
                    return
                }
                self.producer.start(mode: .camera(selected), publish: publish, background: backdrop, settings: settings, configuration: configuration)
            }
        }
    }
    func stop() { savePreferences(); requestID += 1; busy = true; previewMailbox.invalidate(); producer.stop() }
}
