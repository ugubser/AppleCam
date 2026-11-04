import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Runs a real AppKit event loop: an XCTest host does not reliably paint remote WebKit surfaces.
@MainActor final class BrowserLayerHarness: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if arguments[1] == "--write-session" {
            Task {
                do { try await Self.writeSession(url: arguments[2], token: arguments[3]); NSApp.terminate(nil) }
                catch { print("Browser session setup failed: \(error)"); exit(1) }
            }
            return
        }
        Task {
            do {
                try await Self.verifySessionKept(url: arguments[1], token: arguments[3])
                try await Self.verifyPageSound(url: arguments[2])
                let source = try await BrowserSceneSource(settings: BrowserSettings(url: arguments[1]), name: "Generated video verification", fps: 30)
                do {
                    try await source.activate()
                    // Parked: out of sight, yet the page keeps rendering for the layer.
                    try Self.checkParked(source)
                    let parked = try await Self.colours(source, samples: 60)
                    // Interact with Page: an ordinary titled, closable window at the page's size, also while covered.
                    // A stand-in for AppleCam's main window takes the keyboard back when the page window closes.
                    let main = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
                    main.isReleasedWhenClosed = false; main.makeKeyAndOrderFront(nil)
                    defer { main.orderOut(nil); main.close() }
                    source.show()
                    let window = source.window
                    let content = window.contentRect(forFrameRect: window.frame)
                    print("Interactive window: \(window.frame), key: \(window.isKeyWindow), app active: \(NSApp.isActive)")
                    guard !source.isParked, window.styleMask.contains(.titled), window.styleMask.contains(.closable), !window.styleMask.contains(.miniaturizable),
                          window.isVisible, window.alphaValue == 1, !window.ignoresMouseEvents, window.canBecomeKey,
                          window.collectionBehavior.contains(.fullScreenNone), window.collectionBehavior.contains(.participatesInCycle), content.size == CGSize(width: 1280, height: 720), source.webView.bounds.size == CGSize(width: 1280, height: 720),
                          NSScreen.screens.contains(where: { $0.visibleFrame.contains(CGPoint(x: window.frame.midX, y: window.frame.maxY - 10)) }) else {
                        throw CameraError.message("Interact with Page did not show the page in an ordinary window on screen.")
                    }
                    let cover = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    cover.backgroundColor = .green; cover.isReleasedWhenClosed = false
                    defer { cover.orderOut(nil); cover.close() }
                    let interactive = try await Self.colours(source, samples: 30)
                    cover.orderFront(nil)
                    let covered = try await Self.colours(source, samples: 60)
                    cover.orderOut(nil)
                    // Closing the window parks it again; the layer keeps its page.
                    window.performClose(nil)
                    try Self.checkParked(source)
                    print("After closing: page window key: \(window.isKeyWindow), stand-in main window key: \(main.isKeyWindow), app active: \(NSApp.isActive)")
                    guard window.firstResponder === window, !window.isKeyWindow else { throw CameraError.message("The closed page window kept the keyboard.") }
                    let closed = try await Self.colours(source, samples: 60)
                    let muted = try await source.webView.evaluateJavaScript("document.querySelector('video').muted && document.querySelector('video').volume === 0") as? Bool
                    print("Video colours (frames) parked: \(parked), interactive: \(interactive), covered: \(covered), after closing: \(closed); muted: \(muted == true)")
                    let both: Set<String> = ["red", "blue"]
                    // WebKit can pause pictures for up to about a second when its window stops being visible; output
                    // stops only after 2 s without pictures. Gaps are bounded at 1 s (25 samples).
                    guard [parked, covered, closed].allSatisfy({ $0.frames > 30 && $0.colours == both }), interactive.frames > 15,
                          [parked, interactive, covered, closed].allSatisfy({ $0.longestGap < 25 }), muted == true else {
                        print("Video state:", try await source.webView.evaluateJavaScript("JSON.stringify({ready:document.querySelector('video').readyState,paused:document.querySelector('video').paused,time:document.querySelector('video').currentTime})") ?? "none")
                        throw CameraError.message("Changing video pixels or silent playback were not verified.")
                    }
                    // Layer → Audio on: the page's media may sound and the page may change its own volume; off: silent again.
                    let state = "JSON.stringify({muted:document.querySelector('video').muted,volume:document.querySelector('video').volume})"
                    let channel = MixChannel(id: "page", name: "Page", mix: ChannelMix(), active: true)
                    source.setAudioChannel(channel) { _ in }; try await Task.sleep(nanoseconds: 200_000_000)
                    let audible = try await source.webView.evaluateJavaScript(state) as? String
                    _ = try await source.webView.evaluateJavaScript("document.querySelector('video').volume = 0.5")
                    let pageVolume = try await source.webView.evaluateJavaScript("document.querySelector('video').volume") as? Double
                    source.setAudioChannel(nil) { _ in }; try await Task.sleep(nanoseconds: 200_000_000)
                    let silentAgain = try await source.webView.evaluateJavaScript(state) as? String
                    print("Sound on: \(audible ?? "?"), page volume \(pageVolume ?? -1); sound off: \(silentAgain ?? "?")")
                    guard audible == #"{"muted":false,"volume":1}"#, pageVolume == 0.5, silentAgain == #"{"muted":true,"volume":0}"# else {
                        throw CameraError.message("Switching the page's sound on and off was not verified.")
                    }
                    await source.deactivate()
                    let paused = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let later = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    guard abs(later - paused) < 0.1 else { throw CameraError.message("Inactive browser playback did not pause.") }
                    try await source.activate(); try await Task.sleep(nanoseconds: 300_000_000)
                    guard try source.image(at: CMClockGetTime(CMClockGetHostTimeClock())) != nil else { throw CameraError.message("Browser capture did not resume.") }
                    // While the rendering window is covered, WebKit can briefly pause the video before the page script
                    // restarts it, so one fixed-time sample can land in that gap. Require resumed playback within 2 s.
                    var resumed = paused, playing: Bool? = false, waited = 300
                    while waited <= 2_000 {
                        resumed = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                        playing = try await source.webView.evaluateJavaScript("!document.querySelector('video').paused") as? Bool
                        if playing == true && abs(resumed - paused) > 0.05 { break }
                        try await Task.sleep(nanoseconds: 100_000_000); waited += 100
                    }
                    guard playing == true, abs(resumed - paused) > 0.05 else { throw CameraError.message("Browser video playback did not resume.") }
                    print("Playback resumed within \(waited) ms of reactivation.")
                    _ = try await source.webView.evaluateJavaScript("document.querySelector('video').pause()")
                    let userPaused = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    await source.deactivate(); try await source.activate()
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let stillPaused = try await source.webView.evaluateJavaScript("document.querySelector('video').paused") as? Bool
                    let userPosition = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    guard stillPaused == true, abs(userPosition - userPaused) < 0.1 else { throw CameraError.message("An explicit user pause was not preserved.") }
                    await source.deactivate(); source.close()
                    print("Browser video capture (parked, interactive, covered and closed window), silence, sound switching, pause/resume and explicit user-pause preservation passed.")
                    await Self.forgetSession(); exit(0)
                } catch { await source.deactivate(); source.close(); throw error }
            } catch { print("Browser layer integration failed: \(error)"); await Self.forgetSession(); exit(1) }
        }
    }
}

extension BrowserLayerHarness {
    /// Parked: still ordered on a screen at the page's size, but transparent, ignoring the mouse and the keyboard and
    /// left out of window lists and cycling.
    static func checkParked(_ source: BrowserSceneSource) throws {
        let window = source.window, frame = window.frame
        guard source.isParked, window.isVisible, window.alphaValue == 0, window.ignoresMouseEvents, !window.canBecomeKey,
              window.isExcludedFromWindowsMenu, window.collectionBehavior.contains(.ignoresCycle), window.collectionBehavior.contains(.transient),
              window.contentRect(forFrameRect: frame).size == CGSize(width: 1280, height: 720),
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else {
            throw CameraError.message("The page window was not parked out of sight (frame \(frame), alpha \(window.alphaValue)).")
        }
    }
    /// Which test-video colours the layer's pictures show over `samples` × 40 ms, and how many pictures arrived.
    static func colours(_ source: BrowserSceneSource, samples: Int) async throws -> (colours: Set<String>, frames: Int, longestGap: Int) {
        let context = CIContext()
        var colours = Set<String>(), frames = 0, gap = 0, longestGap = 0
        for _ in 0..<samples {
            try await Task.sleep(nanoseconds: 40_000_000)
            guard let picture = try source.image(at: CMClockGetTime(CMClockGetHostTimeClock())) else { gap += 1; longestGap = max(longestGap, gap); continue }
            gap = 0
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(picture, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: picture.extent.midX, y: picture.extent.midY, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            if rgba[0] > 200 && rgba[2] < 50 { colours.insert("red") }
            if rgba[2] > 200 && rgba[0] < 50 { colours.insert("blue") }
            frames += 1
        }
        return (colours, frames, longestGap)
    }
    /// Waits for the page itself: before it commits, the web view shows an empty page that is already "complete".
    static func waitForLoad(_ source: BrowserSceneSource, url: String) async throws {
        for _ in 0..<100 {
            if try await source.webView.evaluateJavaScript("location.href + ' ' + document.readyState") as? String == "\(url) complete" { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CameraError.message("The page did not load.")
    }
    /// First launch: a page stores a cookie that lasts an hour, a cookie for the session only, and local storage.
    /// The harness then quits as the app does.
    static func writeSession(url: String, token: String) async throws {
        await forgetSession()
        let source = try await BrowserSceneSource(settings: BrowserSettings(url: url), name: "Session setup", fps: 30)
        defer { source.close() }
        try await source.activate(); try await waitForLoad(source, url: url)
        _ = try await source.webView.evaluateJavaScript("document.cookie='kept=\(token); max-age=3600; path=/'; document.cookie='session=\(token); path=/'; localStorage.setItem('kept','\(token)'); 0")
        try await Task.sleep(nanoseconds: 500_000_000)
        await source.deactivate()
    }
    /// Second launch: a new browser layer still has the page's logins (cookies) and storage.
    static func verifySessionKept(url: String, token: String) async throws {
        let source = try await BrowserSceneSource(settings: BrowserSettings(url: url), name: "Session check", fps: 30)
        defer { source.close() }
        try await source.activate(); try await waitForLoad(source, url: url)
        let cookie = try await source.webView.evaluateJavaScript("document.cookie") as? String ?? ""
        let stored = try await source.webView.evaluateJavaScript("localStorage.getItem('kept')") as? String
        print("After relaunch: cookies \"\(cookie)\", local storage \(stored ?? "none"); session-only cookie kept: \(cookie.contains("session=\(token)"))")
        guard cookie.contains("kept=\(token)"), stored == token else { throw CameraError.message("The browser session was not kept across launches.") }
        await source.deactivate()
        print("Browser session (cookies and storage) kept across launches passed.")
    }
    /// The harness's own WebKit data (localhost test pages only) is removed when it finishes.
    static func forgetSession() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    /// Layer → Audio on: the page's media is captured into the layer's channel per frame (it never plays through the
    /// speakers), another origin's media is explained, the page's own mute and volume apply, and Audio off stops capture.
    static func verifyPageSound(url: String) async throws {
        let source = try await BrowserSceneSource(settings: BrowserSettings(url: url), name: "Generated sound verification", fps: 30)
        defer { source.close() }
        try await source.activate()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let mixer = AudioMixer(), tap = MixTap()
        let channel = MixChannel(id: "page", name: "Page", mix: ChannelMix(), active: true)
        mixer.onMixBlock = { tap.append($0) }
        mixer.setChannels([channel], master: ChannelMix()); mixer.start()
        defer { mixer.stop() }
        var notes: [String] = []
        source.setAudioChannel(channel) { report in if case .note(let note?) = report { notes.append(note) } }
        // WebKit pauses muted media in a hidden page, so the tones (silent until now) are started again, as a person would.
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await source.webView.evaluateJavaScript("for (const a of [...document.querySelectorAll('audio'), document.querySelector('iframe').contentDocument.getElementById('tone')]) a.play(); 0")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let captured = tap.take(seconds: 1)
        let near = Goertzel.level(captured, 440), frame = Goertzel.level(captured, 660), far = Goertzel.level(captured, 880)
        print(String(format: "Captured page sound: 440 Hz %.1f dB, frame 660 Hz %.1f dB, other origin 880 Hz %.1f dB; late frames %d; notes: %@",
                     near, frame, far, channel.timeline.droppedLate, notes.description))
        guard near > -7, near < -5, frame > -13, frame < -11, far < -60 else { throw CameraError.message("Page sound was not captured per stream at the page's level.") }
        guard notes.contains(where: { $0.contains("localhost") }) else { throw CameraError.message("Sound from another origin was not explained.") }
        // The page's own mute and volume apply to what is captured.
        _ = try await source.webView.evaluateJavaScript("document.getElementById('near').muted = true")
        _ = try await source.webView.evaluateJavaScript("document.querySelector('iframe').contentDocument.getElementById('tone').volume = 0.5")
        try await Task.sleep(nanoseconds: 1_000_000_000); _ = tap.take(seconds: 1)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let changed = tap.take(seconds: 0.8)
        let mutedNear = Goertzel.level(changed, 440), halfFrame = Goertzel.level(changed, 660)
        print(String(format: "After the page muted 440 Hz and halved 660 Hz: %.1f dB and %.1f dB", mutedNear, halfFrame))
        guard mutedNear < -60, abs(halfFrame - (frame - 6)) < 1 else { throw CameraError.message("The page's own mute or volume did not apply to captured sound.") }
        source.setAudioChannel(nil) { _ in }
        try await Task.sleep(nanoseconds: 600_000_000); _ = tap.take(seconds: 1)
        try await Task.sleep(nanoseconds: 800_000_000)
        let afterOff = Goertzel.level(tap.take(seconds: 0.5), 660)
        guard afterOff < -60 else { throw CameraError.message("Page sound was still captured with Audio off.") }
        print("Page sound capture, other-origin note, page mute/volume and Audio off passed.")
        await source.deactivate()
    }
}

/// The newest mix blocks, collected on the mixer queue.
final class MixTap: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ block: UnsafeBufferPointer<Float>) { lock.withLock { samples += block; if samples.count > 480_000 { samples.removeFirst(samples.count - 480_000) } } }
    /// The left channel of the last `seconds`, clearing what was collected.
    func take(seconds: Double) -> [Float] {
        lock.withLock {
            let frames = min(samples.count / 2, Int(seconds * AudioFormat.sampleRate))
            let left = stride(from: samples.count - frames * 2, to: samples.count, by: 2).map { samples[$0] }
            samples = []; return left
        }
    }
}

enum Goertzel {
    /// Amplitude of `frequency` in dBFS (a full-scale sine reads 0 dB).
    static func level(_ samples: [Float], _ frequency: Double) -> Double {
        guard !samples.isEmpty else { return -120 }
        let w = 2 * Double.pi * frequency / AudioFormat.sampleRate, c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples { let s0 = Double(x) + c * s1 - s2; s2 = s1; s1 = s0 }
        let power = s1 * s1 + s2 * s2 - c * s1 * s2
        let amplitude = 2 * sqrt(max(power, 0)) / Double(samples.count)
        return amplitude > 1e-6 ? 20 * log10(amplitude) : -120
    }
}

@main struct BrowserLayerMain {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = BrowserLayerHarness()
        app.setActivationPolicy(.regular); app.delegate = delegate
        app.run(); withExtendedLifetime(delegate) {}
    }
}
