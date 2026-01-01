import Foundation
import Network
import Logging
import OmertaCore

/// Actor managing WireGuard VPN tunnels for job isolation
public actor VPNManager {
    private let logger = Logger(label: "com.omerta.vpn")
    private var activeTunnels: [UUID: VPNTunnel] = [:]
    private let wireguardToolPath: String

    public init(wireguardToolPath: String = "/usr/local/bin/wg-quick") {
        self.wireguardToolPath = wireguardToolPath
        logger.info("VPNManager initialized")
    }

    /// Create and start a WireGuard tunnel for a job
    public func createTunnel(
        for jobId: UUID,
        config: VPNConfiguration
    ) async throws -> VPNTunnel {
        logger.info("Creating VPN tunnel", metadata: ["job_id": "\(jobId)"])

        // Validate configuration
        try validateConfiguration(config)

        // Generate unique interface name
        let interfaceName = "wg-\(jobId.uuidString.prefix(8))"

        // Write WireGuard config to temporary file
        let configURL = try writeConfigFile(config: config, interfaceName: interfaceName)

        // Start WireGuard tunnel
        try await startWireGuardTunnel(configURL: configURL, interfaceName: interfaceName)

        // Verify tunnel is up and routing works
        try await verifyTunnelConnectivity(config: config)

        let tunnel = VPNTunnel(
            jobId: jobId,
            interfaceName: interfaceName,
            configURL: configURL,
            vpnServerIP: config.vpnServerIP,
            endpoint: config.endpoint,
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/wg")
        process.arguments = ["show", tunnel.interfaceName]

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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/wg")
        process.arguments = ["show", tunnel.interfaceName, "transfer"]

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
        guard !config.wireguardConfig.isEmpty else {
            throw VPNError.invalidConfiguration("Empty WireGuard config")
        }

        guard !config.endpoint.isEmpty else {
            throw VPNError.invalidConfiguration("Empty endpoint")
        }

        guard !config.vpnServerIP.isEmpty else {
            throw VPNError.invalidConfiguration("Empty VPN server IP")
        }

        // Validate endpoint format (IP:port)
        let components = config.endpoint.split(separator: ":")
        guard components.count == 2,
              let _ = UInt16(components[1]) else {
            throw VPNError.invalidConfiguration("Invalid endpoint format (expected IP:port)")
        }
    }

    private func writeConfigFile(
        config: VPNConfiguration,
        interfaceName: String
    ) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-vpn")

        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let configURL = tmpDir.appendingPathComponent("\(interfaceName).conf")

        try config.wireguardConfig.write(to: configURL, atomically: true, encoding: .utf8)

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
        process.executableURL = URL(fileURLWithPath: wireguardToolPath)
        process.arguments = ["up", configURL.path]

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
        process.executableURL = URL(fileURLWithPath: wireguardToolPath)
        process.arguments = ["down", interfaceName]

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
        // Ping the VPN server to verify connectivity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "2", config.vpnServerIP]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw VPNError.connectivityCheckFailed("Cannot reach VPN server at \(config.vpnServerIP)")
        }

        logger.info("VPN connectivity verified", metadata: ["vpn_server": "\(config.vpnServerIP)"])
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
    public let vpnServerIP: String
    public let endpoint: String
    public let createdAt: Date
}

/// VPN tunnel statistics
public struct VPNTunnelStats: Sendable {
    public let bytesReceived: UInt64
    public let bytesTransmitted: UInt64
    public let lastHandshake: Date
}

/// VPN errors
public enum VPNError: Error {
    case invalidConfiguration(String)
    case tunnelNotFound(UUID)
    case tunnelStartFailed(String)
    case tunnelStatsFailed
    case connectivityCheckFailed(String)
}
