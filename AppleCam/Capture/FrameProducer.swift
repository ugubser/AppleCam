#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AppKit
import AVFoundation
import CoreImage

/// Captures webcam or diagnostic-pattern frames on one serial queue.
/// Each frame is copied into a private sRGB BGRA buffer and handed to `onCameraFrame`;
/// keying, composition and publication belong to `SceneOutput`.
final class FrameProducer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Mode { case pattern, camera(String) }
    let queue = DispatchQueue(label: "com.vanguardsignals.AppleCam.producer", qos: .userInitiated)
    /// Called on `queue` for every captured frame with its host-clock timestamp.
    var onCameraFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Called on `queue` once capture has stopped because of an error. No substitute source is started.
    var onFailure: ((Error) -> Void)?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private var timer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var session: AVCaptureSession?
    private var camera: AVCaptureDevice?
    private var observations: [NSObjectProtocol] = []
    private var pool: CVPixelBufferPool?
    private var pattern: CIImage?
    private var frame = 0
    private var running = false
    private var lastFrame: Double = 0
    private var configuration = CaptureConfiguration()

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
            .devices.filter { $0.uniqueID != CameraContract.deviceID.uuidString && $0.localizedName != CameraContract.name }
    }
    func start(mode: Mode, configuration: CaptureConfiguration = CaptureConfiguration()) {
        queue.async { [self] in
            stopOnQueue()
            do {
                guard configuration.isValid else { throw CameraError.message("Invalid camera format.") }
                self.configuration = configuration
                try makePool()
                running = true; frame = 0
                switch mode {
                case .pattern:
                    pattern = try makePattern()
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / configuration.fps)))
                    timer.setEventHandler { [weak self] in self?.drawPattern() }
                    self.timer = timer; timer.resume()
                case .camera(let id): try startCamera(id: id)
                }
            } catch { fail(error) }
        }
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        running = false
        timer?.cancel(); timer = nil
        watchdog?.cancel(); watchdog = nil
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        session?.stopRunning(); session = nil; camera = nil
        pool = nil; pattern = nil
    }
    private func fail(_ error: Error) { stopOnQueue(); onFailure?(error) }
    private func makePool() throws {
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: configuration.width,
            kCVPixelBufferHeightKey: configuration.height, kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess else { throw CameraError.operation("Create frame pool", status) }
    }
    private func makePattern() throws -> CIImage {
        let width = configuration.width, height = configuration.height
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CameraError.message("Cannot draw diagnostic pattern") }
        let colors: [NSColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue, .black]
        for (index, color) in colors.enumerated() {
            bitmap.setFillColor(color.cgColor)
            bitmap.fill(CGRect(x: index * width / colors.count, y: 0, width: width / colors.count, height: height))
        }
        let graphics = NSGraphicsContext(cgContext: bitmap, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let label = "APPLECAM • DEVELOPMENT TEST\n\(configuration.resolution) • \(configuration.rateLabel)\nNo webcam image"
        let style = NSMutableParagraphStyle(); style.alignment = .center
        (label as NSString).draw(in: CGRect(x: CGFloat(width) * 0.07, y: CGFloat(height) * 0.4, width: CGFloat(width) * 0.86, height: CGFloat(height) * 0.24), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: CGFloat(width) / 30), .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black, .paragraphStyle: style])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.makeImage() else { throw CameraError.message("Cannot make diagnostic pattern") }
        return CIImage(cgImage: image)
    }
    private func drawPattern() {
        guard running, let pattern else { return }
        let bar = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to:
            CGRect(x: (frame * 16) % configuration.width, y: 60, width: 12, height: 160))
        emit(bar.composited(over: pattern), at: CMClockGetTime(CMClockGetHostTimeClock()))
    }
    private func startCamera(id: String) throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.message("Camera permission is required. Grant access before starting the selected camera.")
        }
        guard let device = Self.cameras().first(where: { $0.uniqueID == id }) else {
            throw CameraError.message("The selected camera is disconnected.")
        }
        guard let (format, frameDuration) = CameraCapabilities.selection(for: configuration, device: device) else {
            throw CameraError.message("The selected camera no longer offers \(configuration.label). Choose another available format.")
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
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
        try pin(device, format: format, duration: frameDuration)
        session.startRunning()
        // Session startup applies the preset's hardware timing (24 fps on this BRIO).
        // Pin the selected format and exact supported duration after that completes,
        // before this serial queue can process any capture callbacks.
        try pin(device, format: format, duration: frameDuration)
    }
    private func pin(_ device: AVCaptureDevice, format: AVCaptureDevice.Format, duration: CMTime) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, camera != nil, let image = sampleBuffer.imageBuffer else { return }
        guard CVPixelBufferGetWidth(image) == configuration.width, CVPixelBufferGetHeight(image) == configuration.height else {
            fail(CameraError.message("Camera delivered an unsupported frame size.")); return
        }
        lastFrame = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        do {
            let timestamp = try CaptureFrameTiming.hostTimestamp(sampleBuffer.presentationTimeStamp,
                from: session?.synchronizationClock)
            emit(CIImage(cvPixelBuffer: image), at: timestamp)
        } catch { fail(error) }
    }
    /// Copies the frame so the capture pool is never held by downstream composition.
    private func emit(_ image: CIImage, at time: CMTime) {
        guard running, let pool else { return }
        var allocation: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary, &allocation)
        if status == kCVReturnWouldExceedAllocationThreshold { return }
        guard status == kCVReturnSuccess, let raw = allocation else { fail(CameraError.operation("Allocate frame", status)); return }
        context.render(image, to: raw, bounds: CGRect(x: 0, y: 0, width: configuration.width, height: configuration.height), colorSpace: space)
        onCameraFrame?(raw, time); frame += 1
    }
}
