import AVFoundation
// Microphone level at the given frequencies every 0.5 s: "<seconds since 1970> <dB> <dB> …", for `seconds` seconds.
let arguments = CommandLine.arguments
let seconds = Double(arguments[1])!, frequencies = arguments.dropFirst(2).compactMap(Double.init)
let engine = AVAudioEngine(), input = engine.inputNode, format = input.outputFormat(forBus: 0)
var collected: [Float] = [], last = Date()
func level(_ samples: [Float], _ f: Double) -> Double {
    let w = 2 * Double.pi * f / format.sampleRate, c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
    for x in samples { let s0 = Double(x) + c * s1 - s2; s2 = s1; s1 = s0 }
    let a = 2 * sqrt(max(s1 * s1 + s2 * s2 - c * s1 * s2, 0)) / Double(max(samples.count, 1))
    return a > 1e-7 ? 20 * log10(a) : -140
}
input.installTap(onBus: 0, bufferSize: 4800, format: format) { buffer, _ in
    collected += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    guard Date().timeIntervalSince(last) >= 0.5 else { return }
    print(([String(format: "%.2f", Date().timeIntervalSince1970)] + frequencies.map { String(format: "%.1f", level(collected, $0)) }).joined(separator: " "))
    fflush(stdout); collected = []; last = Date()
}
try! engine.start(); RunLoop.main.run(until: Date().addingTimeInterval(seconds))
