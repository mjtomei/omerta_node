import Foundation

/// Generates cloud-init configuration for VM provisioning
public enum CloudInitGenerator {

    /// Network configuration for static IP assignment
    public struct NetworkConfig {
        public let ipAddress: String
        public let gateway: String
        public let prefixLength: UInt8
        public let dns: [String]

        public init(ipAddress: String, gateway: String, prefixLength: UInt8 = 24, dns: [String] = ["8.8.8.8", "8.8.4.4"]) {
            self.ipAddress = ipAddress
            self.gateway = gateway
            self.prefixLength = prefixLength
            self.dns = dns
        }
    }

    /// Generate cloud-init user-data with the consumer's SSH public key
    public static func generateUserData(
        sshPublicKey: String,
        sshUser: String = "omerta",
        password: String? = nil  // Optional password for recovery
    ) -> String {
        var userData = """
        #cloud-config
        users:
          - name: \(sshUser)
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/bash
            ssh_authorized_keys:
              - \(sshPublicKey)
        """

        // Add password auth as fallback if provided
        if let password = password {
            userData += """


        # Enable password auth as backup
        ssh_pwauth: true
        chpasswd:
          list: |
            \(sshUser):\(password)
          expire: false
        """
        }

        // Add post-boot configuration
        userData += """


        # Disable cloud-init after first boot for faster subsequent boots
        runcmd:
          - touch /etc/cloud/cloud-init.disabled
          # Ensure SSH is enabled
          - systemctl enable ssh
          - systemctl start ssh
        """

        return userData
    }

    /// Generate cloud-init meta-data
    public static func generateMetaData(instanceId: UUID) -> String {
        """
        instance-id: omerta-\(instanceId.uuidString.lowercased().prefix(8))
        local-hostname: omerta-vm
        """
    }

    /// Generate cloud-init network-config for static IP (Netplan v2 format)
    /// Uses wildcard match for interface to work across different QEMU configurations
    public static func generateNetworkConfig(_ config: NetworkConfig) -> String {
        let dnsServers = config.dns.map { "\"\($0)\"" }.joined(separator: ", ")
        // Use id0 with match on driver:virtio* to work across different QEMU setups
        // On ARM64 QEMU the interface is typically enp0s1, on x86 it might be ens3
        return """
        version: 2
        ethernets:
          id0:
            match:
              driver: virtio*
            addresses:
              - \(config.ipAddress)/\(config.prefixLength)
            routes:
              - to: default
                via: \(config.gateway)
            nameservers:
              addresses: [\(dnsServers)]
        """
    }

    /// Create a cloud-init seed ISO file
    /// - Parameters:
    ///   - path: Output path for the ISO file
    ///   - sshPublicKey: SSH public key for the omerta user
    ///   - sshUser: Username for SSH access (default: "omerta")
    ///   - instanceId: Unique ID for this VM instance
    ///   - password: Optional password for recovery access
    ///   - networkConfig: Optional static IP configuration (if nil, VM uses DHCP)
    public static func createSeedISO(
        at path: String,
        sshPublicKey: String,
        sshUser: String = "omerta",
        instanceId: UUID,
        password: String? = "omerta123",  // Default recovery password
        networkConfig: NetworkConfig? = nil
    ) throws {
        let expandedPath = expandPath(path)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudinit-\(instanceId.uuidString)")

        // Create temp directory
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Write user-data
        let userData = generateUserData(
            sshPublicKey: sshPublicKey,
            sshUser: sshUser,
            password: password
        )
        let userDataPath = tempDir.appendingPathComponent("user-data")
        try userData.write(to: userDataPath, atomically: true, encoding: .utf8)

        // Write meta-data
        let metaData = generateMetaData(instanceId: instanceId)
        let metaDataPath = tempDir.appendingPathComponent("meta-data")
        try metaData.write(to: metaDataPath, atomically: true, encoding: .utf8)

        // Write network-config if static IP is specified
        if let netConfig = networkConfig {
            let networkConfigData = generateNetworkConfig(netConfig)
            let networkConfigPath = tempDir.appendingPathComponent("network-config")
            try networkConfigData.write(to: networkConfigPath, atomically: true, encoding: .utf8)
        }

        // Create ISO using hdiutil (macOS) or genisoimage (Linux)
        #if os(macOS)
        try createISOmacOS(
            from: tempDir.path,
            to: expandedPath
        )
        #else
        try createISOLinux(
            from: tempDir.path,
            to: expandedPath
        )
        #endif
    }

    /// Create ISO from a directory containing cloud-init files (cross-platform)
    /// - Parameters:
    ///   - directory: Path to directory containing user-data, meta-data, etc.
    ///   - outputPath: Path for output ISO file
    public static func createISOFromDirectory(from directory: String, to outputPath: String) throws {
        #if os(macOS)
        try createISOmacOS(from: directory, to: outputPath)
        #else
        try createISOLinux(from: directory, to: outputPath)
        #endif
    }

    #if os(macOS)
    private static func createISOmacOS(from directory: String, to outputPath: String) throws {
        // Prefer mkisofs/genisoimage if available (creates proper ISO9660 that Linux/cloud-init can read)
        // Fall back to hdiutil which creates hybrid format
        let isoBinaries = ["/opt/homebrew/bin/mkisofs", "/usr/local/bin/mkisofs",
                          "/opt/homebrew/bin/genisoimage", "/usr/local/bin/genisoimage"]

        var executablePath: String?
        for binary in isoBinaries {
            if FileManager.default.fileExists(atPath: binary) {
                executablePath = binary
                break
            }
        }

        let process = Process()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        if let executable = executablePath {
            // Use mkisofs/genisoimage for proper ISO9660 (cloud-init compatible)
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "-output", outputPath,
                "-volid", "cidata",
                "-joliet",
                "-rock",
                directory
            ]
        } else {
            // Fall back to hdiutil - use ISO9660 only (no HFS which Linux can't read)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = [
                "makehybrid",
                "-o", outputPath,
                "-joliet",
                "-iso",
                "-default-volume-name", "cidata",
                directory
            ]
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw CloudInitError.isoCreationFailed(errorMessage)
        }
    }
    #else
    private static func createISOLinux(from directory: String, to outputPath: String) throws {
        let process = Process()
        // Try genisoimage first, fall back to mkisofs
        let isoBinaries = ["/usr/bin/genisoimage", "/usr/bin/mkisofs", "/usr/bin/xorrisofs"]

        var executablePath: String?
        for binary in isoBinaries {
            if FileManager.default.fileExists(atPath: binary) {
                executablePath = binary
                break
            }
        }

        guard let executable = executablePath else {
            throw CloudInitError.isoCreationFailed("No ISO creation tool found. Install genisoimage or mkisofs.")
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-output", outputPath,
            "-volid", "cidata",
            "-joliet",
            "-rock",
            directory
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw CloudInitError.isoCreationFailed(errorMessage)
        }
    }
    #endif

    private static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let homeDir: String
            if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"] {
                #if os(macOS)
                homeDir = "/Users/\(sudoUser)"
                #else
                homeDir = "/home/\(sudoUser)"
                #endif
            } else if let home = ProcessInfo.processInfo.environment["HOME"] {
                homeDir = home
            } else {
                homeDir = NSHomeDirectory()
            }
            return homeDir + String(path.dropFirst(1))
        }
        return path
    }
}

// MARK: - VM Network Isolation (Phase 9)

/// Configuration for VM network isolation via WireGuard
public struct VMNetworkConfig: Codable, Sendable {

    /// WireGuard interface configuration
    public struct WireGuard: Codable, Sendable {
        public let privateKey: String      // Base64 WG private key
        public let address: String         // e.g., "10.200.200.2/24"
        public let listenPort: UInt16?     // Optional, usually not needed for client

        public struct Peer: Codable, Sendable {
            public let publicKey: String   // Consumer's public key
            public let endpoint: String    // e.g., "203.0.113.50:51820"
            public let allowedIPs: String  // e.g., "0.0.0.0/0, ::/0"
            public let persistentKeepalive: UInt16?  // e.g., 25

            public init(publicKey: String, endpoint: String, allowedIPs: String = "0.0.0.0/0, ::/0", persistentKeepalive: UInt16? = 25) {
                self.publicKey = publicKey
                self.endpoint = endpoint
                self.allowedIPs = allowedIPs
                self.persistentKeepalive = persistentKeepalive
            }
        }
        public let peer: Peer

        public init(privateKey: String, address: String, listenPort: UInt16? = nil, peer: Peer) {
            self.privateKey = privateKey
            self.address = address
            self.listenPort = listenPort
            self.peer = peer
        }
    }
    public let wireGuard: WireGuard

    /// Firewall configuration
    public struct Firewall: Codable, Sendable {
        public let allowLoopback: Bool           // Always true
        public let allowWireGuardInterface: Bool // Always true
        public let allowDHCP: Bool               // For initial network setup
        public let allowDNS: Bool                // Usually false (use WG DNS)
        public let allowPackageInstall: Bool     // Allow DNS/HTTP/HTTPS for package installation (DEVELOPMENT ONLY)
        public let customRules: [String]?        // Additional iptables rules

        public init(allowLoopback: Bool = true, allowWireGuardInterface: Bool = true, allowDHCP: Bool = true, allowDNS: Bool = false, allowPackageInstall: Bool = false, customRules: [String]? = nil) {
            self.allowLoopback = allowLoopback
            self.allowWireGuardInterface = allowWireGuardInterface
            self.allowDHCP = allowDHCP
            self.allowDNS = allowDNS
            self.allowPackageInstall = allowPackageInstall
            self.customRules = customRules
        }
    }
    public let firewall: Firewall

    /// Package installation configuration
    public struct PackageConfig: Codable, Sendable {
        public let packages: [String]      // Package names to install
        public let updateFirst: Bool       // apt-get update / apk update first

        public init(packages: [String] = ["wireguard-tools", "iptables"], updateFirst: Bool = true) {
            self.packages = packages
            self.updateFirst = updateFirst
        }

        /// Default packages for Ubuntu/Debian
        public static let debian = PackageConfig(packages: ["wireguard", "iptables"])

        /// Default packages for Alpine
        public static let alpine = PackageConfig(packages: ["wireguard-tools", "iptables"])
    }
    public let packageConfig: PackageConfig?

    /// VM metadata
    public let instanceId: String        // Unique per VM instance
    public let hostname: String          // e.g., "omerta-vm-abc123"

    public init(wireGuard: WireGuard, firewall: Firewall = Firewall(), packageConfig: PackageConfig? = .debian, instanceId: String? = nil, hostname: String? = nil) {
        let id = instanceId ?? "omerta-\(UUID().uuidString.prefix(8).lowercased())"
        self.wireGuard = wireGuard
        self.firewall = firewall
        self.packageConfig = packageConfig
        self.instanceId = id
        self.hostname = hostname ?? "omerta-vm-\(id.suffix(8))"
    }
}

// MARK: - VM Network Config Generation

extension CloudInitGenerator {

    /// Generate cloud-init user-data for VM network isolation
    public static func generateNetworkIsolationUserData(config: VMNetworkConfig) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())

        // Extract port from endpoint for firewall rule
        let endpointPort = config.wireGuard.peer.endpoint.split(separator: ":").last.map(String.init) ?? "51820"

        var yaml = """
        #cloud-config

        # Omerta VM Network Isolation Configuration
        # Generated: \(timestamp)
        # Instance: \(config.instanceId)

        hostname: \(config.hostname)

        """

        // Package installation
        if let pkgConfig = config.packageConfig {
            yaml += """

            # Package installation
            package_update: \(pkgConfig.updateFirst)
            package_upgrade: false
            packages:

            """
            for package in pkgConfig.packages {
                yaml += "  - \(package)\n"
            }
        }

        // WireGuard configuration file
        yaml += """

        # Write WireGuard configuration
        write_files:
          - path: /etc/wireguard/wg0.conf
            permissions: '0600'
            content: |
              [Interface]
              PrivateKey = \(config.wireGuard.privateKey)
              Address = \(config.wireGuard.address)

        """

        if let listenPort = config.wireGuard.listenPort {
            yaml += "      ListenPort = \(listenPort)\n"
        }

        yaml += """

              [Peer]
              PublicKey = \(config.wireGuard.peer.publicKey)
              Endpoint = \(config.wireGuard.peer.endpoint)
              AllowedIPs = \(config.wireGuard.peer.allowedIPs)

        """

        if let keepalive = config.wireGuard.peer.persistentKeepalive {
            yaml += "      PersistentKeepalive = \(keepalive)\n"
        }

        // Firewall script
        yaml += """

          - path: /etc/omerta/firewall.sh
            permissions: '0755'
            content: |
              #!/bin/sh
              set -e

              # Flush existing rules
              iptables -F
              iptables -X
              ip6tables -F 2>/dev/null || true
              ip6tables -X 2>/dev/null || true

              # Default policies: DROP everything
              iptables -P INPUT DROP
              iptables -P FORWARD DROP
              iptables -P OUTPUT DROP
              ip6tables -P INPUT DROP 2>/dev/null || true
              ip6tables -P FORWARD DROP 2>/dev/null || true
              ip6tables -P OUTPUT DROP 2>/dev/null || true

              # Allow established connections
              iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
              iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

        """

        if config.firewall.allowLoopback {
            yaml += """
              # Allow loopback
              iptables -A INPUT -i lo -j ACCEPT
              iptables -A OUTPUT -o lo -j ACCEPT
              ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
              ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

        """
        }

        if config.firewall.allowDHCP {
            yaml += """
              # Allow DHCP (for initial network config)
              iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT
              iptables -A INPUT -p udp --sport 67:68 -j ACCEPT

        """
        }

        // Allow DNS and HTTP/HTTPS for package installation (DEVELOPMENT ONLY)
        // WARNING: This creates a security window where VM has unrestricted network access
        // For production, use pre-built images with WireGuard pre-installed
        if config.firewall.allowPackageInstall {
            yaml += """
              # DEVELOPMENT ONLY: Allow DNS/HTTP/HTTPS for package installation
              # This opens network access before WireGuard isolation is active
              iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
              iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
              iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
              iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

        """
        }

        if config.firewall.allowWireGuardInterface {
            yaml += """
              # Allow all traffic on WireGuard interface
              iptables -A INPUT -i wg0 -j ACCEPT
              iptables -A OUTPUT -o wg0 -j ACCEPT
              ip6tables -A INPUT -i wg0 -j ACCEPT 2>/dev/null || true
              ip6tables -A OUTPUT -o wg0 -j ACCEPT 2>/dev/null || true

        """
        }

        // Allow WireGuard handshake
        yaml += """
              # Allow WireGuard UDP to establish tunnel (before wg0 is up)
              iptables -A OUTPUT -p udp --dport \(endpointPort) -j ACCEPT

        """

        // Custom rules
        if let customRules = config.firewall.customRules {
            yaml += "      # Custom rules\n"
            for rule in customRules {
                yaml += "      \(rule)\n"
            }
        }

        yaml += """

              echo "Firewall configured successfully"

          - path: /etc/omerta/setup-complete.sh
            permissions: '0755'
            content: |
              #!/bin/sh
              # Signal that setup is complete
              echo "OMERTA_SETUP_COMPLETE" > /run/omerta-ready
              echo "VM network isolation active"

        # Run commands on first boot
        runcmd:
          # Create omerta directory
          - mkdir -p /etc/omerta

          # Start WireGuard FIRST (before firewall)
          - wg-quick up wg0

          # Verify WireGuard is running
          - wg show wg0

          # Apply firewall rules AFTER WireGuard is up
          # This ensures the tunnel can establish before we lock down
          - /etc/omerta/firewall.sh

          # Signal completion
          - /etc/omerta/setup-complete.sh

        # Ensure firewall starts on reboot (only if WireGuard is configured)
        bootcmd:
          - test -f /etc/wireguard/wg0.conf && test -f /etc/omerta/firewall.sh && /etc/omerta/firewall.sh || true
        """

        return yaml
    }

    /// Generate cloud-init meta-data for VM network isolation config
    public static func generateNetworkIsolationMetaData(config: VMNetworkConfig) -> String {
        """
        instance-id: \(config.instanceId)
        local-hostname: \(config.hostname)
        """
    }

    /// Create a cloud-init seed ISO for VM network isolation
    public static func createNetworkIsolationISO(
        config: VMNetworkConfig,
        outputPath: String
    ) throws {
        let expandedPath = expandPath(outputPath)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudinit-network-\(config.instanceId)")

        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Write user-data
        let userData = generateNetworkIsolationUserData(config: config)
        let userDataPath = tempDir.appendingPathComponent("user-data")
        try userData.write(to: userDataPath, atomically: true, encoding: .utf8)

        // Write meta-data
        let metaData = generateNetworkIsolationMetaData(config: config)
        let metaDataPath = tempDir.appendingPathComponent("meta-data")
        try metaData.write(to: metaDataPath, atomically: true, encoding: .utf8)

        // Create ISO
        #if os(macOS)
        try createISOmacOS(from: tempDir.path, to: expandedPath)
        #else
        try createISOLinux(from: tempDir.path, to: expandedPath)
        #endif
    }
}

// MARK: - VM Network Config Factory

public struct VMNetworkConfigFactory {

    /// Create a standard VM network config for consumer connection
    public static func createForConsumer(
        consumerPublicKey: String,
        consumerEndpoint: String,
        vmPrivateKey: String,
        vmAddress: String = "10.200.200.2/24",
        packageConfig: VMNetworkConfig.PackageConfig? = .debian
    ) -> VMNetworkConfig {
        let instanceId = "omerta-\(UUID().uuidString.prefix(8).lowercased())"

        return VMNetworkConfig(
            wireGuard: .init(
                privateKey: vmPrivateKey,
                address: vmAddress,
                listenPort: nil,
                peer: .init(
                    publicKey: consumerPublicKey,
                    endpoint: consumerEndpoint,
                    allowedIPs: "0.0.0.0/0, ::/0",
                    persistentKeepalive: 25
                )
            ),
            firewall: .init(
                allowLoopback: true,
                allowWireGuardInterface: true,
                allowDHCP: true,
                allowDNS: false,
                // Only allow package install if packages are specified (DEVELOPMENT ONLY)
                // For production, use pre-built images with WireGuard pre-installed
                allowPackageInstall: packageConfig != nil,
                customRules: nil
            ),
            packageConfig: packageConfig,
            instanceId: instanceId,
            hostname: "omerta-vm-\(instanceId.suffix(8))"
        )
    }
}

// MARK: - Errors

public enum CloudInitError: Error, CustomStringConvertible {
    case isoCreationFailed(String)
    case directoryCreationFailed(String)
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .isoCreationFailed(let reason):
            return "Failed to create cloud-init ISO: \(reason)"
        case .directoryCreationFailed(let reason):
            return "Failed to create directory: \(reason)"
        case .invalidConfiguration(let reason):
            return "Invalid cloud-init configuration: \(reason)"
        }
    }
}
