#if SWIFT_PACKAGE
import AppleCamCore
#endif
import Foundation
import SystemExtensions

final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Extension activation has not been checked."
    @Published var pending = false
    func activate() {
        guard Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications" else {
            status = "Use the signed, notarized app in Applications before installing the extension."
            return
        }
        pending = true
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: CameraContract.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve AppleCam in System Settings → General → Login Items & Extensions → Camera Extensions."
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        pending = false
        status = result == .completed ? "Activation completed. Start the test pattern to check frame transport."
            : "macOS requires a restart to finish activation. Your current sessions have been left running."
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        pending = false
        let error = error as NSError
        status = "Activation failed: \(error.localizedDescription) (\(error.domain), \(error.code))."
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
