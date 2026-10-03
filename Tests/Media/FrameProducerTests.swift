import XCTest
import CoreGraphics
import CoreImage
import CoreMedia
import AppleCamCore
@testable import AppleCamMedia

/// Exercises the real Core Image/pixel-buffer producer without camera permissions or an installed extension.
final class FrameProducerTests: XCTestCase {
    func testLiveGreenScreenSwitchAndBackgroundChangePreserveTransport() throws {
        final class Receiver: FrameTransport {
            var starts = 0
            var frame: ((CMSampleBuffer) -> Void)?
            func start(configuration: CaptureConfiguration) throws { starts += 1 }
            func send(_ sample: CMSampleBuffer) throws { frame?(sample) }
            func stop() {}
        }
        let receiver = Receiver(), context = CIContext()
        let producer = FrameProducer(transport: receiver)
        func backdrop(_ color: CIColor) throws -> CGImage {
            try XCTUnwrap(context.createCGImage(CIImage(color: color), from: CGRect(x: 0, y: 0, width: 32, height: 16)))
        }
        let blue = try backdrop(CIColor(red: 0, green: 0, blue: 1)), red = try backdrop(CIColor(red: 1, green: 0, blue: 0))
        var settings = KeySettings(); settings.color = SIMD3(0, 1, 0)
        let sequence = expectation(description: "Raw, keyed, raw, keyed with new background")
        let stopped = expectation(description: "Stopped")
        var stage = 0
        receiver.frame = { sample in
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cvPixelBuffer: sample.imageBuffer!), toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 800, y: 900, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            switch stage {
            case 0:
                XCTAssertGreaterThan(pixel[1], 252)
                producer.setGreenScreen(background: blue, settings: settings)
            case 1:
                XCTAssertGreaterThan(pixel[2], 252); XCTAssertLessThan(pixel[1], 3)
                producer.setGreenScreen(background: nil, settings: settings)
            case 2:
                XCTAssertGreaterThan(pixel[1], 252); XCTAssertLessThan(pixel[2], 3)
                producer.setGreenScreen(background: blue, settings: settings)
                producer.setGreenScreen(background: red, settings: settings)
            case 3:
                XCTAssertGreaterThan(pixel[0], 252); XCTAssertLessThan(pixel[1], 3)
                sequence.fulfill()
            default: break
            }
            stage += 1
        }
        producer.onStatus = { _, active in if !active { stopped.fulfill() } }
        producer.start(mode: .pattern, publish: true)
        wait(for: [sequence], timeout: 10)
        producer.stop(); wait(for: [stopped], timeout: 5)
        producer.queue.sync { XCTAssertEqual(receiver.starts, 1) }
    }

    func testKeyedPublishingContinuesAcrossLiveCalibrationAndSampling() throws {
        final class Receiver: FrameTransport {
            var starts = 0, frames = 0
            func start(configuration: CaptureConfiguration) throws { starts += 1 }
            func send(_ sample: CMSampleBuffer) throws { frames += 1 }
            func stop() {}
        }
        let receiver = Receiver(), context = CIContext()
        let producer = FrameProducer(transport: receiver)
        let background = try XCTUnwrap(context.createCGImage(CIImage(color: .blue), from: CGRect(x: 0, y: 0, width: 32, height: 16)))
        var settings = KeySettings(); settings.color = SIMD3(0, 1, 0)
        let continuous = expectation(description: "All captured frames reach keyed preview and output")
        let sampled = expectation(description: "Sampling remains available during keying")
        let stopped = expectation(description: "Stopped")
        var previews = 0, checked = false
        producer.onCaptureRate = { _, count in
            guard !checked else { return }; checked = true
            XCTAssertGreaterThan(count, 1)
            XCTAssertEqual(count, receiver.frames)
            XCTAssertEqual(count, previews)
            continuous.fulfill()
        }
        producer.onPreview = { image in
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 800, y: 900, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            XCTAssertGreaterThan(pixel[2], 252); XCTAssertLessThan(pixel[1], 3)
            previews += 1
            if previews == 1 {
                var updated = settings; updated.protection = 0.9
                producer.updateKey(updated)
                producer.sample(x: 800.0 / 1920, y: 0.1)
            }
        }
        producer.onSample = { result in
            switch result {
            case .success(let color): XCTAssertEqual(color, SIMD3(0, 1, 0))
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            sampled.fulfill()
        }
        producer.onStatus = { text, active in if !active { XCTAssertTrue(text.hasPrefix("Stopped")); stopped.fulfill() } }
        producer.start(mode: .pattern, publish: true, background: background, settings: settings)
        wait(for: [continuous, sampled], timeout: 10)
        producer.stop(); wait(for: [stopped], timeout: 5)
        producer.queue.sync { XCTAssertEqual(receiver.starts, 1) }
    }

    func testSwitchBetweenLocalPreviewAndPublishingWithoutStoppingSource() {
        final class Receiver: FrameTransport {
            var starts = 0, frames = 0
            func start(configuration: CaptureConfiguration) throws { starts += 1 }
            func send(_ sample: CMSampleBuffer) throws { frames += 1 }
            func stop() {}
        }
        let receiver = Receiver()
        // The stream stays alive across destination changes; transport is opened only on explicit Send.
        let stream = FrameProducer(transport: receiver)
        let done = expectation(description: "Preview to Send to Preview")
        let stopped = expectation(description: "Stopped")
        var stage = 0, sent = 0
        stream.onPreview = { _ in
            switch stage {
            case 0: XCTAssertEqual(receiver.frames, 0); stream.setPublishing(true)
            case 1: XCTAssertEqual(receiver.starts, 1); XCTAssertGreaterThan(receiver.frames, 0); sent = receiver.frames; stream.setPublishing(false)
            case 2: XCTAssertEqual(receiver.frames, sent); done.fulfill()
            default: break
            }
            stage += 1
        }
        stream.onStatus = { _, active in if !active { stopped.fulfill() } }
        stream.start(mode: .pattern, publish: false)
        wait(for: [done], timeout: 10)
        stream.stop(); wait(for: [stopped], timeout: 5)
    }

    func testInvalidLiveKeySwitchStopsWithoutRawOutput() throws {
        let context = CIContext()
        let background = try XCTUnwrap(context.createCGImage(CIImage(color: .blue), from: CGRect(x: 0, y: 0, width: 32, height: 16)))
        let producer = FrameProducer()
        let rejected = expectation(description: "Invalid live change stops capture")
        var requested = false
        producer.onPreview = { _ in
            guard !requested else { XCTFail("Delivered a frame after invalid switch"); return }
            requested = true
            var invalid = KeySettings(); invalid.softness = 0
            producer.setGreenScreen(background: background, settings: invalid)
        }
        producer.onStatus = { text, active in
            if !active { XCTAssertTrue(text.contains("Invalid")); rejected.fulfill() }
        }
        producer.start(mode: .pattern, publish: false, background: background)
        wait(for: [rejected], timeout: 5)
        producer.queue.sync {}
    }

    func testPublishingFailureStopsRatherThanContinuingLocally() {
        final class Receiver: FrameTransport {
            func start(configuration: CaptureConfiguration) throws { throw CameraError.message("Receiver unavailable") }
            func send(_ sample: CMSampleBuffer) throws { XCTFail("Sent after startup failure") }
            func stop() {}
        }
        let producer = FrameProducer(transport: Receiver())
        let rejected = expectation(description: "Publishing failure stops capture")
        var requested = false
        producer.onPreview = { _ in
            guard !requested else { XCTFail("Continued locally after failure"); return }
            requested = true; producer.setPublishing(true)
        }
        producer.onStatus = { text, active in
            if !active { XCTAssertEqual(text, "Receiver unavailable"); rejected.fulfill() }
        }
        producer.start(mode: .pattern, publish: false)
        wait(for: [rejected], timeout: 5)
        producer.queue.sync {}
    }

    func testMaskPreviewNeverReplacesPublishedCompositeAndSamplesStayRaw() throws {
        final class Receiver: FrameTransport {
            var frame: ((CMSampleBuffer) -> Void)?
            func start(configuration: CaptureConfiguration) throws {}
            func send(_ sample: CMSampleBuffer) throws { frame?(sample) }
            func stop() {}
        }
        let receiver = Receiver(), context = CIContext()
        let producer = FrameProducer(transport: receiver)
        let background = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red:0,green:0,blue:1)),from:CGRect(x:0,y:0,width:1920,height:1080)))
        let maskSeen = expectation(description:"Local mask"), pictureSeen = expectation(description:"Local picture after switch")
        let rawSeen = expectation(description:"Raw sampler while masking"), stopped = expectation(description:"Stopped")
        var previewCount = 0, sent = 0
        func pixel(_ image: CIImage) -> [UInt8] {
            var result = [UInt8](repeating:0,count:4)
            context.render(image,toBitmap:&result,rowBytes:4,bounds:CGRect(x:800,y:900,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            return result
        }
        receiver.frame = { sample in
            guard let buffer = sample.imageBuffer else { XCTFail("Missing composite"); return }
            let c = pixel(CIImage(cvPixelBuffer:buffer))
            XCTAssertLessThan(c[0],3); XCTAssertLessThan(c[1],3); XCTAssertGreaterThan(c[2],252)
            sent += 1
        }
        producer.onPreview = { image in
            let c = pixel(CIImage(cgImage:image))
            if previewCount == 0 {
                XCTAssertLessThan(c[0],3); XCTAssertLessThan(c[1],3); XCTAssertLessThan(c[2],3)
                maskSeen.fulfill()
                producer.sample(x:800.0/1920,y:0.1)
                producer.setPreviewMode(.composite)
            } else if previewCount == 1 {
                XCTAssertGreaterThan(c[2],252); pictureSeen.fulfill()
            }
            previewCount += 1
        }
        producer.onSample = { result in
            switch result {
            case .success(let color): XCTAssertEqual(color,SIMD3(0,1,0))
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            rawSeen.fulfill()
        }
        producer.onStatus = { text, active in if !active { XCTAssertTrue(text.hasPrefix("Stopped"),text); stopped.fulfill() } }
        var settings = KeySettings(); settings.color = SIMD3(0,1,0)
        producer.setPreviewMode(.mask)
        producer.start(mode:.pattern,publish:true,background:background,settings:settings)
        wait(for:[maskSeen,pictureSeen,rawSeen],timeout:10)
        producer.stop(); wait(for:[stopped],timeout:5)
        producer.queue.sync { XCTAssertGreaterThanOrEqual(sent,2) }
    }
    func testGreenScreenProducesCompositeAtFullPreviewCadence() throws {
        let context = CIContext()
        let background = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 0, green: 0, blue: 1)),
            from: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        let producer = FrameProducer()
        var settings = KeySettings(); settings.color = SIMD3(0, 1, 0)
        let measured = expectation(description: "Processed interval")
        let sampled = expectation(description: "Sampler sees raw green behind processed blue")
        let stopped = expectation(description: "Stopped")
        var frames = 0, checked = false
        producer.onPreview = { image in
            if frames == 0 {
                // This position is inside the diagnostic pattern's green band,
                // away from the moving bar and label. It must become blue.
                var pixel = [UInt8](repeating: 0, count: 4)
                context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                               bounds: CGRect(x: 800, y: 900, width: 1, height: 1), format: .RGBA8,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                XCTAssertLessThan(pixel[0], 3); XCTAssertLessThan(pixel[1], 3)
                XCTAssertGreaterThan(pixel[2], 252); XCTAssertEqual(pixel[3], 255)
                producer.sample(x: 800.0 / 1920, y: 0.1)
            }
            frames += 1
        }
        producer.onSample = { result in
            switch result {
            case .success(let color): XCTAssertEqual(color, SIMD3(0, 1, 0))
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            sampled.fulfill()
        }
        producer.onCaptureRate = { rate, count in
            guard !checked else { return }; checked = true
            XCTAssertGreaterThan(count, 0); XCTAssertEqual(frames, count)
            print("APPLECAM_COMPOSITE_SYNTHETIC_FPS=\(rate)")
            measured.fulfill()
        }
        producer.onStatus = { text, active in
            if !active { XCTAssertTrue(text.hasPrefix("Stopped"), text); stopped.fulfill() }
        }
        producer.start(mode: .pattern, publish: false, background: background, settings: settings)
        wait(for: [measured, sampled], timeout: 10)
        producer.stop(); wait(for: [stopped], timeout: 5)
    }
    func testInvalidKeyConfigurationStopsWithoutRawPreview() throws {
        let background = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white), from: CGRect(x: 0, y: 0, width: 32, height: 16)))
        let producer = FrameProducer()
        let failure = expectation(description: "Settings rejected")
        let raw = expectation(description: "No raw output"); raw.isInverted = true
        producer.onPreview = { _ in raw.fulfill() }
        producer.onStatus = { text, active in XCTAssertFalse(active); XCTAssertTrue(text.contains("Invalid")); failure.fulfill() }
        var invalid = KeySettings(); invalid.softness = 0
        producer.start(mode: .pattern, publish: false, background: background, settings: invalid)
        wait(for: [failure, raw], timeout: 0.5)
    }
    func testPatternProduces1080pPreviewAndStops() {
        let producer = FrameProducer()
        let preview = expectation(description: "Synthetic frame")
        let stopped = expectation(description: "Producer stopped")
        var sawFrame = false
        producer.onPreview = { image in
            XCTAssertEqual(image.width, 1920)
            XCTAssertEqual(image.height, 1080)
            if !sawFrame { sawFrame = true; preview.fulfill() }
        }
        producer.onStatus = { _, active in if !active { stopped.fulfill() } }
        producer.start(mode: .pattern, publish: false)
        wait(for: [preview], timeout: 10)
        producer.stop()
        wait(for: [stopped], timeout: 5)
        let quiet = expectation(description: "No frames after stop")
        quiet.isInverted = true
        producer.queue.sync { producer.onPreview = { _ in quiet.fulfill() } }
        wait(for: [quiet], timeout: 0.25)
    }
    func testEveryProducedPatternFrameReachesPreview() {
        let producer = FrameProducer()
        let measured = expectation(description: "One measured source interval")
        let stopped = expectation(description: "Stopped")
        // Both callbacks run on the producer queue, so the interval counts are exact
        // without imposing a machine-dependent minimum rendering speed.
        var previewCount = 0
        var checked = false
        producer.onPreview = { _ in previewCount += 1 }
        producer.onCaptureRate = { rate, captured in
            guard !checked else { return }
            checked = true
            XCTAssertGreaterThan(captured, 0)
            XCTAssertGreaterThan(rate, 0)
            XCTAssertEqual(previewCount, captured, "Preview must not discard five of every six frames")
            measured.fulfill()
        }
        producer.onStatus = { _, active in if !active { stopped.fulfill() } }
        producer.start(mode: .pattern, publish: false)
        wait(for: [measured], timeout: 10)
        producer.stop()
        wait(for: [stopped], timeout: 5)
    }

    func testMissingCameraFailsWithoutSubstitutingPattern() {
        let producer = FrameProducer()
        let failure = expectation(description: "Specific camera error")
        let frame = expectation(description: "No substituted output")
        frame.isInverted = true
        producer.onPreview = { _ in frame.fulfill() }
        producer.onStatus = { text, active in
            XCTAssertFalse(active)
            XCTAssertFalse(text.isEmpty)
            failure.fulfill()
        }
        producer.start(mode: .camera("nonexistent-test-camera"), publish: false)
        wait(for: [failure, frame], timeout: 0.5)
    }
    func testRepeatedPatternStartStopReleasesProducer() {
        weak var reference: FrameProducer?
        for _ in 0..<5 {
            let producer = FrameProducer()
            reference = producer
            let active = expectation(description: "Started")
            let stopped = expectation(description: "Stopped")
            producer.onStatus = { _, running in (running ? active : stopped).fulfill() }
            producer.start(mode: .pattern, publish: false)
            wait(for: [active], timeout: 5)
            producer.stop()
            wait(for: [stopped], timeout: 5)
            producer.queue.sync {}
        }
        XCTAssertNil(reference)
    }
}

extension FrameProducerTests {
    func testSelectedHDAnd4KFormatsReachTransportAndProcessedFrames() throws {
        final class Receiver: FrameTransport {
            var selected: CaptureConfiguration?
            var frame: ((CMSampleBuffer) -> Void)?
            func start(configuration: CaptureConfiguration) throws { selected = configuration }
            func send(_ sample: CMSampleBuffer) throws { frame?(sample) }
            func stop() {}
        }
        let context = CIContext()
        let background = try XCTUnwrap(context.createCGImage(CIImage(color: .blue), from: CGRect(x: 0, y: 0, width: 16, height: 16)))
        for configuration in [CaptureConfiguration(width: 1280, height: 720, fps: 24), .init(width: 3840, height: 2160, fps: 30)] {
            let receiver = Receiver(), seen = expectation(description: configuration.label), stopped = expectation(description: "Stopped")
            let producer = FrameProducer(transport: receiver)
            var received = false
            receiver.frame = { sample in
                guard !received else { return }; received = true
                XCTAssertEqual(receiver.selected, configuration)
                XCTAssertEqual(CVPixelBufferGetWidth(sample.imageBuffer!), configuration.width)
                XCTAssertEqual(CVPixelBufferGetHeight(sample.imageBuffer!), configuration.height)
                XCTAssertEqual(sample.duration.seconds, configuration.duration.seconds, accuracy: 0.00000001)
                seen.fulfill()
            }
            producer.onStatus = { text, active in if !active { XCTAssertTrue(text.hasPrefix("Stopped")); stopped.fulfill() } }
            producer.start(mode: .pattern, publish: true, background: background, configuration: configuration)
            wait(for: [seen], timeout: 10)
            producer.stop(); wait(for: [stopped], timeout: 5)
            producer.queue.sync {}
        }
    }
}
