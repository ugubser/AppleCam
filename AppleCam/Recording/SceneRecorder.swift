#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AVFoundation

/// Writes the composed canvas (HEVC) and the audio mix plus one track per channel (AAC) to a QuickTime movie.
/// Video is appended on the scene output queue and audio on the mixer queue; each input has a single writer thread.
/// The movie is written in fragments, so a crash keeps everything up to the last couple of seconds.
final class SceneRecorder: @unchecked Sendable {
    let url: URL
    let configuration: CaptureConfiguration
    let trackNames: [String]
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: [AVAssetWriterInput]
    private let audioFormat: CMAudioFormatDescription
    private let lock = NSLock()
    private var started: CMTime?
    private var stopAt: CMTime?
    private var finishing = false
    private var videoBusySince: Double?
    private var audioBusySince: Double?
    private(set) var videoFrames = 0
    private(set) var audioFrames: Int64 = 0
    /// A writer that cannot accept media for this long is too slow for real time; recording stops with an explanation.
    static let stallLimit: Double = 2

    /// `audioTracks` names the mix first, then each recorded channel; empty records video only.
    init(url: URL, configuration: CaptureConfiguration, audioTracks: [String]) throws {
        guard configuration.isValid else { throw CameraError.message("The canvas format is invalid; recording cannot start.") }
        self.url = url; self.configuration = configuration; trackNames = audioTracks
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: configuration.width, AVVideoHeightKey: configuration.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingPolicy.videoBitRate(width: configuration.width, height: configuration.height, fps: configuration.fps),
                AVVideoExpectedSourceFrameRateKey: configuration.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                // No reordering: the encoder holds fewer canvas buffers and the file stays decodable to the last fragment.
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else { throw CameraError.message("This Mac cannot record HEVC video at \(configuration.label).") }
        writer.add(video)
        var asbd = AudioStreamBasicDescription(mSampleRate: AudioFormat.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw CameraError.operation("Describe recording audio", status) }
        audioFormat = format
        var inputs: [AVAssetWriterInput] = []
        for (index, name) in audioTracks.enumerated() {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioFormat.sampleRate, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: index == 0 ? RecordingPolicy.mixBitRate : RecordingPolicy.channelBitRate])
            input.expectsMediaDataInRealTime = true
            // Players play every enabled audio track at once; only the mix is enabled. Editors import all tracks.
            input.marksOutputTrackAsEnabled = index == 0
            let title = AVMutableMetadataItem()
            title.identifier = .quickTimeUserDataTrackName; title.value = name as NSString
            input.metadata = [title]
            guard writer.canAdd(input) else { throw CameraError.message("Cannot add the audio track “\(name)” to the recording.") }
            writer.add(input); inputs.append(input)
        }
        audio = inputs
        guard writer.startWriting() else {
            throw writer.error ?? CameraError.message("The recording file could not be created.")
        }
    }
    private func check() throws {
        if writer.status == .failed { throw writer.error ?? CameraError.message("The recording could not be written.") }
    }
    /// Appends one canvas frame. The first frame starts the movie's timeline.
    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        guard stopAt == nil, !finishing else { return }
        try check()
        if started == nil { writer.startSession(atSourceTime: time); started = time }
        guard video.isReadyForMoreMediaData else {
            let now = ProcessInfo.processInfo.systemUptime
            if let since = videoBusySince, now - since > Self.stallLimit {
                throw CameraError.message("The video encoder cannot keep up with \(configuration.label). Recording stopped; choose a smaller canvas or frame rate.")
            }
            if videoBusySince == nil { videoBusySince = now }
            return
        }
        videoBusySince = nil
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? CameraError.message("A video frame could not be written to the recording.")
        }
        videoFrames += 1
    }
    /// Appends one block per audio track (interleaved stereo float, `frames` long) starting at `time`.
    /// Blocks before the first video frame or after the stop time are not part of the movie.
    func appendAudio(_ tracks: [UnsafeBufferPointer<Float>], frames: Int, at time: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        guard let started, !finishing, tracks.count == audio.count, frames > 0 else { return }
        if time < started { return }
        if let stopAt, time >= stopAt { return }
        try check()
        guard audio.allSatisfy(\.isReadyForMoreMediaData) else {
            let now = ProcessInfo.processInfo.systemUptime
            if let since = audioBusySince, now - since > Self.stallLimit {
                throw CameraError.message("The audio encoder cannot keep up. Recording stopped.")
            }
            if audioBusySince == nil { audioBusySince = now }
            return
        }
        audioBusySince = nil
        for (input, samples) in zip(audio, tracks) {
            let sample = try Self.sampleBuffer(samples, frames: frames, at: time, format: audioFormat)
            guard input.append(sample) else { throw writer.error ?? CameraError.message("Audio could not be written to the recording.") }
        }
        audioFrames += Int64(frames)
    }
    /// Ends the movie at `end`. Audio runs `AudioFormat.latency` behind video, so the writer waits for it before closing.
    /// Calls `completion` once with nil when the file is complete.
    func finish(at end: CMTime, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        guard stopAt == nil else { lock.unlock(); return }
        stopAt = end
        let hasVideo = started != nil
        lock.unlock()
        guard hasVideo else {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: url)
            completion(CameraError.message("The recording stopped before the first frame, so no file was kept.")); return
        }
        let wait = audio.isEmpty ? 0 : AudioFormat.latency + 0.15
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) { [self] in
            lock.lock(); finishing = true; lock.unlock()
            video.markAsFinished(); audio.forEach { $0.markAsFinished() }
            writer.endSession(atSourceTime: end)
            writer.finishWriting { [self] in
                completion(writer.status == .completed ? nil : (writer.error ?? CameraError.message("The recording could not be completed.")))
            }
        }
    }
    var bytesWritten: Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }

    static func sampleBuffer(_ samples: UnsafeBufferPointer<Float>, frames: Int, at time: CMTime, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let bytes = frames * 8
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block, let base = samples.baseAddress else { throw CameraError.operation("Allocate recording audio", status) }
        status = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        guard status == noErr else { throw CameraError.operation("Copy recording audio", status) }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CameraError.operation("Package recording audio", status) }
        return sample
    }
}
