#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AVFoundation
import CoreImage

struct SceneRenderPlan: @unchecked Sendable {
    var scene: CameraScene
    var sources: [UUID: SceneMediaSource]
    var key: KeySettings
    var greenScreen: Bool
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
    var onPreview: ((CGImage, CGImage, UUID, UUID) -> Void)?
    var onStatus: ((String, Bool, UUID) -> Void)?
    var onPublishing: ((Bool, UUID) -> Void)?
    var onRate: ((Double, UUID) -> Void)?
    var onSample: ((Result<SIMD3<Float>, Error>, UUID) -> Void)?
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
                    rate.reset(at: startedAt); lastRate = startedAt
                    configureCamera(needed: plan.scene.needsCamera)
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / output.fps)))
                    timer.setEventHandler { [weak self] in self?.tick() }
                    self.timer = timer; timer.resume()
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
    private func configureCamera(needed: Bool) {
        guard needed != cameraRunning else { return }
        cameraRunning = needed; cameraFrames.enable(needed); freshness = SceneCameraFreshness()
        if needed {
            startedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            camera.start(mode: cameraMode, publish: false, configuration: cameraConfiguration, captureOnly: true)
        } else { camera.stop() }
    }
    private func stopOnQueue() {
        running = false; timer?.cancel(); timer = nil
        cameraFrames.enable(false); camera.stop(); cameraRunning = false
        transport.stop(); publishing = false; compositor = nil; plan = nil; announced = false
        onPublishing?(false, eventID)
    }
    private func report() { onStatus?(publishing ? "Scene sent to AppleCam. Confirm the picture in your meeting preview." : "Scene preview — local only.", true, eventID) }
    private func fail(_ error: Error) { stopOnQueue(); onStatus?(error.localizedDescription, false, eventID) }
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
                let processed = try compositor.cameraImage(frame.0, key: plan.key, enabled: plan.greenScreen, mask: plan.maskPreview)
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
            let picture = try compositor.preview(output)
            let preview = try mask.map { try compositor.preview($0) } ?? picture
            onPreview?(preview, picture, plan.scene.id, eventID); rate.record()
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
