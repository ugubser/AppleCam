import XCTest
@testable import AppleCamCore

final class ChromaKeyTests: XCTestCase {
    func testScreenIsRemovedAcrossBrightnessAndNeutralForegroundIsPreserved() {
        let settings = KeySettings(), background = SIMD3<Float>(0.2, 0.3, 0.8)
        for brightness: Float in [0.1, 0.4, 0.8, 1] {
            let screen = settings.color * brightness
            XCTAssertEqual(ChromaKey.alpha(screen, settings: settings), 0, accuracy: 0.0001)
            let result = ChromaKey.composite(screen, background: background, settings: settings)
            for i in 0..<3 { XCTAssertEqual(result[i], background[i], accuracy: 0.0001) }
        }
        for gray: Float in [0, 0.05, 0.4, 1] {
            let color = SIMD3<Float>(repeating: gray)
            XCTAssertEqual(ChromaKey.alpha(color, settings: settings), 1)
            let result = ChromaKey.composite(color, background: background, settings: settings)
            for i in 0..<3 { XCTAssertEqual(result[i], gray, accuracy: 0.0001) }
        }
    }
    func testSoftTransitionIsContinuousAndMonotonic() {
        var last: Float = 0
        var s = KeySettings(); s.softness = 0.16
        var fractional = 0
        for n in 0...100 {
            let t = Float(n) / 100
            let color = s.color * (1 - t) + SIMD3<Float>(repeating: 0.5) * t
            let a = ChromaKey.alpha(color, settings: s)
            XCTAssertGreaterThanOrEqual(a + 0.00001, last)
            if a > 0 && a < 1 { fractional += 1 }
            last = a
        }
        XCTAssertGreaterThan(fractional, 10)
        XCTAssertEqual(last, 1)
    }
    func testSpillReducesGreenWithoutChangingRedOrBlue() {
        var s = KeySettings(); s.tolerance = 0; s.softness = 0.005; s.spill = 0
        let c = SIMD3<Float>(0.45, 0.6, 0.5), bg = SIMD3<Float>(repeating: 0)
        let before = ChromaKey.composite(c, background: bg, settings: s)
        s.spill = 1
        let after = ChromaKey.composite(c, background: bg, settings: s)
        XCTAssertLessThan(after.y, before.y)
        XCTAssertEqual(after.x, before.x); XCTAssertEqual(after.z, before.z)
        XCTAssertEqual(after.y, after.z, accuracy: 0.0001)
    }
    func testHalfTransparentFixtureRemovesOldBackgroundInLinearLight() {
        // Known foreground and screen mixed at alpha 0.5, modelling a translucent
        // edge. Calibrate the matte midpoint, then verify decontamination/compositing.
        var s = KeySettings(); s.spill = 0
        let foreground = SIMD3<Float>(repeating: 0.6), replacement = SIMD3<Float>(0.2, 0.3, 0.8)
        var source = SIMD3<Float>()
        for i in 0..<3 { source[i] = ChromaKey.encoded((ChromaKey.linear(foreground[i]) + ChromaKey.linear(s.color[i])) / 2) }
        let delta = source / (source.x + source.y + source.z) - s.color / (s.color.x + s.color.y + s.color.z)
        let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
        s.softness = 0.1; s.tolerance = distance - 0.05
        XCTAssertTrue(s.isValid)
        XCTAssertEqual(ChromaKey.alpha(source, settings: s), 0.5, accuracy: 0.0001)
        let result = ChromaKey.composite(source, background: replacement, settings: s)
        for i in 0..<3 {
            let expected = ChromaKey.encoded((ChromaKey.linear(foreground[i]) + ChromaKey.linear(replacement[i])) / 2)
            XCTAssertEqual(result[i], expected, accuracy: 0.0001)
        }
    }
    func testRejectsNonGreenNonFiniteAndOutOfRangeParameters() {
        XCTAssertTrue(KeySettings().isValid)
        var s = KeySettings(); s.color = SIMD3(0.8, 0.4, 0.2); XCTAssertFalse(s.isValid)
        s = KeySettings(); s.tolerance = .nan; XCTAssertFalse(s.isValid)
        s = KeySettings(); s.softness = 0; XCTAssertFalse(s.isValid)
        s = KeySettings(); s.spill = 1.1; XCTAssertFalse(s.isValid)
    }
}
