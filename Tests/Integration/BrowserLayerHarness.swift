import AppKit
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// Runs a real AppKit event loop: an XCTest host does not reliably paint remote WebKit surfaces.
@MainActor final class BrowserLayerHarness: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let source = try await BrowserSceneSource(settings: BrowserSettings(url: CommandLine.arguments[1]), name: "Generated video verification", fps: 30)
                do {
                    try await source.activate()
                    let context = CIContext()
                    var colours = Set<String>(), occludedColours = Set<String>(), frames = 0
                    let cover = NSWindow(contentRect: source.window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    cover.backgroundColor = .green; cover.isReleasedWhenClosed = false
                    defer { cover.orderOut(nil); cover.close() }
                    for index in 0..<150 {
                        if index == 25 { cover.orderFront(nil) }
                        try await Task.sleep(nanoseconds: 40_000_000)
                        if let picture = try source.image(at: CMClockGetTime(CMClockGetHostTimeClock())) {
                            var rgba = [UInt8](repeating: 0, count: 4)
                            context.render(picture, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: picture.extent.midX, y: picture.extent.midY, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                            if rgba[0] > 200 && rgba[2] < 50 { colours.insert("red"); if index > 30 { occludedColours.insert("red") } }
                            if rgba[2] > 200 && rgba[0] < 50 { colours.insert("blue"); if index > 30 { occludedColours.insert("blue") } }; frames += 1
                        }
                    }
                    let muted = try await source.webView.evaluateJavaScript("document.querySelector('video').muted && document.querySelector('video').volume === 0") as? Bool
                    print("Captured \(frames) frames; video colours: \(colours.sorted()); muted: \(muted == true)")
                    guard frames > 30, colours == ["red", "blue"], occludedColours == ["red", "blue"], muted == true else {
                        print("Video state:", try await source.webView.evaluateJavaScript("JSON.stringify({ready:document.querySelector('video').readyState,paused:document.querySelector('video').paused,time:document.querySelector('video').currentTime})") ?? "none")
                        throw CameraError.message("Changing video pixels or silent playback were not verified.")
                    }
                    await source.deactivate()
                    let paused = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let later = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    guard abs(later - paused) < 0.1 else { throw CameraError.message("Inactive browser playback did not pause.") }
                    try await source.activate(); try await Task.sleep(nanoseconds: 300_000_000)
                    guard try source.image(at: CMClockGetTime(CMClockGetHostTimeClock())) != nil else { throw CameraError.message("Browser capture did not resume.") }
                    let resumed = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    let playing = try await source.webView.evaluateJavaScript("!document.querySelector('video').paused") as? Bool
                    guard playing == true, abs(resumed - paused) > 0.05 else { throw CameraError.message("Browser video playback did not resume.") }
                    _ = try await source.webView.evaluateJavaScript("document.querySelector('video').pause()")
                    let userPaused = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    await source.deactivate(); try await source.activate()
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let stillPaused = try await source.webView.evaluateJavaScript("document.querySelector('video').paused") as? Bool
                    let userPosition = try await source.webView.evaluateJavaScript("document.querySelector('video').currentTime") as! Double
                    guard stillPaused == true, abs(userPosition - userPaused) < 0.1 else { throw CameraError.message("An explicit user pause was not preserved.") }
                    await source.deactivate(); source.close()
                    print("Browser video capture (including an obscured source window), silence, pause/resume and explicit user-pause preservation passed.")
                    exit(0)
                } catch { await source.deactivate(); source.close(); throw error }
            } catch { print("Browser layer integration failed: \(error)"); exit(1) }
        }
    }
}

@main struct BrowserLayerMain {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = BrowserLayerHarness()
        app.setActivationPolicy(.regular); app.delegate = delegate
        app.run(); withExtendedLifetime(delegate) {}
    }
}
