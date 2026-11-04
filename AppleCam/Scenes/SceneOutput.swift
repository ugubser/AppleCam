#if SWIFT_PACKAGE
import AppleCamCore
#endif
import Accelerate
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// A decoded background picture. Immutable and shared between the main actor and the output queue.
final class LoadedPlate: @unchecked Sendable, Equatable {
    let id: UUID
    let image: CGImage
    init(id: UUID, image: CGImage) { self.id = id; self.image = image }
    static func == (a: LoadedPlate, b: LoadedPlate) -> Bool { a.id == b.id }
}

/// How webcam layers are separated from their surroundings. Green screen and background mask are exclusive.
enum CameraKeying: Equatable {
    case off
    case greenScreen(KeySettings)
    case backgroundMask(DifferenceKeySettings, LoadedPlate)
    var isValid: Bool {
        switch self {
        case .off: return true
        case .greenScreen(let key): return key.isValid
        case .backgroundMask(let settings, _): return settings.isValid
        }
    }
}

struct SceneRenderPlan: @unchecked Sendable {
    var scene: CameraScene
    var sources: [UUID: SceneMediaSource]
    var keying: CameraKeying
    var maskPreview: Bool
}

/// Camera frame age is checked before composing; a new canvas timestamp never rescues stale camera pixels.
struct SceneCameraFreshness {
    private var staleSince: Double?
    mutating func accept(timestamp: Double, now: Double) throws -> Bool {
        guard timestamp.isFinite, timestamp >= 0, timestamp <= now + 0.005 else { throw FrameGate.Rejection.invalidTime }
        if now - timestamp <= CameraContract.maximumFrameAge { staleSince = nil; return true }
        if let start = staleSince, now - start >= 2 { throw CameraError.message("Camera frames remain over 150 ms old. Scene output stopped.") }
        if staleSince == nil { staleSince = now }; return false
    }
}

/// All composition and transport operations are serialized. Media sources expose bounded frame snapshots.
final class SceneOutput: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.vanguardsignals.AppleCam.scene-output", qos: .userInitiated)
    /// Local preview frame (downscaled; the mask in Mask view), an occasional scene thumbnail, scene ID and event ID.
    var onPreview: ((CVPixelBuffer, CGImage?, UUID, UUID) -> Void)?
    /// Scene buttons only need a recognisable picture; rendering a thumbnail every frame would waste GPU readback.
    static let thumbnailInterval = 0.5
    private var lastThumbnail: Double = -.infinity
    var onStatus: ((String, Bool, UUID) -> Void)?
    var onPublishing: ((Bool, UUID) -> Void)?
    var onRate: ((Double, UUID) -> Void)?
    var onSample: ((Result<SIMD3<Float>, Error>, UUID) -> Void)?
    /// A recording ended: its file, and the reason when it stopped on its own (nil after Stop Recording).
    var onRecordingEnded: ((URL, Error?, UUID) -> Void)?
    /// Mixes audio while a scene runs; created once and restarted with each scene run.
    let mixer = AudioMixer()
    private var recorder: SceneRecorder?
    /// Smoothed age of the camera picture in composed frames; sound is delayed by it so lips and voice line up.
    private var cameraAge: Double = 0
    private var lastDelayUpdate: Double = 0
    private let transport: FrameTransport
    private let camera = FrameProducer()
    private let cameraFrames = CameraFrameStore()
    private var cameraMode = FrameProducer.Mode.pattern
    private var cameraConfiguration = CaptureConfiguration()
    private var timer: DispatchSourceTimer?
    private var plan: SceneRenderPlan?
    private var compositor: SceneCompositor?
    private var eventID = UUID()
    private var publishing = false
    private var running = false
    private var cameraRunning = false
    private var startedAt: Double = 0
    private var announced = false
    private var rate = FrameRateCounter()
    private var lastRate: Double = 0
    private var freshness = SceneCameraFreshness()
    private var missingSince: Double?
    private var slowSince: Double?
    init(transport: FrameTransport = SinkTransport()) {
        self.transport = transport
        camera.onCameraFrame = { [weak self] buffer, time in self?.cameraFrames.set(buffer, at: time) }
        camera.onFailure = { [weak self] error in self?.cameraFrames.failIfEnabled(error) }
        mixer.onRecorderFailure = { [weak self] error in
            guard let self else { return }
            queue.async { self.endRecording(error) }
        }
    }
    func start(plan: SceneRenderPlan, output: CaptureConfiguration, cameraMode: FrameProducer.Mode,
               capture: CaptureConfiguration, publish: Bool, eventID: UUID = UUID()) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    stopOnQueue(); self.eventID = eventID
                    compositor = try SceneCompositor(configuration: output)
                    self.cameraMode = cameraMode; cameraConfiguration = capture
                    if publish { try transport.start(configuration: output) }
                    publishing = publish; self.plan = plan; running = true; missingSince = nil; slowSince = nil
                    startedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    rate.reset(at: startedAt); lastRate = startedAt; lastThumbnail = -.infinity
                    configureCamera(needed: plan.scene.needsCamera)
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / output.fps)))
                    timer.setEventHandler { [weak self] in self?.tick() }
                    self.timer = timer; timer.resume()
                    cameraAge = 0; mixer.setVideoDelay(0); mixer.start()
                    onPublishing?(publish, self.eventID); continuation.resume()
                } catch { stopOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }
    /// Waits for the previous frame before swapping the complete configuration.
    func update(_ plan: SceneRenderPlan) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard running else { continuation.resume(); return }
                self.plan = plan; missingSince = nil; freshness = SceneCameraFreshness(); configureCamera(needed: plan.scene.needsCamera)
                lastThumbnail = -.infinity
                continuation.resume()
            }
        }
    }
    func sourceFailed(_ error: Error) { queue.async { [self] in if running { fail(error) } } }
    func setPublishing(_ enabled: Bool) {
        queue.async { [self] in
            guard running, let compositor else { return }
            do {
                if enabled != publishing {
                    if enabled { try transport.start(configuration: compositor.configuration) } else { transport.stop() }
                    publishing = enabled
                }
                onPublishing?(publishing, eventID); report()
            } catch { fail(error) }
        }
    }
    func stop() async { await withCheckedContinuation { continuation in queue.async { [self] in stopOnQueue(); continuation.resume() } } }
    /// Starts writing every composed frame, and the mix plus `channels` (IDs in track order), to `recorder`.
    func startRecording(_ recorder: SceneRecorder, channels: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard running, let compositor, self.recorder == nil else {
                    continuation.resume(throwing: CameraError.message(self.recorder == nil ? "Start a scene before recording." : "A recording is already running.")); return
                }
                self.recorder = recorder; compositor.outputBufferLimit = 12
                if !recorder.trackNames.isEmpty { mixer.attach(recorder, channels: channels) }
                continuation.resume()
            }
        }
    }
    /// Ends the recording; `onRecordingEnded` reports when the file is complete.
    func stopRecording(_ reason: Error? = nil) { queue.async { [self] in endRecording(reason) } }
    var isRecording: Bool { queue.sync { recorder != nil } }
    private func endRecording(_ reason: Error?) {
        guard let recorder else { return }
        self.recorder = nil; mixer.detach(); compositor?.outputBufferLimit = 5
        let event = eventID, end = CMClockGetTime(CMClockGetHostTimeClock())
        recorder.finish(at: end) { [weak self] error in self?.onRecordingEnded?(recorder.url, reason ?? error, event) }
    }
    private func configureCamera(needed: Bool) {
        guard needed != cameraRunning else { return }
        cameraRunning = needed; cameraFrames.enable(needed); freshness = SceneCameraFreshness()
        if needed {
            startedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            camera.start(mode: cameraMode, configuration: cameraConfiguration)
        } else { camera.stop() }
    }
    private func stopOnQueue() {
        endRecording(nil); mixer.stop()
        running = false; timer?.cancel(); timer = nil
        cameraFrames.enable(false); camera.stop(); cameraRunning = false
        transport.stop(); publishing = false; compositor = nil; plan = nil; announced = false
        onPublishing?(false, eventID)
    }
    private func report() { onStatus?(publishing ? "Scene sent to AppleCam. Confirm the picture in your meeting preview." : "Scene preview — local only.", true, eventID) }
    private func fail(_ error: Error) { endRecording(error); stopOnQueue(); onStatus?(error.localizedDescription, false, eventID) }
    private func tick() {
        guard running, let plan, let compositor else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            var images: [UUID: CIImage] = [:]
            var mask: CIImage?
            if plan.scene.needsCamera {
                guard let frame = try cameraFrames.get() else {
                    if now.seconds - startedAt > 5 { throw CameraError.message("The selected camera did not start delivering frames.") }; return
                }
                guard try freshness.accept(timestamp: frame.1.seconds, now: now.seconds) else { return }
                cameraAge = cameraAge == 0 ? now.seconds - frame.1.seconds : cameraAge * 0.95 + (now.seconds - frame.1.seconds) * 0.05
                let processed = try compositor.cameraImage(frame.0, keying: plan.keying, mask: plan.maskPreview)
                mask = processed.1
                for layer in plan.scene.layers where layer.visible && layer.source == .camera { images[layer.id] = processed.0 }
            }
            for layer in plan.scene.layers where layer.visible && layer.source != .camera {
                guard let source = plan.sources[layer.id], let image = try source.image(at: now) else {
                    if let since = missingSince, now.seconds - since > 2 { throw CameraError.message("\(layer.name) is not delivering frames. Output stopped.") }
                    if missingSince == nil { missingSince = now.seconds }; return
                }
                images[layer.id] = image
            }
            missingSince = nil
            guard let output = try compositor.compose(scene: plan.scene, images: images) else { return }
            let completed = CMClockGetTime(CMClockGetHostTimeClock())
            if completed.seconds - now.seconds > CameraContract.maximumFrameAge {
                if let since = slowSince, completed.seconds - since > 2 { throw CameraError.message("Scene processing remains too slow to deliver fresh frames. Output stopped; simplify the scene before restarting.") }
                if slowSince == nil { slowSince = now.seconds }; return
            }
            slowSince = nil
            let sample = try Self.package(output, time: now, duration: compositor.configuration.duration)
            if publishing { try transport.send(sample) }
            if let recorder {
                do { try recorder.appendVideo(output, at: now) } catch { endRecording(error) }
            }
            if completed.seconds - lastDelayUpdate >= 1 {
                lastDelayUpdate = completed.seconds; mixer.setVideoDelay(plan.scene.needsCamera ? cameraAge : 0)
            }
            var thumbnail: CGImage?
            if completed.seconds - lastThumbnail >= Self.thumbnailInterval {
                thumbnail = try compositor.thumbnail(CIImage(cvPixelBuffer: output)); lastThumbnail = completed.seconds
            }
            // A preview frame is skipped (not the published frame) while the display still holds every pooled buffer.
            if let preview = try compositor.previewBuffer(mask ?? CIImage(cvPixelBuffer: output)) {
                onPreview?(preview, thumbnail, plan.scene.id, eventID)
            }
            rate.record()
            if completed.seconds - lastRate >= 1 { onRate?(rate.sample(at: completed.seconds), eventID); lastRate = completed.seconds }
            if !announced { announced = true; report() }
        } catch { fail(error) }
    }
    func sample(x: Double, y: Double, layer: SceneLayer?, canvas: CGSize, mask: Bool) {
        queue.async { [self] in
            onSample?(Result {
                guard let frame = try cameraFrames.get() else { throw CameraError.message("Start a scene with a webcam layer before sampling.") }
                var point = CGPoint(x: x, y: y)
                if !mask {
                    guard let layer, let mapped = layer.placement.sourcePoint(canvasPoint: CGPoint(x: x * canvas.width, y: y * canvas.height),
                        source: CGSize(width: CVPixelBufferGetWidth(frame.0), height: CVPixelBufferGetHeight(frame.0)), canvas: canvas) else {
                        throw CameraError.message("Click inside the selected webcam layer.")
                    }
                    point = mapped
                }
                return try GreenScreenProcessor.sample(frame.0, x: point.x, y: point.y)
            }, eventID)
        }
    }
    /// Averages `count` consecutive raw camera frames (before keying) into one low-noise background picture.
    /// Runs off the output queue so the scene keeps rendering while the frames are collected.
    func capturePlate(frames count: Int = PlateAverager.defaultFrames, timeout: Double = 3) async throws -> PlateCapture {
        let store = cameraFrames
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    var averager: PlateAverager?
                    var last = CMTime.invalid
                    let deadline = ProcessInfo.processInfo.systemUptime + timeout
                    while (averager?.count ?? 0) < count {
                        guard ProcessInfo.processInfo.systemUptime < deadline else {
                            throw CameraError.message("The camera did not deliver enough frames for a background picture. Start a preview with a webcam layer and try again.")
                        }
                        if let (buffer, time) = try store.get(), time != last {
                            last = time
                            if averager == nil { averager = try PlateAverager(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }
                            try averager?.add(buffer)
                        } else { usleep(4_000) }
                    }
                    return try averager!.result()
                })
            }
        }
    }
    private static func package(_ buffer: CVPixelBuffer, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw CameraError.operation("Describe scene output", status) }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let result = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw CameraError.operation("Package scene output", result) }; return sample
    }
}

private final class CameraFrameStore {
    private let lock = NSLock()
    private var frame: (CVPixelBuffer, CMTime)?
    private var failure: Error?
    private var enabled = false
    func enable(_ enabled: Bool) { lock.lock(); defer { lock.unlock() }; self.enabled = enabled; frame = nil; failure = nil }
    func set(_ buffer: CVPixelBuffer, at time: CMTime) { lock.lock(); defer { lock.unlock() }; if enabled { frame = (buffer, time) } }
    func failIfEnabled(_ error: Error) { lock.lock(); defer { lock.unlock() }; if enabled { failure = error } }
    func get() throws -> (CVPixelBuffer, CMTime)? { lock.lock(); defer { lock.unlock() }; if let failure { throw failure }; return frame }
}

/// A finished background picture: the averaged BGRA image and its lossless PNG encoding for storage.
struct PlateCapture: @unchecked Sendable {
    let image: CGImage
    let png: Data
    var width: Int { image.width }
    var height: Int { image.height }
}

/// Sums BGRA camera frames in floating point and produces their rounded average.
struct PlateAverager {
    static let defaultFrames = 8
    let width: Int
    let height: Int
    private var sum: [Float]
    private var scratch: [Float]
    private(set) var count = 0
    init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw CameraError.message("The camera delivered an empty frame.") }
        self.width = width; self.height = height
        sum = Array(repeating: 0, count: width * height * 4); scratch = sum
    }
    mutating func add(_ buffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { throw CameraError.message("The camera delivered an unsupported frame.") }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
            throw CameraError.message("The camera format changed while taking the background picture. Try again.")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw CameraError.message("Cannot read the camera frame.") }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), row = width * 4
        scratch.withUnsafeMutableBufferPointer { scratch in
            for y in 0..<height { vDSP_vfltu8(base + y * rowBytes, 1, scratch.baseAddress! + y * row, 1, vDSP_Length(row)) }
        }
        vDSP.add(sum, scratch, result: &sum)
        count += 1
    }
    func result() throws -> PlateCapture {
        guard count > 0 else { throw CameraError.message("No camera frames were collected.") }
        var average = vDSP.divide(sum, Float(count))
        vDSP.clip(average, to: 0...255, result: &average)
        var bytes = [UInt8](repeating: 0, count: average.count)
        vDSP.convertElements(of: average, to: &bytes, rounding: .towardNearestInteger)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        // Camera frames are sRGB-encoded BGRA; the picture keeps those exact values.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CameraError.message("Cannot create the background picture.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CameraError.message("Cannot encode the background picture.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CameraError.message("Cannot encode the background picture.") }
        return PlateCapture(image: image, png: data as Data)
    }
}
