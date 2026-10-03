import Foundation

public struct SavedBackground: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

/// Persistent preferences only. Capture and publication are deliberately not serializable.
public struct SavedPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var cameraID = "pattern"
    public var cameraName = "Labelled test pattern (no webcam)"
    public var greenScreen = false
    public var preview = KeyPreview.composite
    public var key = KeySettings()
    public var background: SavedBackground?
    public init() {}
    public func validate() throws {
        guard version == 1 else { throw CameraError.message("Saved settings use an unsupported version.") }
        guard !cameraID.isEmpty, key.isValid, !greenScreen || background != nil else {
            throw CameraError.message("Saved settings are invalid.")
        }
    }
}

/// Small atomic preference writes; imported image bytes are written once, not per slider change.
/// Uses the app's private Application Support directory in its sandbox.
public final class PreferencesStore {
    public let directory: URL
    private var lastBackground: SavedBackground?
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
        lastBackground = settings.background
        return settings
    }
    public func save(_ settings: SavedPreferences) throws {
        try settings.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        let old = lastBackground
        lastBackground = settings.background
        if let old, old.id != settings.background?.id {
            // Cleanup is best effort after the new settings commit; never delete the current image.
            try? FileManager.default.removeItem(at: backgroundURL(old))
        }
    }
    public func importBackground(_ data: Data, name: String, settings: SavedPreferences) throws -> SavedPreferences {
        var next = settings
        let background = SavedBackground(name: name)
        next.background = background
        try next.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = backgroundURL(background)
        try data.write(to: destination, options: .atomic)
        do { try save(next) }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return next
    }
}
