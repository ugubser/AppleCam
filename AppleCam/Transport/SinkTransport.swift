#if SWIFT_PACKAGE
import AppleCamCore
#endif
import Foundation
import CoreMediaIO

protocol FrameTransport: AnyObject {
    func start() throws
    func send(_ sample: CMSampleBuffer) throws
    func stop()
}

/// All methods run on the producer's serial queue. CMIO owns successfully enqueued retains.
final class SinkTransport: FrameTransport {
    private var device: CMIODeviceID = 0
    private var stream: CMIOStreamID = 0
    private var buffers: CMSimpleQueue?
    private var gate = FrameAdmission()
    private var budget = QueueBudget()
    private(set) var submitted = 0
    private(set) var dropped = 0

    func start() throws {
        guard buffers == nil else { throw CameraError.message("Transport already running") }
        // Public opt-in needed for extension-backed devices in CMIO discovery.
        var allow: UInt32 = 1
        var allowAddress = address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
        try check(CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &allowAddress,
            0, nil, UInt32(MemoryLayout<UInt32>.size), &allow), "Enable extension discovery")
        let devices: [UInt32] = try values(object: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices)
        var match: CMIODeviceID?
        for candidate in devices {
            if try string(object: candidate, selector: kCMIODevicePropertyDeviceUID) == CameraContract.deviceID.uuidString {
                match = candidate; break
            }
        }
        guard let match else { throw CameraError.message("AppleCam camera is not available. Install and approve the extension first.") }
        device = match
        let streams: [UInt32] = try values(object: device, selector: kCMIODevicePropertyStreams)
        var output: CMIOStreamID?
        for candidate in streams {
            let directions: [UInt32] = try values(object: candidate, selector: kCMIOStreamPropertyDirection)
            if directions.first == 0 { output = candidate; break }
        }
        guard let output else { throw CameraError.message("AppleCam input stream was not found.") }
        stream = output
        var queue: Unmanaged<CMSimpleQueue>?
        try check(CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queue), "Open input queue")
        guard let queue else { throw CameraError.message("AppleCam returned no frame queue") }
        buffers = queue.takeRetainedValue()
        do { try check(CMIODeviceStartStream(device, stream), "Start input stream") }
        catch { buffers = nil; throw error }
        gate = FrameAdmission(); budget = QueueBudget(); submitted = 0; dropped = 0
    }
    func send(_ sample: CMSampleBuffer) throws {
        guard let buffers, let image = CMSampleBufferGetImageBuffer(sample) else {
            throw CameraError.message("Transport is stopped or frame has no image")
        }
        guard try gate.shouldSend(timestamp: sample.presentationTimeStamp.seconds,
            now: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
            width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
            isBGRA: CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA) else {
            dropped += 1
            return
        }
        switch budget.decision(depth: Int(CMSimpleQueueGetCount(buffers)), now: CMClockGetTime(CMClockGetHostTimeClock()).seconds) {
        case .enqueue: break
        case .drop: dropped += 1; return
        case .stalled: throw CameraError.message("The camera extension stopped consuming frames. Stop and check its activation status.")
        }
        let retained = Unmanaged.passRetained(sample)
        let status = CMSimpleQueueEnqueue(buffers, element: retained.toOpaque())
        if status != noErr {
            retained.release()
            throw CameraError.operation("Enqueue frame", status)
        }
        submitted += 1
    }
    func stop() {
        guard let buffers else { return }
        CMIODeviceStopStream(device, stream)
        var unused: Unmanaged<CMSimpleQueue>?
        CMIOStreamCopyBufferQueue(stream, nil, nil, &unused)
        _ = unused?.takeRetainedValue()
        // Stop synchronizes the stream before reclaiming any unconsumed producer frames.
        while let item = CMSimpleQueueDequeue(buffers) {
            Unmanaged<CMSampleBuffer>.fromOpaque(item).release()
        }
        self.buffers = nil
        gate = FrameAdmission()
    }
    private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    }
    private func values(object: CMIOObjectID, selector: Int) throws -> [UInt32] {
        var property = address(selector)
        var size: UInt32 = 0
        try check(CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Read property size")
        guard size > 0 else { return [] }
        var result = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        try result.withUnsafeMutableBytes { bytes in
            try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, bytes.baseAddress!), "Read property")
        }
        return result
    }
    private func string(object: CMIOObjectID, selector: Int) throws -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, &value), "Read device identifier")
        return value?.takeRetainedValue() as String?
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CameraError.operation(operation, status) }
    }
}
