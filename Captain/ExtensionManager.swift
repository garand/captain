import Foundation
import Observation
import SystemExtensions

/// Installs/updates the Captain Camera system extension.
@Observable
final class ExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
    enum Status: Equatable {
        case unknown
        case activating
        case needsApproval
        case active
        case needsReboot
        case notInApplications
        /// Preview build: the camera extension isn't embedded in the app.
        case notBundled
        case failed(String)
    }

    private(set) var status: Status = .unknown

    var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    var isExtensionBundled: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(CaptainShared.extensionBundleID).systemextension")
        return FileManager.default.fileExists(atPath: url.path)
    }

    func activate() {
        guard isExtensionBundled else {
            status = .notBundled
            return
        }
        guard isInApplicationsFolder else {
            status = .notInApplications
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: CaptainShared.extensionBundleID, queue: .main)
        request.delegate = self
        status = .activating
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: CaptainShared.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: status = .active
        case .willCompleteAfterReboot: status = .needsReboot
        @unknown default: status = .active
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = .failed(error.localizedDescription)
    }
}
