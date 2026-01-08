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

    #if os(macOS)
    private static func createISOmacOS(from directory: String, to outputPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid",
            "-o", outputPath,
            "-hfs",
            "-joliet",
            "-iso",
            "-default-volume-name", "cidata",
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

// MARK: - Errors

public enum CloudInitError: Error, CustomStringConvertible {
    case isoCreationFailed(String)
    case directoryCreationFailed(String)

    public var description: String {
        switch self {
        case .isoCreationFailed(let reason):
            return "Failed to create cloud-init ISO: \(reason)"
        case .directoryCreationFailed(let reason):
            return "Failed to create directory: \(reason)"
        }
    }
}
