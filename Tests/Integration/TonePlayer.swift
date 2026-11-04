import AppKit
import AVFoundation

/// A stand-in third-party app for the window-sound check: plays 880 Hz, and after `delay` seconds starts its helper
/// app (bundle ID below its own, like Chrome's audio helper), which plays 1320 Hz. Both play at −26 dBFS until quit.
/// With `--window` it shows a small window, so it can be chosen as a window layer.
@main struct TonePlayer {
    static func main() {
        let arguments = CommandLine.arguments
        let helper = arguments.contains("--helper")
        let engine = AVAudioEngine(), rate = 48_000.0, frequency = helper ? 1_320.0 : 880.0
        var phase = 0.0
        let node = AVAudioSourceNode { _, _, frames, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                var p = phase
                for i in 0..<Int(frames) { samples[i] = Float(0.05 * sin(p)); p += 2 * .pi * frequency / rate }
            }
            phase = (phase + Double(frames) * 2 * .pi * frequency / rate).truncatingRemainder(dividingBy: 2 * .pi)
            return noErr
        }
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        do { try engine.start() } catch { print("Tone player failed: \(error)"); exit(1) }
        var child: Process?
        if !helper, let index = arguments.firstIndex(of: "--helper-after"), let delay = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let process = Process()
                process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Tone Helper.app/Contents/MacOS/TonePlayer")
                process.arguments = ["--helper"]
                try? process.run(); child = process
            }
        }
        signal(SIGTERM) { _ in exit(0) }
        atexit { }
        let app = NSApplication.shared
        let window = arguments.contains("--window")
        app.setActivationPolicy(helper ? .prohibited : (window ? .regular : .accessory))
        var shown: NSWindow?
        if window && !helper {
            let w = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "AppleCam Tone Player"; w.backgroundColor = .systemTeal; w.makeKeyAndOrderFront(nil); shown = w
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in child?.terminate() }
        withExtendedLifetime((engine, node, shown)) { app.run() }
    }
}
