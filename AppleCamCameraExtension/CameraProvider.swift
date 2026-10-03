import Foundation
import AVFoundation
import CoreMediaIO
import IOKit.audio
import os
import Security

final class CameraProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let camera: CameraDevice
    init(queue: DispatchQueue) throws {
        camera = try CameraDevice(queue: queue)
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: queue)
        try provider.addDevice(camera.device)
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        result.manufacturer = "AppleCam"
        return result
    }
    func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) { camera.disconnect(client) }
}

final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStream!
    private var sink: CameraStream!
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var producer: CMIOExtensionClient?
    private var consuming = false
    private var generation = 0
    private var readers = 0
    private var gate = FrameGate()
    private var converter: VideoOutputConverter!
    private var cadence = OutputCadence()
    private var consumedFrames = 0
    private var sentFrames = 0
    private var emptyReads = 0
    private var missingImages = 0
    private var rejectedFrames = 0
    private var lastDiagnosticTime: Double = 0
    private let log = Logger(subsystem: CameraContract.extensionBundleID, category: "transport")

    init(queue: DispatchQueue) throws {
        self.queue = queue
        super.init()
        device = CMIOExtensionDevice(localizedName: CameraContract.name,
                                     deviceID: CameraContract.deviceID,
                                     legacyDeviceID: CameraContract.deviceID.uuidString, source: self)
        converter = try VideoOutputConverter()
        // Advertise standard meeting formats plus every resolution of cameras currently attached.
        // CMIO requires this list to remain stable for the lifetime of the stream.
        var sizes = Set(["1920x1080", "1280x720", "3840x2160", "4096x2160", "2560x1440", "640x480", "640x360", "320x240", "800x600", "1024x768", "1280x960", "1600x1200", "1920x1200", "5120x2880", "7680x4320"])
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        for camera in devices where camera.uniqueID != CameraContract.deviceID.uuidString {
            for format in camera.formats {
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if size.width > 0 && size.height > 0 && size.width <= 16384 && size.height <= 16384 { sizes.insert("\(size.width)x\(size.height)") }
            }
        }
        let ordered = ["1920x1080"] + sizes.filter { $0 != "1920x1080" }.sorted()
        let formats = try ordered.map { size -> CMIOExtensionStreamFormat in
            let dimensions = size.split(separator: "x").map { Int32($0)! }
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_32BGRA,
                width: dimensions[0], height: dimensions[1], extensions: nil, formatDescriptionOut: &description)
            guard status == noErr, let description else { throw CameraError.operation("Video format", status) }
            return CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: CMTime(value: 1, timescale: 1),
                minFrameDuration: CMTime(value: 1, timescale: 1000), validFrameDurations: nil)
        }
        source = CameraStream(owner: self, direction: .source, formats: formats)
        sink = CameraStream(owner: self, direction: .sink, formats: formats)
        try device.addStream(source.stream)
        try device.addStream(sink.stream)
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        result.transportType = kIOAudioDeviceTransportTypeVirtual
        result.model = "AppleCam"
        return result
    }
    func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
    func authorize(_ client: CMIOExtensionClient) -> Bool {
        // One producer per session; browser clients use the source stream.
        // CMIO reports "unknown" here for our notarized host on macOS 27.
        // Authenticate the actual process with Security.framework instead; the
        // requirement below enforces BOTH the host identifier and signing team.
        guard let team = Bundle.main.object(forInfoDictionaryKey: "AppleCamTeamIdentifier") as? String,
              !team.isEmpty else { log.error("Producer rejected: missing configured team"); return false }
        var code: SecCode?
        // Use kernel-backed signing information: the extension sandbox cannot
        // read the producer's app bundle. Keep the same full signing requirement.
        let guestStatus = SecCodeCopyGuestWithAttributes(nil,
            [kSecGuestAttributePid: client.pid, kSecGuestAttributeDynamicCode: true] as CFDictionary, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            log.error("Producer rejected: code lookup status \(guestStatus, privacy: .public)")
            return false
        }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(CameraContract.hostBundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        let ruleStatus = SecRequirementCreateWithString(rule as CFString, [], &requirement)
        guard ruleStatus == errSecSuccess else { log.error("Producer rejected: requirement status \(ruleStatus, privacy: .public)"); return false }
        let signatureStatus = SecCodeCheckValidity(code, [], requirement)
        guard signatureStatus == errSecSuccess else { log.error("Producer rejected: signature status \(signatureStatus, privacy: .public)"); return false }
        guard producer == nil || producer == client else { log.error("Producer rejected: another producer owns the stream"); return false }
        producer = client
        log.info("Producer signature verified")
        return true
    }
    func start(_ direction: CMIOExtensionStream.Direction) throws {
        if direction == .source {
            readers += 1
            log.notice("Receiver started; readers=\(self.readers)")
            return
        }
        guard producer != nil, timer == nil else { throw CameraError.message("No producer, or sink already started") }
        generation += 1
        gate = FrameGate(width: sink.configuration.width, height: sink.configuration.height)
        cadence = OutputCadence()
        consumedFrames = 0; sentFrames = 0; emptyReads = 0
        missingImages = 0; rejectedFrames = 0; lastDiagnosticTime = 0
        log.notice("Producer stream started")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / sink.configuration.fps)))
        timer.setEventHandler { [weak self] in self?.consume() }
        self.timer = timer
        timer.resume()
    }
    func stop(_ direction: CMIOExtensionStream.Direction) {
        if direction == .source {
            readers = max(0, readers - 1)
            log.notice("Receiver stopped; readers=\(self.readers)")
            return
        }
        log.notice("Producer stopped; consumed=\(self.consumedFrames) sent=\(self.sentFrames)")
        generation += 1
        timer?.cancel(); timer = nil
        producer = nil; consuming = false
        gate = FrameGate()
    }
    func configure(_ stream: CameraStream, index: Int?, duration: CMTime?) throws {
        let nextIndex = index ?? stream.activeIndex
        guard stream.formats.indices.contains(nextIndex) else { throw CameraError.message("Unsupported virtual-camera resolution.") }
        let nextDuration = duration ?? stream.duration
        guard nextDuration.isNumeric, nextDuration.seconds >= 0.001, nextDuration.seconds <= 1 else {
            throw CameraError.message("Unsupported virtual-camera frame rate.")
        }
        if stream === sink, timer != nil { throw CameraError.message("Stop sending before changing the virtual-camera format.") }
        stream.activeIndex = nextIndex; stream.duration = nextDuration
        stream.notifyFormat()
        if stream === sink && readers == 0 {
            source.activeIndex = nextIndex; source.duration = nextDuration; source.notifyFormat()
        }
        cadence = OutputCadence()
    }
    func disconnect(_ client: CMIOExtensionClient) {
        if producer == client { stop(.sink) }
    }
    private func consume() {
        let diagnosticTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if diagnosticTime - lastDiagnosticTime >= 5 {
            lastDiagnosticTime = diagnosticTime
            log.notice("Transport readers=\(self.readers) pending=\(self.consuming) producer=\(self.producer != nil) consumed=\(self.consumedFrames) sent=\(self.sentFrames) empty=\(self.emptyReads) missingImage=\(self.missingImages) rejected=\(self.rejectedFrames)")
        }
        guard !consuming, let producer, timer != nil else { return }
        consuming = true
        let epoch = generation
        sink.stream.consumeSampleBuffer(from: producer) { [weak self] buffer, sequence, flags, _, error in
            guard let self else { return }
            self.queue.async {
                guard epoch == self.generation else { return }
                self.consuming = false
                if let error {
                    self.log.error("Sink stopped: \(error.localizedDescription, privacy: .public)")
                    self.stop(.sink)
                    return
                }
                guard let buffer else { self.emptyReads += 1; return }
                self.consumedFrames += 1
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let nanos = UInt64(now.seconds * 1_000_000_000)
                // Acknowledge consumption even when a stale/malformed frame is discarded.
                self.sink.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(
                    sequenceNumber: sequence, hostTimeInNanoseconds: nanos))
                guard let image = CMSampleBufferGetImageBuffer(buffer) else { self.missingImages += 1; return }
                do {
                    try self.gate.accept(timestamp: buffer.presentationTimeStamp.seconds, now: now.seconds,
                        width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                        isBGRA: CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA)
                } catch {
                    self.rejectedFrames += 1
                    if self.rejectedFrames == 1 {
                        self.log.error("Rejected frame: \(String(describing: error), privacy: .public); pts=\(buffer.presentationTimeStamp.seconds) now=\(now.seconds)")
                    }
                    return
                }
                guard self.readers > 0, self.cadence.shouldEmit(timestamp: buffer.presentationTimeStamp.seconds,
                    inputFPS: self.sink.configuration.fps, outputFPS: self.source.configuration.fps) else { return }
                do {
                    let converted = try self.converter.convert(buffer, to: self.source.configuration)
                    self.source.stream.send(converted, discontinuity: flags, hostTimeInNanoseconds: nanos)
                    self.sentFrames += 1
                } catch {
                    self.log.error("Output conversion stopped: \(error.localizedDescription, privacy: .public)")
                    self.stop(.sink)
                }
            }
        }
    }
}

final class CameraStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let owner: CameraDevice
    private let direction: CMIOExtensionStream.Direction
    let formats: [CMIOExtensionStreamFormat]
    var activeIndex = 0
    var duration = CMTime(value: 1, timescale: 30)
    var configuration: CaptureConfiguration {
        let size = CMVideoFormatDescriptionGetDimensions(formats[activeIndex].formatDescription)
        return CaptureConfiguration(width: Int(size.width), height: Int(size.height), fps: 1 / duration.seconds)
    }
    func notifyFormat() {
        stream.notifyPropertiesChanged([.streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(value: NSNumber(value: activeIndex)),
            .streamFrameDuration: CMIOExtensionPropertyState<AnyObject>(value: CMTimeCopyAsDictionary(duration, allocator: nil)!)])
    }
    init(owner: CameraDevice, direction: CMIOExtensionStream.Direction, formats: [CMIOExtensionStreamFormat]) {
        self.owner = owner; self.direction = direction; self.formats = formats
        super.init()
        stream = CMIOExtensionStream(localizedName: direction == .source ? "AppleCam Video" : "AppleCam Input",
            streamID: direction == .source ? CameraContract.sourceID : CameraContract.sinkID,
            direction: direction, clockType: .hostTime, source: self)
    }
    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink { properties.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]) }
        return properties
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        result.activeFormatIndex = activeIndex
        result.frameDuration = duration
        if direction == .sink {
            result.sinkBufferQueueSize = CameraContract.queueCapacity
            result.sinkBuffersRequiredForStartup = 1
        }
        return result
    }
    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        try owner.configure(self, index: properties.activeFormatIndex, duration: properties.frameDuration)
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        direction == .source || owner.authorize(client)
    }
    func startStream() throws { try owner.start(direction) }
    func stopStream() throws { owner.stop(direction) }
}
