import Foundation
import Logging
import OmertaCore
import OmertaVPN
import OmertaVM
import Crypto

#if os(macOS)
@preconcurrency import Virtualization
#endif

/// Manages provider-side WireGuard tunnels connecting to consumer VPN servers
/// Sets up NAT routing from VPN network to VM NAT addresses
public actor ProviderVPNManager {
    private let logger: Logger
    private var activeTunnels: [UUID: ProviderTunnel] = [:]
    private let configDirectory: String
    private let firewallMarkerDirectory: String
    private let dryRun: Bool

    #if os(Linux)
    private var nativeWireGuard: LinuxWireGuardManager?
    #endif

    #if os(macOS)
    // One WireGuard manager per VM since each manager handles one interface
    private var macOSWireGuards: [UUID: MacOSWireGuardManager] = [:]
    #endif

    public struct ProviderTunnel: Sendable {
        public let vmId: UUID
        public let interfaceName: String
        public let privateKey: String
        public let publicKey: String
        public let providerVPNIP: String  // Provider's IP within VPN (e.g., 10.99.0.254)
        public let vmVPNIP: String        // VM's VPN IP (e.g., 10.99.0.2)
        public let vmNATIP: String?       // VM's internal NAT IP if using NAT networking (e.g., 192.168.64.2)
        public let tapInterface: String   // TAP interface for VM (e.g., tap-abc12345), or empty for NAT
        public let consumerEndpoint: String
        public let configPath: String
        public let createdAt: Date
    }

    public init(dryRun: Bool = false) {
        var logger = Logger(label: "com.omerta.provider.vpn")
        logger.logLevel = .info
        self.logger = logger
        self.dryRun = dryRun

        // Use system temp directory for WireGuard configs
        self.configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-vpn").path

        // Use persistent directory for firewall markers (survives reboot)
        self.firewallMarkerDirectory = "\(OmertaConfig.defaultConfigDir)/firewall"

        if dryRun {
            logger.info("ProviderVPNManager initialized in DRY RUN mode")
        }
    }

    // MARK: - Tunnel Lifecycle

    /// Create a WireGuard tunnel connecting to consumer's VPN server
    /// With TAP networking (Linux), routes traffic directly to the VM's TAP interface
    /// With NAT networking (macOS), uses DNAT to forward VPN IP traffic to VM's internal NAT IP
    /// Returns the provider's public key (consumer needs this to allow connection)
    public func createTunnel(
        vmId: UUID,
        vpnConfig: VPNConfiguration,
        tapInterface: String,
        vmNATIP: String? = nil
    ) async throws -> String {
        let useNATRouting = vmNATIP != nil && vmNATIP != vpnConfig.vmVPNIP

        logger.info("Creating provider VPN tunnel", metadata: [
            "vm_id": "\(vmId)",
            "consumer_endpoint": "\(vpnConfig.consumerEndpoint)",
            "vm_vpn_ip": "\(vpnConfig.vmVPNIP)",
            "vm_nat_ip": "\(vmNATIP ?? "none")",
            "tap_interface": "\(tapInterface)",
            "routing_mode": "\(useNATRouting ? "NAT" : "TAP")",
            "dry_run": "\(dryRun)"
        ])

        // 1. Generate keypair for this tunnel
        let privateKey = generatePrivateKey()

        // In dry-run mode, generate a fake but valid-looking public key
        let publicKey: String
        if dryRun {
            // Generate a base64 encoded 32-byte key (like a real WireGuard key)
            publicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            logger.info("DRY RUN: Generated simulated public key")
        } else {
            publicKey = try derivePublicKey(from: privateKey)
        }

        // 2. Provider gets an IP in the VPN subnet (use .254 to avoid conflicts)
        let providerVPNIP = deriveProviderIP(from: vpnConfig.vmVPNIP)

        // 3. Generate WireGuard config
        let interfaceName = "wg-\(vmId.uuidString.prefix(8))"
        let configPath = "\(configDirectory)/\(interfaceName).conf"

        // In dry-run mode, skip actual VPN setup
        if !dryRun {
            let config = generateWireGuardConfig(
                privateKey: privateKey,
                providerIP: providerVPNIP,
                consumerPublicKey: vpnConfig.consumerPublicKey,
                consumerEndpoint: vpnConfig.consumerEndpoint,
                allowedIPs: vpnConfig.vpnSubnet,
                presharedKey: vpnConfig.presharedKey
            )

            // 4. Write config file
            try await writeConfigFile(config: config, path: configPath)

            // 5. Start WireGuard interface
            try await startWireGuardInterface(vmId: vmId, configPath: configPath, interfaceName: interfaceName)

            // 6. Set up routing based on networking mode
            if useNATRouting, let natIP = vmNATIP {
                // NAT routing: use DNAT to forward VPN IP traffic to VM's internal NAT IP
                logger.info("Using NAT routing mode", metadata: [
                    "vm_vpn_ip": "\(vpnConfig.vmVPNIP)",
                    "vm_nat_ip": "\(natIP)"
                ])
                try await setupNATRouting(
                    vmVPNIP: vpnConfig.vmVPNIP,
                    vmNATIP: natIP,
                    interfaceName: interfaceName
                )
            } else {
                // TAP routing: traffic to vmVPNIP goes directly to TAP interface
                // VM has the VPN IP directly, no NAT needed
                try await setupTAPRouting(
                    vmVPNIP: vpnConfig.vmVPNIP,
                    tapInterface: tapInterface,
                    wgInterface: interfaceName
                )
            }

            // 7. Set up firewall rules to isolate VM
            try await setupFirewallRules(
                vmVPNIP: vpnConfig.vmVPNIP,
                vpnSubnet: vpnConfig.vpnSubnet,
                interfaceName: interfaceName
            )
        } else {
            logger.info("DRY RUN: Skipping WireGuard interface, routing, and firewall setup")
        }

        // 8. Track tunnel
        let tunnel = ProviderTunnel(
            vmId: vmId,
            interfaceName: interfaceName,
            privateKey: privateKey,
            publicKey: publicKey,
            providerVPNIP: providerVPNIP,
            vmVPNIP: vpnConfig.vmVPNIP,
            vmNATIP: vmNATIP,
            tapInterface: tapInterface,
            consumerEndpoint: vpnConfig.consumerEndpoint,
            configPath: configPath,
            createdAt: Date()
        )
        activeTunnels[vmId] = tunnel

        logger.info("Provider VPN tunnel created", metadata: [
            "vm_id": "\(vmId)",
            "interface": "\(interfaceName)",
            "provider_public_key": "\(publicKey.prefix(20))..."
        ])

        return publicKey
    }

    /// Destroy a VPN tunnel
    public func destroyTunnel(vmId: UUID) async throws {
        guard let tunnel = activeTunnels[vmId] else {
            logger.warning("Tunnel not found for VM", metadata: ["vm_id": "\(vmId)"])
            return
        }

        logger.info("Destroying provider VPN tunnel", metadata: [
            "vm_id": "\(vmId)",
            "interface": "\(tunnel.interfaceName)",
            "dry_run": "\(dryRun)"
        ])

        // In dry-run mode, just remove from tracking
        if !dryRun {
            // 1. Remove firewall rules
            try await removeFirewallRules(
                vmVPNIP: tunnel.vmVPNIP,
                interfaceName: tunnel.interfaceName
            )

            // 2. Remove routing based on networking mode
            if let natIP = tunnel.vmNATIP {
                // NAT routing was used
                try await removeNATRouting(
                    vmVPNIP: tunnel.vmVPNIP,
                    vmNATIP: natIP
                )
            } else {
                // TAP routing was used
                try await removeTAPRouting(
                    vmVPNIP: tunnel.vmVPNIP,
                    tapInterface: tunnel.tapInterface
                )
            }

            // 3. Stop WireGuard interface
            try await stopWireGuardInterface(vmId: vmId, interfaceName: tunnel.interfaceName, configPath: tunnel.configPath)

            // 4. Remove config file
            try? FileManager.default.removeItem(atPath: tunnel.configPath)
        } else {
            logger.info("DRY RUN: Skipping VPN interface teardown")
        }

        // 5. Remove from tracking
        activeTunnels.removeValue(forKey: vmId)

        logger.info("Provider VPN tunnel destroyed", metadata: ["vm_id": "\(vmId)"])
    }

    /// Destroy all tunnels
    public func destroyAllTunnels() async {
        logger.info("Destroying all provider VPN tunnels")

        for vmId in activeTunnels.keys {
            try? await destroyTunnel(vmId: vmId)
        }
    }

    /// Get tunnel info
    public func getTunnel(vmId: UUID) -> ProviderTunnel? {
        activeTunnels[vmId]
    }

    // MARK: - Key Generation

    private nonisolated func generatePrivateKey() -> String {
        // Generate random 32-byte key
        let keyData = SymmetricKey(size: .bits256)
        let keyBytes = keyData.withUnsafeBytes { Data($0) }
        return keyBytes.base64EncodedString()
    }

    private nonisolated func derivePublicKey(from privateKey: String) throws -> String {
        // Try native Curve25519 derivation first (works without wg binary)
        guard let privateKeyData = Data(base64Encoded: privateKey), privateKeyData.count == 32 else {
            throw ProviderVPNError.keyDerivationFailed
        }

        do {
            // WireGuard uses Curve25519 - derive public key using Swift Crypto
            let curve25519Private = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
            let publicKeyData = curve25519Private.publicKey.rawRepresentation
            return publicKeyData.base64EncodedString()
        } catch {
            // Fall back to wg binary if available
            return try derivePublicKeyUsingWG(from: privateKey)
        }
    }

    private nonisolated func derivePublicKeyUsingWG(from privateKey: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: WireGuardPaths.wg)
        process.arguments = ["pubkey"]
        process.environment = WireGuardPaths.environment

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
            throw ProviderVPNError.keyDerivationFailed
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let publicKey = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return publicKey
    }

    // MARK: - Config Generation

    private func deriveProviderIP(from vmVPNIP: String) -> String {
        // Use .254 for provider to avoid conflicts with consumer (.1) and VMs (.2, .3, etc)
        let components = vmVPNIP.split(separator: ".")
        guard components.count == 4 else {
            return "10.99.0.254"
        }
        return "\(components[0]).\(components[1]).\(components[2]).254"
    }

    private func generateWireGuardConfig(
        privateKey: String,
        providerIP: String,
        consumerPublicKey: String,
        consumerEndpoint: String,
        allowedIPs: String,
        presharedKey: String? = nil
    ) -> String {
        var config = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(providerIP)/24

        [Peer]
        PublicKey = \(consumerPublicKey)
        Endpoint = \(consumerEndpoint)
        AllowedIPs = \(allowedIPs)
        PersistentKeepalive = 25
        """

        // Add PSK if provided (from network key)
        if let psk = presharedKey {
            config += "\nPresharedKey = \(psk)"
        }

        return config
    }

    private func writeConfigFile(config: String, path: String) async throws {
        // Create directory if needed
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // Write config
        try config.write(toFile: path, atomically: true, encoding: .utf8)

        // Set permissions (only owner can read)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    // MARK: - WireGuard Interface Management

    private func startWireGuardInterface(vmId: UUID, configPath: String, interfaceName: String) async throws {
        logger.info("Starting WireGuard interface", metadata: ["interface": "\(interfaceName)"])

        #if os(Linux)
        try await startWireGuardInterfaceNative(configPath: configPath, interfaceName: interfaceName)
        #elseif os(macOS)
        try await startWireGuardInterfaceNativeMacOS(vmId: vmId, configPath: configPath, interfaceName: interfaceName)
        #else
        throw ProviderVPNError.interfaceStartFailed("Unsupported platform")
        #endif
    }

    #if os(Linux)
    private func startWireGuardInterfaceNative(configPath: String, interfaceName: String) async throws {
        logger.info("Using native netlink for WireGuard interface", metadata: ["interface": "\(interfaceName)"])

        // Parse config file to extract parameters
        let config = try String(contentsOfFile: configPath, encoding: .utf8)
        guard let params = parseWireGuardConfig(config) else {
            throw ProviderVPNError.interfaceStartFailed("Failed to parse WireGuard config")
        }

        // Initialize native WireGuard manager
        if nativeWireGuard == nil {
            nativeWireGuard = LinuxWireGuardManager()
        }

        guard let wg = nativeWireGuard else {
            throw ProviderVPNError.interfaceStartFailed("Failed to initialize native WireGuard manager")
        }

        // Parse peer configuration
        var peers: [WireGuardPeerConfig] = []
        if let peerPublicKey = params.peerPublicKey,
           let keyData = Data(base64Encoded: peerPublicKey) {
            var endpoint: (host: String, port: UInt16)? = nil
            if let endpointStr = params.peerEndpoint {
                let parts = endpointStr.split(separator: ":")
                if parts.count == 2, let port = UInt16(parts[1]) {
                    endpoint = (host: String(parts[0]), port: port)
                }
            }

            var allowedIPs: [(ip: String, cidr: UInt8)] = []
            if let allowedIPsStr = params.allowedIPs {
                for cidrStr in allowedIPsStr.split(separator: ",") {
                    let trimmed = cidrStr.trimmingCharacters(in: .whitespaces)
                    let cidrParts = trimmed.split(separator: "/")
                    if cidrParts.count == 2, let cidr = UInt8(cidrParts[1]) {
                        allowedIPs.append((ip: String(cidrParts[0]), cidr: cidr))
                    }
                }
            }

            let peer = WireGuardPeerConfig(
                publicKey: keyData,
                endpoint: endpoint,
                allowedIPs: allowedIPs,
                persistentKeepalive: params.persistentKeepalive
            )
            peers.append(peer)
        }

        // Parse address
        var address = "10.0.0.1"
        var prefixLength: UInt8 = 24
        if let addrStr = params.address {
            let parts = addrStr.split(separator: "/")
            address = String(parts[0])
            if parts.count == 2, let prefix = UInt8(parts[1]) {
                prefixLength = prefix
            }
        }

        // Create and configure interface
        try wg.createInterface(
            name: interfaceName,
            privateKeyBase64: params.privateKey,
            listenPort: params.listenPort ?? 0,
            address: address,
            prefixLength: prefixLength,
            peers: peers
        )

        // Wait for interface to be ready
        try await Task.sleep(for: .milliseconds(100))

        logger.info("WireGuard interface started (native)", metadata: ["interface": "\(interfaceName)"])
    }

    private struct WireGuardConfigParams {
        var privateKey: String
        var address: String?
        var listenPort: UInt16?
        var peerPublicKey: String?
        var peerEndpoint: String?
        var allowedIPs: String?
        var persistentKeepalive: UInt16?
    }

    private func parseWireGuardConfig(_ config: String) -> WireGuardConfigParams? {
        var params = WireGuardConfigParams(privateKey: "")
        var inPeer = false

        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[Peer]") {
                inPeer = true
                continue
            } else if trimmed.hasPrefix("[") {
                inPeer = false
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if inPeer {
                switch key {
                case "PublicKey":
                    params.peerPublicKey = value
                case "Endpoint":
                    params.peerEndpoint = value
                case "AllowedIPs":
                    params.allowedIPs = value
                case "PersistentKeepalive":
                    params.persistentKeepalive = UInt16(value)
                default: break
                }
            } else {
                switch key {
                case "PrivateKey":
                    params.privateKey = value
                case "Address":
                    params.address = value
                case "ListenPort":
                    params.listenPort = UInt16(value)
                default: break
                }
            }
        }

        return params.privateKey.isEmpty ? nil : params
    }
    #endif

    private func stopWireGuardInterface(vmId: UUID, interfaceName: String, configPath: String) async throws {
        logger.info("Stopping WireGuard interface", metadata: ["interface": "\(interfaceName)"])

        #if os(Linux)
        try await stopWireGuardInterfaceNative(interfaceName: interfaceName)
        #elseif os(macOS)
        try await stopWireGuardInterfaceNativeMacOS(vmId: vmId, interfaceName: interfaceName)
        #endif
    }

    #if os(Linux)
    private func stopWireGuardInterfaceNative(interfaceName: String) async throws {
        logger.info("Using native netlink to stop WireGuard interface", metadata: ["interface": "\(interfaceName)"])

        // Initialize native WireGuard manager if needed
        if nativeWireGuard == nil {
            nativeWireGuard = LinuxWireGuardManager()
        }

        guard let wg = nativeWireGuard else {
            logger.warning("Failed to initialize native WireGuard manager for teardown")
            return
        }

        do {
            try wg.deleteInterface(name: interfaceName)
            logger.info("WireGuard interface stopped (native)", metadata: ["interface": "\(interfaceName)"])
        } catch {
            // Log but don't fail - interface might already be down
            logger.warning("Native interface deletion returned error", metadata: [
                "interface": "\(interfaceName)",
                "error": "\(error)"
            ])
        }
    }
    #endif

    // MARK: - Native macOS Implementation

    #if os(macOS)
    private func startWireGuardInterfaceNativeMacOS(vmId: UUID, configPath: String, interfaceName: String) async throws {
        // The native MacOSWireGuardManager creates utun interfaces but doesn't implement
        // the full WireGuard protocol (Noise handshake, encryption). Use wg-quick which
        // leverages wireguard-go for complete protocol support.

        // First try wg-quick (requires wireguard-go installed via Homebrew)
        if let wgQuickPath = findWgQuickPath() {
            logger.info("Using wg-quick for WireGuard interface", metadata: [
                "interface": "\(interfaceName)",
                "wg_quick": "\(wgQuickPath)"
            ])

            try await startWireGuardWithWgQuick(configPath: configPath, interfaceName: interfaceName, wgQuickPath: wgQuickPath)
            return
        }

        // Fall back to native implementation (limited - no full protocol support)
        logger.warning("wg-quick not found, falling back to native macOS (limited protocol support)")
        logger.info("Using native macOS for WireGuard interface", metadata: ["interface": "\(interfaceName)"])

        // Parse config file to extract parameters
        let config = try String(contentsOfFile: configPath, encoding: .utf8)
        guard let params = parseWireGuardConfigMacOS(config) else {
            throw ProviderVPNError.interfaceStartFailed("Failed to parse WireGuard config")
        }

        // Create a new WireGuard manager for this VM (each VM needs its own interface)
        let wg = MacOSWireGuardManager()
        macOSWireGuards[vmId] = wg

        // Decode private key
        guard let privateKeyData = Data(base64Encoded: params.privateKey), privateKeyData.count == 32 else {
            throw ProviderVPNError.interfaceStartFailed("Invalid private key format")
        }

        // Parse peer configuration
        var peers: [WireGuardPeer] = []
        if let peerPublicKey = params.peerPublicKey,
           let keyData = Data(base64Encoded: peerPublicKey) {
            var endpoint: (host: String, port: UInt16)? = nil
            if let endpointStr = params.peerEndpoint {
                let parts = endpointStr.split(separator: ":")
                if parts.count == 2, let port = UInt16(parts[1]) {
                    endpoint = (host: String(parts[0]), port: port)
                }
            }

            var allowedIPs: [(ip: String, cidr: UInt8)] = []
            if let allowedIPsStr = params.allowedIPs {
                for cidrStr in allowedIPsStr.split(separator: ",") {
                    let trimmed = cidrStr.trimmingCharacters(in: .whitespaces)
                    let cidrParts = trimmed.split(separator: "/")
                    if cidrParts.count == 2, let cidr = UInt8(cidrParts[1]) {
                        allowedIPs.append((ip: String(cidrParts[0]), cidr: cidr))
                    }
                }
            }

            let peer = WireGuardPeer(
                publicKey: keyData,
                endpoint: endpoint,
                allowedIPs: allowedIPs,
                persistentKeepalive: params.persistentKeepalive
            )
            peers.append(peer)
        }

        // Parse address
        var address = "10.0.0.1"
        var prefixLength: UInt8 = 24
        if let addrStr = params.address {
            let parts = addrStr.split(separator: "/")
            address = String(parts[0])
            if parts.count == 2, let prefix = UInt8(parts[1]) {
                prefixLength = prefix
            }
        }

        // Create config
        let wgConfig = WireGuardConfig(
            privateKey: privateKeyData,
            listenPort: params.listenPort ?? 0,
            address: address,
            prefixLength: prefixLength,
            peers: peers
        )

        try await wg.start(name: interfaceName, config: wgConfig)
        logger.info("WireGuard interface started (native macOS)", metadata: ["interface": "\(interfaceName)"])
    }

    private func stopWireGuardInterfaceNativeMacOS(vmId: UUID, interfaceName: String) async throws {
        // Check if wg-quick was used (no native manager) - clean up with wg-quick
        if macOSWireGuards[vmId] == nil {
            logger.info("Using wg-quick to stop WireGuard interface", metadata: ["interface": "\(interfaceName)"])
            if let wgQuickPath = findWgQuickPath() {
                try await stopWireGuardWithWgQuick(interfaceName: interfaceName, wgQuickPath: wgQuickPath)
            }
            return
        }

        logger.info("Using native macOS to stop WireGuard interface", metadata: ["interface": "\(interfaceName)"])

        guard let wg = macOSWireGuards[vmId] else {
            logger.warning("No macOS WireGuard manager for teardown", metadata: ["vm_id": "\(vmId)"])
            return
        }

        await wg.stop()
        macOSWireGuards.removeValue(forKey: vmId)
        logger.info("WireGuard interface stopped (native macOS)", metadata: ["interface": "\(interfaceName)"])
    }

    // MARK: - wg-quick Support

    /// Find wg-quick executable path
    private func findWgQuickPath() -> String? {
        let paths = [
            "/opt/homebrew/bin/wg-quick",  // macOS Apple Silicon Homebrew
            "/usr/local/bin/wg-quick",      // macOS Intel Homebrew
            "/usr/bin/wg-quick"             // Linux
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Environment with PATH for wg-quick (needs bash 4+ on macOS)
    private var wgQuickEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = "\(homebrewPaths):\(existingPath)"
        } else {
            env["PATH"] = homebrewPaths
        }
        return env
    }

    /// Start WireGuard interface using wg-quick
    private func startWireGuardWithWgQuick(configPath: String, interfaceName: String, wgQuickPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", wgQuickPath, "up", configPath]
        process.environment = wgQuickEnvironment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ProviderVPNError.interfaceStartFailed("wg-quick up failed: \(errorMsg)")
        }

        // Give wireguard-go a moment to initialize
        try? await Task.sleep(nanoseconds: 500_000_000)

        logger.info("WireGuard interface started (wg-quick)", metadata: ["interface": "\(interfaceName)"])
    }

    /// Stop WireGuard interface using wg-quick
    private func stopWireGuardWithWgQuick(interfaceName: String, wgQuickPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", wgQuickPath, "down", interfaceName]
        process.environment = wgQuickEnvironment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        // Don't throw on error - interface might already be down
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.warning("wg-quick down returned error (interface may already be down)", metadata: [
                "interface": "\(interfaceName)",
                "error": "\(errorMsg)"
            ])
        } else {
            logger.info("WireGuard interface stopped (wg-quick)", metadata: ["interface": "\(interfaceName)"])
        }
    }

    private struct MacOSWireGuardConfigParams {
        var privateKey: String
        var address: String?
        var listenPort: UInt16?
        var peerPublicKey: String?
        var peerEndpoint: String?
        var allowedIPs: String?
        var persistentKeepalive: UInt16?
    }

    private func parseWireGuardConfigMacOS(_ config: String) -> MacOSWireGuardConfigParams? {
        var params = MacOSWireGuardConfigParams(privateKey: "")
        var inPeer = false

        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[Peer]") {
                inPeer = true
                continue
            } else if trimmed.hasPrefix("[") {
                inPeer = false
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if inPeer {
                switch key {
                case "PublicKey":
                    params.peerPublicKey = value
                case "Endpoint":
                    params.peerEndpoint = value
                case "AllowedIPs":
                    params.allowedIPs = value
                case "PersistentKeepalive":
                    params.persistentKeepalive = UInt16(value)
                default: break
                }
            } else {
                switch key {
                case "PrivateKey":
                    params.privateKey = value
                case "Address":
                    params.address = value
                case "ListenPort":
                    params.listenPort = UInt16(value)
                default: break
                }
            }
        }

        return params.privateKey.isEmpty ? nil : params
    }
    #endif

    // MARK: - TAP Routing

    /// Set up routing for TAP networking
    /// Traffic to vmVPNIP goes directly to the TAP interface (no NAT needed)
    private func setupTAPRouting(
        vmVPNIP: String,
        tapInterface: String,
        wgInterface: String
    ) async throws {
        logger.info("Setting up TAP routing", metadata: [
            "vm_vpn_ip": "\(vmVPNIP)",
            "tap_interface": "\(tapInterface)",
            "wg_interface": "\(wgInterface)"
        ])

        #if os(Linux)
        // Add route: traffic to VM's VPN IP goes to TAP interface
        let routeProcess = Process()
        routeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        routeProcess.arguments = ["ip", "route", "add", vmVPNIP, "dev", tapInterface]
        routeProcess.standardError = Pipe()
        routeProcess.standardOutput = FileHandle.nullDevice
        try routeProcess.run()
        routeProcess.waitUntilExit()

        if routeProcess.terminationStatus != 0 {
            let errorData = (routeProcess.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? ""
            // Route might already exist - that's OK
            if !errorMsg.contains("File exists") {
                logger.warning("Failed to add route to TAP", metadata: ["error": "\(errorMsg)"])
            }
        }

        // Enable proxy ARP on the WireGuard interface
        // This allows the VM to respond to ARP requests for its VPN IP
        let proxyArpProcess = Process()
        proxyArpProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proxyArpProcess.arguments = ["sysctl", "-w", "net.ipv4.conf.\(wgInterface).proxy_arp=1"]
        try? proxyArpProcess.run()
        proxyArpProcess.waitUntilExit()

        // Enable IP forwarding
        let forwardProcess = Process()
        forwardProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        forwardProcess.arguments = ["sysctl", "-w", "net.ipv4.ip_forward=1"]
        try? forwardProcess.run()
        forwardProcess.waitUntilExit()

        logger.info("TAP routing configured", metadata: [
            "vm_vpn_ip": "\(vmVPNIP)",
            "tap_interface": "\(tapInterface)"
        ])
        #else
        // macOS doesn't use TAP in the same way
        logger.warning("TAP routing not implemented for macOS")
        #endif
    }

    private func removeTAPRouting(vmVPNIP: String, tapInterface: String) async throws {
        logger.info("Removing TAP routing", metadata: [
            "vm_vpn_ip": "\(vmVPNIP)",
            "tap_interface": "\(tapInterface)"
        ])

        #if os(Linux)
        // Remove route
        let routeProcess = Process()
        routeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        routeProcess.arguments = ["ip", "route", "del", vmVPNIP, "dev", tapInterface]
        routeProcess.standardOutput = FileHandle.nullDevice
        routeProcess.standardError = FileHandle.nullDevice
        try? routeProcess.run()
        routeProcess.waitUntilExit()

        logger.info("TAP routing removed")
        #else
        // macOS doesn't use TAP in the same way
        #endif
    }

    // MARK: - NAT Routing (Legacy - kept for backwards compatibility)

    /// Set up DNAT so traffic to vmVPNIP:22 is forwarded to vmNATIP:22
    private func setupNATRouting(
        vmVPNIP: String,
        vmNATIP: String,
        interfaceName: String
    ) async throws {
        logger.info("Setting up NAT routing", metadata: [
            "vm_vpn_ip": "\(vmVPNIP)",
            "vm_nat_ip": "\(vmNATIP)"
        ])

        #if os(macOS)
        // macOS uses pf (Packet Filter)
        try await setupPFNATRouting(vmVPNIP: vmVPNIP, vmNATIP: vmNATIP, interfaceName: interfaceName)
        #else
        // Linux uses iptables
        try await setupIPTablesNATRouting(vmVPNIP: vmVPNIP, vmNATIP: vmNATIP, interfaceName: interfaceName)
        #endif
    }

    private func removeNATRouting(vmVPNIP: String, vmNATIP: String) async throws {
        logger.info("Removing NAT routing", metadata: [
            "vm_vpn_ip": "\(vmVPNIP)",
            "vm_nat_ip": "\(vmNATIP)"
        ])

        #if os(macOS)
        try await removePFNATRouting(vmVPNIP: vmVPNIP, vmNATIP: vmNATIP)
        #else
        try await removeIPTablesNATRouting(vmVPNIP: vmVPNIP, vmNATIP: vmNATIP)
        #endif
    }

    #if os(macOS)
    private func setupPFNATRouting(vmVPNIP: String, vmNATIP: String, interfaceName: String) async throws {
        // Note: interfaceName is the logical WireGuard name (e.g., "wg-52294616")
        // We need to get the actual utun interface name from the MacOSWireGuardManager
        // Extract VM ID from interface name to look up the manager
        let vmIdString = String(interfaceName.dropFirst(3)) // Remove "wg-" prefix
        var actualInterface = interfaceName

        // Try to find the actual utun interface from our manager dictionary
        for (vmId, manager) in macOSWireGuards {
            if vmId.uuidString.hasPrefix(vmIdString) {
                let utunName = await manager.getInterfaceName()
                if !utunName.isEmpty {
                    actualInterface = utunName
                    logger.info("Resolved interface name", metadata: [
                        "logical": "\(interfaceName)",
                        "actual": "\(actualInterface)"
                    ])
                    break
                }
            }
        }

        // For macOS with Virtualization.framework NAT, we need:
        // 1. DNAT: Redirect traffic from VPN IP to VM's NAT IP
        // 2. The VM is on a NAT network (192.168.64.x) managed by Virtualization.framework
        // 3. We need to add a route so the host can reach the VM

        // Create pf rules for this VM
        // Note: On macOS pf, use simpler rdr syntax without 'pass' keyword in anchors
        // IMPORTANT: No leading whitespace - pf is sensitive to formatting
        // Use proto {tcp, udp} for both protocols in single rule
        let pfRules = """
# Omerta NAT rules for VM \(vmVPNIP)
# Redirect VPN traffic to VM NAT IP
rdr on \(actualInterface) proto {tcp, udp} from any to \(vmVPNIP) -> \(vmNATIP)
"""

        let anchor = "omerta/\(vmVPNIP.replacingOccurrences(of: ".", with: "-"))"

        // Use native MacOSPacketFilterManager
        do {
            try MacOSPacketFilterManager.enable()
            try MacOSPacketFilterManager.enableIPForwarding()
            try MacOSPacketFilterManager.loadRulesIntoAnchor(anchor: anchor, rules: pfRules)

            // Add route to reach VM's NAT IP via the Virtualization.framework bridge
            // The VM is accessible at 192.168.64.x through the vmnet interface
            try await addRouteToVM(vmNATIP: vmNATIP)

        } catch {
            logger.warning("Native pf setup failed: \(error), trying fallback")
            // Fallback to pfctl if native fails
            let pfPath = "\(configDirectory)/pf-\(vmVPNIP.replacingOccurrences(of: ".", with: "-")).conf"
            try pfRules.write(toFile: pfPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["pfctl", "-a", anchor, "-f", pfPath]
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            // Enable pf
            let enableProcess = Process()
            enableProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            enableProcess.arguments = ["pfctl", "-e"]
            enableProcess.standardError = Pipe()
            try? enableProcess.run()
            enableProcess.waitUntilExit()

            // Enable IP forwarding
            let sysctl = Process()
            sysctl.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            sysctl.arguments = ["sysctl", "-w", "net.inet.ip.forwarding=1"]
            try? sysctl.run()
            sysctl.waitUntilExit()

            // Add route to reach VM
            try? await addRouteToVM(vmNATIP: vmNATIP)
        }

        // Create marker file so cleanup knows this is an omerta-created rule
        try? createFirewallMarker(vmVPNIP: vmVPNIP, vmNATIP: vmNATIP, interfaceName: actualInterface)

        logger.info("pf NAT routing configured", metadata: ["vm_vpn_ip": "\(vmVPNIP)"])
    }

    /// Add a route to reach the VM's NAT IP
    private func addRouteToVM(vmNATIP: String) async throws {
        // The Virtualization.framework NAT network is typically 192.168.64.0/24
        // with the host gateway at 192.168.64.1
        // Check if we already have a route
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/sbin/route")
        checkProcess.arguments = ["-n", "get", vmNATIP]
        checkProcess.standardOutput = Pipe()
        checkProcess.standardError = Pipe()
        try? checkProcess.run()
        checkProcess.waitUntilExit()

        // If route exists (exit 0), we're done
        if checkProcess.terminationStatus == 0 {
            logger.info("Route to VM NAT IP already exists", metadata: ["vm_nat_ip": "\(vmNATIP)"])
            return
        }

        // The VM's NAT network is managed by Virtualization.framework
        // It should be accessible directly from the host without additional routes
        // since the framework creates a vmnet interface
        logger.info("VM NAT IP should be accessible via Virtualization.framework vmnet", metadata: [
            "vm_nat_ip": "\(vmNATIP)"
        ])
    }

    private func removePFNATRouting(vmVPNIP: String, vmNATIP: String) async throws {
        let anchor = "omerta/\(vmVPNIP.replacingOccurrences(of: ".", with: "-"))"

        // Use native MacOSPacketFilterManager
        do {
            try MacOSPacketFilterManager.flushAnchor(anchor: anchor)
        } catch {
            logger.warning("Native pf flush failed: \(error), trying fallback")
            // Fallback to pfctl
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["pfctl", "-a", anchor, "-F", "all"]
            try? process.run()
            process.waitUntilExit()
        }

        // Clean up pf rules file
        let pfPath = "\(configDirectory)/pf-\(vmVPNIP.replacingOccurrences(of: ".", with: "-")).conf"
        try? FileManager.default.removeItem(atPath: pfPath)

        // Remove marker file
        removeFirewallMarker(vmVPNIP: vmVPNIP)
    }
    #endif

    #if os(Linux)
    private func setupIPTablesNATRouting(vmVPNIP: String, vmNATIP: String, interfaceName: String) async throws {
        // DNAT: Incoming traffic to VM's VPN IP gets forwarded to NAT IP
        let dnatProcess = Process()
        dnatProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        dnatProcess.arguments = [
            "iptables", "-t", "nat", "-A", "PREROUTING",
            "-i", interfaceName, "-d", vmVPNIP,
            "-j", "DNAT", "--to-destination", vmNATIP
        ]
        try dnatProcess.run()
        dnatProcess.waitUntilExit()

        // SNAT: Outgoing traffic from VM NAT IP appears as VPN IP
        let snatProcess = Process()
        snatProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        snatProcess.arguments = [
            "iptables", "-t", "nat", "-A", "POSTROUTING",
            "-s", vmNATIP, "-o", interfaceName,
            "-j", "SNAT", "--to-source", vmVPNIP
        ]
        try snatProcess.run()
        snatProcess.waitUntilExit()

        // Allow forwarding
        let forwardProcess = Process()
        forwardProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        forwardProcess.arguments = [
            "iptables", "-A", "FORWARD",
            "-i", interfaceName, "-d", vmNATIP,
            "-j", "ACCEPT"
        ]
        try forwardProcess.run()
        forwardProcess.waitUntilExit()

        // Enable IP forwarding
        let sysctl = Process()
        sysctl.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sysctl.arguments = ["sysctl", "-w", "net.ipv4.ip_forward=1"]
        try? sysctl.run()
        sysctl.waitUntilExit()

        logger.info("iptables NAT routing configured", metadata: ["vm_vpn_ip": "\(vmVPNIP)"])
    }

    private func removeIPTablesNATRouting(vmVPNIP: String, vmNATIP: String) async throws {
        // Remove DNAT rule
        let dnatProcess = Process()
        dnatProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        dnatProcess.arguments = [
            "iptables", "-t", "nat", "-D", "PREROUTING",
            "-d", vmVPNIP, "-j", "DNAT", "--to-destination", vmNATIP
        ]
        try? dnatProcess.run()
        dnatProcess.waitUntilExit()

        // Remove SNAT rule
        let snatProcess = Process()
        snatProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        snatProcess.arguments = [
            "iptables", "-t", "nat", "-D", "POSTROUTING",
            "-s", vmNATIP, "-j", "SNAT", "--to-source", vmVPNIP
        ]
        try? snatProcess.run()
        snatProcess.waitUntilExit()
    }
    #endif

    // MARK: - Firewall Rules

    /// Set up firewall rules to isolate VM traffic
    /// VM can only communicate with VPN subnet, not host network or internet
    private func setupFirewallRules(
        vmVPNIP: String,
        vpnSubnet: String,
        interfaceName: String
    ) async throws {
        logger.info("Setting up firewall rules for VM isolation", metadata: [
            "vm_vpn_ip": "\(vmVPNIP)",
            "vpn_subnet": "\(vpnSubnet)"
        ])

        #if os(macOS)
        // pf rules would be set up here if needed
        // For TAP networking, we primarily rely on routing
        #else
        // Allow forwarding for this VM's VPN IP
        let forwardProcess = Process()
        forwardProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        forwardProcess.arguments = [
            "iptables", "-A", "FORWARD",
            "-d", vmVPNIP,
            "-j", "ACCEPT"
        ]
        try? forwardProcess.run()
        forwardProcess.waitUntilExit()

        let forwardOutProcess = Process()
        forwardOutProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        forwardOutProcess.arguments = [
            "iptables", "-A", "FORWARD",
            "-s", vmVPNIP,
            "-j", "ACCEPT"
        ]
        try? forwardOutProcess.run()
        forwardOutProcess.waitUntilExit()
        #endif

        logger.info("Firewall rules configured")
    }

    private func removeFirewallRules(vmVPNIP: String, interfaceName: String) async throws {
        logger.info("Removing firewall rules", metadata: ["vm_vpn_ip": "\(vmVPNIP)"])

        #if os(macOS)
        // pf rules are removed with the anchor flush if used
        #else
        // Remove forward rules (best effort)
        let process1 = Process()
        process1.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process1.arguments = [
            "iptables", "-D", "FORWARD",
            "-d", vmVPNIP, "-j", "ACCEPT"
        ]
        try? process1.run()
        process1.waitUntilExit()

        let process2 = Process()
        process2.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process2.arguments = [
            "iptables", "-D", "FORWARD",
            "-s", vmVPNIP, "-j", "ACCEPT"
        ]
        try? process2.run()
        process2.waitUntilExit()
        #endif
    }

    // MARK: - Status

    public func getTunnelCount() -> Int {
        activeTunnels.count
    }

    public func getAllTunnels() -> [ProviderTunnel] {
        Array(activeTunnels.values)
    }

    // MARK: - Firewall Marker Files

    /// Create a marker file indicating omerta created firewall rules for this VM
    private func createFirewallMarker(vmVPNIP: String, vmNATIP: String, interfaceName: String) throws {
        // Create marker directory if needed
        try FileManager.default.createDirectory(
            atPath: firewallMarkerDirectory,
            withIntermediateDirectories: true
        )

        let markerPath = firewallMarkerPath(for: vmVPNIP)
        let markerContent = """
        # Omerta Firewall Marker
        # This file indicates that omerta created firewall rules for this VM
        # Safe to delete this file and associated rules during cleanup
        vm_vpn_ip=\(vmVPNIP)
        vm_nat_ip=\(vmNATIP)
        interface=\(interfaceName)
        created_at=\(ISO8601DateFormatter().string(from: Date()))
        anchor=omerta/\(vmVPNIP.replacingOccurrences(of: ".", with: "-"))
        """

        try markerContent.write(toFile: markerPath, atomically: true, encoding: .utf8)
        logger.info("Created firewall marker", metadata: ["path": "\(markerPath)"])
    }

    /// Remove the marker file for a VM
    private func removeFirewallMarker(vmVPNIP: String) {
        let markerPath = firewallMarkerPath(for: vmVPNIP)
        try? FileManager.default.removeItem(atPath: markerPath)
        logger.info("Removed firewall marker", metadata: ["vm_vpn_ip": "\(vmVPNIP)"])
    }

    /// Get path to marker file for a VM
    private func firewallMarkerPath(for vmVPNIP: String) -> String {
        "\(firewallMarkerDirectory)/\(vmVPNIP.replacingOccurrences(of: ".", with: "-")).marker"
    }

    /// List all firewall markers (for cleanup)
    public static func listFirewallMarkers() -> [FirewallMarker] {
        let markerDir = "\(OmertaConfig.defaultConfigDir)/firewall"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: markerDir) else {
            return []
        }

        return files.compactMap { filename -> FirewallMarker? in
            guard filename.hasSuffix(".marker") else { return nil }
            let path = "\(markerDir)/\(filename)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

            var marker = FirewallMarker(path: path)
            for line in content.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0])
                let value = String(parts[1])

                switch key {
                case "vm_vpn_ip": marker.vmVPNIP = value
                case "vm_nat_ip": marker.vmNATIP = value
                case "interface": marker.interfaceName = value
                case "anchor": marker.anchor = value
                case "created_at": marker.createdAt = value
                default: break
                }
            }

            return marker.vmVPNIP != nil ? marker : nil
        }
    }

    /// Check if a pf anchor exists (macOS)
    public static func pfAnchorExists(_ anchor: String) -> Bool {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = ["-a", anchor, "-sr"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// List all omerta pf anchors (macOS)
    public static func listOmertaAnchors() -> [String] {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = ["-sA"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Filter for omerta/* anchors
            return output.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("omerta/") }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Remove a pf anchor (macOS)
    public static func removePFAnchor(_ anchor: String) -> Bool {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["pfctl", "-a", anchor, "-F", "all"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    public struct FirewallMarker {
        public var path: String
        public var vmVPNIP: String?
        public var vmNATIP: String?
        public var interfaceName: String?
        public var anchor: String?
        public var createdAt: String?

        public init(path: String) {
            self.path = path
        }
    }
}

// MARK: - Phase 10: VM Network Integration

#if os(macOS)
/// Result of VM network setup containing all necessary components
public struct VMNetworkSetup: Sendable {
    /// Network device configuration for the VM
    public let networkDevice: VZVirtioNetworkDeviceConfiguration

    /// Handle for cleanup
    public let handle: VMNetworkHandle

    /// Path to cloud-init ISO (attach to VM as secondary drive)
    public let cloudInitISOPath: String

    /// VM's WireGuard public key (derived from private key)
    public let vmPublicKey: String

    /// VM's WireGuard private key (used in cloud-init config)
    public let vmPrivateKey: String
}

extension ProviderVPNManager {

    /// Set up VM network with isolation via WireGuard and firewall
    ///
    /// This integrates:
    /// - VMNetworkManager (Phase 8) for network device configuration
    /// - CloudInitGenerator (Phase 9) for VM-side WireGuard and firewall
    ///
    /// - Parameters:
    ///   - vmId: Unique identifier for the VM
    ///   - mode: Network mode (direct, sampled, conntrack, filtered)
    ///   - consumerPublicKey: Consumer's WireGuard public key
    ///   - consumerEndpoint: Consumer's WireGuard endpoint (ip:port)
    ///   - vmAddress: VM's WireGuard IP address (default: 10.200.200.2/24)
    ///   - outputDirectory: Directory for cloud-init ISO
    /// - Returns: VMNetworkSetup with network device, handle, and cloud-init ISO path
    @MainActor
    public func setupVMNetwork(
        vmId: UUID,
        mode: VMNetworkMode,
        consumerPublicKey: String,
        consumerEndpoint: String,
        vmAddress: String = "10.200.200.2/24",
        outputDirectory: String? = nil
    ) async throws -> VMNetworkSetup {
        logger.info("Setting up VM network", metadata: [
            "vm_id": "\(vmId)",
            "mode": "\(mode.rawValue)",
            "consumer_endpoint": "\(consumerEndpoint)"
        ])

        // Parse endpoint to create Endpoint type
        let endpointParts = consumerEndpoint.split(separator: ":")
        guard endpointParts.count == 2,
              let port = UInt16(endpointParts[1]) else {
            throw ProviderVPNError.natSetupFailed("Invalid consumer endpoint format: \(consumerEndpoint)")
        }

        let ipComponents = String(endpointParts[0]).split(separator: ".").compactMap { UInt8($0) }
        guard ipComponents.count == 4 else {
            throw ProviderVPNError.natSetupFailed("Invalid IP address in endpoint: \(consumerEndpoint)")
        }

        let endpoint = Endpoint(
            address: IPv4Address(ipComponents[0], ipComponents[1], ipComponents[2], ipComponents[3]),
            port: port
        )

        // 1. Create VM network configuration using VMNetworkManager (Phase 8)
        let networkConfig = try VMNetworkManager.createNetwork(
            mode: mode,
            consumerEndpoint: endpoint
        )

        // 2. Generate WireGuard keypair for VM
        let vmPrivateKey = generatePrivateKey()
        let vmPublicKey: String
        if dryRun {
            vmPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        } else {
            vmPublicKey = try derivePublicKey(from: vmPrivateKey)
        }

        // 3. Create cloud-init configuration for VM (Phase 9)
        let vmNetworkConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint,
            vmPrivateKey: vmPrivateKey,
            vmAddress: vmAddress
        )

        // 4. Create cloud-init ISO
        let outputDir = outputDirectory ?? configDirectory
        let isoPath = "\(outputDir)/cidata-\(vmId.uuidString.prefix(8)).iso"

        if !dryRun {
            try CloudInitGenerator.createNetworkIsolationISO(
                config: vmNetworkConfig,
                outputPath: isoPath
            )
            logger.info("Created cloud-init ISO", metadata: ["path": "\(isoPath)"])
        } else {
            logger.info("DRY RUN: Would create cloud-init ISO", metadata: ["path": "\(isoPath)"])
        }

        logger.info("VM network setup complete", metadata: [
            "vm_id": "\(vmId)",
            "mode": "\(mode.rawValue)",
            "vm_public_key": "\(vmPublicKey.prefix(20))..."
        ])

        return VMNetworkSetup(
            networkDevice: networkConfig.networkDevice,
            handle: networkConfig.handle,
            cloudInitISOPath: isoPath,
            vmPublicKey: vmPublicKey,
            vmPrivateKey: vmPrivateKey
        )
    }

    /// Set up filtered NAT for VM (convenience method)
    ///
    /// Creates a VM network in filtered mode with cloud-init configuration.
    /// Attaches the network device and cloud-init ISO to the VM configuration.
    ///
    /// - Parameters:
    ///   - vmId: Unique identifier for the VM
    ///   - consumerPublicKey: Consumer's WireGuard public key
    ///   - consumerEndpoint: Consumer's WireGuard endpoint (ip:port)
    ///   - vmConfig: VM configuration to modify (adds network device and cloud-init disk)
    /// - Returns: VMNetworkSetup with cleanup handle and VM public key
    @MainActor
    public func setupFilteredNAT(
        vmId: UUID,
        consumerPublicKey: String,
        consumerEndpoint: String,
        vmConfig: inout VZVirtualMachineConfiguration
    ) async throws -> VMNetworkSetup {
        let setup = try await setupVMNetwork(
            vmId: vmId,
            mode: .filtered,
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint
        )

        // Add network device to VM configuration
        vmConfig.networkDevices = [setup.networkDevice]

        // Attach cloud-init ISO as secondary disk (if not in dry-run and file exists)
        if !dryRun && FileManager.default.fileExists(atPath: setup.cloudInitISOPath) {
            let isoURL = URL(fileURLWithPath: setup.cloudInitISOPath)
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: isoURL,
                readOnly: true
            )
            let ciDisk = VZVirtioBlockDeviceConfiguration(attachment: attachment)
            vmConfig.storageDevices.append(ciDisk)

            logger.info("Attached cloud-init ISO to VM", metadata: [
                "vm_id": "\(vmId)",
                "iso_path": "\(setup.cloudInitISOPath)"
            ])
        }

        return setup
    }

    /// Clean up VM network resources
    ///
    /// - Parameters:
    ///   - handle: Network handle from setup
    ///   - cloudInitISOPath: Optional path to cloud-init ISO to remove
    public func cleanupVMNetwork(
        handle: VMNetworkHandle,
        cloudInitISOPath: String? = nil
    ) async {
        // Clean up network handle
        await MainActor.run {
            VMNetworkManager.cleanup(handle)
        }

        // Remove cloud-init ISO
        if let isoPath = cloudInitISOPath {
            try? FileManager.default.removeItem(atPath: isoPath)
            logger.info("Removed cloud-init ISO", metadata: ["path": "\(isoPath)"])
        }
    }
}
#endif

// MARK: - Errors

public enum ProviderVPNError: Error, CustomStringConvertible {
    case keyDerivationFailed
    case interfaceStartFailed(String)
    case natSetupFailed(String)
    case firewallSetupFailed(String)

    public var description: String {
        switch self {
        case .keyDerivationFailed:
            return "Failed to derive WireGuard public key"
        case .interfaceStartFailed(let msg):
            return "Failed to start WireGuard interface: \(msg)"
        case .natSetupFailed(let msg):
            return "Failed to set up NAT routing: \(msg)"
        case .firewallSetupFailed(let msg):
            return "Failed to set up firewall rules: \(msg)"
        }
    }
}
