#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import CoreImage
import AVFoundation
import CoreMedia
import WebKit

/// One public WebKit snapshot at a time. The native integration harness verifies accelerated video, the parked and
/// interactive window, silence, pause/resume and the kept session; there is no alternative browser capture path.
///
/// The page renders in its own titled window. While the layer is active that window is parked: fully transparent,
/// ignoring the mouse, unable to take the keyboard, left out of window lists and behind other windows, but still
/// ordered on a screen so WebKit keeps rendering at full rate (a window outside every screen delivered pictures
/// irregularly, and switching between borderless and titled briefly stalled them). Interact with Page shows it as an
/// ordinary window; closing it parks it again where it is. All browser layers share WebKit's persistent website store, so cookies and
/// logins are kept across layers and launches (separately from Safari).
@MainActor final class BrowserSceneSource: NSObject, SceneMediaSource, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    let window: BrowserRenderingWindow
    private nonisolated let pixels = BrowserFrameStore()
    private var snapshotTask: Task<Void, Never>?
    private var generation = UUID()
    private let fps: Double
    private let settingsWidth: Int
    private let pageSize: CGSize
    /// Whether Interact with Page has shown the window yet: the first time it is centred on AppleCam's screen, later it
    /// reopens where the person left it.
    private var shownBefore = false
    private nonisolated let errors = BrowserFailure()
    private var active = false
    private var mediaSuspended = false
    /// Whether this page may make sound (Layer → Audio). Every page load starts silent and is switched on again.
    private var soundEnabled = false
    private var historyObservations: [NSKeyValueObservation] = []
    /// Called on the main actor when back/forward availability changes.
    var onStateChange: (() -> Void)?
    /// Runs in every frame before the page's own scripts. While Layer → Audio is off, the page's media is forced silent.
    /// While it is on, the page plays normally; `BrowserAudioCapture` then takes AppleCam's WebKit sound off the
    /// speakers and into the mix.
    static let silenceScript = """
    (() => {
      const proto = HTMLMediaElement.prototype;
      const muted = Object.getOwnPropertyDescriptor(proto, 'muted');
      const volume = Object.getOwnPropertyDescriptor(proto, 'volume');
      // Silent unless AppleCam turns this layer's sound on (Layer → Audio). Web Audio stays unavailable either way.
      let sound = false;
      Object.defineProperty(proto, 'muted', {get(){return sound ? muted.get.call(this) : true}, set(v){muted.set.call(this, sound ? !!v : true)}});
      Object.defineProperty(proto, 'volume', {get(){return sound ? volume.get.call(this) : 0}, set(v){volume.set.call(this, sound ? v : 0)}});
      const silence = e => {if (!sound) {muted.set.call(e,true); volume.set.call(e,0); e.defaultMuted=true}};
      const soundMessage = 'com.vanguardsignals.AppleCam.layer-sound-v1';
      const tellFrame = target => target?.postMessage({type:soundMessage,sound},'*');
      window.__appleCamSetSound = value => {
        sound = !!value;
        for (const frame of document.querySelectorAll('iframe')) tellFrame(frame.contentWindow);
        document.querySelectorAll('video,audio').forEach(e => {
          if (sound) {muted.set.call(e,false); volume.set.call(e,1); e.defaultMuted=false} else silence(e);
        });
      };
      window.addEventListener('message', event => {
        if (event.data?.type === soundMessage && event.source === window.parent && window.parent !== window) window.__appleCamSetSound(!!event.data.sound);
        if (event.data?.type === soundMessage + '-request') tellFrame(event.source);
      });
      // A frame loaded later asks its parent for the current state.
      if (window.parent !== window) window.parent.postMessage({type:soundMessage + '-request'},'*');
      let layerActive = true;
      const intendedPlayback = new Set();
      const nativePause = proto.pause;
      Object.defineProperty(proto, 'pause', {configurable:true,writable:true,value:function(){
        intendedPlayback.delete(this); return nativePause.call(this);
      }});
      window.__appleCamSetLayerActive = value => {
        const resume = value && !layerActive;
        layerActive = value;
        for (const frame of document.querySelectorAll('iframe')) {
          frame.contentWindow?.postMessage({type:'com.vanguardsignals.AppleCam.layer-activity-v1',active:value},'*');
        }
        if (resume) for (const media of intendedPlayback) {
          if (media.isConnected && media.paused && !media.ended) media.play().catch(() => {});
        }
      };
      window.addEventListener('message', event => {
        if (event.source === window.parent && event.data?.type === 'com.vanguardsignals.AppleCam.layer-activity-v1') {
          window.__appleCamSetLayerActive(!!event.data.active);
        }
      });
      let occlusionResumeAttempted = new WeakSet();
      document.addEventListener('playing', e => {
        if (e.target instanceof HTMLMediaElement) intendedPlayback.add(e.target);
      }, true);
      document.addEventListener('pause', e => {
        const media = e.target;
        if (!(media instanceof HTMLMediaElement) || !layerActive) return;
        if (document.hidden && !media.ended && intendedPlayback.has(media) && !occlusionResumeAttempted.has(media)) {
          occlusionResumeAttempted.add(media);
          // Re-check intent: an explicit pause() during this delay must win over the occlusion restart.
          setTimeout(() => { if (layerActive && intendedPlayback.has(media)) media.play().catch(() => {}) }, 50);
        } else intendedPlayback.delete(media);
      }, true);
      document.addEventListener('visibilitychange', () => {
        if (!document.hidden) occlusionResumeAttempted = new WeakSet();
      });
      const autoplayRequested = new WeakSet();
      const prepare = e => {
        silence(e);
        if (e.autoplay && !autoplayRequested.has(e)) {
          autoplayRequested.add(e);
          // Programmatic playback preserves the page's autoplay intent when the rendering window is obscured.
          // Do this once; subsequent user pauses remain under the page's control.
          e.autoplay = false;
          e.play().catch(() => {});
        }
      };
      const apply = () => {
        for (const media of intendedPlayback) if (!media.isConnected) intendedPlayback.delete(media);
        document.querySelectorAll('video,audio').forEach(prepare);
      };
      new MutationObserver(apply).observe(document,{childList:true,subtree:true});
      document.addEventListener('play',e=>{if(e.target instanceof HTMLMediaElement)silence(e.target)},true);
      document.addEventListener('volumechange',e=>{if(!sound && e.target instanceof HTMLMediaElement && (!muted.get.call(e.target)||volume.get.call(e.target)!==0))silence(e.target)},true);
      // Web Audio is unavailable in browser layers: a layer with Audio off could not keep it silent.
      for (const key of ['AudioContext','webkitAudioContext']) {
        if (window[key]) Object.defineProperty(window,key,{value:class {constructor(){throw new DOMException('Audio is disabled in AppleCam browser layers','NotSupportedError')}},writable:false,configurable:false});
      }
      apply();
    })();
    """
    init(settings: BrowserSettings, name: String, fps: Double) async throws {
        guard settings.isValid, let url = URL(string: settings.url) else { throw CameraError.message("Enter a valid HTTP or HTTPS browser address.") }
        self.fps = fps; settingsWidth = settings.width
        pageSize = CGSize(width: settings.width, height: settings.height)
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.inactiveSchedulingPolicy = .none
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(WKUserScript(source: Self.silenceScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: settings.width, height: settings.height), configuration: config)
        window = BrowserRenderingWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AppleCam Browser — \(name)"; window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        park()
        window.delegate = self; webView.navigationDelegate = self; webView.uiDelegate = self
        historyObservations = [\WKWebView.canGoBack, \WKWebView.canGoForward].map { path in
            webView.observe(path) { [weak self] _, _ in Task { @MainActor in self?.onStateChange?() } }
        }
        webView.load(URLRequest(url: url))
    }
    func activate() async throws {
        guard !active else { return }
        active = true; webView.configuration.preferences.inactiveSchedulingPolicy = .none; park()
        if mediaSuspended { await webView.setAllMediaPlaybackSuspended(false); mediaSuspended = false }
        _ = try await webView.evaluateJavaScript("if(window.__appleCamSetLayerActive)window.__appleCamSetLayerActive(true)")
        pixels.begin(); generation = UUID()
        let ticket = generation
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            var failures = SnapshotFailureWindow()
            while self.active && self.generation == ticket && !Task.isCancelled {
                let began = CMClockGetTime(CMClockGetHostTimeClock())
                do {
                    let configuration = WKSnapshotConfiguration()
                    configuration.rect = self.webView.bounds
                    configuration.snapshotWidth = NSNumber(value: self.settingsWidth)
                    let result = try await self.webView.takeSnapshot(configuration: configuration)
                    guard self.active, self.generation == ticket, !Task.isCancelled else { return }
                    guard let image = result.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CameraError.message("WebKit supplied no page image.") }
                    self.pixels.set(image, at: began.seconds); failures.succeeded()
                    let remaining = max(0, 1 / self.fps - (CMClockGetTime(CMClockGetHostTimeClock()).seconds - began.seconds))
                    if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                } catch is CancellationError { return }
                catch {
                    guard self.active, self.generation == ticket else { return }
                    // Individual snapshots can fail transiently (WKError.unknown, seen at 60 fps) while the page keeps
                    // rendering. Retry after one frame; only persistent failure stops the layer with a visible error.
                    if failures.failed(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds) { self.errors.set(error); return }
                    do { try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / self.fps)) } catch { return }
                }
            }
        }
    }
    func deactivate() async {
        guard active else { return }
        active = false; generation = UUID(); pixels.end(); snapshotTask?.cancel(); snapshotTask = nil
        _ = try? await webView.evaluateJavaScript("if(window.__appleCamSetLayerActive)window.__appleCamSetLayerActive(false)")
        await webView.pauseAllMediaPlayback()
        await webView.setAllMediaPlaybackSuspended(true); mediaSuspended = true
        webView.configuration.preferences.inactiveSchedulingPolicy = .suspend
        park(); window.orderOut(nil)
    }
    /// Interact with Page: the page in an ordinary window the person can move and close. The page keeps its size.
    func show() {
        guard active else { return }
        if isParked {
            let reference = NSApp.orderedWindows.first { !($0 is BrowserRenderingWindow) && $0.isVisible }?.screen ?? NSScreen.main
            let frame = BrowserWindowPlacement.interactiveFrame(size: window.frame.size, remembered: shownBefore ? window.frame.origin : nil,
                screens: NSScreen.screens.map(\.visibleFrame), preferred: reference?.visibleFrame)
            if frame != window.frame { window.setFrame(frame, display: false) }
            shownBefore = true
        }
        window.parked = false; window.alphaValue = 1; window.ignoresMouseEvents = false; window.isExcludedFromWindowsMenu = false
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(webView); NSApp.activate(ignoringOtherApps: true)
    }
    /// Whether the window is parked (not shown for interaction).
    var isParked: Bool { window.parked }
    /// Parks the window where it is: transparent, ignoring the mouse and behind other windows, so it keeps rendering
    /// unseen. The page loses keyboard focus and the next AppleCam window gets the keyboard, so typing never goes to a
    /// page nobody sees.
    private func park() {
        let hadKey = window.isKeyWindow
        window.makeFirstResponder(nil)
        window.parked = true; window.alphaValue = 0; window.ignoresMouseEvents = true; window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        window.orderBack(nil)
        if hadKey { NSApp.orderedWindows.first { !($0 is BrowserRenderingWindow) && $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil) }
    }
    func reload() { errors.set(nil); webView.reload() }
    func close() {
        historyObservations.removeAll(); onStateChange = nil
        webView.stopLoading(); window.delegate = nil; window.orderOut(nil); window.close()
    }
    nonisolated func image(at hostTime: CMTime) throws -> CIImage? { try errors.check(); return pixels.image(at: hostTime.seconds) }
    /// How old the page picture is when it is composed (see `BrowserFrameStore.pictureAge`).
    nonisolated var pictureAge: Double { pixels.pictureAge }
    /// Closing the interactive window parks it: the layer still needs the page.
    func windowShouldClose(_ sender: NSWindow) -> Bool { park(); return false }
    /// Turns the page's sound on or off (Layer → Audio).
    func setSound(_ enabled: Bool) {
        guard enabled != soundEnabled else { return }
        soundEnabled = enabled; applySound()
    }
    private func applySound() {
        webView.evaluateJavaScript("if(window.__appleCamSetSound)window.__appleCamSetSound(\(soundEnabled))", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if soundEnabled { applySound() } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if soundEnabled { applySound() }
        let value = active ? "true" : "false"
        webView.evaluateJavaScript("if(window.__appleCamSetLayerActive)window.__appleCamSetLayerActive(\(value))", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { record(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { record(error) }
    private func record(_ error: Error) { if (error as NSError).code != NSURLErrorCancelled { errors.set(error) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { errors.set(CameraError.message("The browser process stopped. Reload the page before restarting output.")) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { webView.load(URLRequest(url: url)) }
        return nil
    }
}

/// WebKit can fail a single snapshot while the page keeps rendering. A failure becomes fatal only when snapshots
/// keep failing for `limit` seconds without a success, matching the other sources' two-second persistence rule.
struct SnapshotFailureWindow {
    static let limit: Double = 2
    private var failingSince: Double?
    mutating func succeeded() { failingSince = nil }
    /// Returns true when the failure should stop the layer.
    mutating func failed(at now: Double) -> Bool {
        guard let start = failingSince else { failingSince = now; return false }
        return now - start >= Self.limit
    }
}

private final class BrowserFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ error: Error?) { lock.lock(); defer { lock.unlock() }; self.error = error }
    func check() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
}

/// A browser layer's own window, told apart from AppleCam's other windows. Parked, it cannot take the keyboard.
final class BrowserRenderingWindow: NSWindow {
    var parked = true
    override var canBecomeKey: Bool { !parked }
    override var canBecomeMain: Bool { !parked }
}

/// Frame rules for a browser layer's window, kept free of AppKit state so they can be unit tested.
enum BrowserWindowPlacement {
    /// The interactive window's frame: where the person left it while that spot is still on a screen, otherwise centred
    /// on `preferred` (the screen AppleCam is on). A window taller than the screen keeps its title bar visible.
    static func interactiveFrame(size: CGSize, remembered: CGPoint?, screens: [CGRect], preferred: CGRect?) -> CGRect {
        if let remembered {
            let frame = CGRect(origin: remembered, size: size)
            let titleBar = CGRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
            if screens.contains(where: { $0.intersection(titleBar).width >= 80 && $0.intersection(titleBar).height >= 20 }) { return frame }
        }
        guard let area = preferred ?? screens.first else { return CGRect(origin: .zero, size: size) }
        let x = area.midX - size.width / 2
        let y = size.height > area.height ? area.maxY - size.height : area.midY - size.height / 2
        return CGRect(x: max(area.minX, x), y: y, width: size.width, height: size.height)
    }
}

/// The snapshot's request time is preserved; a slow WebKit response cannot make old pixels fresh.
final class BrowserFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CGImage?
    private var timestamp: Double = 0
    private var enabled = false
    private var age: Double = 0
    func begin() { lock.withLock { enabled = true; frame = nil; age = 0 } }
    func end() { lock.withLock { enabled = false; frame = nil } }
    func set(_ image: CGImage, at time: Double) { lock.withLock { if enabled { frame = image; timestamp = time } } }
    func image(at now: Double) -> CIImage? {
        lock.withLock {
            guard enabled, let frame, now >= timestamp, now - timestamp <= CameraContract.maximumFrameAge else { return nil }
            age = age == 0 ? now - timestamp : age * 0.95 + (now - timestamp) * 0.05
            return CIImage(cgImage: frame)
        }
    }
    /// Smoothed age of the page picture when it is composed: snapshots take time and the newest one is shown until the
    /// next arrives. The page's sound is delayed by this so it lines up with the picture.
    var pictureAge: Double { lock.withLock { age } }
}
