#if os(macOS)
import Foundation
import NetworkExtension
import Logging
import OmertaCore

/// VPN provider using macOS Network Extension framework
/// No sudo required - uses system-approved extension for tunnel management
public actor NetworkExtensionVPN: VPNProvider {
    private let logger = Logger(label: "com.omerta.network-extension-vpn")
    private var managers: [UUID: NETunnelProviderManager] = [:]
    private var configs: [UUID: GeneratedVPNConfig] = [:]
    private let extensionBundleId: String
    private let basePort: UInt16
    private var nextPort: UInt16

    /// Generated VPN configuration (server and client configs)
    private struct GeneratedVPNConfig {
        let serverConfig: String      // Config for the tunnel provider (server-side)
        let clientConfig: String      // Config to send to provider's VM
        let vpnConfiguration: VPNConfiguration  // Public config object
        let port: UInt16
        let serverVPNIP: String
        let clientVPNIP: String
    }

    public init(
        extensionBundleId: String = "com.matthewtomei.Omerta.OmertaVPNExtension",
        basePort: UInt16 = 51820
    ) {
        self.extensionBundleId = extensionBundleId
        self.basePort = basePort
        self.nextPort = basePort
        logger.info("NetworkExtensionVPN initialized", metadata: [
            "extension_bundle_id": "\(extensionBundleId)",
            "base_port": "\(basePort)"
        ])
    }

    // MARK: - VPNProvider Protocol

    public func createVPN(for vmId: UUID) async throws -> VPNConfiguration {
        logger.info("Creating VPN via Network Extension", metadata: ["vm_id": "\(vmId)"])

        // Generate WireGuard keys and config
        let config = try await generateConfig(for: vmId)
        configs[vmId] = config

        // Check if we have permission to create VPN configurations
        try await ensureExtensionApproved()

        // Create tunnel provider manager
        let manager = NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleId
        proto.providerConfiguration = [
            "wgConfig": config.serverConfig as NSString,
            "vmId": vmId.uuidString as NSString
        ]
        proto.serverAddress = "Omerta VM \(vmId.uuidString.prefix(8))"

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Omerta VPN - \(vmId.uuidString.prefix(8))"
        manager.isEnabled = true

        // Save to system preferences (may prompt user on first use)
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        logger.info("VPN configuration saved", metadata: ["vm_id": "\(vmId)"])

        // Start the tunnel
        let session = manager.connection as! NETunnelProviderSession
        try session.startVPNTunnel(options: [
            "wgConfig": config.serverConfig as NSString
        ])

        // Wait for connection
        try await waitForConnection(session: session, timeout: 30.0)

        managers[vmId] = manager

        logger.info("VPN tunnel started", metadata: [
            "vm_id": "\(vmId)",
            "server_ip": "\(config.serverVPNIP)"
        ])

        return config.vpnConfiguration
    }

    public func destroyVPN(for vmId: UUID) async throws {
        logger.info("Destroying VPN", metadata: ["vm_id": "\(vmId)"])

        guard let manager = managers[vmId] else {
            logger.warning("VPN manager not found", metadata: ["vm_id": "\(vmId)"])
            return
        }

        // Stop the tunnel
        manager.connection.stopVPNTunnel()

        // Remove from preferences
        try await manager.removeFromPreferences()

        managers.removeValue(forKey: vmId)
        configs.removeValue(forKey: vmId)

        logger.info("VPN destroyed", metadata: ["vm_id": "\(vmId)"])
    }

    public func isConnected(for vmId: UUID) async throws -> Bool {
        guard let manager = managers[vmId] else {
            return false
        }
        return manager.connection.status == .connected
    }

    public func getActiveTunnels() async -> [UUID] {
        Array(managers.keys)
    }

    // MARK: - Extension Management

    /// Check if the Network Extension is approved by the user
    private func ensureExtensionApproved() async throws {
        // Load existing managers to check if extension is approved
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        // If we have any managers with our bundle ID, extension is approved
        let hasApprovedExtension = managers.contains { manager in
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == extensionBundleId
        }

        if !hasApprovedExtension {
            logger.info("Network Extension not yet approved, will prompt user")
            // The first saveToPreferences() call will prompt the user
        }
    }

    /// Wait for VPN connection to establish
    private func waitForConnection(session: NETunnelProviderSession, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            switch session.status {
            case .connected:
                return
            case .disconnected, .invalid:
                throw VPNProviderError.tunnelCreationFailed("Connection failed")
            case .connecting, .reasserting, .disconnecting:
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            @unknown default:
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        throw VPNProviderError.connectionTimeout
    }

    // MARK: - Configuration Generation

    private func generateConfig(for vmId: UUID) async throws -> GeneratedVPNConfig {
        // Generate key pairs
        let serverPrivateKey = generatePrivateKey()
        let serverPublicKey = try await derivePublicKey(from: serverPrivateKey)
        let clientPrivateKey = generatePrivateKey()
        let clientPublicKey = try await derivePublicKey(from: clientPrivateKey)

        // Allocate port
        let port = allocatePort()

        // Determine endpoint
        let endpoint = try await determineEndpoint(port: port)

        // VPN network addresses - choose a subnet that doesn't conflict with LAN
        let vpnSubnet = try await findAvailableVPNSubnet()
        let serverVPNIP = "\(vpnSubnet).1"
        let clientVPNIP = "\(vpnSubnet).2"

        // Generate server config (what runs in the extension)
        let serverConfig = """
            [Interface]
            PrivateKey = \(serverPrivateKey)
            Address = \(serverVPNIP)/24
            ListenPort = \(port)

            [Peer]
            PublicKey = \(clientPublicKey)
            AllowedIPs = \(clientVPNIP)/32
            """

        // Generate client config (sent to provider's VM)
        let clientConfig = """
            [Interface]
            PrivateKey = \(clientPrivateKey)
            Address = \(clientVPNIP)/24
            DNS = 8.8.8.8

            [Peer]
            PublicKey = \(serverPublicKey)
            Endpoint = \(endpoint)
            AllowedIPs = 0.0.0.0/0
            PersistentKeepalive = 25
            """

        // In Option 3 architecture, consumer (us) is the VPN server
        // Provider will generate its own keypair and connect to us
        let vpnConfiguration = VPNConfiguration(
            consumerPublicKey: serverPublicKey,
            consumerEndpoint: endpoint,
            consumerVPNIP: serverVPNIP,
            vmVPNIP: clientVPNIP,
            vpnSubnet: "\(vpnSubnet).0/24"
        )

        return GeneratedVPNConfig(
            serverConfig: serverConfig,
            clientConfig: clientConfig,
            vpnConfiguration: vpnConfiguration,
            port: port,
            serverVPNIP: serverVPNIP,
            clientVPNIP: clientVPNIP
        )
    }

    private func generatePrivateKey() -> String {
        // Generate 32 random bytes and base64 encode
        var keyData = Data(count: 32)
        _ = keyData.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        return keyData.base64EncodedString()
    }

    private func derivePublicKey(from privateKey: String) async throws -> String {
        // Use wg command to derive public key (doesn't require sudo)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/wg")
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
            throw VPNProviderError.configurationInvalid("Failed to derive public key")
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func allocatePort() -> UInt16 {
        let port = nextPort
        nextPort += 1
        return port
    }

    private func determineEndpoint(port: UInt16) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/hostname")
        process.arguments = ["-f"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let hostname = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "localhost"

        return "\(hostname):\(port)"
    }

    /// Find a VPN subnet that doesn't conflict with existing network routes
    private func findAvailableVPNSubnet() async throws -> String {
        // Get current network routes to detect conflicts
        let usedSubnets = try await getCurrentSubnets()

        // Candidate subnets in 10.x.0.0/24 range (less commonly used ranges)
        // Avoiding common ones like 10.0.x, 10.1.x, 10.10.x
        let candidates = [
            "10.147.19",  // Unusual, unlikely to conflict
            "10.99.88",
            "10.77.66",
            "10.213.37",
            "10.189.42",
            "10.167.23",
            "10.143.91",
            "10.199.55",
        ]

        for candidate in candidates {
            let candidatePrefix = candidate.split(separator: ".").prefix(2).joined(separator: ".")
            let conflicts = usedSubnets.contains { subnet in
                // Check if any used subnet overlaps with our candidate
                subnet.hasPrefix(candidatePrefix) || candidate.hasPrefix(subnet.split(separator: ".").prefix(2).joined(separator: "."))
            }

            if !conflicts {
                logger.info("Selected VPN subnet", metadata: ["subnet": "\(candidate).0/24"])
                return candidate
            }
        }

        // Fallback: generate a random subnet in 10.x.y.0/24
        let x = UInt8.random(in: 128...250)
        let y = UInt8.random(in: 2...250)
        let fallback = "10.\(x).\(y)"
        logger.warning("Using random VPN subnet (all candidates conflicted)", metadata: ["subnet": "\(fallback).0/24"])
        return fallback
    }

    /// Get list of subnets currently in use on this machine
    private func getCurrentSubnets() async throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Parse ifconfig output for inet addresses
        var subnets = Set<String>()
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") {
                // Line format: "inet 192.168.1.100 netmask 0xffffff00 ..."
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2 {
                    let ip = String(parts[1])
                    // Extract the /24 prefix (first 3 octets)
                    let octets = ip.split(separator: ".")
                    if octets.count >= 3 {
                        let prefix = octets.prefix(3).joined(separator: ".")
                        subnets.insert(prefix)
                    }
                }
            }
        }

        logger.debug("Detected local subnets", metadata: ["subnets": "\(subnets)"])
        return subnets
    }

    // MARK: - IPC with Extension

    /// Send a message to the tunnel extension and get a response
    public func sendMessage(to vmId: UUID, message: String) async throws -> String? {
        guard let manager = managers[vmId] else {
            throw VPNProviderError.tunnelNotFound(vmId)
        }

        let session = manager.connection as! NETunnelProviderSession

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(Data(message.utf8)) { response in
                    if let response = response, let str = String(data: response, encoding: .utf8) {
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
#endif
