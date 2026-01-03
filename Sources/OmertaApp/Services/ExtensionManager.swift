import Foundation
import NetworkExtension
import SystemExtensions

/// Manages the VPN Network Extension lifecycle
@MainActor
class ExtensionManager: NSObject, ObservableObject {
    static let shared = ExtensionManager()

    @Published var status: ExtensionStatus = .unknown

    private let extensionBundleId = "com.matthewtomei.Omerta.OmertaVPNExtension"
    private var activationContinuation: CheckedContinuation<Bool, Error>?

    struct ExtensionStatus {
        var isInstalled: Bool = false
        var isApproved: Bool = false
        var isEnabled: Bool = false
        var error: String?
    }

    private override init() {
        super.init()
    }

    /// Check current extension status
    func checkStatus() async -> ExtensionStatus {
        var status = ExtensionStatus()

        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()

            // Check if we have a manager with our extension
            let ourManager = managers.first { manager in
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return proto.providerBundleIdentifier == extensionBundleId
            }

            if let manager = ourManager {
                status.isInstalled = true
                status.isApproved = true
                status.isEnabled = manager.isEnabled
            }
        } catch {
            status.error = error.localizedDescription
        }

        self.status = status
        return status
    }

    /// Activate the system extension (prompts user for approval)
    func activateExtension() async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            self.activationContinuation = continuation

            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: extensionBundleId,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    /// Deactivate the system extension
    func deactivateExtension() async throws {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionBundleId,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Create initial VPN configuration to trigger approval flow
    func createInitialConfiguration() async throws {
        let manager = NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleId
        proto.serverAddress = "Omerta VPN"

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Omerta VPN"
        manager.isEnabled = true

        // This will prompt user for VPN permission
        try await manager.saveToPreferences()

        // Refresh status
        _ = await checkStatus()
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension ExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Replace existing extension with new version
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // User needs to approve in System Preferences
        Task { @MainActor in
            print("Extension needs user approval in System Preferences > Security & Privacy")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            switch result {
            case .completed:
                print("Extension activation completed")
                activationContinuation?.resume(returning: true)
            case .willCompleteAfterReboot:
                print("Extension will complete after reboot")
                activationContinuation?.resume(returning: true)
            @unknown default:
                activationContinuation?.resume(returning: false)
            }
            activationContinuation = nil
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            print("Extension activation failed: \(error)")
            activationContinuation?.resume(throwing: error)
            activationContinuation = nil
        }
    }
}
