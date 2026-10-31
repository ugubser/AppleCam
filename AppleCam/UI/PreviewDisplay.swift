#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import AVFoundation
import SwiftUI

/// Shows preview frames with `AVSampleBufferDisplayLayer`. The GPU scales the IOSurface-backed buffer directly, so no
/// image is created, copied or converted on the main thread per frame (SwiftUI `Image` did that and saturated it at 60 fps).
@MainActor final class PreviewDisplay {
    let layer = AVSampleBufferDisplayLayer()
    init() {
        layer.videoGravity = .resize // The SwiftUI frame already has the canvas aspect ratio.
        layer.backgroundColor = NSColor.black.cgColor
    }
    func show(_ buffer: CVPixelBuffer) throws {
        let renderer = layer.sampleBufferRenderer
        // A failed renderer accepts frames again only after a flush.
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(try Self.sample(buffer))
    }
    func clear() { layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    /// Wraps the buffer in a sample marked for immediate display, independent of any timebase.
    nonisolated static func sample(_ buffer: CVPixelBuffer) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        let described = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description)
        guard described == noErr, let description else { throw CameraError.operation("Describe preview frame", described) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CameraError.operation("Package preview frame", status) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// Hosts the shared display layer inside the SwiftUI canvas.
struct PreviewLayerView: NSViewRepresentable {
    let display: PreviewDisplay
    func makeNSView(context: Context) -> HostView { HostView(display: display) }
    func updateNSView(_ view: HostView, context: Context) {}
    final class HostView: NSView {
        private let display: PreviewDisplay
        init(display: PreviewDisplay) {
            self.display = display
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(display.layer)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            display.layer.frame = bounds
            CATransaction.commit()
        }
        // Clicks belong to the SwiftUI canvas (sampling, layer handles).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
