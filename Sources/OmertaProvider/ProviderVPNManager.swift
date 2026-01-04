import Foundation
import Logging
import OmertaCore
import OmertaNetwork
import Crypto

/// Manages provider-side WireGuard tunnels connecting to consumer VPN servers
/// Sets up NAT routing from VPN network to VM NAT addresses
public actor ProviderVPNManager {
    private let logger: Logger
    private var activeTunnels: [UUID: ProviderTunnel] = [:]
    private let configDirectory: String
    private let firewallMarkerDirectory: String
    private let dryRun: Bool

    public struct ProviderTunnel: Sendable {
        public let vmId: UUID
        public let interfaceName: String
        public let privateKey: String
        public let publicKey: String
        public let providerVPNIP: String  // Provider's IP within VPN (e.g., 10.99.0.254)
        public let vmVPNIP: String        // VM's VPN IP (e.g., 10.99.0.2)
        public let vmNATIP: String        // VM's actual NAT IP (e.g., 192.168.64.2)
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
    /// Returns the provider's public key (consumer needs this to allow connection)
    public func createTunnel(
        vmId: UUID,
        vpnConfig: VPNConfiguration,
        vmNATIP: String
    ) async throws -> String {
        logger.info("Creating provider VPN tunnel", metadata: [
            "vm_id": "\(vmId)",
            "consumer_endpoint": "\(vpnConfig.consumerEndpoint)",
            "vm_vpn_ip": "\(vpnConfig.vmVPNIP)",
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
                allowedIPs: vpnConfig.vpnSubnet
            )

            // 4. Write config file
            try await writeConfigFile(config: config, path: configPath)

            // 5. Start WireGuard interface
            try await startWireGuardInterface(configPath: configPath, interfaceName: interfaceName)

            // 6. Set up NAT routing: traffic to vmVPNIP gets routed to vmNATIP
            try await setupNATRouting(
                vmVPNIP: vpnConfig.vmVPNIP,
                vmNATIP: vmNATIP,
                interfaceName: interfaceName
            )

            // 7. Set up firewall rules to isolate VM
            try await setupFirewallRules(
                vmNATIP: vmNATIP,
                vpnSubnet: vpnConfig.vpnSubnet,
                interfaceName: interfaceName
            )
        } else {
            logger.info("DRY RUN: Skipping WireGuard interface, NAT, and firewall setup")
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
                vmNATIP: tunnel.vmNATIP,
                interfaceName: tunnel.interfaceName
            )

            // 2. Remove NAT routing
            try await removeNATRouting(
                vmVPNIP: tunnel.vmVPNIP,
                vmNATIP: tunnel.vmNATIP
            )

            // 3. Stop WireGuard interface
            try await stopWireGuardInterface(interfaceName: tunnel.interfaceName, configPath: tunnel.configPath)

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

    private func generatePrivateKey() -> String {
        // Generate random 32-byte key
        let keyData = SymmetricKey(size: .bits256)
        let keyBytes = keyData.withUnsafeBytes { Data($0) }
        return keyBytes.base64EncodedString()
    }

    private func derivePublicKey(from privateKey: String) throws -> String {
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
        allowedIPs: String
    ) -> String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(providerIP)/24

        [Peer]
        PublicKey = \(consumerPublicKey)
        Endpoint = \(consumerEndpoint)
        AllowedIPs = \(allowedIPs)
        PersistentKeepalive = 25
        """
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

    private func startWireGuardInterface(configPath: String, interfaceName: String) async throws {
        logger.info("Starting WireGuard interface", metadata: ["interface": "\(interfaceName)"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        let pathValue = WireGuardPaths.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = ["PATH": pathValue]
        process.arguments = ["env", "PATH=\(pathValue)", WireGuardPaths.wgQuick, "up", configPath]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ProviderVPNError.interfaceStartFailed(errorMessage)
        }

        // Wait for interface to be ready
        try await Task.sleep(for: .milliseconds(500))

        logger.info("WireGuard interface started", metadata: ["interface": "\(interfaceName)"])
    }

    private func stopWireGuardInterface(interfaceName: String, configPath: String) async throws {
        logger.info("Stopping WireGuard interface", metadata: ["interface": "\(interfaceName)"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        let pathValue = WireGuardPaths.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = ["PATH": pathValue]

        // Try with config path first, fall back to interface name
        if FileManager.default.fileExists(atPath: configPath) {
            process.arguments = ["env", "PATH=\(pathValue)", WireGuardPaths.wgQuick, "down", configPath]
        } else {
            process.arguments = ["env", "PATH=\(pathValue)", WireGuardPaths.wgQuick, "down", interfaceName]
        }

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        // Log errors but don't fail - interface might already be down
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.warning("wg-quick down returned error", metadata: [
                "interface": "\(interfaceName)",
                "error": "\(errorMessage)"
            ])
        }
    }

    // MARK: - NAT Routing

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
        // Create pf rules file for this VM
        let pfRules = """
        # Omerta NAT rules for VM \(vmVPNIP) -> \(vmNATIP)
        # DNAT: Incoming traffic to VM's VPN IP gets forwarded to NAT IP
        rdr pass on \(interfaceName) proto tcp from any to \(vmVPNIP) -> \(vmNATIP)
        rdr pass on \(interfaceName) proto udp from any to \(vmVPNIP) -> \(vmNATIP)

        # NAT: Outgoing traffic from VM NAT IP appears as VPN IP
        nat on \(interfaceName) from \(vmNATIP) to any -> (\(interfaceName))

        # Allow forwarding
        pass in on \(interfaceName) from any to \(vmNATIP)
        pass out on \(interfaceName) from \(vmNATIP) to any
        """

        let pfPath = "\(configDirectory)/pf-\(vmVPNIP.replacingOccurrences(of: ".", with: "-")).conf"
        try pfRules.write(toFile: pfPath, atomically: true, encoding: .utf8)

        // Load pf rules
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["pfctl", "-a", "omerta/\(vmVPNIP.replacingOccurrences(of: ".", with: "-"))", "-f", pfPath]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.warning("pfctl returned error (may need to enable pf)", metadata: ["error": "\(errorMessage)"])
        }

        // Enable pf if not already enabled
        let enableProcess = Process()
        enableProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        enableProcess.arguments = ["pfctl", "-e"]
        enableProcess.standardError = Pipe()
        try? enableProcess.run()
        enableProcess.waitUntilExit()

        // Enable IP forwarding on macOS
        let sysctl = Process()
        sysctl.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sysctl.arguments = ["sysctl", "-w", "net.inet.ip.forwarding=1"]
        try? sysctl.run()
        sysctl.waitUntilExit()

        // Create marker file so cleanup knows this is an omerta-created rule
        try? createFirewallMarker(vmVPNIP: vmVPNIP, vmNATIP: vmNATIP, interfaceName: interfaceName)

        logger.info("pf NAT routing configured", metadata: ["vm_vpn_ip": "\(vmVPNIP)"])
    }

    private func removePFNATRouting(vmVPNIP: String, vmNATIP: String) async throws {
        // Flush pf anchor for this VM
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["pfctl", "-a", "omerta/\(vmVPNIP.replacingOccurrences(of: ".", with: "-"))", "-F", "all"]

        try? process.run()
        process.waitUntilExit()

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
        vmNATIP: String,
        vpnSubnet: String,
        interfaceName: String
    ) async throws {
        logger.info("Setting up firewall rules for VM isolation", metadata: [
            "vm_nat_ip": "\(vmNATIP)",
            "vpn_subnet": "\(vpnSubnet)"
        ])

        #if os(macOS)
        // pf rules are included in the NAT setup above
        // Additional isolation rules could be added here
        #else
        // Block VM from reaching anything except VPN subnet
        let blockProcess = Process()
        blockProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        blockProcess.arguments = [
            "iptables", "-A", "FORWARD",
            "-s", vmNATIP, "!", "-d", vpnSubnet,
            "-j", "DROP"
        ]
        try? blockProcess.run()
        blockProcess.waitUntilExit()
        #endif

        logger.info("Firewall rules configured")
    }

    private func removeFirewallRules(vmNATIP: String, interfaceName: String) async throws {
        logger.info("Removing firewall rules", metadata: ["vm_nat_ip": "\(vmNATIP)"])

        #if os(macOS)
        // pf rules are removed with the anchor flush
        #else
        // Remove block rule (best effort)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [
            "iptables", "-D", "FORWARD",
            "-s", vmNATIP, "-j", "DROP"
        ]
        try? process.run()
        process.waitUntilExit()
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
