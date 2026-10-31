import Foundation
import AVFoundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32,
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
writer.add(input)
guard writer.startWriting() else { throw writer.error! }
writer.startSession(atSourceTime: .zero)
for index in 0..<60 {
    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
    var optional: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &optional) == kCVReturnSuccess, let buffer = optional else { fatalError("Synthetic frame allocation failed") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<32 { for x in 0..<64 {
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        base[offset] = (index / 15).isMultiple(of: 2) ? 0 : 255
        base[offset + 1] = 0; base[offset + 2] = (index / 15).isMultiple(of: 2) ? 255 : 0; base[offset + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw writer.error! }
}
input.markAsFinished(); await writer.finishWriting()
guard writer.status == .completed else { throw writer.error! }
print("Generated two-second red/blue test movie.")
