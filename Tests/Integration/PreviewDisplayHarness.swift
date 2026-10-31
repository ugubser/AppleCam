import AppKit
import AVFoundation
import SwiftUI

/// Runs a real AppKit event loop and feeds composed 3840x2160 @ 60 fps scene frames into the preview display layer,
/// as the app does. Checks that the renderer accepts every frame and keeps rendering. Synthetic canvas only.
@MainActor final class PreviewDisplayHarness: NSObject, NSApplicationDelegate {
    private final class NullTransport: FrameTransport {
        func start(configuration: CaptureConfiguration) throws {}
        func send(_ sample: CMSampleBuffer) throws {}
        func stop() {}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let display = PreviewDisplay()
            let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "AppleCam Preview Verification"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreviewLayerView(display: display)); window.orderFront(nil)
            let output = SceneOutput(transport: NullTransport())
            var shown = 0, failures = 0, size = ""
            output.onPreview = { buffer, _, _, _ in
                DispatchQueue.main.async {
                    do { try display.show(buffer); shown += 1; size = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))" }
                    catch { failures += 1 }
                }
            }
            var scene = CameraScene(name: "Harness"); scene.canvasRed = 0.8; scene.canvasBlue = 0.2
            let plan = SceneRenderPlan(scene: scene, sources: [:], keying: .off, maskPreview: false)
            do {
                try await output.start(plan: plan, output: .init(width: 3840, height: 2160, fps: 60), cameraMode: .pattern, capture: .init(), publish: false)
                try await Task.sleep(nanoseconds: 3_000_000_000)
                await output.stop()
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch { print("Preview display verification failed: \(error)"); exit(1) }
            let renderer = display.layer.sampleBufferRenderer
            print("Shown \(shown) preview frames of \(size) in 3 s; failures \(failures); renderer status \(renderer.status.rawValue) error \(String(describing: renderer.error))")
            guard shown >= 120, failures == 0, renderer.status == .rendering, renderer.error == nil, size == "1920x1080" else {
                print("Preview display verification failed."); exit(1)
            }
            print("Preview display layer accepted downscaled 4K60 frames without errors.")
            exit(0)
        }
    }
}

@main struct PreviewDisplayMain {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = PreviewDisplayHarness()
        app.setActivationPolicy(.regular); app.delegate = delegate
        app.run(); withExtendedLifetime(delegate) {}
    }
}
