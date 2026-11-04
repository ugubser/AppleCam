#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AVFoundation

/// Which Apple video effects macOS offers for one camera format. macOS applies them to whichever app captures
/// the camera, and only for formats it marks as supported (on current Macs: 1920 × 1080 and smaller).
struct VideoEffects: Equatable {
    var reactions: Bool
    var portrait: Bool
    var studioLight: Bool
    var background: Bool
    init(reactions: Bool, portrait: Bool, studioLight: Bool, background: Bool) {
        self.reactions = reactions; self.portrait = portrait; self.studioLight = studioLight; self.background = background
    }
    init(_ format: AVCaptureDevice.Format) {
        self.init(reactions: format.reactionEffectsSupported, portrait: format.isPortraitEffectSupported,
                  studioLight: format.isStudioLightSupported, background: format.isBackgroundReplacementSupported)
    }
    var names: [String] {
        [(reactions, "Reactions"), (portrait, "Portrait"), (studioLight, "Studio Light"), (background, "Backgrounds")]
            .filter(\.0).map(\.1)
    }
    /// Short status for a format of the given size, or the reason no status is available.
    static func summary(_ effects: VideoEffects?, size: String, unavailable: String) -> String {
        guard let effects else { return unavailable }
        let names = effects.names
        if names.isEmpty { return "Not available at \(size)" }
        if names.count == 4 { return "All available at \(size)" }
        return names.joined(separator: ", ") + " at \(size)"
    }

    /// Effects of the selected webcam format, or nil when there is no webcam or it does not offer the format.
    static func webcam(_ device: AVCaptureDevice?, configuration: CaptureConfiguration) -> VideoEffects? {
        guard let device, let (format, _) = CameraCapabilities.selection(for: configuration, device: device) else { return nil }
        return VideoEffects(format)
    }
    /// Effects meeting apps get from the AppleCam camera at the canvas size, or nil when the camera is not installed.
    static func virtualCamera(width: Int, height: Int) -> VideoEffects? {
        guard let device = AVCaptureDevice(uniqueID: CameraContract.deviceID.uuidString) else { return nil }
        return device.formats.first {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(size.width) == width && Int(size.height) == height
        }.map(VideoEffects.init)
    }
    /// Portrait blur and Apple backgrounds replace what is behind you, so keying sees a changed background.
    static var changesBackgroundInAppleCam: Bool { AVCaptureDevice.isPortraitEffectEnabled || AVCaptureDevice.isBackgroundReplacementEnabled }
}
