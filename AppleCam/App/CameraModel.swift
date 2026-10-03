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
    @Published var cameraReady = false
    private var openEffectsWhenReady = false
    @Published var image: CGImage?
    @Published var captureFPS: Double = 0
    @Published var previewFPS: Double = 0
    private let previewMailbox = LatestFrameMailbox<CGImage>()
    private var previewRate = FrameRateCounter()
    private var rateTimer: Timer?
    @Published var selection = "pattern" { didSet { savePreferences() } }
    @Published var cameras: [AVCaptureDevice] = []
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
        producer.onState = { [weak self] publishing, ready in
            DispatchQueue.main.async {
                guard let self else { return }
                self.publishing = publishing; self.cameraReady = ready
                if ready && self.openEffectsWhenReady {
                    self.openEffectsWhenReady = false
                    self.showAppleEffects()
                }
            }
        }
        producer.onStatus = { [weak self] text, active in
            DispatchQueue.main.async {
                self?.status = text; self?.running = active; self?.busy = false
                if !active {
                    self?.openEffectsWhenReady = false
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
        refresh()
        restorePreferences()
    }
    private func snapshot() -> SavedPreferences {
        var settings = SavedPreferences()
        settings.cameraID = selection
        settings.cameraName = selection == "pattern" ? "Labelled test pattern (no webcam)" :
            (cameras.first { $0.uniqueID == selection }?.localizedName ?? savedCameraName)
        settings.greenScreen = useGreenScreen; settings.preview = previewMode
        settings.key = key; settings.background = savedBackground
        return settings
    }
    private func restorePreferences() {
        defer { restoring = false }
        do {
            guard let settings = try preferencesStore.load() else { return }
            selection = settings.cameraID; savedCameraName = settings.cameraName
            savedBackground = settings.background
            key = settings.key; useGreenScreen = settings.greenScreen; previewMode = settings.preview
            if let savedBackground {
                backgroundName = savedBackground.name
                do { background = try GreenScreenProcessor.loadBackground(preferencesStore.backgroundURL(savedBackground)) }
                catch { status = "Saved background could not be opened. Choose the background again before using Green screen."; return }
            }
            status = "Settings restored. Start a preview or send to AppleCam when ready."
        } catch {
            restorationFailed = true; settingsError = true
            settingsMessage = "Saved settings could not be loaded: \(error.localizedDescription) Review the controls, then choose Save current settings to replace them."
            status = "Saved settings need attention before starting."
        }
    }
    private func savePreferences() {
        guard !restoring, !restorationFailed else { return }
        do {
            try preferencesStore.save(snapshot())
            settingsError = false; settingsMessage = "Settings saved automatically."
        } catch {
            settingsError = true; settingsMessage = "Settings could not be saved: \(error.localizedDescription)"
        }
    }
    func saveCurrentPreferences() {
        // An explicit action is required to replace an unreadable saved configuration.
        do {
            try preferencesStore.save(snapshot())
            restorationFailed = false; settingsError = false
            settingsMessage = "Settings saved automatically."
        } catch { settingsError = true; settingsMessage = "Settings could not be saved: \(error.localizedDescription)" }
    }
    /// Import only the selected background, never camera frames. Committed before changing the live picture.
    func importBackground(_ url: URL) throws {
        guard !restorationFailed else { throw CameraError.message("Save current settings before replacing the background.") }
        let image = try GreenScreenProcessor.loadBackground(url)
        let next = try preferencesStore.importBackground(Data(contentsOf: url), name: url.lastPathComponent, settings: snapshot())
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
    func showAppleEffects() {
        guard selection != "pattern", !busy else { return }
        if !cameraReady {
            openEffectsWhenReady = true
            start(publish: false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }
    func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose an opaque PNG or JPEG. It will fill the camera frame with centred cropping."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try importBackground(url)
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
    func refresh() { cameras = FrameProducer.cameras() }
    func start(publish: Bool) {
        guard !busy else { return }
        guard !restorationFailed else { status = "Review and save your settings before starting."; return }
        if running { busy = true; producer.setPublishing(publish); return }
        guard !useGreenScreen || background != nil else {
            status = "Choose a background image before enabling green-screen processing."; return
        }
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
        if selected == "pattern" { producer.start(mode: .pattern, publish: publish, background: backdrop, settings: settings); return }
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
                self.producer.start(mode: .camera(selected), publish: publish, background: backdrop, settings: settings)
            }
        }
    }
    func stop() { openEffectsWhenReady = false; requestID += 1; busy = true; previewMailbox.invalidate(); producer.stop() }
}
