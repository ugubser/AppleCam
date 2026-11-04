#if SWIFT_PACKAGE
import AppleCamCore
#endif
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps the scene-button pictures across launches as small JPEG files in the app's private settings folder.
/// They show the last composed scene, which can include the webcam picture, so they never leave that folder.
final class SceneThumbnailStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    convenience init(preferences: PreferencesStore) {
        self.init(directory: preferences.directory.appendingPathComponent("Scene Thumbnails", isDirectory: true))
    }
    func url(for scene: UUID) -> URL { directory.appendingPathComponent(scene.uuidString).appendingPathExtension("jpg") }

    func save(_ image: CGImage, scene: UUID) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraError.message("Cannot encode the scene picture.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraError.message("Cannot encode the scene picture.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data as Data).write(to: url(for: scene), options: .atomic)
    }
    /// Pictures of the given scenes. Files of scenes that no longer exist, and files that cannot be decoded, are removed.
    func load(scenes: [UUID]) -> [UUID: CGImage] {
        let wanted = Set(scenes)
        var result: [UUID: CGImage] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jpg" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), wanted.contains(id),
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                try? FileManager.default.removeItem(at: file); continue
            }
            result[id] = image
        }
        return result
    }
}
