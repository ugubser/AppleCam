#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import CoreImage
import CoreMedia
import WebKit

/// One public WebKit snapshot at a time. The native integration harness verifies accelerated video,
/// occlusion, silence and pause/resume; there is no alternative browser capture path.
@MainActor final class BrowserSceneSource: NSObject, SceneMediaSource, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    let window: NSWindow
    private nonisolated let pixels = BrowserFrameStore()
    private var snapshotTask: Task<Void, Never>?
    private var generation = UUID()
    private let fps: Double
    private let settingsWidth: Int
    private nonisolated let errors = BrowserFailure()
    private var active = false
    private var mediaSuspended = false
    private var historyObservations: [NSKeyValueObservation] = []
    /// Called on the main actor when back/forward availability changes.
    var onStateChange: (() -> Void)?
    static let silenceScript = """
    (() => {
      const proto = HTMLMediaElement.prototype;
      const muted = Object.getOwnPropertyDescriptor(proto, 'muted');
      const volume = Object.getOwnPropertyDescriptor(proto, 'volume');
      Object.defineProperty(proto, 'muted', {get(){return true}, set(){muted.set.call(this,true)}});
      Object.defineProperty(proto, 'volume', {get(){return 0}, set(){volume.set.call(this,0)}});
      const silence = e => {muted.set.call(e,true); volume.set.call(e,0); e.defaultMuted=true};
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
      document.addEventListener('volumechange',e=>{if(e.target instanceof HTMLMediaElement && (!muted.get.call(e.target)||volume.get.call(e.target)!==0))silence(e.target)},true);
      // Web Audio is intentionally unavailable in silent browser layers.
      for (const key of ['AudioContext','webkitAudioContext']) {
        if (window[key]) Object.defineProperty(window,key,{value:class {constructor(){throw new DOMException('Audio is disabled in AppleCam browser layers','NotSupportedError')}},writable:false,configurable:false});
      }
      apply();
    })();
    """
    init(settings: BrowserSettings, name: String, fps: Double) async throws {
        guard settings.isValid, let url = URL(string: settings.url) else { throw CameraError.message("Enter a valid HTTP or HTTPS browser address.") }
        self.fps = fps; settingsWidth = settings.width
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.inactiveSchedulingPolicy = .none
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: Self.silenceScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: settings.width, height: settings.height), configuration: config)
        window = BrowserRenderingWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "AppleCam Browser — \(name)"; window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true; window.contentView = webView
        window.setFrameOrigin(CGPoint(x: 40, y: 60)); window.orderBack(nil)
        super.init()
        window.delegate = self; webView.navigationDelegate = self; webView.uiDelegate = self
        historyObservations = [\WKWebView.canGoBack, \WKWebView.canGoForward].map { path in
            webView.observe(path) { [weak self] _, _ in Task { @MainActor in self?.onStateChange?() } }
        }
        webView.load(URLRequest(url: url))
    }
    func activate() async throws {
        guard !active else { return }
        active = true; webView.configuration.preferences.inactiveSchedulingPolicy = .none; window.orderBack(nil)
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
        window.orderOut(nil)
    }
    func show() { if active { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } }
    func reload() { errors.set(nil); webView.reload() }
    func close() {
        historyObservations.removeAll(); onStateChange = nil
        webView.stopLoading(); window.delegate = nil; window.orderOut(nil); window.close()
    }
    nonisolated func image(at hostTime: CMTime) throws -> CIImage? { try errors.check(); return pixels.image(at: hostTime.seconds) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderBack(nil); return false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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

private final class BrowserRenderingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The snapshot's request time is preserved; a slow WebKit response cannot make old pixels fresh.
final class BrowserFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CGImage?
    private var timestamp: Double = 0
    private var enabled = false
    func begin() { lock.withLock { enabled = true; frame = nil } }
    func end() { lock.withLock { enabled = false; frame = nil } }
    func set(_ image: CGImage, at time: Double) { lock.withLock { if enabled { frame = image; timestamp = time } } }
    func image(at now: Double) -> CIImage? {
        lock.withLock {
            guard enabled, let frame, now >= timestamp, now - timestamp <= CameraContract.maximumFrameAge else { return nil }
            return CIImage(cgImage: frame)
        }
    }
}
