import Foundation
import Logging
import OmertaCore

#if canImport(Network)
import Network
#endif

/// Monitors VM network traffic to detect rogue connections (traffic bypassing VPN)
/// Automatically starts with every VM to ensure provider's network security
public actor RogueConnectionDetector {
    private let logger = Logger(label: "com.omerta.rogue-detector")
    private var monitors: [UUID: NetworkMonitor] = [:]
    private let monitoringInterval: TimeInterval

    public init(monitoringInterval: TimeInterval = 5.0) {
        self.monitoringInterval = monitoringInterval
        logger.info("RogueConnectionDetector initialized")
    }

    /// Start monitoring a VM's network traffic
    public func startMonitoring(
        jobId: UUID,
        vpnConfig: VPNConfiguration,
        vmInterface: String? = nil,
        onRogueDetected: @escaping @Sendable (RogueConnectionEvent) -> Void
    ) async throws {
        logger.info("Starting rogue connection monitoring", metadata: ["job_id": "\(jobId)"])

        let monitor = NetworkMonitor(
            jobId: jobId,
            consumerVPNIP: vpnConfig.consumerVPNIP,
            consumerEndpoint: vpnConfig.consumerEndpoint,
            vmInterface: vmInterface,
            startedAt: Date()
        )

        monitors[jobId] = monitor

        // Start monitoring task
        Task {
            await monitorTrafficLoop(
                jobId: jobId,
                monitor: monitor,
                onRogueDetected: onRogueDetected
            )
        }

        logger.info("Monitoring started", metadata: ["job_id": "\(jobId)"])
    }

    /// Stop monitoring a VM
    public func stopMonitoring(jobId: UUID) {
        logger.info("Stopping rogue connection monitoring", metadata: ["job_id": "\(jobId)"])
        monitors.removeValue(forKey: jobId)
    }

    /// Get monitoring statistics for a job
    public func getMonitoringStats(for jobId: UUID) -> NetworkMonitor? {
        monitors[jobId]
    }

    // MARK: - Private Methods

    private func monitorTrafficLoop(
        jobId: UUID,
        monitor: NetworkMonitor,
        onRogueDetected: @escaping @Sendable (RogueConnectionEvent) -> Void
    ) async {
        while monitors[jobId] != nil {
            do {
                // Check for non-VPN traffic
                let rogueConnections = try await detectRogueConnections(
                    jobId: jobId,
                    monitor: monitor
                )

                if !rogueConnections.isEmpty {
                    logger.warning("Rogue connections detected!", metadata: [
                        "job_id": "\(jobId)",
                        "count": "\(rogueConnections.count)"
                    ])

                    for connection in rogueConnections {
                        let event = RogueConnectionEvent(
                            jobId: jobId,
                            connection: connection,
                            detectedAt: Date()
                        )
                        onRogueDetected(event)
                    }

                    // Stop monitoring - VM should be terminated by caller
                    break
                }

                // Sleep before next check
                try await Task.sleep(for: .seconds(monitoringInterval))

            } catch {
                logger.error("Monitoring error", metadata: [
                    "job_id": "\(jobId)",
                    "error": "\(error)"
                ])
                try? await Task.sleep(for: .seconds(monitoringInterval))
            }
        }
    }

    private func detectRogueConnections(
        jobId: UUID,
        monitor: NetworkMonitor
    ) async throws -> [SuspiciousConnection] {
        // Use netstat or ss to check active connections
        // Look for connections NOT going through VPN interface

        let connections = try await getCurrentConnections()

        var rogueConnections: [SuspiciousConnection] = []

        for connection in connections {
            // Skip localhost connections
            if connection.destinationIP.hasPrefix("127.") || connection.destinationIP == "::1" {
                continue
            }

            // Skip VPN server connection itself (the consumer's VPN server)
            if connection.destinationIP == monitor.consumerVPNIP {
                continue
            }

            // Check if connection is going through WireGuard interface
            let isVPNTraffic = try await isConnectionThroughVPN(connection)

            if !isVPNTraffic {
                logger.warning("Suspicious non-VPN connection detected", metadata: [
                    "destination": "\(connection.destinationIP):\(connection.destinationPort)",
                    "protocol": "\(connection.protocolType)"
                ])

                rogueConnections.append(SuspiciousConnection(
                    destinationIP: connection.destinationIP,
                    destinationPort: connection.destinationPort,
                    protocolType: connection.protocolType,
                    processName: connection.processName
                ))
            }
        }

        return rogueConnections
    }

    private func getCurrentConnections() async throws -> [ActiveConnection] {
        // Use netstat to get active connections
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-n", "-a", "-p", "tcp"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RogueDetectionError.netstatFailed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return parseNetstatOutput(output)
    }

    private func parseNetstatOutput(_ output: String) -> [ActiveConnection] {
        var connections: [ActiveConnection] = []

        let lines = output.split(separator: "\n")

        for line in lines {
            // Skip header lines
            if line.contains("Proto") || line.contains("Active") {
                continue
            }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true)

            // Netstat format: Proto Recv-Q Send-Q Local-Address Foreign-Address State
            guard parts.count >= 5 else { continue }

            let proto = String(parts[0])
            let foreignAddress = String(parts[4])

            // Parse foreign address (IP:port)
            let addressParts = foreignAddress.split(separator: ":")
            guard addressParts.count >= 2 else { continue }

            let ip = String(addressParts[0])
            let port = String(addressParts[1])

            // Skip if not established connection
            if parts.count >= 6 && !String(parts[5]).contains("ESTABLISHED") {
                continue
            }

            connections.append(ActiveConnection(
                destinationIP: ip,
                destinationPort: port,
                protocolType: proto,
                processName: nil // Would need lsof for process name
            ))
        }

        return connections
    }

    private func isConnectionThroughVPN(_ connection: ActiveConnection) async throws -> Bool {
        // Check routing table to see if destination goes through VPN interface
        let process = Process()

        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["get", connection.destinationIP]
        #else
        process.executableURL = URL(fileURLWithPath: "/sbin/ip")
        process.arguments = ["route", "get", connection.destinationIP]
        #endif

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // Cannot determine routing - assume safe
            return true
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Check if route goes through wg* interface
        #if os(macOS)
        return output.contains("interface: utun") || output.contains("interface: wg")
        #else
        return output.contains("dev wg") || output.contains("via wg")
        #endif
    }

    /// Check VPN tunnel health
    public func checkVPNTunnelHealth(
        jobId: UUID,
        vpnConfig: VPNConfiguration
    ) async throws -> VPNTunnelHealth {
        // Ping VPN server to check connectivity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "2", vpnConfig.consumerVPNIP]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let isReachable = process.terminationStatus == 0

        // Check WireGuard interface status
        let wgProcess = Process()
        wgProcess.executableURL = URL(fileURLWithPath: "/usr/bin/wg")
        wgProcess.arguments = ["show"]

        let wgPipe = Pipe()
        wgProcess.standardOutput = wgPipe

        try wgProcess.run()
        wgProcess.waitUntilExit()

        let wgData = wgPipe.fileHandleForReading.readDataToEndOfFile()
        let wgOutput = String(data: wgData, encoding: .utf8) ?? ""

        let hasActiveInterface = wgOutput.contains("interface:")

        return VPNTunnelHealth(
            isVPNReachable: isReachable,
            hasActiveInterface: hasActiveInterface,
            checkedAt: Date()
        )
    }
}

/// Network monitor for a specific job
public struct NetworkMonitor: Sendable {
    public let jobId: UUID
    public let consumerVPNIP: String
    public let consumerEndpoint: String
    public let vmInterface: String?
    public let startedAt: Date
}

/// Active network connection
struct ActiveConnection {
    let destinationIP: String
    let destinationPort: String
    let protocolType: String
    let processName: String?
}

/// Suspicious connection that bypasses VPN
public struct SuspiciousConnection: Sendable {
    public let destinationIP: String
    public let destinationPort: String
    public let protocolType: String
    public let processName: String?
}

/// Rogue connection event
public struct RogueConnectionEvent: Sendable {
    public let jobId: UUID
    public let connection: SuspiciousConnection
    public let detectedAt: Date
}

/// VPN tunnel health status
public struct VPNTunnelHealth: Sendable {
    public let isVPNReachable: Bool
    public let hasActiveInterface: Bool
    public let checkedAt: Date

    public var isHealthy: Bool {
        isVPNReachable && hasActiveInterface
    }
}

/// Rogue detection errors
public enum RogueDetectionError: Error {
    case netstatFailed
    case monitoringFailed(String)
}
