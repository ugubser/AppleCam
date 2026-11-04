#if SWIFT_PACKAGE
import AppleCamCore
#endif
import AVFoundation
import MediaToolbox

/// Copies a clip's decoded sound into its channel, stamped with the host time at which the player presents it,
/// then silences the player's own output: clips are heard in the mix (and Monitor) only, never through the speakers.
final class ClipAudioTap: @unchecked Sendable {
    let input = ChannelInput()
    fileprivate weak var item: AVPlayerItem?
    fileprivate var format: AVAudioFormat?
    init(item: AVPlayerItem) { self.item = item }

    /// An audio mix that runs this tap on `track`.
    func audioMix(for track: AVAssetTrack) throws -> AVAudioMix {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<ClipAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, description in
                let owner = Unmanaged<ClipAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                owner.format = AVAudioFormat(streamDescription: description)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
                let owner = Unmanaged<ClipAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                owner.deliver(bufferList, frames: Int(framesOut.pointee), itemTime: range.start)
                // Silence local playback after copying.
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<ClipAudioTap>.fromOpaque(callbacks.clientInfo!).release()
            throw CameraError.operation("Open the clip's sound", status)
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
        return mix
    }
    fileprivate func deliver(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, itemTime: CMTime) {
        // Before the player has a timebase there is no presentation time; such buffers are not part of the mix.
        guard frames > 0, input.isAttached, let format, let timebase = item?.timebase, itemTime.isNumeric,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let host = CMSyncConvertTime(itemTime, from: timebase, to: CMClockGetHostTimeClock())
        guard host.isNumeric else { return }
        input.write(buffer, hostTime: host.seconds)
    }
}
