import Foundation
import NetworkExtension
import Logging

/// Service for managing VPN tunnels via the Network Extension
/// This replaces wg-quick shell commands with proper NetworkExtension APIs
public actor VPNTunnelService {
    private let logger = Logger(label: "com.omerta.vpn-tunnel-service")
    private let extensionBundleId = "com.matthewtomei.Omerta.OmertaVPNExtension"

    /// Active tunnel managers keyed by job/VM ID
    private var activeTunnels: [UUID: NETunnelProviderManager] = [:]

    public init() {}

    // MARK: - Extension Status

    /// Check if the VPN extension is installed and approved
    public func isExtensionInstalled() async -> Bool {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            return managers.contains { manager in
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return proto.providerBundleIdentifier == extensionBundleId
            }
        } catch {
            logger.error("Failed to check extension status: \(error)")
            return false
        }
    }

    /// Get or create a tunnel manager for our extension
    private func getOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        // Find existing manager for our extension
        if let existing = managers.first(where: { manager in
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == extensionBundleId
        }) {
            return existing
        }

        // Create new manager
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleId
        proto.serverAddress = "Omerta VPN"

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Omerta VPN"
        manager.isEnabled = true

        // This will prompt user for VPN permission on first run
        try await manager.saveToPreferences()

        // Reload to get the saved manager
        try await manager.loadFromPreferences()

        return manager
    }

    // MARK: - Tunnel Management

    /// Start a VPN tunnel for a specific job/VM
    /// - Parameters:
    ///   - jobId: Unique identifier for this tunnel
    ///   - config: WireGuard configuration string
    /// - Returns: The interface name for this tunnel
    public func startTunnel(jobId: UUID, config: String) async throws -> String {
        logger.info("Starting VPN tunnel", metadata: ["job_id": "\(jobId)"])

        let manager = try await getOrCreateManager()

        // Update the provider configuration with WireGuard config
        // On macOS, options passed to startVPNTunnel don't reach the extension
        // We must store config in providerConfiguration instead
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw VPNTunnelError.configurationError("Invalid protocol configuration")
        }

        // Store WireGuard config in provider configuration
        proto.providerConfiguration = [
            "wgConfig": config,
            "jobId": jobId.uuidString
        ]

        // Save updated configuration
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        // Store for later cleanup
        activeTunnels[jobId] = manager

        // Start the tunnel
        let session = manager.connection as! NETunnelProviderSession

        try session.startVPNTunnel()

        // Wait for connection to establish
        try await waitForConnection(session: session, timeout: 30)

        let interfaceName = "utun-\(jobId.uuidString.prefix(8))"
        logger.info("VPN tunnel started", metadata: [
            "job_id": "\(jobId)",
            "interface": "\(interfaceName)"
        ])

        return interfaceName
    }

    /// Stop a VPN tunnel for a specific job/VM
    public func stopTunnel(jobId: UUID) async throws {
        logger.info("Stopping VPN tunnel", metadata: ["job_id": "\(jobId)"])

        guard let manager = activeTunnels[jobId] else {
            logger.warning("No tunnel found for job", metadata: ["job_id": "\(jobId)"])
            return
        }

        manager.connection.stopVPNTunnel()
        activeTunnels.removeValue(forKey: jobId)

        logger.info("VPN tunnel stopped", metadata: ["job_id": "\(jobId)"])
    }

    /// Check if a tunnel is connected
    public func isTunnelConnected(jobId: UUID) async -> Bool {
        guard let manager = activeTunnels[jobId] else {
            return false
        }
        return manager.connection.status == .connected
    }

    /// Get all active tunnel job IDs
    public func getActiveTunnelIds() -> [UUID] {
        Array(activeTunnels.keys)
    }

    // MARK: - Private Helpers

    private func waitForConnection(session: NETunnelProviderSession, timeout: TimeInterval) async throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            switch session.status {
            case .connected:
                return
            case .invalid, .disconnected:
                throw VPNTunnelError.connectionFailed("Tunnel disconnected unexpectedly")
            case .connecting, .reasserting:
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            case .disconnecting:
                throw VPNTunnelError.connectionFailed("Tunnel is disconnecting")
            @unknown default:
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        throw VPNTunnelError.connectionTimeout
    }

    /// Send a message to the running tunnel extension
    public func sendMessage(jobId: UUID, message: String) async throws -> String? {
        guard let manager = activeTunnels[jobId] else {
            throw VPNTunnelError.tunnelNotFound(jobId)
        }

        let session = manager.connection as! NETunnelProviderSession

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(Data(message.utf8)) { response in
                    if let data = response, let str = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: str)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Errors

public enum VPNTunnelError: Error, CustomStringConvertible {
    case extensionNotInstalled
    case connectionFailed(String)
    case connectionTimeout
    case tunnelNotFound(UUID)
    case configurationError(String)

    public var description: String {
        switch self {
        case .extensionNotInstalled:
            return "VPN extension not installed. Run 'omerta setup' first."
        case .connectionFailed(let reason):
            return "VPN connection failed: \(reason)"
        case .connectionTimeout:
            return "VPN connection timed out"
        case .tunnelNotFound(let id):
            return "No tunnel found for job: \(id)"
        case .configurationError(let reason):
            return "VPN configuration error: \(reason)"
        }
    }
}
