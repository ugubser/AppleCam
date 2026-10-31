import Foundation
import CoreGraphics

public struct MediaAsset: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var fileExtension: String
    public init(id: UUID = UUID(), name: String, fileExtension: String) {
        self.id = id; self.name = name; self.fileExtension = fileExtension
    }
    public var isValid: Bool {
        !name.isEmpty && !fileExtension.isEmpty && fileExtension.count <= 16 &&
        fileExtension.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}

public struct WindowReference: Codable, Equatable, Sendable {
    public var windowID: UInt32
    public var processID: Int32
    public var applicationID: String
    public var launchTime: Double
    public var title: String
    public init(windowID: UInt32, processID: Int32, applicationID: String, launchTime: Double, title: String) {
        self.windowID = windowID; self.processID = processID; self.applicationID = applicationID
        self.launchTime = launchTime; self.title = title
    }
    public func identifiesSameWindow(as other: WindowReference) -> Bool {
        windowID == other.windowID && processID == other.processID && applicationID == other.applicationID && launchTime == other.launchTime
    }
}

public struct DisplayReference: Codable, Equatable, Sendable {
    public var uuid: String
    public var name: String
    public init(uuid: String, name: String) { self.uuid = uuid; self.name = name }
}

public struct BrowserSettings: Codable, Equatable, Sendable {
    public var url: String
    public var width: Int = 1280
    public var height: Int = 720
    public init(url: String = "https://www.youtube.com/") { self.url = url }
    public var isValid: Bool {
        guard let u = URL(string: url), ["https", "http"].contains(u.scheme?.lowercased() ?? ""),
              u.host != nil, u.user == nil, u.password == nil else { return false }
        return (200...4096).contains(width) && (200...4096).contains(height)
    }
}

public enum LayerSource: Codable, Equatable, Sendable {
    case camera
    case image(MediaAsset)
    case clip(MediaAsset)
    case browser(BrowserSettings)
    case window(WindowReference?)
    case display(DisplayReference?)
    public var label: String {
        switch self {
        case .camera: return "Webcam"
        case .image: return "Image"
        case .clip: return "Video clip"
        case .browser: return "Browser"
        case .window: return "Window"
        case .display: return "Screen"
        }
    }
    public var asset: MediaAsset? {
        switch self { case .image(let a), .clip(let a): return a; default: return nil }
    }
    public var isValid: Bool {
        switch self {
        case .image(let a), .clip(let a): return a.isValid
        case .browser(let b): return b.isValid
        case .window(let w): return w == nil || (w!.windowID > 0 && w!.processID > 0 && w!.launchTime.isFinite)
        case .display(let d): return d == nil || UUID(uuidString: d!.uuid) != nil
        case .camera: return true
        }
    }
}

public enum LayerSizing: String, Codable, CaseIterable, Sendable { case fit = "Fit", fill = "Fill" }

/// Normalized, top-left canvas coordinates. The rectangle is a viewport; Fill crops inside it.
public struct LayerPlacement: Codable, Equatable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    public var width: Double = 1
    public var height: Double = 1
    public var sizing = LayerSizing.fill
    public var aspectLocked = true
    public init() {}
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && abs(x) <= 10 && abs(y) <= 10 &&
        (0.001...10).contains(width) && (0.001...10).contains(height)
    }
    public func viewport(canvas: CGSize) -> CGRect {
        CGRect(x: x * canvas.width, y: y * canvas.height, width: width * canvas.width, height: height * canvas.height)
    }
    public func contentRect(source: CGSize, canvas: CGSize) -> CGRect {
        let box = viewport(canvas: canvas)
        let scale = sizing == .fill ? max(box.width / source.width, box.height / source.height) :
            min(box.width / source.width, box.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }
    public func sourcePoint(canvasPoint: CGPoint, source: CGSize, canvas: CGSize) -> CGPoint? {
        let box = viewport(canvas: canvas), content = contentRect(source: source, canvas: canvas)
        guard box.contains(canvasPoint), content.contains(canvasPoint) else { return nil }
        return CGPoint(x: (canvasPoint.x - content.minX) / content.width, y: (canvasPoint.y - content.minY) / content.height)
    }
}

public struct SceneLayer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var source: LayerSource
    public var visible = true
    public var locked = false
    public var placement = LayerPlacement()
    public init(id: UUID = UUID(), name: String, source: LayerSource) { self.id = id; self.name = name; self.source = source }
}

public struct CameraScene: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Front to back, matching the editor list.
    public var layers: [SceneLayer]
    public var canvasRed: Double = 0
    public var canvasGreen: Double = 0
    public var canvasBlue: Double = 0
    public init(id: UUID = UUID(), name: String, layers: [SceneLayer] = []) { self.id = id; self.name = name; self.layers = layers }
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Set(layers.map(\.id)).count == layers.count &&
        layers.allSatisfy { !$0.name.isEmpty && $0.placement.isValid && $0.source.isValid } &&
        [canvasRed, canvasGreen, canvasBlue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    public var needsCamera: Bool { layers.contains { $0.visible && $0.source == .camera } }
    public static func defaults() -> [CameraScene] {
        (1...4).map { CameraScene(name: "Scene \($0)", layers: [SceneLayer(name: "Webcam", source: .camera)]) }
    }
    /// Locked rows cannot be dragged or crossed by another row.
    @discardableResult public mutating func move(_ id: UUID, to destination: Int) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == id }), layers.indices.contains(destination),
              !layers[min(index, destination)...max(index, destination)].contains(where: \.locked) else { return false }
        let layer = layers.remove(at: index); layers.insert(layer, at: destination); return true
    }
}
