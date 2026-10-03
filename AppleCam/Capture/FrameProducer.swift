#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import AVFoundation
import CoreImage

/// Captures, processes and delivers frames on one bounded serial queue.
final class FrameProducer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Mode { case pattern, camera(String) }
    let queue = DispatchQueue(label: "com.vanguardsignals.AppleCam.producer", qos: .userInitiated)
    var onStatus: ((String, Bool) -> Void)?
    var onPreview: ((CGImage) -> Void)?
    var onCaptureRate: ((Double, Int) -> Void)?
    var onSample: ((Result<SIMD3<Float>, Error>) -> Void)?
    var onState: ((_ publishing: Bool, _ cameraReady: Bool) -> Void)?
    private var cameraReady = false
    private var keyer: GreenScreenProcessor?
    private var keySettings = KeySettings()
    private var latestRaw: CVPixelBuffer?
    private var captureRate = FrameRateCounter()
    private var metricsTimer: DispatchSourceTimer?
    private let transport: FrameTransport
    private var previewMode = KeyPreview.composite
    init(transport: FrameTransport = SinkTransport()) {
        self.transport = transport
        super.init()
    }
    func setPreviewMode(_ mode: KeyPreview) { queue.async { [self] in previewMode = mode } }
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var timer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var session: AVCaptureSession?
    private var camera: AVCaptureDevice?
    private var observations: [NSObjectProtocol] = []
    private var pool: CVPixelBufferPool?
    private var videoDescription: CMVideoFormatDescription?
    private var pattern: CIImage?
    private var frame = 0
    private var running = false
    private var publish = false
    private var lastFrame: Double = 0

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.filter { $0.uniqueID != CameraContract.deviceID.uuidString && $0.localizedName != CameraContract.name }
    }
    func start(mode: Mode, publish: Bool, background: CGImage? = nil, settings: KeySettings = KeySettings()) {
        queue.async { [self] in
            stopOnQueue()
            do {
                self.publish = publish
                if let background {
                    guard settings.isValid else { throw CameraError.message("Invalid green-screen settings.") }
                    keyer = try GreenScreenProcessor(background: background)
                    keySettings = settings
                }
                if publish { try transport.start() }
                try makePool()
                running = true; frame = 0
                captureRate.reset(at: ProcessInfo.processInfo.systemUptime)
                let metricsTimer = DispatchSource.makeTimerSource(queue: queue)
                metricsTimer.schedule(deadline: .now() + 1, repeating: 1)
                metricsTimer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let count = self.captureRate.count
                    self.onCaptureRate?(self.captureRate.sample(at: ProcessInfo.processInfo.systemUptime), count)
                }
                self.metricsTimer = metricsTimer; metricsTimer.resume()
                switch mode {
                case .pattern:
                    pattern = try makePattern()
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Int(CameraContract.fps)))
                    timer.setEventHandler { [weak self] in self?.drawPattern() }
                    self.timer = timer; timer.resume()
                case .camera(let id): try startCamera(id: id)
                }
                reportStatus()
            } catch { fail(error) }
        }
    }
    /// Applied between frames without restarting capture or changing the output destination.
    func setGreenScreen(background: CGImage?, settings: KeySettings) {
        queue.async { [self] in
            guard running else { return }
            do {
                guard settings.isValid else { throw CameraError.message("Invalid green-screen settings.") }
                let next = try background.map { try GreenScreenProcessor(background: $0) }
                keyer = next; keySettings = settings
                if next == nil { previewMode = .composite }
                reportStatus()
            } catch { fail(error) }
        }
    }
    func setPublishing(_ enabled: Bool) {
        queue.async { [self] in
            guard running else { return }
            do {
                if enabled != publish {
                    if enabled { try transport.start() } else { transport.stop() }
                    publish = enabled
                }
                reportStatus()
            } catch { fail(error) }
        }
    }
    private func reportStatus() {
        onState?(publish, cameraReady)
        let processing = keyer == nil ? "Camera" : "Green-screen"
        onStatus?(publish ? "\(processing) picture sent to AppleCam. Check your meeting preview to confirm delivery." : "\(processing) preview — local only.", true)
    }
    func stop() { queue.async { [self] in stopOnQueue(); onStatus?("Stopped — no new frames sent.", false) } }
    func updateKey(_ settings: KeySettings) {
        queue.async { [self] in
            guard settings.isValid else { fail(CameraError.message("Invalid green-screen settings.")); return }
            keySettings = settings
        }
    }
    func sample(x: Double, y: Double) {
        queue.async { [self] in
            guard running, let latestRaw else { onSample?(.failure(CameraError.message("Start a preview before sampling the screen."))); return }
            onSample?(Result { try GreenScreenProcessor.sample(latestRaw, x: x, y: y) })
        }
    }
    private func stopOnQueue() {
        running = false
        publish = false; cameraReady = false
        onState?(false, false)
        metricsTimer?.cancel(); metricsTimer = nil
        timer?.cancel(); timer = nil
        watchdog?.cancel(); watchdog = nil
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        session?.stopRunning(); session = nil; camera = nil
        transport.stop(); pool = nil; videoDescription = nil; pattern = nil
        latestRaw = nil; keyer = nil
    }
    private func fail(_ error: Error) { stopOnQueue(); onStatus?(error.localizedDescription, false) }
    private func makePool() throws {
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: CameraContract.width,
            kCVPixelBufferHeightKey: CameraContract.height, kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess else { throw CameraError.operation("Create frame pool", status) }
    }
    private func makePattern() throws -> CIImage {
        let width = CameraContract.width, height = CameraContract.height
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CameraError.message("Cannot draw diagnostic pattern") }
        let colors: [NSColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue, .black]
        for (index, color) in colors.enumerated() {
            bitmap.setFillColor(color.cgColor)
            bitmap.fill(CGRect(x: index * width / colors.count, y: 0, width: width / colors.count, height: height))
        }
        let graphics = NSGraphicsContext(cgContext: bitmap, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let label = "APPLECAM • DEVELOPMENT TEST\n1920 × 1080 • 30 FPS\nNo webcam image"
        let style = NSMutableParagraphStyle(); style.alignment = .center
        (label as NSString).draw(in: CGRect(x: 140, y: 430, width: 1640, height: 250), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black, .paragraphStyle: style])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.makeImage() else { throw CameraError.message("Cannot make diagnostic pattern") }
        return CIImage(cgImage: image)
    }
    private func drawPattern() {
        guard running, let pattern else { return }
        captureRate.record()
        let bar = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to:
            CGRect(x: (frame * 16) % CameraContract.width, y: 60, width: 12, height: 160))
        emit(bar.composited(over: pattern), at: CMClockGetTime(CMClockGetHostTimeClock()))
    }
    private func startCamera(id: String) throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.message("Camera permission is required. Grant access before starting the BRIO diagnostic.")
        }
        guard let device = Self.cameras().first(where: { $0.uniqueID == id }) else {
            throw CameraError.message("The selected camera is disconnected.")
        }
        let selection = device.formats.lazy.compactMap { format -> (AVCaptureDevice.Format, CMTime)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == CameraContract.width, dimensions.height == CameraContract.height else { return nil }
            for range in format.videoSupportedFrameRateRanges {
                if let duration = CaptureFrameTiming.duration(minimum: range.minFrameDuration,
                                                               maximum: range.maxFrameDuration) {
                    return (format, duration)
                }
            }
            return nil
        }.first
        guard let (format, frameDuration) = selection else {
            throw CameraError.message("The selected camera does not offer 1920 × 1080 at nominal 30 fps.")
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canSetSessionPreset(.hd1920x1080) else {
            throw CameraError.message("The session does not support 1080p capture.")
        }
        session.sessionPreset = .hd1920x1080
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.message("Cannot open selected camera input.") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.message("Cannot create camera output.") }
        session.addOutput(output)
        session.commitConfiguration()
        self.session = session; camera = device
        observations.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.queue.async { [weak self] in self?.fail(error ?? CameraError.message("Camera session failed.")) }
            })
        observations.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.fail(CameraError.message("The selected camera was disconnected.")) }
            })
        lastFrame = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 3, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if CMClockGetTime(CMClockGetHostTimeClock()).seconds - self.lastFrame > 3 {
                self.fail(CameraError.message("The camera stopped delivering frames."))
            }
        }
        self.watchdog = watchdog; watchdog.resume()
        session.startRunning()
        // Session startup applies the preset's hardware timing (24 fps on this BRIO).
        // Pin the selected format and exact supported duration after that completes,
        // before this serial queue can process any capture callbacks.
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, camera != nil, let image = sampleBuffer.imageBuffer else { return }
        captureRate.record()
        if !cameraReady { cameraReady = true; reportStatus() }
        guard CVPixelBufferGetWidth(image) == CameraContract.width, CVPixelBufferGetHeight(image) == CameraContract.height else {
            fail(CameraError.message("Camera delivered an unsupported frame size.")); return
        }
        lastFrame = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        do {
            let timestamp = try CaptureFrameTiming.hostTimestamp(sampleBuffer.presentationTimeStamp,
                from: session?.synchronizationClock)
            emit(CIImage(cvPixelBuffer: image), at: timestamp)
        } catch { fail(error) }
    }
    private func emit(_ image: CIImage, at time: CMTime) {
        guard running, let pool else { return }
        do {
            var rawAllocation: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary, &rawAllocation)
            if status == kCVReturnWouldExceedAllocationThreshold { return }
            guard status == kCVReturnSuccess, let raw = rawAllocation else { throw CameraError.operation("Allocate frame", status) }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            context.render(image, to: raw, bounds: CGRect(x: 0, y: 0, width: CameraContract.width, height: CameraContract.height), colorSpace: space)
            latestRaw = raw
            var delivered = raw
            var localMask: CVPixelBuffer?
            if let keyer {
                var processed: CVPixelBuffer?
                let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                    [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary, &processed)
                if result == kCVReturnWouldExceedAllocationThreshold { return }
                guard result == kCVReturnSuccess, let processed else { throw CameraError.operation("Allocate processed frame", result) }
                localMask = try keyer.render(raw, into: processed, settings: keySettings, maskPreview: previewMode == .mask)
                delivered = processed
            }
            let buffer = delivered
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            if videoDescription == nil {
                let result = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &videoDescription)
                guard result == noErr else { throw CameraError.operation("Describe frame", result) }
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CameraContract.fps),
                presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            let result = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                formatDescription: videoDescription!, sampleTiming: &timing, sampleBufferOut: &sample)
            guard result == noErr, let sample else { throw CameraError.operation("Package frame", result) }
            if publish { try transport.send(sample) }
            // Every produced frame is eligible for preview; the UI mailbox coalesces
            // only when the main thread actually falls behind.
            let previewImage: CIImage
            if keyer != nil && previewMode == .mask {
                guard let localMask else { throw CameraError.message("Cannot render the local mask preview.") }
                previewImage = CIImage(cvPixelBuffer: localMask, options: [.colorSpace: space])
            } else {
                previewImage = keyer == nil ? image : CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space])
            }
            guard let preview = context.createCGImage(previewImage, from: previewImage.extent) else {
                throw CameraError.message("Cannot render preview frame.")
            }
            onPreview?(preview)
            frame += 1
        } catch { fail(error) }
    }
}
