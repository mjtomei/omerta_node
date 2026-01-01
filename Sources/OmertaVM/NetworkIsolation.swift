import Foundation
import Virtualization
import Logging
import OmertaCore

/// Handles network isolation and VPN routing for VMs
/// Ensures ALL VM traffic routes through requester-provided VPN
public actor NetworkIsolation {
    private let logger = Logger(label: "com.omerta.network-isolation")

    public init() {
        logger.info("NetworkIsolation initialized")
    }

    /// Configure VM network to route all traffic through VPN
    /// This modifies the initramfs to set up VPN routing on boot
    public func configureVPNRouting(
        initramfsPath: URL,
        vpnConfig: VPNConfiguration,
        jobId: UUID
    ) async throws -> URL {
        logger.info("Configuring VPN routing for VM", metadata: ["job_id": "\(jobId)"])

        // Create modified initramfs with VPN setup
        let modifiedInitramfsPath = try await injectVPNSetup(
            initramfsPath: initramfsPath,
            vpnConfig: vpnConfig,
            jobId: jobId
        )

        logger.info("VPN routing configured", metadata: ["job_id": "\(jobId)"])

        return modifiedInitramfsPath
    }

    /// Create network device configuration with VPN routing
    public func createVPNRoutedNetworkDevice() -> VZVirtioNetworkDeviceConfiguration {
        // Use NAT attachment - VM will configure VPN routing internally
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        return networkDevice
    }

    // MARK: - Private Methods

    private func injectVPNSetup(
        initramfsPath: URL,
        vpnConfig: VPNConfiguration,
        jobId: UUID
    ) async throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-vpn-\(jobId.uuidString)")

        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Extract existing initramfs
        let extractDir = tmpDir.appendingPathComponent("initramfs-extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        try await extractInitramfs(initramfsPath, to: extractDir)

        // Write WireGuard config
        let wgConfigPath = extractDir.appendingPathComponent("wg0.conf")
        try vpnConfig.wireguardConfig.write(to: wgConfigPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wgConfigPath.path)

        // Create VPN setup script
        let vpnSetupScript = generateVPNSetupScript(
            vpnServerIP: vpnConfig.vpnServerIP,
            endpoint: vpnConfig.endpoint
        )

        let vpnSetupPath = extractDir.appendingPathComponent("setup-vpn.sh")
        try vpnSetupScript.write(to: vpnSetupPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vpnSetupPath.path)

        // Modify init script to call VPN setup
        try await modifyInitScript(in: extractDir)

        // Repack initramfs
        let modifiedInitramfsPath = tmpDir.appendingPathComponent("initramfs-vpn.gz")
        try await repackInitramfs(from: extractDir, to: modifiedInitramfsPath)

        return modifiedInitramfsPath
    }

    private func extractInitramfs(_ initramfsPath: URL, to extractDir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "cd \(extractDir.path) && gunzip -c \(initramfsPath.path) | cpio -idm 2>/dev/null"
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NetworkIsolationError.initramfsExtractionFailed
        }
    }

    private func repackInitramfs(from extractDir: URL, to outputPath: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "cd \(extractDir.path) && find . | cpio -o -H newc 2>/dev/null | gzip > \(outputPath.path)"
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NetworkIsolationError.initramfsRepackFailed
        }
    }

    private func modifyInitScript(in extractDir: URL) async throws {
        let initPath = extractDir.appendingPathComponent("init")

        guard FileManager.default.fileExists(atPath: initPath.path) else {
            throw NetworkIsolationError.initScriptNotFound
        }

        // Read existing init script
        let existingInit = try String(contentsOf: initPath, encoding: .utf8)

        // Insert VPN setup before workload execution
        let modifiedInit = existingInit.replacingOccurrences(
            of: "# Execute workload",
            with: """
            # Setup VPN routing (CRITICAL: All traffic must go through VPN)
            echo "=== SETTING UP VPN ROUTING ==="
            if [ -f /setup-vpn.sh ]; then
                /setup-vpn.sh
                if [ $? -ne 0 ]; then
                    echo "ERROR: VPN setup failed - terminating for security"
                    poweroff -f
                fi
            else
                echo "ERROR: VPN setup script not found - terminating for security"
                poweroff -f
            fi
            echo "=== VPN ROUTING ACTIVE ==="

            # Execute workload
            """
        )

        try modifiedInit.write(to: initPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: initPath.path)
    }

    private func generateVPNSetupScript(
        vpnServerIP: String,
        endpoint: String
    ) -> String {
        """
        #!/bin/sh
        set -e

        echo "Configuring VPN routing..."

        # Install WireGuard (if not already present)
        # For Alpine Linux minimal initramfs, wireguard-tools should be included

        # Bring up WireGuard interface
        if [ -f /wg0.conf ]; then
            wg-quick up /wg0.conf
            if [ $? -ne 0 ]; then
                echo "ERROR: Failed to bring up WireGuard interface"
                exit 1
            fi
        else
            echo "ERROR: WireGuard config not found"
            exit 1
        fi

        # Verify VPN is up
        if ! ip link show wg0 > /dev/null 2>&1; then
            echo "ERROR: WireGuard interface not found"
            exit 1
        fi

        # Test connectivity to VPN server
        echo "Testing VPN connectivity..."
        ping -c 1 -W 5 \(vpnServerIP) > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "ERROR: Cannot reach VPN server at \(vpnServerIP)"
            exit 1
        fi

        echo "VPN routing configured successfully"
        echo "All traffic will route through \(endpoint)"

        # Block any traffic not going through VPN (defense in depth)
        # Allow localhost and VPN interface only
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT DROP

        # Allow localhost
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A OUTPUT -o lo -j ACCEPT

        # Allow VPN interface
        iptables -A INPUT -i wg0 -j ACCEPT
        iptables -A OUTPUT -o wg0 -j ACCEPT

        # Allow established connections
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

        echo "Firewall rules applied - only VPN traffic permitted"

        exit 0
        """
    }

    /// Verify VPN is active and routing correctly
    public func verifyVPNRouting(
        vmConsoleOutput: String
    ) throws -> Bool {
        // Check console output for VPN setup success markers
        let hasVPNSetup = vmConsoleOutput.contains("=== VPN ROUTING ACTIVE ===")
        let hasVPNSuccess = vmConsoleOutput.contains("VPN routing configured successfully")

        guard hasVPNSetup && hasVPNSuccess else {
            logger.error("VPN routing verification failed")
            return false
        }

        return true
    }
}

/// Network isolation errors
public enum NetworkIsolationError: Error {
    case initramfsExtractionFailed
    case initramfsRepackFailed
    case initScriptNotFound
    case vpnSetupFailed
    case vpnVerificationFailed
}
