import Foundation

public enum KeyPreview: String, CaseIterable, Sendable, Codable {
    case composite = "Picture"
    case mask = "Mask"
}

/// Encoded sRGB samples; chromaticity selection followed by linear-light compositing.
public struct KeySettings: Equatable, Sendable, Codable {
    public static let maximumSamples = 6
    public var color = SIMD3<Float>(0.12, 0.72, 0.12)
    public var additionalColors: [SIMD3<Float>] = []
    public var tolerance: Float = 0.12
    public var softness: Float = 0.04
    public var spill: Float = 0.65
    public var protection: Float = 0.5
    public var fillHoles: Float = 0
    public var colors: [SIMD3<Float>] { [color] + additionalColors }
    public init() {}
    public static func validColor(_ c: SIMD3<Float>) -> Bool {
        c.x.isFinite && c.y.isFinite && c.z.isFinite &&
        (0...1).contains(c.x) && (0...1).contains(c.y) && (0...1).contains(c.z) &&
        c.y > max(c.x, c.z) + 0.02
    }
    public mutating func sample(_ c: SIMD3<Float>, append: Bool) throws {
        guard Self.validColor(c) else { throw CameraError.message("That area isn't green. Sample the screen away from your hair, face and chair.") }
        if append {
            guard colors.count < Self.maximumSamples else { throw CameraError.message("Six samples are already selected. Remove one or replace the samples.") }
            guard !colors.contains(c) else { throw CameraError.message("That screen colour is already selected.") }
            additionalColors.append(c)
        } else { color = c; additionalColors = [] }
    }
    public var isValid: Bool {
        colors.count <= Self.maximumSamples && colors.allSatisfy(Self.validColor) &&
        tolerance.isFinite && (0...0.5).contains(tolerance) &&
        softness.isFinite && (0.005...0.5).contains(softness) &&
        spill.isFinite && (0...1).contains(spill) &&
        protection.isFinite && (0...1).contains(protection) &&
        fillHoles.isFinite && (0...1).contains(fillHoles)
    }
}

public enum ChromaKey {
    private static func ramp(_ lo: Float, _ hi: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }
    public static func closestColor(_ rgb: SIMD3<Float>, settings: KeySettings) -> SIMD3<Float> {
        let c = rgb / max(0.001, rgb.x + rgb.y + rgb.z)
        return settings.colors.min { a, b in
            let da = c - a / (a.x + a.y + a.z), db = c - b / (b.x + b.y + b.z)
            return da.x * da.x + da.y * da.y + da.z * da.z < db.x * db.x + db.y * db.y + db.z * db.z
        }! // Valid settings always contain the primary sample.
    }
    public static func alpha(_ rgb: SIMD3<Float>, settings: KeySettings) -> Float {
        let sum = rgb.x + rgb.y + rgb.z
        if sum < 0.001 { return 1 }
        let key = closestColor(rgb, settings: settings)
        let delta = rgb / sum - key / (key.x + key.y + key.z)
        let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
        let base = ramp(settings.tolerance, settings.tolerance + settings.softness, distance)
        let green = max(0, rgb.y - max(rgb.x, rgb.z)) / sum
        let neutral = 1 - ramp(0.015, 0.10, green)
        let dark = (1 - ramp(0.02, 0.12, max(rgb.x, max(rgb.y, rgb.z)))) * (1 - ramp(0.10, 0.30, green))
        return max(base, settings.protection * max(neutral, dark))
    }
    /// Only a small hole enclosed by a solid 5x5 perimeter is eligible.
    public static func fill(alpha: Float, perimeterMinimum: Float, strength: Float) -> Float {
        alpha + (1 - alpha) * strength * ramp(0.95, 1, perimeterMinimum)
    }
    public static func linear(_ x: Float) -> Float {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    public static func encoded(_ x: Float) -> Float {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
    /// CPU fixture reference only; runtime processing always uses Metal.
    public static func composite(_ rgb: SIMD3<Float>, background: SIMD3<Float>, settings: KeySettings, refinedAlpha: Float? = nil) -> SIMD3<Float> {
        let a = refinedAlpha ?? alpha(rgb, settings: settings)
        let key = closestColor(rgb, settings: settings)
        var fg = SIMD3<Float>()
        for i in 0..<3 { fg[i] = min(a, max(0, linear(rgb[i]) - (1 - a) * linear(key[i]))) }
        fg.y -= settings.spill * max(0, fg.y - max(fg.x, fg.z))
        var result = SIMD3<Float>()
        for i in 0..<3 { result[i] = encoded(min(1, max(0, fg[i] + (1 - a) * linear(background[i])))) }
        return result
    }
}
