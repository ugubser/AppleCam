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
    /// No longer shown in the interface (v0.3 uses an inspector). Kept so v0.2 can still read these settings.
    public var controlsExpanded = true
    public var capture: CaptureConfiguration?
    /// Optional so settings written before version 0.5 still decode.
    public var backgroundMask: BackgroundMaskProfile?
    public init() {}
    public var mask: BackgroundMaskProfile { get { backgroundMask ?? BackgroundMaskProfile() } set { backgroundMask = newValue } }
    public var isValid: Bool {
        key.isValid && backgrounds.count == 4 && (capture?.isValid ?? true) && mask.isValid && !(greenScreen && mask.enabled)
    }
    public var imageReferences: Set<SavedBackground> { Set(backgrounds.compactMap { $0 } + [background].compactMap { $0 }) }
}

/// Preferences per physical camera identifier. Running/capture/publication state is never serialized.
public struct SavedPreferences: Codable, Equatable, Sendable {
    public var version = 3
    public var cameraID = "pattern"
    public var profiles: [String: CameraProfile] = [:]
    public var scenes = CameraScene.defaults()
    public var selectedScene = 0
    public var output = CaptureConfiguration()
    public var audio = AudioPreferences()
    public var recording = RecordingPreferences()
    /// Every private file the settings refer to: scene media and each camera's background picture.
    public var mediaReferences: Set<MediaAsset> {
        Set(scenes.flatMap(\.layers).compactMap { $0.source.asset } + profiles.values.compactMap { $0.mask.plate?.asset })
    }
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
        guard version == 3 else { throw CameraError.message("Saved settings use an unsupported version.") }
        guard scenes.count == 4, scenes.allSatisfy(\.isValid), (0..<4).contains(selectedScene), output.isValid, audio.isValid,
              Set(scenes.map(\.id)).count == 4,
              Set(scenes.flatMap(\.layers).map(\.id)).count == scenes.flatMap(\.layers).count,
              !cameraID.isEmpty, profiles.keys.allSatisfy({ !$0.isEmpty }), profiles.values.allSatisfy(\.isValid) else {
            throw CameraError.message("Saved settings are invalid.")
        }
    }
    private enum CodingKeys: String, CodingKey { case version, cameraID, profiles, cameraName, greenScreen, preview, key, background, scenes, selectedScene, output, audio, recording }
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
        case 2, 3: profiles = try c.decode([String: CameraProfile].self, forKey: .profiles)
        default: throw CameraError.message("Saved settings use an unsupported version.")
        }
        if schema == 3 {
            scenes = try c.decode([CameraScene].self, forKey: .scenes)
            selectedScene = try c.decode(Int.self, forKey: .selectedScene)
            output = try c.decode(CaptureConfiguration.self, forKey: .output)
        } else {
            guard profiles.values.allSatisfy({ $0.isValid && (!$0.greenScreen || $0.background != nil) }) else {
                throw CameraError.message("Legacy camera settings are invalid.")
            }
            migrateScenes()
        }
        // Added in build 22; absent in earlier version-3 files.
        audio = try c.decodeIfPresent(AudioPreferences.self, forKey: .audio) ?? AudioPreferences()
        recording = try c.decodeIfPresent(RecordingPreferences.self, forKey: .recording) ?? RecordingPreferences()
        version = 3
        try validate()
    }
    private mutating func migrateScenes() {
        scenes = CameraScene.defaults()
        output = profile.capture ?? CaptureConfiguration()
        let active = profile
        for slot in 0..<4 {
            if let image = active.backgrounds[slot] {
                let asset = MediaAsset(id: image.id, name: image.name, fileExtension: "image")
                scenes[slot].layers.append(SceneLayer(name: image.name, source: .image(asset)))
            }
        }
        if let image = active.background {
            if let slot = active.backgrounds.firstIndex(where: { $0?.id == image.id }) { selectedScene = slot }
            else {
                // The active image may never have occupied a button. Preserve it in Scene 1.
                let asset = MediaAsset(id: image.id, name: image.name, fileExtension: "image")
                for i in scenes[0].layers.indices where scenes[0].layers[i].source.asset != nil { scenes[0].layers[i].visible = false }
                scenes[0].layers.insert(SceneLayer(name: image.name, source: .image(asset)), at: 1)
            }
        }
        // Preserve other camera backgrounds as named, hidden layers in the shared scenes.
        var retained = Set(scenes.flatMap(\.layers).compactMap { $0.source.asset?.id })
        for camera in profiles.keys.sorted() {
            guard let old = profiles[camera] else { continue }
            let images = old.backgrounds.enumerated().compactMap { index, image in image.map { (index, $0) } } +
                (old.background.map { [(0, $0)] } ?? [])
            for (slot, image) in images where retained.insert(image.id).inserted {
                var layer = SceneLayer(name: "\(old.cameraName): \(image.name)", source: .image(MediaAsset(id: image.id, name: image.name, fileExtension: "image")))
                layer.visible = false; scenes[slot].layers.append(layer)
            }
        }
        // Assets are now owned by scenes, not the retired camera buttons.
        for camera in Array(profiles.keys) { profiles[camera]?.background = nil; profiles[camera]?.backgrounds = Array(repeating: nil, count: 4) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(cameraID, forKey: .cameraID)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(scenes, forKey: .scenes); try c.encode(selectedScene, forKey: .selectedScene)
        try c.encode(output, forKey: .output)
        try c.encode(audio, forKey: .audio); try c.encode(recording, forKey: .recording)
    }
}

public final class PreferencesStore {
    public let directory: URL
    private var lastImages = Set<SavedBackground>()
    private var lastMedia = Set<MediaAsset>()
    private var pendingRemoval = Set<MediaAsset>()
    /// The pre-upgrade backup check reads the file once per store, not on every save.
    private var legacyBackupChecked = false
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
        lastMedia = settings.mediaReferences
        return settings
    }
    public func save(_ settings: SavedPreferences, deferCleanup: Bool = false) throws {
        try settings.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Preserve the exact pre-upgrade document before the first schema-3 commit.
        if !legacyBackupChecked, FileManager.default.fileExists(atPath: settingsURL.path),
           let data = try? Data(contentsOf: settingsURL),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let schema = object["version"] as? Int, schema < 3 {
            let backup = directory.appendingPathComponent("preferences-v\(schema)-before-scenes.json")
            if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: settingsURL, to: backup) }
        }
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        legacyBackupChecked = true
        let old = lastImages; lastImages = settings.imageReferences
        for image in old where !lastImages.contains(where: { $0.id == image.id }) {
            pendingRemoval.insert(MediaAsset(id: image.id, name: image.name, fileExtension: "image"))
        }
        let oldMedia = lastMedia; lastMedia = settings.mediaReferences
        pendingRemoval.formUnion(oldMedia.subtracting(lastMedia))
        if !deferCleanup { cleanupUnusedMedia() }
    }
    /// The scene controller calls this only after old source readers have been detached.
    public func cleanupUnusedMedia() {
        for asset in pendingRemoval where !lastMedia.contains(where: { $0.id == asset.id }) && !lastImages.contains(where: { $0.id == asset.id }) {
            try? FileManager.default.removeItem(at: mediaURL(asset))
        }
        pendingRemoval.removeAll()
    }

    public func mediaURL(_ asset: MediaAsset) -> URL {
        directory.appendingPathComponent(asset.id.uuidString).appendingPathExtension(asset.fileExtension)
    }
    /// Copies large clips without reading the complete movie into memory. Caller validates decoding first.
    public func importMedia(from source: URL, asset: MediaAsset, settings: SavedPreferences, deferCleanup: Bool = false) throws {
        guard asset.isValid, settings.mediaReferences.contains(asset) else { throw CameraError.message("Invalid media import.") }
        try settings.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = mediaURL(asset)
        try FileManager.default.copyItem(at: source, to: destination)
        do { try save(settings, deferCleanup: deferCleanup) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    /// Writes a new background picture and the settings that refer to it; the replaced picture is removed by cleanup.
    public func importPlate(_ data: Data, plate: BackgroundPlate, settings: SavedPreferences, deferCleanup: Bool = false) throws {
        guard plate.isValid, settings.mediaReferences.contains(plate.asset) else { throw CameraError.message("Invalid background picture.") }
        try settings.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = mediaURL(plate.asset)
        try data.write(to: destination, options: .atomic)
        do { try save(settings, deferCleanup: deferCleanup) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
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
