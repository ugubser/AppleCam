import Foundation
public enum CameraError: LocalizedError {
    case operation(String, Int32)
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .operation(let name, let code): return "\(name) failed (\(code))."
        case .message(let text): return text
        }
    }
}
