import XCTest
import CoreImage
import AppleCamCore
@testable import AppleCamMedia

final class GreenScreenProcessorTests: XCTestCase {
    private let context = CIContext()
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private func image(_ color: SIMD3<Float>, width: Int = 32, height: Int = 16, alpha: CGFloat = 1) throws -> CGImage {
        try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: alpha)),
                                            from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: space))
    }
    private func write(_ buffer: CVPixelBuffer, colorAt: (Int, Int) -> SIMD3<Float>) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let c = colorAt(x, y), offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                base[offset] = UInt8((c.z * 255).rounded()); base[offset + 1] = UInt8((c.y * 255).rounded())
                base[offset + 2] = UInt8((c.x * 255).rounded()); base[offset + 3] = 255
            }
        }
    }
    func testGPUAgreesWithReferenceAcrossSoftEdgesAndSpill() throws {
        let width = 64, height = 32
        let background = SIMD3<Float>(0.2, 0.3, 0.8)
        let keyer = try GreenScreenProcessor(background: image(background), width: width, height: height)
        let input = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        let output = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        var settings = KeySettings()
        for spill: Float in [0, 0.65, 1] {
            settings.spill = spill
            write(input) { x, y in
                let t = Float(x) / Float(width - 1)
                return (settings.color * (1 - t) + SIMD3<Float>(repeating: 0.6) * t) * (0.2 + 0.8 * Float(y) / Float(height - 1))
            }
            try keyer.render(input, into: output, settings: settings)
            CVPixelBufferLockBaseAddress(input, .readOnly); CVPixelBufferLockBaseAddress(output, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(input, .readOnly); CVPixelBufferUnlockBaseAddress(output, .readOnly) }
            let src = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
            let dst = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
            let quantizedBG = SIMD3<Float>(background.x, (background.y * 255).rounded() / 255, background.z)
            for y in 0..<height {
                for x in 0..<width {
                    let a = y * CVPixelBufferGetBytesPerRow(input) + x * 4
                    let b = y * CVPixelBufferGetBytesPerRow(output) + x * 4
                    let rgb = SIMD3(Float(src[a + 2]), Float(src[a + 1]), Float(src[a])) / 255
                    let reference = ChromaKey.composite(rgb, background: quantizedBG, settings: settings)
                    for c in 0..<3 { XCTAssertEqual(Float(dst[b + 2 - c]) / 255, reference[c], accuracy: 2.0 / 255) }
                    XCTAssertEqual(dst[b + 3], 255)
                }
            }
        }
    }
    func testGPUMultiSampleProtectionAndHoleFillMatchReferenceMask() throws {
        let width = 32, height = 16
        let bg = SIMD3<Float>(0.2, 0.4, 0.8)
        let keyer = try GreenScreenProcessor(background: image(bg), width: width, height: height)
        let input = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        let output = try GreenScreenProcessor.makeBuffer(width: width, height: height)
        var settings = KeySettings(); settings.protection = 1; settings.fillHoles = 1
        settings.additionalColors = [SIMD3(0.1, 0.7, 0.45), SIMD3(0.3, 0.41, 0.3)]
        settings.tolerance = 0.1
        write(input) { x, y in
            if x == 8 && y == 8 { return settings.color } // enclosed hole
            if x < 16 { return SIMD3(repeating: 0.4) }
            if x < 22 { return settings.additionalColors[0] }
            if x < 27 { return SIMD3(0.03, 0.041, 0.03) }
            return settings.color
        }
        let mask = try XCTUnwrap(keyer.render(input, into: output, settings: settings, maskPreview: true))
        func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> SIMD3<Float> {
            let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return SIMD3(Float(data[offset+2]), Float(data[offset+1]), Float(data[offset])) / 255
        }
        for buffer in [input, output, mask] { CVPixelBufferLockBaseAddress(buffer, .readOnly) }
        defer { for buffer in [input, output, mask] { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) } }
        for y in 0..<height { for x in 0..<width {
            let rgb = pixel(input,x,y)
            var a = ChromaKey.alpha(rgb, settings: settings)
            if x >= 2 && y >= 2 && x+2 < width && y+2 < height {
                var minimum: Float = 1
                for dy in -2...2 { for dx in -2...2 where abs(dx) == 2 || abs(dy) == 2 {
                    minimum = min(minimum, ChromaKey.alpha(pixel(input,x+dx,y+dy),settings:settings))
                } }
                a = ChromaKey.fill(alpha:a, perimeterMinimum:minimum, strength:settings.fillHoles)
            }
            let actualMask = pixel(mask,x,y)
            for c in 0..<3 { XCTAssertEqual(actualMask[c],a,accuracy:2.0/255) }
            let composite = ChromaKey.composite(rgb,background:bg,settings:settings,refinedAlpha:a)
            let actual = pixel(output,x,y)
            for c in 0..<3 { XCTAssertEqual(actual[c],composite[c],accuracy:2.0/255) }
        } }
        XCTAssertEqual(pixel(mask,8,8).x,1) // enclosed hole filled
        XCTAssertEqual(pixel(mask,18,8).x,0) // broad screen stays removed
        XCTAssertEqual(pixel(mask,31,8).x,0) // frame boundary not filled
    }
    func testSamplerUsesTopLeftOriginAndClampsEdgePatch() throws {
        let input = try GreenScreenProcessor.makeBuffer(width: 16, height: 16)
        write(input) { x, y in SIMD3(x < 8 ? 1 : 0, y < 8 ? 1 : 0, 0) }
        XCTAssertEqual(try GreenScreenProcessor.sample(input, x: 0, y: 0), SIMD3(1, 1, 0))
        XCTAssertEqual(try GreenScreenProcessor.sample(input, x: 1, y: 0), SIMD3(0, 1, 0))
        XCTAssertEqual(try GreenScreenProcessor.sample(input, x: 0, y: 1), SIMD3(1, 0, 0))
        XCTAssertEqual(try GreenScreenProcessor.sample(input, x: 1, y: 1), SIMD3(0, 0, 0))
        XCTAssertThrowsError(try GreenScreenProcessor.sample(input, x: .nan, y: 0))
        XCTAssertThrowsError(try GreenScreenProcessor.sample(input, x: -0.1, y: 0))
    }
    func testInvalidSettingsAndFrameDimensionsAreRejected() throws {
        let keyer = try GreenScreenProcessor(background: image(SIMD3(0, 0, 1)), width: 32, height: 16)
        let input = try GreenScreenProcessor.makeBuffer(width: 32, height: 16)
        let wrong = try GreenScreenProcessor.makeBuffer(width: 16, height: 16)
        XCTAssertThrowsError(try keyer.render(input, into: wrong, settings: KeySettings()))
        var invalid = KeySettings(); invalid.softness = 0
        XCTAssertThrowsError(try keyer.render(input, into: input, settings: invalid))
    }
    func testTransparentBackgroundIsRejected() throws {
        XCTAssertThrowsError(try GreenScreenProcessor(background: image(SIMD3(0, 0, 1), alpha: 0.5), width: 32, height: 16))
    }
    func testPortraitBackgroundFillsWithoutStretchingOrFlipping() throws {
        // Three horizontal colour bands in a tall image. A centre crop must
        // preserve top-to-bottom order and remove the excess top/bottom equally.
        let source = try GreenScreenProcessor.makeBuffer(width: 16, height: 48)
        write(source) { _, y in y < 16 ? SIMD3(1, 0, 0) : (y < 32 ? SIMD3(0, 0, 1) : SIMD3(1, 1, 0)) }
        let sourceImage = try XCTUnwrap(context.createCGImage(CIImage(cvPixelBuffer: source), from: CGRect(x: 0, y: 0, width: 16, height: 48), format: .RGBA8, colorSpace: space))
        let keyer = try GreenScreenProcessor(background: sourceImage, width: 16, height: 16)
        let input = try GreenScreenProcessor.makeBuffer(width: 16, height: 16)
        let output = try GreenScreenProcessor.makeBuffer(width: 16, height: 16)
        write(input) { _, _ in KeySettings().color }
        try keyer.render(input, into: output, settings: KeySettings())
        for point in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0)] {
            XCTAssertEqual(try GreenScreenProcessor.sample(output, x: point.0, y: point.1), SIMD3(0, 0, 1))
        }
        let full = try GreenScreenProcessor(background: sourceImage, width: 16, height: 48)
        let tallInput = try GreenScreenProcessor.makeBuffer(width: 16, height: 48)
        let tallOutput = try GreenScreenProcessor.makeBuffer(width: 16, height: 48)
        write(tallInput) { _, _ in KeySettings().color }
        try full.render(tallInput, into: tallOutput, settings: KeySettings())
        XCTAssertEqual(try GreenScreenProcessor.sample(tallOutput, x: 0.5, y: 0), SIMD3(1, 0, 0))
        XCTAssertEqual(try GreenScreenProcessor.sample(tallOutput, x: 0.5, y: 1), SIMD3(1, 1, 0))
    }
    func testMissingBackgroundFileIsRejected() {
        XCTAssertThrowsError(try GreenScreenProcessor.loadBackground(URL(fileURLWithPath: "/nonexistent/applecam-test.png")))
    }
    func test1080pGPUPerformance() throws {
        let keyer = try GreenScreenProcessor(background: image(SIMD3(0.2, 0.3, 0.8)))
        let input = try GreenScreenProcessor.makeBuffer(width: 1920, height: 1080)
        let output = try GreenScreenProcessor.makeBuffer(width: 1920, height: 1080)
        write(input) { _, _ in KeySettings().color }
        for _ in 0..<5 { try keyer.render(input, into: output, settings: KeySettings()) }
        let begin = ProcessInfo.processInfo.systemUptime
        for _ in 0..<60 { try keyer.render(input, into: output, settings: KeySettings()) }
        let ms = (ProcessInfo.processInfo.systemUptime - begin) * 1000 / 60
        print("APPLECAM_KEY_GPU_MEAN_MS=\(ms)")
        var advanced = KeySettings(); advanced.fillHoles = 1; advanced.protection = 1
        advanced.additionalColors = (1...5).map { SIMD3(Float($0)*0.025, 0.8, 0.2) }
        for _ in 0..<5 { try keyer.render(input, into: output, settings: advanced, maskPreview: true) }
        let advancedBegin = ProcessInfo.processInfo.systemUptime
        for _ in 0..<60 { try keyer.render(input, into: output, settings: advanced, maskPreview: true) }
        print("APPLECAM_KEY_ADVANCED_GPU_MEAN_MS=\((ProcessInfo.processInfo.systemUptime - advancedBegin)*1000/60)")
        // Measurement is evidence, not a timing assertion dependent on system load.
    }
}
