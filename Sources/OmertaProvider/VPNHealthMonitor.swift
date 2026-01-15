import Foundation
import Logging
import OmertaCore
import OmertaVPN

/// Monitors VPN tunnel health and terminates VMs when consumer connection dies
/// Uses WireGuard handshake timestamps to detect dead tunnels
public actor VPNHealthMonitor {
    private let logger: Logger
    private let checkInterval: TimeInterval
    private let timeoutThreshold: TimeInterval
    private var monitoredVMs: [UUID: MonitoredVM] = [:]
    private var monitoringTasks: [UUID: Task<Void, Never>] = [:]

    /// Configuration for a monitored VM
    private struct MonitoredVM {
        let vmId: UUID
        let vpnInterface: String
        let consumerPublicKey: String
        let onTunnelDeath: @Sendable (UUID) async -> Void
        let startedAt: Date
    }

    public init(
        checkInterval: TimeInterval = 30.0,
        timeoutThreshold: TimeInterval = 600.0  // 10 minutes - extended for testing
    ) {
        var logger = Logger(label: "com.omerta.provider.vpn-health")
        logger.logLevel = .info
        self.logger = logger
        self.checkInterval = checkInterval
        self.timeoutThreshold = timeoutThreshold
    }

    // MARK: - Monitoring Lifecycle

    /// Start monitoring VPN tunnel for a VM
    public func startMonitoring(
        vmId: UUID,
        vpnInterface: String,
        consumerPublicKey: String,
        onTunnelDeath: @escaping @Sendable (UUID) async -> Void
    ) async {
        logger.info("Starting VPN health monitoring", metadata: [
            "vm_id": "\(vmId)",
            "interface": "\(vpnInterface)"
        ])

        // Store monitoring configuration
        let monitored = MonitoredVM(
            vmId: vmId,
            vpnInterface: vpnInterface,
            consumerPublicKey: consumerPublicKey,
            onTunnelDeath: onTunnelDeath,
            startedAt: Date()
        )
        monitoredVMs[vmId] = monitored

        // Start monitoring task
        let task = Task {
            await self.monitorLoop(vmId: vmId)
        }
        monitoringTasks[vmId] = task
    }

    /// Stop monitoring VPN tunnel for a VM
    public func stopMonitoring(vmId: UUID) async {
        logger.info("Stopping VPN health monitoring", metadata: ["vm_id": "\(vmId)"])

        // Cancel monitoring task
        monitoringTasks[vmId]?.cancel()
        monitoringTasks.removeValue(forKey: vmId)

        // Remove from monitored VMs
        monitoredVMs.removeValue(forKey: vmId)
    }

    /// Stop all monitoring
    public func stopAll() async {
        logger.info("Stopping all VPN health monitoring")

        for task in monitoringTasks.values {
            task.cancel()
        }
        monitoringTasks.removeAll()
        monitoredVMs.removeAll()
    }

    // MARK: - Monitoring Loop

    /// Main monitoring loop for a VM
    private func monitorLoop(vmId: UUID) async {
        logger.info("VPN monitoring loop started", metadata: ["vm_id": "\(vmId)"])

        while !Task.isCancelled {
            // Check tunnel health
            do {
                let isHealthy = try await checkTunnelHealth(vmId: vmId)

                if !isHealthy {
                    logger.error("VPN tunnel is dead - initiating VM termination", metadata: [
                        "vm_id": "\(vmId)"
                    ])

                    // Notify via callback
                    if let monitored = monitoredVMs[vmId] {
                        await monitored.onTunnelDeath(vmId)
                    }

                    // Stop monitoring this VM
                    await stopMonitoring(vmId: vmId)
                    break
                }
            } catch {
                logger.error("Error checking tunnel health", metadata: [
                    "vm_id": "\(vmId)",
                    "error": "\(error)"
                ])
            }

            // Wait before next check
            do {
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            } catch {
                // Task was cancelled
                break
            }
        }

        logger.info("VPN monitoring loop stopped", metadata: ["vm_id": "\(vmId)"])
    }

    /// Check if VPN tunnel is healthy
    private func checkTunnelHealth(vmId: UUID) async throws -> Bool {
        guard let monitored = monitoredVMs[vmId] else {
            logger.warning("VM not in monitored list", metadata: ["vm_id": "\(vmId)"])
            return false
        }

        logger.debug("Checking tunnel health", metadata: [
            "vm_id": "\(vmId)",
            "interface": "\(monitored.vpnInterface)"
        ])

        // Query WireGuard for latest handshake time
        let handshakeTime = try await getLatestHandshake(
            interface: monitored.vpnInterface,
            publicKey: monitored.consumerPublicKey
        )

        guard let handshakeTime = handshakeTime else {
            // No handshake found - check if VM just started
            let secondsSinceStart = Date().timeIntervalSince(monitored.startedAt)
            if secondsSinceStart < timeoutThreshold {
                logger.debug("No handshake yet, but VM recently started", metadata: [
                    "vm_id": "\(vmId)",
                    "seconds_since_start": "\(secondsSinceStart)"
                ])
                return true
            } else {
                logger.warning("No handshake found and timeout exceeded", metadata: [
                    "vm_id": "\(vmId)"
                ])
                return false
            }
        }

        // Check if handshake is recent
        let secondsSinceHandshake = Date().timeIntervalSince(handshakeTime)

        if secondsSinceHandshake > timeoutThreshold {
            logger.warning("Handshake timeout exceeded", metadata: [
                "vm_id": "\(vmId)",
                "seconds_since_handshake": "\(secondsSinceHandshake)",
                "threshold": "\(timeoutThreshold)"
            ])
            return false
        }

        logger.debug("Tunnel healthy", metadata: [
            "vm_id": "\(vmId)",
            "seconds_since_handshake": "\(secondsSinceHandshake)"
        ])
        return true
    }

    /// Get latest handshake timestamp from WireGuard
    private func getLatestHandshake(
        interface: String,
        publicKey: String
    ) async throws -> Date? {
        // First try the wg CLI (works for wg-quick/wireguard-go implementations)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [WireGuardPaths.wg, "show", interface, "latest-handshakes"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // wg show failed - on macOS this may be because we're using native utun
            // implementation that doesn't have a wg socket interface
            #if os(macOS)
            // Check if the interface exists using ifconfig
            let ifaceExists = await checkInterfaceExists(interface)
            if ifaceExists {
                logger.debug("wg show failed but interface exists (native macOS mode)", metadata: [
                    "interface": "\(interface)"
                ])
                // In native mode, we can't easily check handshake times
                // For now, assume the tunnel is healthy if the interface exists
                // The interface will be destroyed when the VM is released
                return Date() // Return current time to indicate "healthy"
            }
            #endif

            logger.error("Failed to query WireGuard", metadata: [
                "interface": "\(interface)",
                "exit_code": "\(process.terminationStatus)"
            ])
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Parse output format: "public_key\ttimestamp"
        // Example: "abc123...\t1672531200"
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }

            let linePublicKey = String(parts[0])
            let timestampStr = String(parts[1])

            // Match consumer's public key
            if linePublicKey.contains(publicKey) || publicKey.contains(linePublicKey) {
                guard let timestamp = TimeInterval(timestampStr), timestamp > 0 else {
                    // Timestamp is 0 - no handshake yet
                    return nil
                }

                return Date(timeIntervalSince1970: timestamp)
            }
        }

        // Public key not found in output
        return nil
    }

    #if os(macOS)
    /// Check if an interface exists on macOS (works for both utun and wg interfaces)
    private func checkInterfaceExists(_ interface: String) async -> Bool {
        // On macOS, check for utun interfaces via ifconfig
        // The interface name might be either the wg name (wg-XXXX) or the actual utun name
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")

        // Try to find any utun interface that might be ours
        // Provider WG interfaces are named wg-<uuid8> internally but create utun externally
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        // List all interfaces
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Check if there are any utun interfaces with IPs in our VPN range (10.x.x.x)
        // This is a heuristic - the native implementation creates utun interfaces
        let utunPattern = "utun"
        let vpnIPPattern = "inet 10."

        // Simple check: if output contains utun and a 10.x IP, consider it exists
        // This isn't perfect but avoids killing VMs unnecessarily
        return output.contains(utunPattern) && output.contains(vpnIPPattern)
    }
    #endif

    // MARK: - Status

    /// Get monitoring status
    public func getStatus() -> MonitoringStatus {
        MonitoringStatus(
            monitoredVMs: monitoredVMs.count,
            checkInterval: checkInterval,
            timeoutThreshold: timeoutThreshold
        )
    }

    public struct MonitoringStatus: Sendable {
        public let monitoredVMs: Int
        public let checkInterval: TimeInterval
        public let timeoutThreshold: TimeInterval
    }
}
