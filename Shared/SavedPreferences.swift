import Foundation

public struct SavedBackground: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct CameraProfile: Codable, Equatable, Sendable {
    public var cameraName = "Saved camera"
    public var greenScreen = false
    public var preview = KeyPreview.composite
    public var key = KeySettings()
    public var background: SavedBackground?
    public var backgrounds: [SavedBackground?] = Array(repeating: nil, count: 4)
    public var controlsExpanded = true
    public var capture: CaptureConfiguration?
    public init() {}
    public var isValid: Bool {
        key.isValid && (!greenScreen || background != nil) && backgrounds.count == 4 && (capture?.isValid ?? true)
    }
    public var imageReferences: Set<SavedBackground> { Set(backgrounds.compactMap { $0 } + [background].compactMap { $0 }) }
}

/// Preferences per physical camera identifier. Running/capture/publication state is never serialized.
public struct SavedPreferences: Codable, Equatable, Sendable {
    public var version = 2
    public var cameraID = "pattern"
    public var profiles: [String: CameraProfile] = [:]
    public init() {}
    public var profile: CameraProfile {
        get { profiles[cameraID] ?? CameraProfile() }
        set { profiles[cameraID] = newValue }
    }
    // Accessors keep the active-profile API explicit for callers and migrate the original settings format.
    public var cameraName: String { get { profile.cameraName } set { profile.cameraName = newValue } }
    public var greenScreen: Bool { get { profile.greenScreen } set { profile.greenScreen = newValue } }
    public var preview: KeyPreview { get { profile.preview } set { profile.preview = newValue } }
    public var key: KeySettings { get { profile.key } set { profile.key = newValue } }
    public var background: SavedBackground? { get { profile.background } set { profile.background = newValue } }
    public var imageReferences: Set<SavedBackground> { profiles.values.reduce(into: []) { $0.formUnion($1.imageReferences) } }
    public func validate() throws {
        guard version == 2 else { throw CameraError.message("Saved settings use an unsupported version.") }
        guard !cameraID.isEmpty, profiles.keys.allSatisfy({ !$0.isEmpty }), profiles.values.allSatisfy(\.isValid) else {
            throw CameraError.message("Saved settings are invalid.")
        }
    }
    private enum CodingKeys: String, CodingKey { case version, cameraID, profiles, cameraName, greenScreen, preview, key, background }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .version)
        cameraID = try c.decode(String.self, forKey: .cameraID)
        switch schema {
        case 1:
            var migrated = CameraProfile()
            migrated.cameraName = try c.decode(String.self, forKey: .cameraName)
            migrated.greenScreen = try c.decode(Bool.self, forKey: .greenScreen)
            migrated.preview = try c.decode(KeyPreview.self, forKey: .preview)
            migrated.key = try c.decode(KeySettings.self, forKey: .key)
            migrated.background = try c.decodeIfPresent(SavedBackground.self, forKey: .background)
            migrated.backgrounds[0] = migrated.background
            migrated.capture = CaptureConfiguration()
            profiles = [cameraID: migrated]
        case 2: profiles = try c.decode([String: CameraProfile].self, forKey: .profiles)
        default: throw CameraError.message("Saved settings use an unsupported version.")
        }
        version = 2
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(cameraID, forKey: .cameraID)
        try c.encode(profiles, forKey: .profiles)
    }
}

public final class PreferencesStore {
    public let directory: URL
    private var lastImages = Set<SavedBackground>()
    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AppleCam", isDirectory: true)) { self.directory = directory }
    public var settingsURL: URL { directory.appendingPathComponent("preferences.json") }
    public func backgroundURL(_ background: SavedBackground) -> URL {
        directory.appendingPathComponent(background.id.uuidString).appendingPathExtension("image")
    }
    public func load() throws -> SavedPreferences? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let settings = try JSONDecoder().decode(SavedPreferences.self, from: Data(contentsOf: settingsURL))
        try settings.validate()
        lastImages = settings.imageReferences
        return settings
    }
    public func save(_ settings: SavedPreferences) throws {
        try settings.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        let old = lastImages; lastImages = settings.imageReferences
        for image in old where !lastImages.contains(where: { $0.id == image.id }) {
            try? FileManager.default.removeItem(at: backgroundURL(image))
        }
    }
    public func importBackground(_ data: Data, name: String, settings: SavedPreferences, slot: Int? = nil) throws -> SavedPreferences {
        var next = settings
        let background = SavedBackground(name: name)
        if let slot {
            guard (0..<4).contains(slot) else { throw CameraError.message("Invalid background button.") }
            next.profile.backgrounds[slot] = background
        }
        next.background = background
        try next.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = backgroundURL(background)
        try data.write(to: destination, options: .atomic)
        do { try save(next) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return next
    }
}
