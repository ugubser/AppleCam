import Foundation

/// Where recordings go. The folder is kept as a security-scoped bookmark chosen by the person in an open panel.
public struct RecordingPreferences: Codable, Equatable, Sendable {
    public var folderBookmark: Data?
    /// The folder's name for display; the bookmark is the authority.
    public var folderName: String?
    public init() {}
}

public enum RecordingPolicy {
    /// HEVC bit rate: about 10 Mbit/s at 1920 × 1080 30 fps, scaled sub-linearly with pixels and frame rate
    /// (encoders gain efficiency at higher resolution and rate), kept between 2 and 120 Mbit/s.
    public static func videoBitRate(width: Int, height: Int, fps: Double) -> Int {
        let pixels = Double(width * height) / (1920 * 1080)
        let rate = 10_000_000 * pow(pixels, 0.75) * pow(max(fps, 1) / 30, 0.6)
        return Int(min(max(rate, 2_000_000), 120_000_000).rounded())
    }
    public static let mixBitRate = 256_000
    public static let channelBitRate = 192_000
    /// Bytes per second of the finished file, for the free-space margin and the size estimate.
    public static func bytesPerSecond(width: Int, height: Int, fps: Double, audioTracks: Int) -> Double {
        let audio = audioTracks > 0 ? Double(mixBitRate + (audioTracks - 1) * channelBitRate) : 0
        return (Double(videoBitRate(width: width, height: height, fps: fps)) + audio) / 8
    }
    /// Recording stops before the disk fills: at least 2 GB, or two minutes of recording, must stay free.
    public static func minimumFreeBytes(bytesPerSecond: Double) -> Int64 { max(2_000_000_000, Int64(bytesPerSecond * 120)) }
    /// "AppleCam 2026-11-04 at 10.52.31.mov", with " 2", " 3" … when that name exists.
    public static func fileName(at date: Date, timeZone: TimeZone = .current, exists: (String) -> Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "AppleCam \(formatter.string(from: date))"
        var name = base + ".mov", n = 2
        while exists(name) { name = "\(base) \(n).mov"; n += 1 }
        return name
    }
    /// "1:02:03" or "2:03".
    public static func durationLabel(_ seconds: Double) -> String {
        let s = max(0, Int(seconds)), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
