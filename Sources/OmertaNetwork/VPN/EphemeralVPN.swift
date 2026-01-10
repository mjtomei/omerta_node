import Foundation
import Crypto
import Logging
import OmertaCore

/// VPN backend mode (simplified for Phase 3 - wg-quick only)
public enum VPNBackend: String, Sendable {
    case wgQuick          // Use wg-quick CLI (requires sudo)
    case dryRun           // Skip actual VPN setup (for testing)
}

/// Helper to find WireGuard tools on different systems
public struct WireGuardPaths {
    public static let wg: String = {
        let paths = [
            "/opt/homebrew/bin/wg",      // macOS Apple Silicon Homebrew
            "/usr/local/bin/wg",          // macOS Intel Homebrew / Linux manual
            "/usr/bin/wg"                 // Linux package manager
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/bin/wg"  // Default fallback
    }()

    public static let wgQuick: String = {
        let paths = [
            "/opt/homebrew/bin/wg-quick",  // macOS Apple Silicon Homebrew
            "/usr/local/bin/wg-quick",      // macOS Intel Homebrew / Linux manual
            "/usr/bin/wg-quick"             // Linux package manager
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/bin/wg-quick"  // Default fallback
    }()

    /// Environment with PATH including Homebrew bash (required for wg-quick on macOS)
    public static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        // Prepend Homebrew paths to ensure bash 4+ is found
        let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = "\(homebrewPaths):\(existingPath)"
        } else {
            env["PATH"] = "\(homebrewPaths):/usr/bin:/bin"
        }
        return env
    }()
}

/// Creates and manages ephemeral WireGuard VPN servers for individual jobs
/// Used by consumers/requesters to create isolated network environments
/// Simplified for Phase 3: uses wg-quick only (requires sudo)
public actor EphemeralVPN: VPNProvider {
    private let logger = Logger(label: "com.omerta.ephemeral-vpn")
    private var activeServers: [UUID: VPNServer] = [:]
    private let basePort: UInt16
    private var nextPort: UInt16
    private let backend: VPNBackend

    /// Initialize EphemeralVPN
    /// - Parameters:
    ///   - basePort: Base port for WireGuard listeners
    ///   - backend: Which VPN backend to use (.wgQuick or .dryRun)
    public init(basePort: UInt16 = 51900, backend: VPNBackend = .wgQuick) {
        self.basePort = basePort
        self.nextPort = basePort
        self.backend = backend

        logger.info("EphemeralVPN initialized", metadata: [
            "base_port": "\(basePort)",
            "dry_run": "\(backend == .dryRun)"
        ])
    }

    /// Initialize with dryRun parameter (convenience)
    public init(basePort: UInt16 = 51900, dryRun: Bool) {
        self.basePort = basePort
        self.nextPort = basePort
        self.backend = dryRun ? .dryRun : .wgQuick

        logger.info("EphemeralVPN initialized", metadata: [
            "base_port": "\(basePort)",
            "dry_run": "\(dryRun)"
        ])
    }

    /// Check if the VPN backend is available
    public func isBackendAvailable() async -> Bool {
        switch backend {
        case .dryRun:
            return true
        case .wgQuick:
            return FileManager.default.fileExists(atPath: WireGuardPaths.wgQuick)
        }
    }

    /// Create an ephemeral VPN server for a job
    /// Provider will connect to this server after receiving the VPNConfiguration
    /// Call addProviderPeer() after receiving provider's public key
    public func createVPNForJob(_ jobId: UUID) async throws -> VPNConfiguration {
        logger.info("Creating ephemeral VPN for job", metadata: ["job_id": "\(jobId)"])

        // Generate key pair for server (consumer)
        let serverPrivateKey = try generatePrivateKey()
        let serverPublicKey = try derivePublicKey(from: serverPrivateKey)

        // Allocate port
        let port = allocatePort()

        // Determine server IP (this machine's IP or specified endpoint)
        let serverEndpoint = try await determineServerEndpoint()
        let endpoint = "\(serverEndpoint):\(port)"

        // VPN network addresses - use unique subnet per job to avoid conflicts
        // Use job ID bytes to generate a unique /24 subnet in 10.x.y.0/24 range
        let jobBytes = withUnsafeBytes(of: jobId.uuid) { Array($0) }
        let subnetByte1 = Int(jobBytes[0] % 200) + 50  // 50-249 to avoid common subnets
        let subnetByte2 = Int(jobBytes[1] % 250) + 1   // 1-250
        let serverVPNIP = "10.\(subnetByte1).\(subnetByte2).1"
        let clientVPNIP = "10.\(subnetByte1).\(subnetByte2).2"

        // Create initial server configuration WITHOUT peer
        // Peer (provider) will be added dynamically after we receive their public key
        let serverConfig = generateServerConfigNoPeer(
            privateKey: serverPrivateKey,
            serverIP: serverVPNIP,
            port: port
        )

        // Start WireGuard server based on backend
        // Interface name must be ≤15 chars for wg-quick
        let interfaceName = "wg\(jobId.uuidString.prefix(8))"

        switch backend {
        case .dryRun:
            logger.info("Dry run - skipping VPN server start", metadata: ["interface": "\(interfaceName)"])

        case .wgQuick:
            try await startVPNServerWgQuick(
                config: serverConfig,
                interfaceName: interfaceName
            )

            // Configure NAT/forwarding for internet access
            try await configureNATForwarding(interfaceName: interfaceName)
        }

        let server = VPNServer(
            jobId: jobId,
            interfaceName: interfaceName,
            port: port,
            serverVPNIP: serverVPNIP,
            clientVPNIP: clientVPNIP,
            serverPrivateKey: serverPrivateKey,
            serverPublicKey: serverPublicKey,
            endpoint: endpoint,
            providerPublicKey: nil,
            createdAt: Date(),
            usedWgQuick: backend == .wgQuick
        )

        activeServers[jobId] = server

        logger.info("Ephemeral VPN created", metadata: [
            "job_id": "\(jobId)",
            "interface": "\(interfaceName)",
            "endpoint": "\(endpoint)"
        ])

        // Return configuration for provider (contains consumer's info)
        let vpnSubnet = "10.\(subnetByte1).\(subnetByte2).0/24"
        return VPNConfiguration(
            consumerPublicKey: serverPublicKey,
            consumerEndpoint: endpoint,
            consumerVPNIP: serverVPNIP,
            vmVPNIP: clientVPNIP,
            vpnSubnet: vpnSubnet
        )
    }

    /// Add provider as a peer on the WireGuard server
    /// Called after receiving the provider's public key from VMCreatedResponse
    public func addProviderPeer(
        jobId: UUID,
        providerPublicKey: String
    ) async throws {
        guard var server = activeServers[jobId] else {
            throw VPNError.tunnelNotFound(jobId)
        }

        logger.info("Adding provider peer to VPN", metadata: [
            "job_id": "\(jobId)",
            "provider_public_key": "\(providerPublicKey.prefix(20))..."
        ])

        // Update server with provider's public key
        server.providerPublicKey = providerPublicKey
        activeServers[jobId] = server

        // Add peer to WireGuard interface
        switch backend {
        case .dryRun:
            logger.info("Dry run - skipping peer addition", metadata: ["interface": "\(server.interfaceName)"])

        case .wgQuick:
            // Use wg command to add peer dynamically
            try await addPeerToInterface(
                interfaceName: server.interfaceName,
                peerPublicKey: providerPublicKey,
                allowedIPs: "\(server.clientVPNIP)/32"  // Provider routes traffic for the VM's VPN IP
            )
        }

        logger.info("Provider peer added successfully", metadata: ["job_id": "\(jobId)"])
    }

    /// Add a peer to an existing WireGuard interface
    private func addPeerToInterface(
        interfaceName: String,
        peerPublicKey: String,
        allowedIPs: String
    ) async throws {
        // On macOS, we need the utun device name, not the wg interface name
        // Use `sudo wg show interfaces` which is already in the passwordless sudo list
        var actualInterface = interfaceName
        #if os(macOS)
        let wgDir = "/var/run/wireguard"

        // Use wg show to find the matching interface
        // wg show interfaces lists all active interfaces (utun names)
        // We need to find which one corresponds to our wg interface name
        let showProcess = Process()
        showProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        showProcess.arguments = [WireGuardPaths.wg, "show", "interfaces"]
        let showPipe = Pipe()
        showProcess.standardOutput = showPipe
        showProcess.standardError = Pipe()

        do {
            try showProcess.run()
            showProcess.waitUntilExit()
            let data = showPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                // The output is space-separated or newline-separated interface names (utun devices)
                let interfaces = output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                logger.info("WireGuard interfaces from wg show", metadata: ["interfaces": "\(interfaces)"])

                // If there's exactly one interface with our name file, use the utun name from wg show
                let nameFile = "\(wgDir)/\(interfaceName).name"
                if FileManager.default.fileExists(atPath: nameFile) && interfaces.count == 1 {
                    actualInterface = interfaces[0]
                    logger.info("Using interface from wg show", metadata: [
                        "wg_name": "\(interfaceName)",
                        "utun_name": "\(actualInterface)"
                    ])
                } else if interfaces.count > 0 {
                    // Multiple interfaces - try to find ours by checking sockets
                    for iface in interfaces {
                        let sockFile = "\(wgDir)/\(iface).sock"
                        if FileManager.default.fileExists(atPath: sockFile) {
                            actualInterface = iface
                            logger.info("Found interface by socket", metadata: [
                                "wg_name": "\(interfaceName)",
                                "utun_name": "\(iface)"
                            ])
                            break
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to list WireGuard interfaces", metadata: ["error": "\(error)"])
        }

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: wgDir) {
            logger.info("WireGuard runtime files", metadata: ["files": "\(contents)"])
        }
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [
            WireGuardPaths.wg, "set", actualInterface,
            "peer", peerPublicKey,
            "allowed-ips", allowedIPs
        ]
        process.environment = WireGuardPaths.environment

        logger.info("Running wg set command", metadata: [
            "interface": "\(actualInterface)",
            "wg_path": "\(WireGuardPaths.wg)"
        ])

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw VPNError.tunnelStartFailed("Failed to add peer: \(errorMessage)")
        }

        // On macOS, `wg set` doesn't add routes, so we need to add them manually
        #if os(macOS)
        try await addRouteForPeer(allowedIPs: allowedIPs, interface: actualInterface)
        #endif
    }

    #if os(macOS)
    /// Add a route for peer's AllowedIPs on macOS
    private func addRouteForPeer(allowedIPs: String, interface: String) async throws {
        // allowedIPs is like "10.223.58.2/32" - add route via the utun interface
        let routeProcess = Process()
        routeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        routeProcess.arguments = ["/sbin/route", "add", "-net", allowedIPs, "-interface", interface]

        let errorPipe = Pipe()
        routeProcess.standardError = errorPipe
        routeProcess.standardOutput = Pipe()

        do {
            try routeProcess.run()
            routeProcess.waitUntilExit()

            if routeProcess.terminationStatus == 0 {
                logger.info("Route added for peer", metadata: [
                    "allowed_ips": "\(allowedIPs)",
                    "interface": "\(interface)"
                ])
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                logger.warning("Failed to add route (may already exist)", metadata: [
                    "error": "\(errorMessage)",
                    "allowed_ips": "\(allowedIPs)"
                ])
            }
        } catch {
            logger.warning("Route add failed", metadata: ["error": "\(error)"])
        }
    }
    #endif

    /// Destroy an ephemeral VPN server
    public func destroyVPN(for jobId: UUID) async throws {
        guard let server = activeServers[jobId] else {
            logger.warning("VPN server not found", metadata: ["job_id": "\(jobId)"])
            return
        }

        logger.info("Destroying ephemeral VPN", metadata: [
            "job_id": "\(jobId)",
            "interface": "\(server.interfaceName)",
            "usedWgQuick": "\(server.usedWgQuick)"
        ])

        switch backend {
        case .dryRun:
            logger.info("Dry run - skipping VPN server stop", metadata: ["interface": "\(server.interfaceName)"])

        case .wgQuick:
            // Remove NAT forwarding rules
            try await removeNATForwarding(interfaceName: server.interfaceName)
            // Stop WireGuard server
            try await stopVPNServerWgQuick(interfaceName: server.interfaceName)
        }

        activeServers.removeValue(forKey: jobId)

        logger.info("Ephemeral VPN destroyed", metadata: ["job_id": "\(jobId)"])
    }

    /// Check if VPN server is accepting connections from provider
    public func isClientConnected(for jobId: UUID) async throws -> Bool {
        guard let server = activeServers[jobId] else {
            return false
        }

        // Need provider public key to check connection
        guard let providerKey = server.providerPublicKey else {
            return false
        }

        // Check WireGuard handshake status
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [WireGuardPaths.wg, "show", server.interfaceName, "latest-handshakes"]

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
        return output.contains(providerKey) && !output.contains("\t0\n")
    }

    // MARK: - Private Methods

    private func generatePrivateKey() throws -> String {
        // Generate random 32-byte key
        let keyData = SymmetricKey(size: .bits256)
        let keyBytes = keyData.withUnsafeBytes { Data($0) }
        return keyBytes.base64EncodedString()
    }

    private func derivePublicKey(from privateKey: String) throws -> String {
        // Use native Curve25519 to derive public key
        // WireGuard uses Curve25519 for key exchange
        guard let privateKeyData = Data(base64Encoded: privateKey), privateKeyData.count == 32 else {
            throw VPNError.invalidConfiguration("Invalid private key format")
        }

        do {
            // Curve25519.KeyAgreement.PrivateKey expects raw 32-byte key
            let curve25519PrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
            let publicKeyData = curve25519PrivateKey.publicKey.rawRepresentation
            return publicKeyData.base64EncodedString()
        } catch {
            throw VPNError.invalidConfiguration("Failed to derive public key: \(error)")
        }
    }

    private func allocatePort() -> UInt16 {
        let port = nextPort
        nextPort += 1
        return port
    }

    private func determineServerEndpoint() async throws -> String {
        // Get the machine's IP address that the VM can reach
        // The VM connects via TAP interface on the same host, so we need the host's
        // IP address on the network that can route to the TAP interface

        // Try to get the default route interface's IP address
        #if os(macOS)
        // On macOS, get the IP of the default interface
        // First, find the default interface using route
        let routeProcess = Process()
        routeProcess.executableURL = URL(fileURLWithPath: "/sbin/route")
        routeProcess.arguments = ["-n", "get", "default"]

        let routePipe = Pipe()
        routeProcess.standardOutput = routePipe
        routeProcess.standardError = Pipe()

        try? routeProcess.run()
        routeProcess.waitUntilExit()

        let routeData = routePipe.fileHandleForReading.readDataToEndOfFile()
        let routeOutput = String(data: routeData, encoding: .utf8) ?? ""

        // Parse output like: "interface: en0"
        var interfaceName: String?
        for line in routeOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                interfaceName = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                break
            }
        }

        if let iface = interfaceName {
            // Get IP address of that interface using ifconfig
            let ifconfigProcess = Process()
            ifconfigProcess.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
            ifconfigProcess.arguments = [iface]

            let ifconfigPipe = Pipe()
            ifconfigProcess.standardOutput = ifconfigPipe
            ifconfigProcess.standardError = Pipe()

            try? ifconfigProcess.run()
            ifconfigProcess.waitUntilExit()

            let ifconfigData = ifconfigPipe.fileHandleForReading.readDataToEndOfFile()
            let ifconfigOutput = String(data: ifconfigData, encoding: .utf8) ?? ""

            // Parse "inet 192.168.1.100 netmask ..."
            for line in ifconfigOutput.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("inet ") && !trimmed.contains("127.0.0.1") {
                    let parts = trimmed.split(separator: " ")
                    if parts.count >= 2 {
                        let ipAddress = String(parts[1])
                        logger.info("Using macOS interface IP for endpoint", metadata: ["interface": "\(iface)", "ip": "\(ipAddress)"])
                        return ipAddress
                    }
                }
            }
        }
        #elseif os(Linux)
        // On Linux, get the IP of the interface with the default route
        let routeProcess = Process()
        routeProcess.executableURL = URL(fileURLWithPath: "/sbin/ip")
        routeProcess.arguments = ["route", "get", "8.8.8.8"]

        let routePipe = Pipe()
        routeProcess.standardOutput = routePipe
        routeProcess.standardError = Pipe()

        try? routeProcess.run()
        routeProcess.waitUntilExit()

        let routeData = routePipe.fileHandleForReading.readDataToEndOfFile()
        let routeOutput = String(data: routeData, encoding: .utf8) ?? ""

        // Parse output like: "8.8.8.8 via 192.168.1.1 dev eth0 src 192.168.1.100 uid 0"
        // We want the "src" address
        if let srcRange = routeOutput.range(of: "src ") {
            let afterSrc = routeOutput[srcRange.upperBound...]
            if let endRange = afterSrc.firstIndex(where: { $0.isWhitespace }) {
                let ipAddress = String(afterSrc[..<endRange])
                if !ipAddress.isEmpty && ipAddress != "127.0.0.1" {
                    logger.info("Using source IP for endpoint", metadata: ["ip": "\(ipAddress)"])
                    return ipAddress
                }
            }
        }
        #endif

        // Fallback: try hostname -I to get IP addresses (Linux)
        let hostIProcess = Process()
        hostIProcess.executableURL = URL(fileURLWithPath: "/bin/hostname")
        hostIProcess.arguments = ["-I"]

        let hostIPipe = Pipe()
        hostIProcess.standardOutput = hostIPipe
        hostIProcess.standardError = Pipe()

        try? hostIProcess.run()
        hostIProcess.waitUntilExit()

        if hostIProcess.terminationStatus == 0 {
            let data = hostIPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // hostname -I returns space-separated IPs, take the first non-localhost one
            let ips = output.split(separator: " ").map(String.init)
            for ip in ips {
                if !ip.hasPrefix("127.") && !ip.contains(":") {  // Skip localhost and IPv6
                    logger.info("Using hostname -I IP for endpoint", metadata: ["ip": "\(ip)"])
                    return ip
                }
            }
        }

        // Last resort: use 127.0.0.1 for local testing
        // This works when consumer and provider are on the same machine
        logger.warning("Could not determine external IP, using 127.0.0.1")
        return "127.0.0.1"
    }

    /// Generate server config WITHOUT peer - peer will be added dynamically
    private func generateServerConfigNoPeer(
        privateKey: String,
        serverIP: String,
        port: UInt16
    ) -> String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(serverIP)/24
        ListenPort = \(port)
        """
    }

    private func startVPNServerWgQuick(
        config: String,
        interfaceName: String
    ) async throws {
        // Write config to user-writable temp directory
        // wg-quick accepts full paths to config files
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-wg").path
        let configPath = "\(configDir)/\(interfaceName).conf"

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: configDir) {
            try FileManager.default.createDirectory(
                atPath: configDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        // Write config file
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Set secure permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configPath
        )

        // Start WireGuard with sudo
        // Set PATH before calling sudo so wg-quick finds bash 4+
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        let pathValue = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
        process.environment = ["PATH": pathValue]
        process.arguments = [WireGuardPaths.wgQuick, "up", configPath]

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

        // On macOS, wireguard-go needs a moment to create the socket
        // before we can use `wg set` to add peers
        // Wait for the socket to appear (up to 5 seconds)
        #if os(macOS)
        let socketPath = "/var/run/wireguard/\(interfaceName).name"
        for _ in 0..<50 {  // 50 * 100ms = 5 seconds max
            if FileManager.default.fileExists(atPath: socketPath) {
                logger.info("WireGuard socket ready", metadata: ["interface": "\(interfaceName)"])
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #endif
    }

    private func stopVPNServerWgQuick(interfaceName: String) async throws {
        // Config is in our temp directory
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-wg").path
        let configPath = "\(configDir)/\(interfaceName).conf"

        // Stop WireGuard with sudo (same pattern as start)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        let pathValue = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
        process.environment = ["PATH": pathValue]
        process.arguments = [WireGuardPaths.wgQuick, "down", configPath]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        // Log any errors but don't fail - interface might already be down
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.warning("wg-quick down returned error (interface may already be down)", metadata: [
                "interface": "\(interfaceName)",
                "error": "\(errorMessage)"
            ])
        }

        // Clean up config file
        try? FileManager.default.removeItem(atPath: configPath)

        logger.info("VPN server stopped", metadata: ["interface": "\(interfaceName)"])
    }

    // MARK: - NAT Forwarding

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

    // MARK: - VPNProvider Protocol

    /// Create a VPN tunnel for a VM session (VPNProvider protocol)
    public func createVPN(for vmId: UUID) async throws -> VPNConfiguration {
        try await createVPNForJob(vmId)
    }

    /// Check if a VPN tunnel is connected (VPNProvider protocol)
    public func isConnected(for vmId: UUID) async throws -> Bool {
        try await isClientConnected(for: vmId)
    }

    /// Get all active VPN tunnel IDs (VPNProvider protocol)
    public func getActiveTunnels() async -> [UUID] {
        Array(activeServers.keys)
    }
}

/// VPN server instance
public struct VPNServer: Sendable {
    public let jobId: UUID
    public let interfaceName: String
    public let port: UInt16
    public let serverVPNIP: String       // Consumer's VPN IP (e.g., 10.99.0.1)
    public let clientVPNIP: String       // VM's VPN IP (e.g., 10.99.0.2)
    public let serverPrivateKey: String  // Consumer's private key
    public let serverPublicKey: String   // Consumer's public key
    public let endpoint: String          // Consumer's WireGuard endpoint (IP:port)
    public var providerPublicKey: String? // Provider's public key (set after response)
    public let createdAt: Date
    /// True if wg-quick was used (either as primary backend or as fallback from Network Extension)
    public let usedWgQuick: Bool
}

// MARK: - Static Cleanup Methods

/// Cleanup utilities for orphaned WireGuard interfaces
/// These are static so they can be used without an EphemeralVPN instance
public enum WireGuardCleanup {
    private static let logger = Logger(label: "com.omerta.wg-cleanup")

    /// Pattern for Omerta-managed WireGuard interfaces
    /// Consumer format: wg + 8 hex chars (e.g., wg3AD3F0D1)
    /// Provider format: wg- + 8 hex chars (e.g., wg-3AD3F0D1)
    /// Also matches tap interfaces: tap- + 8 hex chars (e.g., tap-3AD3F0D1)
    public static let interfacePattern = #"^(wg-?|tap-)[0-9A-Fa-f]{8}$"#

    /// List all active WireGuard interfaces
    public static func listAllInterfaces() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [WireGuardPaths.wg, "show", "interfaces"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// List only Omerta-managed interfaces (matching our naming pattern)
    /// On macOS, also checks /var/run/wireguard/*.name files for interface mappings
    /// On Linux, also checks `ip link` for native kernel WireGuard interfaces
    public static func listOmertaInterfaces() throws -> [String] {
        var omertaInterfaces: [String] = []
        let regex = try NSRegularExpression(pattern: interfacePattern)

        // Method 1: Check wg show interfaces output
        let allInterfaces = try listAllInterfaces()

        for interfaceName in allInterfaces {
            let range = NSRange(interfaceName.startIndex..., in: interfaceName)
            if regex.firstMatch(in: interfaceName, range: range) != nil {
                omertaInterfaces.append(interfaceName)
            }
        }

        #if os(macOS)
        // Method 2: On macOS, check /var/run/wireguard/*.name files
        // These map our config names to utun interfaces
        let wireguardRunDir = "/var/run/wireguard"
        if FileManager.default.fileExists(atPath: wireguardRunDir) {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: wireguardRunDir) {
                for file in files where file.hasSuffix(".name") {
                    // Extract config name from filename (e.g., "wg3E8EBF8E.name" -> "wg3E8EBF8E")
                    let configName = String(file.dropLast(5))
                    let range = NSRange(configName.startIndex..., in: configName)
                    if regex.firstMatch(in: configName, range: range) != nil {
                        if !omertaInterfaces.contains(configName) {
                            omertaInterfaces.append(configName)
                        }
                    }
                }
            }
        }
        #else
        // Method 2: On Linux, check `ip link` for native kernel interfaces
        // Native WireGuard interfaces may not show up in `wg show interfaces`
        let ipProcess = Process()
        ipProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/ip")
        ipProcess.arguments = ["link", "show"]

        let ipPipe = Pipe()
        ipProcess.standardOutput = ipPipe
        ipProcess.standardError = FileHandle.nullDevice

        try? ipProcess.run()
        ipProcess.waitUntilExit()

        if ipProcess.terminationStatus == 0 {
            let data = ipPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Parse interface names from `ip link` output
            // Format: "29: wg-892362D4: <POINTOPOINT,..."
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: ":")
                if parts.count >= 2 {
                    let interfaceName = parts[1].trimmingCharacters(in: .whitespaces)
                    let range = NSRange(interfaceName.startIndex..., in: interfaceName)
                    if regex.firstMatch(in: interfaceName, range: range) != nil {
                        if !omertaInterfaces.contains(interfaceName) {
                            omertaInterfaces.append(interfaceName)
                        }
                    }
                }
            }
        }
        #endif

        return omertaInterfaces
    }

    /// Stop a WireGuard interface by name
    public static func stopInterface(_ interfaceName: String) throws {
        // First try with config file path (if it exists)
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-wg").path
        let configPath = "\(configDir)/\(interfaceName).conf"

        let pathValue = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

        var wgQuickSuccess = false

        // Try with config path first
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.environment = ["PATH": pathValue]

        if FileManager.default.fileExists(atPath: configPath) {
            process.arguments = [WireGuardPaths.wgQuick, "down", configPath]
        } else {
            // Fall back to interface name (for interfaces created without our config)
            process.arguments = [WireGuardPaths.wgQuick, "down", interfaceName]
        }

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        wgQuickSuccess = process.terminationStatus == 0

        // Clean up config file if it exists
        try? FileManager.default.removeItem(atPath: configPath)

        #if os(macOS)
        // Clean up macOS name file if it exists (in /var/run/wireguard/)
        let nameFilePath = "/var/run/wireguard/\(interfaceName).name"
        if FileManager.default.fileExists(atPath: nameFilePath) {
            // Need sudo to remove files in /var/run/wireguard
            let rmProcess = Process()
            rmProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            rmProcess.arguments = ["rm", "-f", nameFilePath]
            rmProcess.standardError = FileHandle.nullDevice
            try? rmProcess.run()
            rmProcess.waitUntilExit()
            logger.info("Removed name file", metadata: ["path": "\(nameFilePath)"])
        }
        #else
        // On Linux, if wg-quick failed, try `ip link delete` for native kernel interfaces
        if !wgQuickSuccess {
            logger.info("wg-quick failed, trying ip link delete", metadata: ["interface": "\(interfaceName)"])

            let ipProcess = Process()
            ipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            ipProcess.arguments = ["ip", "link", "delete", interfaceName]
            ipProcess.standardOutput = FileHandle.nullDevice
            ipProcess.standardError = FileHandle.nullDevice

            try? ipProcess.run()
            ipProcess.waitUntilExit()

            if ipProcess.terminationStatus == 0 {
                logger.info("Deleted interface via ip link", metadata: ["interface": "\(interfaceName)"])
                wgQuickSuccess = true  // Mark as success since we deleted it
            }
        }
        #endif

        if !wgQuickSuccess {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.warning("Failed to stop interface", metadata: [
                "interface": "\(interfaceName)",
                "error": "\(errorMessage)"
            ])
        } else {
            logger.info("Stopped interface", metadata: ["interface": "\(interfaceName)"])
        }
    }

    /// Stop all Omerta-managed WireGuard interfaces
    public static func cleanupAllOmertaInterfaces() throws -> [String] {
        let interfaces = try listOmertaInterfaces()

        for interfaceName in interfaces {
            try stopInterface(interfaceName)
        }

        // Also clean up any leftover config files
        cleanupConfigFiles()

        return interfaces
    }

    /// Stop orphaned interfaces (interfaces not in the tracked list)
    public static func cleanupOrphanedInterfaces(trackedInterfaceNames: Set<String>) throws -> [String] {
        let activeInterfaces = try listOmertaInterfaces()
        var cleaned: [String] = []

        for interfaceName in activeInterfaces {
            if !trackedInterfaceNames.contains(interfaceName) {
                logger.info("Cleaning up orphaned interface", metadata: ["interface": "\(interfaceName)"])
                try stopInterface(interfaceName)
                cleaned.append(interfaceName)
            }
        }

        return cleaned
    }

    /// Clean up leftover config files in temp directory
    public static func cleanupConfigFiles() {
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-wg").path

        guard FileManager.default.fileExists(atPath: configDir) else { return }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: configDir)
            for file in files where file.hasSuffix(".conf") {
                let filePath = "\(configDir)/\(file)"
                try? FileManager.default.removeItem(atPath: filePath)
                logger.info("Removed config file", metadata: ["path": "\(filePath)"])
            }
        } catch {
            logger.warning("Failed to list config directory", metadata: ["error": "\(error)"])
        }
    }

    /// Get cleanup status report
    public static func getCleanupStatus() throws -> CleanupStatus {
        let omertaInterfaces = try listOmertaInterfaces()

        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-wg").path
        var configFiles: [String] = []
        if FileManager.default.fileExists(atPath: configDir) {
            configFiles = (try? FileManager.default.contentsOfDirectory(atPath: configDir)
                .filter { $0.hasSuffix(".conf") }) ?? []
        }

        // Check for orphaned wireguard-go processes
        let orphanedProcesses = listOrphanedWireGuardProcesses()

        return CleanupStatus(
            activeInterfaces: omertaInterfaces,
            configFiles: configFiles,
            configDirectory: configDir,
            orphanedProcesses: orphanedProcesses
        )
    }

    /// List orphaned wireguard-go processes (processes without matching interfaces)
    public static func listOrphanedWireGuardProcesses() -> [OrphanedProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "wireguard-go"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var processes: [OrphanedProcess] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if let pidStr = parts.first, let pid = Int32(pidStr) {
                let command = parts.count > 1 ? String(parts[1]) : "wireguard-go"
                processes.append(OrphanedProcess(pid: pid, command: command))
            }
        }

        return processes
    }

    /// Kill orphaned wireguard-go processes
    public static func killOrphanedProcesses(_ processes: [OrphanedProcess]) throws -> Int {
        guard !processes.isEmpty else { return 0 }

        var killed = 0
        for proc in processes {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["kill", "-9", String(proc.pid)]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                killed += 1
                logger.info("Killed orphaned process", metadata: ["pid": "\(proc.pid)"])
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown error"
                logger.warning("Failed to kill process", metadata: [
                    "pid": "\(proc.pid)",
                    "error": "\(errorMsg)"
                ])
            }
        }

        return killed
    }
}

/// Represents an orphaned wireguard-go process
public struct OrphanedProcess: Sendable {
    public let pid: Int32
    public let command: String
}

/// Status of WireGuard resources that may need cleanup
public struct CleanupStatus: Sendable {
    public let activeInterfaces: [String]
    public let configFiles: [String]
    public let configDirectory: String
    public let orphanedProcesses: [OrphanedProcess]

    public var needsCleanup: Bool {
        !activeInterfaces.isEmpty || !configFiles.isEmpty || !orphanedProcesses.isEmpty
    }
}
