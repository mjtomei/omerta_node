import NetworkExtension
import os.log

/// Network Extension packet tunnel provider for WireGuard VPN
/// This runs in a separate process managed by the system
class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.matthewtomei.Omerta.OmertaVPNExtension", category: "tunnel")
    private var adapter: WireGuardAdapter?

    override func startTunnel(options: [String: NSObject]?) async throws {
        os_log("Starting tunnel", log: log, type: .info)

        // Extract WireGuard configuration from provider configuration
        // On macOS, options passed to startVPNTunnel don't reach here
        // Configuration is stored in protocolConfiguration.providerConfiguration
        guard let tunnelProviderProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = tunnelProviderProtocol.providerConfiguration,
              let configString = providerConfig["wgConfig"] as? String else {
            os_log("No WireGuard config provided in providerConfiguration", log: log, type: .error)
            throw NEVPNError(.configurationInvalid)
        }

        if let jobId = providerConfig["jobId"] as? String {
            os_log("Starting tunnel for job: %{public}@", log: log, type: .info, jobId)
        }

        os_log("Parsing WireGuard config", log: log, type: .debug)

        // Parse the WireGuard configuration using the wg-quick parser
        let tunnelConfig: TunnelConfiguration
        do {
            tunnelConfig = try TunnelConfiguration(fromWgQuickConfig: configString, called: "Omerta")
        } catch {
            os_log("Failed to parse WireGuard config: %{public}@", log: log, type: .error, error.localizedDescription)
            throw NEVPNError(.configurationInvalid)
        }

        // Create WireGuard adapter
        let adapter = WireGuardAdapter(with: self) { [weak self] logLevel, message in
            guard let self = self else { return }
            let type: OSLogType = logLevel == .error ? .error : .debug
            os_log("%{public}@", log: self.log, type: type, message)
        }

        self.adapter = adapter

        // Start the tunnel using completion handler wrapped in async
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: tunnelConfig) { [weak self] error in
                guard let self = self else {
                    continuation.resume(throwing: NEVPNError(.connectionFailed))
                    return
                }

                if let error = error {
                    os_log("Failed to start tunnel: %{public}@", log: self.log, type: .error, error.localizedDescription)
                    switch error {
                    case .cannotLocateTunnelFileDescriptor:
                        continuation.resume(throwing: NEVPNError(.connectionFailed))
                    case .invalidState:
                        continuation.resume(throwing: NEVPNError(.connectionFailed))
                    default:
                        continuation.resume(throwing: NEVPNError(.connectionFailed))
                    }
                } else {
                    os_log("Tunnel started successfully", log: self.log, type: .info)
                    continuation.resume()
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        os_log("Stopping tunnel, reason: %{public}d", log: log, type: .info, reason.rawValue)

        guard let adapter = adapter else {
            os_log("No adapter to stop", log: log, type: .default)
            return
        }

        // Stop using completion handler wrapped in async
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.stop { [weak self] error in
                if let error = error {
                    os_log("Error stopping tunnel: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                }
                continuation.resume()
            }
        }

        self.adapter = nil
        os_log("Tunnel stopped", log: log, type: .info)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        os_log("Received app message", log: log, type: .debug)

        // Handle IPC messages from the main app
        guard let message = String(data: messageData, encoding: .utf8) else {
            return nil
        }

        switch message {
        case "status":
            // Return connection status
            let status = adapter != nil ? "connected" : "disconnected"
            return status.data(using: .utf8)

        case "stats":
            // Return transfer statistics (placeholder - implement if needed)
            return "{}".data(using: .utf8)

        default:
            os_log("Unknown message: %{public}@", log: log, type: .default, message)
            return nil
        }
    }
}
