import XCTest
@testable import AppleCamCore

final class KeyCalibrationTests: XCTestCase {
    func testAdditionalSamplesRemoveDistinctGreenWithoutBroadeningTolerance() throws {
        var s = KeySettings(); s.tolerance = 0.025; s.softness = 0.01
        let cyanGreen = SIMD3<Float>(0.1, 0.7, 0.45)
        XCTAssertGreaterThan(ChromaKey.alpha(cyanGreen, settings: s), 0.99)
        try s.sample(cyanGreen, append: true)
        XCTAssertEqual(ChromaKey.alpha(cyanGreen, settings: s), 0, accuracy: 0.0001)
        XCTAssertEqual(ChromaKey.alpha(s.color, settings: s), 0, accuracy: 0.0001)
        XCTAssertEqual(ChromaKey.alpha(SIMD3(0.5, 0.4, 0.3), settings: s), 1)
        XCTAssertEqual(s.tolerance, 0.025)
        try s.sample(SIMD3(0.2, 0.8, 0.1), append: false)
        XCTAssertEqual(s.colors.count, 1)
    }
    func testSampleLimitAndInvalidSamplesDoNotModifySelection() throws {
        var s = KeySettings()
        for i in 1...5 { try s.sample(SIMD3(Float(i) * 0.02, 0.8, 0.2), append: true) }
        let before = s
        XCTAssertThrowsError(try s.sample(SIMD3(0.3, 0.8, 0.2), append: true))
        XCTAssertThrowsError(try s.sample(SIMD3(0.5, 0.4, 0.3), append: false))
        XCTAssertEqual(s, before)
        s.additionalColors.append(SIMD3(0.3, 0.8, 0.2)); XCTAssertFalse(s.isValid)
    }
    func testProtectionRestoresNeutralAndDarkWeaklyGreenForeground() {
        var s = KeySettings(); s.color = SIMD3(0.3, 0.41, 0.3); s.tolerance = 0.15; s.protection = 0
        let neutral = SIMD3<Float>(repeating: 0.3), dark = SIMD3<Float>(0.03, 0.041, 0.03)
        XCTAssertEqual(ChromaKey.alpha(neutral, settings: s), 0, accuracy: 0.001)
        XCTAssertEqual(ChromaKey.alpha(dark, settings: s), 0, accuracy: 0.001)
        s.protection = 1
        XCTAssertEqual(ChromaKey.alpha(neutral, settings: s), 1)
        XCTAssertGreaterThan(ChromaKey.alpha(dark, settings: s), 0.8)
        s = KeySettings(); s.protection = 1
        XCTAssertEqual(ChromaKey.alpha(s.color * 0.1, settings: s), 0, accuracy: 0.001)
    }
    func testHoleFillPreservesOpenEdgesAndStrengthIsBounded() {
        XCTAssertEqual(ChromaKey.fill(alpha: 0, perimeterMinimum: 1, strength: 1), 1)
        XCTAssertEqual(ChromaKey.fill(alpha: 0, perimeterMinimum: 1, strength: 0.4), 0.4)
        XCTAssertEqual(ChromaKey.fill(alpha: 0, perimeterMinimum: 0, strength: 1), 0)
        XCTAssertEqual(ChromaKey.fill(alpha: 0.3, perimeterMinimum: 0.9, strength: 1), 0.3)
        XCTAssertEqual(ChromaKey.fill(alpha: 1, perimeterMinimum: 1, strength: 1), 1)
    }
    func testCalibrationValidation() {
        var s = KeySettings(); s.protection = .nan; XCTAssertFalse(s.isValid)
        s = KeySettings(); s.fillHoles = 1.01; XCTAssertFalse(s.isValid)
        s = KeySettings(); s.additionalColors = [SIMD3(.nan, 1, 0)]; XCTAssertFalse(s.isValid)
        s = KeySettings(); s.additionalColors = [SIMD3(0.5, 0.5, 0.5)]; XCTAssertFalse(s.isValid)
    }
}
