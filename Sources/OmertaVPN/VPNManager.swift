import Foundation
import Logging
import OmertaCore

/// Actor managing WireGuard VPN tunnels for job isolation
/// Note: In Option 3 architecture, this is used for client-side tunnels connecting to consumer's VPN server
public actor VPNManager {
    private let logger = Logger(label: "com.omerta.vpn")
    private var activeTunnels: [UUID: VPNTunnel] = [:]
    private let wireguardToolPath: String

    public init(wireguardToolPath: String = WireGuardPaths.wgQuick) {
        self.wireguardToolPath = wireguardToolPath
        logger.info("VPNManager initialized")
    }

    /// Create and start a WireGuard tunnel for a job
    /// Connects to consumer's VPN server using provided configuration
    public func createTunnel(
        for jobId: UUID,
        config: VPNConfiguration,
        privateKey: String
    ) async throws -> VPNTunnel {
        logger.info("Creating VPN tunnel", metadata: ["job_id": "\(jobId)"])

        // Validate configuration
        try validateConfiguration(config)

        // Generate unique interface name
        let interfaceName = "wg-\(jobId.uuidString.prefix(8))"

        // Write WireGuard config to temporary file
        let configURL = try writeConfigFile(
            config: config,
            privateKey: privateKey,
            interfaceName: interfaceName
        )

        // Start WireGuard tunnel
        try await startWireGuardTunnel(configURL: configURL, interfaceName: interfaceName)

        // Verify tunnel is up and routing works
        try await verifyTunnelConnectivity(config: config)

        let tunnel = VPNTunnel(
            jobId: jobId,
            interfaceName: interfaceName,
            configURL: configURL,
            consumerVPNIP: config.consumerVPNIP,
            consumerEndpoint: config.consumerEndpoint,
            createdAt: Date()
        )

        activeTunnels[jobId] = tunnel

        logger.info("VPN tunnel created successfully", metadata: [
            "job_id": "\(jobId)",
            "interface": "\(interfaceName)"
        ])

        return tunnel
    }

    /// Destroy a VPN tunnel
    public func destroyTunnel(for jobId: UUID) async throws {
        guard let tunnel = activeTunnels[jobId] else {
            logger.warning("Tunnel not found for job", metadata: ["job_id": "\(jobId)"])
            return
        }

        logger.info("Destroying VPN tunnel", metadata: [
            "job_id": "\(jobId)",
            "interface": "\(tunnel.interfaceName)"
        ])

        // Stop WireGuard tunnel
        try await stopWireGuardTunnel(interfaceName: tunnel.interfaceName)

        // Cleanup config file
        try? FileManager.default.removeItem(at: tunnel.configURL)

        activeTunnels.removeValue(forKey: jobId)

        logger.info("VPN tunnel destroyed", metadata: ["job_id": "\(jobId)"])
    }

    /// Check if tunnel is still active and connected
    public func isTunnelActive(for jobId: UUID) async throws -> Bool {
        guard let tunnel = activeTunnels[jobId] else {
            return false
        }

        // Check if interface exists and has traffic
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [WireGuardPaths.wg, "show", tunnel.interfaceName]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        return process.terminationStatus == 0
    }

    /// Get tunnel statistics
    public func getTunnelStats(for jobId: UUID) async throws -> VPNTunnelStats {
        guard let tunnel = activeTunnels[jobId] else {
            throw VPNError.tunnelNotFound(jobId)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [WireGuardPaths.wg, "show", tunnel.interfaceName, "transfer"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw VPNError.tunnelStatsFailed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return try parseTransferStats(output)
    }

    // MARK: - Private Methods

    private func validateConfiguration(_ config: VPNConfiguration) throws {
        guard !config.consumerPublicKey.isEmpty else {
            throw VPNError.invalidConfiguration("Empty consumer public key")
        }

        guard !config.consumerEndpoint.isEmpty else {
            throw VPNError.invalidConfiguration("Empty consumer endpoint")
        }

        guard !config.consumerVPNIP.isEmpty else {
            throw VPNError.invalidConfiguration("Empty consumer VPN IP")
        }

        guard !config.vmVPNIP.isEmpty else {
            throw VPNError.invalidConfiguration("Empty VM VPN IP")
        }

        // Validate endpoint format (IP:port)
        let components = config.consumerEndpoint.split(separator: ":")
        guard components.count == 2,
              let _ = UInt16(components[1]) else {
            throw VPNError.invalidConfiguration("Invalid endpoint format (expected IP:port)")
        }
    }

    private func writeConfigFile(
        config: VPNConfiguration,
        privateKey: String,
        interfaceName: String
    ) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-vpn")

        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let configURL = tmpDir.appendingPathComponent("\(interfaceName).conf")

        // Generate WireGuard config to connect to consumer's VPN server
        let wireguardConfig = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(config.vmVPNIP)/24

        [Peer]
        PublicKey = \(config.consumerPublicKey)
        Endpoint = \(config.consumerEndpoint)
        AllowedIPs = \(config.vpnSubnet)
        PersistentKeepalive = 25
        """

        try wireguardConfig.write(to: configURL, atomically: true, encoding: .utf8)

        // Set secure permissions (only owner can read)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )

        return configURL
    }

    private func startWireGuardTunnel(
        configURL: URL,
        interfaceName: String
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [wireguardToolPath, "up", configURL.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw VPNError.tunnelStartFailed(errorMessage)
        }

        // Wait for interface to be fully up
        try await Task.sleep(for: .milliseconds(500))
    }

    private func stopWireGuardTunnel(interfaceName: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [wireguardToolPath, "down", interfaceName]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.warning("Failed to stop tunnel", metadata: ["error": "\(errorMessage)"])
            // Don't throw - cleanup should be best-effort
        }
    }

    private func verifyTunnelConnectivity(config: VPNConfiguration) async throws {
        // Ping the consumer's VPN server to verify connectivity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "2", config.consumerVPNIP]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw VPNError.connectivityCheckFailed("Cannot reach consumer VPN server at \(config.consumerVPNIP)")
        }

        logger.info("VPN connectivity verified", metadata: ["consumer_vpn": "\(config.consumerVPNIP)"])
    }

    private func parseTransferStats(_ output: String) throws -> VPNTunnelStats {
        // Parse wg output format: "peer_pubkey\trx_bytes\ttx_bytes"
        let lines = output.split(separator: "\n")

        var totalReceived: UInt64 = 0
        var totalTransmitted: UInt64 = 0

        for line in lines {
            let parts = line.split(separator: "\t")
            if parts.count >= 3 {
                totalReceived += UInt64(parts[1]) ?? 0
                totalTransmitted += UInt64(parts[2]) ?? 0
            }
        }

        return VPNTunnelStats(
            bytesReceived: totalReceived,
            bytesTransmitted: totalTransmitted,
            lastHandshake: Date() // TODO: Parse from wg output
        )
    }

    /// Get all active tunnels
    public func getActiveTunnels() -> [UUID: VPNTunnel] {
        activeTunnels
    }
}

/// VPN tunnel instance
public struct VPNTunnel: Sendable {
    public let jobId: UUID
    public let interfaceName: String
    public let configURL: URL
    public let consumerVPNIP: String
    public let consumerEndpoint: String
    public let createdAt: Date
}

/// VPN tunnel statistics
public struct VPNTunnelStats: Sendable {
    public let bytesReceived: UInt64
    public let bytesTransmitted: UInt64
    public let lastHandshake: Date
}

/// VPN errors
public enum VPNError: Error, LocalizedError {
    case invalidConfiguration(String)
    case tunnelNotFound(UUID)
    case tunnelStartFailed(String)
    case tunnelStatsFailed
    case connectivityCheckFailed(String)
    case rootRequired

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg):
            return "Invalid VPN configuration: \(msg)"
        case .tunnelNotFound(let id):
            return "VPN tunnel not found: \(id)"
        case .tunnelStartFailed(let msg):
            return "Failed to start VPN tunnel: \(msg)"
        case .tunnelStatsFailed:
            return "Failed to get VPN tunnel stats"
        case .connectivityCheckFailed(let msg):
            return "VPN connectivity check failed: \(msg)"
        case .rootRequired:
            return "omertad must run as root to create WireGuard tunnels. Start with: sudo omertad start"
        }
    }
}
