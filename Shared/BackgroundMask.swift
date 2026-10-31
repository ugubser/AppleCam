import Foundation

/// A picture of the empty background, taken with the camera's current format. The file is private to the app.
public struct BackgroundPlate: Codable, Hashable, Sendable {
    public var asset: MediaAsset
    public var width: Int
    public var height: Int
    public var taken: Date
    public init(asset: MediaAsset = MediaAsset(name: "Background picture", fileExtension: "png"), width: Int, height: Int, taken: Date = Date()) {
        self.asset = asset; self.width = width; self.height = height; self.taken = taken
    }
    public var isValid: Bool { asset.isValid && (1...8192).contains(width) && (1...8192).contains(height) }
    /// The picture only lines up with frames of exactly the size it was taken at; it is never scaled.
    public func mismatch(width frameWidth: Int, height frameHeight: Int) -> String? {
        guard frameWidth != width || frameHeight != height else { return nil }
        return "The background picture was taken at \(width) × \(height), but the camera now delivers \(frameWidth) × \(frameHeight). Retake the background picture or choose the earlier camera format."
    }
}

public struct DifferenceKeySettings: Codable, Equatable, Sendable {
    /// Colour difference below which a pixel counts as background.
    public var threshold: Float = 0.10
    /// Width of the partly transparent range above the threshold.
    public var softness: Float = 0.08
    /// 0 counts brightness differences fully; 1 ignores them (shadows, exposure changes) and compares colour only.
    public var lighting: Float = 0.4
    /// Removes small background specks and fills small holes in the foreground.
    public var cleanup: Float = 0.6
    public init() {}
    public var isValid: Bool {
        threshold.isFinite && (0...0.5).contains(threshold) &&
        softness.isFinite && (0.005...0.5).contains(softness) &&
        lighting.isFinite && (0...1).contains(lighting) &&
        cleanup.isFinite && (0...1).contains(cleanup)
    }
}

/// Per-camera background-mask state. `enabled` is exclusive with the green screen.
public struct BackgroundMaskProfile: Codable, Equatable, Sendable {
    public var enabled = false
    public var plate: BackgroundPlate?
    public var settings = DifferenceKeySettings()
    public init() {}
    public var isValid: Bool { settings.isValid && (plate?.isValid ?? true) && (!enabled || plate != nil) }
}

/// CPU reference for the Metal difference key; runtime processing always uses Metal.
public enum DifferenceKey {
    private static func ramp(_ lo: Float, _ hi: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }
    /// Distance between camera and background colours (gamma-encoded RGB, 0...1). Brightness and colour are
    /// separated so brightness changes can be weighted down without ignoring colour changes.
    public static func distance(_ camera: SIMD3<Float>, _ plate: SIMD3<Float>, lighting: Float) -> Float {
        let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        let a = (camera * weights).sum(), b = (plate * weights).sum()
        let chroma = (camera - SIMD3(repeating: a)) - (plate - SIMD3(repeating: b))
        let luma = (a - b) * (1 - lighting)
        return ((chroma * chroma).sum() + luma * luma).squareRoot()
    }
    public static func alpha(_ camera: SIMD3<Float>, plate: SIMD3<Float>, settings: DifferenceKeySettings) -> Float {
        ramp(settings.threshold, settings.threshold + settings.softness, distance(camera, plate, lighting: settings.lighting))
    }
    /// Uses the lowest and highest alpha on a 7×7 ring around the pixel: a pixel enclosed by foreground is filled,
    /// one enclosed by background is cleared, so small specks and holes (up to about 3 camera pixels) disappear.
    public static func clean(alpha: Float, ringMinimum: Float, ringMaximum: Float, strength: Float) -> Float {
        let filled = alpha + (1 - alpha) * strength * ramp(0.95, 1, ringMinimum)
        return filled * (1 - strength * (1 - ramp(0, 0.05, ringMaximum)))
    }
}
