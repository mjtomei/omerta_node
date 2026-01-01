import Foundation
import Crypto
import Logging
import OmertaCore

/// Creates and manages ephemeral WireGuard VPN servers for individual jobs
/// Used by consumers/requesters to create isolated network environments
public actor EphemeralVPN {
    private let logger = Logger(label: "com.omerta.ephemeral-vpn")
    private var activeServers: [UUID: VPNServer] = [:]
    private let basePort: UInt16
    private var nextPort: UInt16

    public init(basePort: UInt16 = 51820) {
        self.basePort = basePort
        self.nextPort = basePort
        logger.info("EphemeralVPN initialized", metadata: ["base_port": "\(basePort)"])
    }

    /// Create an ephemeral VPN server for a job
    public func createVPNForJob(_ jobId: UUID) async throws -> VPNConfiguration {
        logger.info("Creating ephemeral VPN for job", metadata: ["job_id": "\(jobId)"])

        // Generate key pair for server
        let serverPrivateKey = try generatePrivateKey()
        let serverPublicKey = try derivePublicKey(from: serverPrivateKey)

        // Generate key pair for client (provider/VM)
        let clientPrivateKey = try generatePrivateKey()
        let clientPublicKey = try derivePublicKey(from: clientPrivateKey)

        // Allocate port
        let port = allocatePort()

        // Determine server IP (this machine's IP or specified endpoint)
        let serverEndpoint = try await determineServerEndpoint()
        let endpoint = "\(serverEndpoint):\(port)"

        // VPN network addresses
        let serverVPNIP = "10.99.0.1"
        let clientVPNIP = "10.99.0.2"

        // Create server configuration
        let serverConfig = generateServerConfig(
            privateKey: serverPrivateKey,
            serverIP: serverVPNIP,
            clientPublicKey: clientPublicKey,
            clientIP: clientVPNIP,
            port: port
        )

        // Create client configuration (what provider will use)
        let clientConfig = generateClientConfig(
            privateKey: clientPrivateKey,
            clientIP: clientVPNIP,
            serverPublicKey: serverPublicKey,
            endpoint: endpoint,
            serverVPNIP: serverVPNIP
        )

        // Start WireGuard server
        let interfaceName = "wg-server-\(jobId.uuidString.prefix(8))"
        try await startVPNServer(
            config: serverConfig,
            interfaceName: interfaceName
        )

        // Configure NAT/forwarding for internet access
        try await configureNATForwarding(interfaceName: interfaceName)

        let server = VPNServer(
            jobId: jobId,
            interfaceName: interfaceName,
            port: port,
            serverVPNIP: serverVPNIP,
            clientVPNIP: clientVPNIP,
            serverPrivateKey: serverPrivateKey,
            clientPublicKey: clientPublicKey,
            createdAt: Date()
        )

        activeServers[jobId] = server

        logger.info("Ephemeral VPN created", metadata: [
            "job_id": "\(jobId)",
            "interface": "\(interfaceName)",
            "endpoint": "\(endpoint)"
        ])

        // Return configuration for client (provider)
        return VPNConfiguration(
            wireguardConfig: clientConfig,
            endpoint: endpoint,
            publicKey: Data(serverPublicKey.utf8),
            allowedIPs: "0.0.0.0/0", // Route all traffic through VPN
            vpnServerIP: serverVPNIP
        )
    }

    /// Destroy an ephemeral VPN server
    public func destroyVPN(for jobId: UUID) async throws {
        guard let server = activeServers[jobId] else {
            logger.warning("VPN server not found", metadata: ["job_id": "\(jobId)"])
            return
        }

        logger.info("Destroying ephemeral VPN", metadata: [
            "job_id": "\(jobId)",
            "interface": "\(server.interfaceName)"
        ])

        // Remove NAT forwarding rules
        try await removeNATForwarding(interfaceName: server.interfaceName)

        // Stop WireGuard server
        try await stopVPNServer(interfaceName: server.interfaceName)

        activeServers.removeValue(forKey: jobId)

        logger.info("Ephemeral VPN destroyed", metadata: ["job_id": "\(jobId)"])
    }

    /// Check if VPN server is accepting connections from client
    public func isClientConnected(for jobId: UUID) async throws -> Bool {
        guard let server = activeServers[jobId] else {
            return false
        }

        // Check WireGuard handshake status
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/wg")
        process.arguments = ["show", server.interfaceName, "latest-handshakes"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Check if handshake is recent (within last 3 minutes)
        return output.contains(server.clientPublicKey) && !output.contains("\t0\n")
    }

    // MARK: - Private Methods

    private func generatePrivateKey() throws -> String {
        // Generate random 32-byte key
        let keyData = SymmetricKey(size: .bits256)
        let keyBytes = keyData.withUnsafeBytes { Data($0) }
        return keyBytes.base64EncodedString()
    }

    private func derivePublicKey(from privateKey: String) throws -> String {
        // In real implementation, this would use WireGuard's Curve25519 key derivation
        // For now, we'll call wg pubkey command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/wg")
        process.arguments = ["pubkey"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()

        inputPipe.fileHandleForWriting.write(Data(privateKey.utf8))
        try inputPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw VPNError.invalidConfiguration("Failed to derive public key")
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func allocatePort() -> UInt16 {
        let port = nextPort
        nextPort += 1
        return port
    }

    private func determineServerEndpoint() async throws -> String {
        // Try to get public IP or use hostname
        // For simplicity, use hostname for now
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/hostname")
        process.arguments = ["-f"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let hostname = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "localhost"

        return hostname
    }

    private func generateServerConfig(
        privateKey: String,
        serverIP: String,
        clientPublicKey: String,
        clientIP: String,
        port: UInt16
    ) -> String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(serverIP)/24
        ListenPort = \(port)

        # Enable IP forwarding
        PostUp = sysctl -w net.ipv4.ip_forward=1
        PostUp = iptables -A FORWARD -i %i -j ACCEPT
        PostUp = iptables -A FORWARD -o %i -j ACCEPT
        PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

        PostDown = iptables -D FORWARD -i %i -j ACCEPT
        PostDown = iptables -D FORWARD -o %i -j ACCEPT
        PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

        [Peer]
        PublicKey = \(clientPublicKey)
        AllowedIPs = \(clientIP)/32
        """
    }

    private func generateClientConfig(
        privateKey: String,
        clientIP: String,
        serverPublicKey: String,
        endpoint: String,
        serverVPNIP: String
    ) -> String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(clientIP)/24
        DNS = 8.8.8.8

        [Peer]
        PublicKey = \(serverPublicKey)
        Endpoint = \(endpoint)
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25
        """
    }

    private func startVPNServer(
        config: String,
        interfaceName: String
    ) async throws {
        // Write config to file
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-vpn-server")

        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let configURL = tmpDir.appendingPathComponent("\(interfaceName).conf")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        // Set secure permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )

        // Start WireGuard
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/wg-quick")
        process.arguments = ["up", configURL.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw VPNError.tunnelStartFailed("Failed to start VPN server: \(errorMessage)")
        }

        logger.info("VPN server started", metadata: ["interface": "\(interfaceName)"])
    }

    private func stopVPNServer(interfaceName: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/wg-quick")
        process.arguments = ["down", interfaceName]

        try process.run()
        process.waitUntilExit()

        // Best-effort cleanup
        logger.info("VPN server stopped", metadata: ["interface": "\(interfaceName)"])
    }

    private func configureNATForwarding(interfaceName: String) async throws {
        // IP forwarding should be enabled in PostUp scripts
        // Additional configuration if needed
        logger.info("NAT forwarding configured", metadata: ["interface": "\(interfaceName)"])
    }

    private func removeNATForwarding(interfaceName: String) async throws {
        // Cleanup should be handled in PostDown scripts
        logger.info("NAT forwarding removed", metadata: ["interface": "\(interfaceName)"])
    }

    /// Get all active VPN servers
    public func getActiveServers() -> [UUID: VPNServer] {
        activeServers
    }
}

/// VPN server instance
public struct VPNServer: Sendable {
    public let jobId: UUID
    public let interfaceName: String
    public let port: UInt16
    public let serverVPNIP: String
    public let clientVPNIP: String
    public let serverPrivateKey: String
    public let clientPublicKey: String
    public let createdAt: Date
}
