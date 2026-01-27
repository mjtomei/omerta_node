// ProviderEventLogger.swift - JSON Lines-based event logging for OmertaProvider

import Foundation
import Logging
import OmertaCore

/// Actor responsible for logging provider events to JSON Lines files
public actor ProviderEventLogger {
    // MARK: - Properties

    private let logDir: String
    private var fileHandles: [String: FileHandle] = [:]
    private let logger: Logger

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = []
        return encoder
    }()

    // MARK: - Initialization

    public init(logDir: String? = nil) throws {
        var log = Logger(label: "io.omerta.provider.eventlogger")
        log.logLevel = .info
        self.logger = log

        let dir = logDir ?? ProviderEventLogger.defaultLogDir()
        self.logDir = dir

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        logger.info("Provider event logger initialized", metadata: ["path": "\(dir)"])
    }

    public func stop() async {
        for (_, handle) in fileHandles {
            try? handle.synchronize()
            try? handle.close()
        }
        fileHandles.removeAll()
    }

    private static func defaultLogDir() -> String {
        "\(OmertaConfig.getRealUserHome())/.omerta/logs/provider"
    }

    // MARK: - File Management

    private func getFileHandle(for logType: String) -> FileHandle? {
        if let handle = fileHandles[logType] {
            return handle
        }

        let path = "\(logDir)/\(logType).jsonl"

        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let handle = FileHandle(forWritingAtPath: path) else {
            logger.warning("Failed to open log file", metadata: ["path": "\(path)"])
            return nil
        }

        do {
            try handle.seekToEnd()
        } catch {
            logger.warning("Failed to seek to end of log file", metadata: ["error": "\(error)"])
        }

        fileHandles[logType] = handle
        return handle
    }

    private func appendEvent<T: Encodable>(_ event: T, to logType: String) {
        guard let handle = getFileHandle(for: logType) else { return }

        do {
            var data = try encoder.encode(event)
            data.append(contentsOf: "\n".utf8)
            try handle.write(contentsOf: data)
        } catch {
            logger.warning("Failed to write event", metadata: [
                "logType": "\(logType)",
                "error": "\(error)"
            ])
        }
    }

    // MARK: - VM Lifecycle Events

    /// Log VM creation request
    public func recordVMRequest(
        vmId: UUID,
        consumerMachineId: String,
        cpuCores: Int,
        memoryMB: Int,
        diskGB: Int
    ) async {
        let event = VMRequestEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            consumerMachineId: consumerMachineId,
            cpuCores: cpuCores,
            memoryMB: memoryMB,
            diskGB: diskGB
        )
        appendEvent(event, to: "vm_requests")
    }

    /// Log VM creation result
    public func recordVMCreated(
        vmId: UUID,
        consumerMachineId: String,
        success: Bool,
        error: String? = nil,
        durationMs: Int? = nil
    ) async {
        let event = VMCreatedEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            consumerMachineId: consumerMachineId,
            success: success,
            error: error,
            durationMs: durationMs
        )
        appendEvent(event, to: "vm_lifecycle")
    }

    /// Log VM release
    public func recordVMReleased(
        vmId: UUID,
        consumerMachineId: String,
        reason: String,
        durationMs: Int? = nil
    ) async {
        let event = VMReleasedEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            consumerMachineId: consumerMachineId,
            reason: reason,
            durationMs: durationMs
        )
        appendEvent(event, to: "vm_lifecycle")
    }

    /// Log VM timeout (heartbeat failure)
    public func recordVMTimeout(
        vmId: UUID,
        consumerMachineId: String,
        lastHeartbeat: Date
    ) async {
        let event = VMTimeoutEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            consumerMachineId: consumerMachineId,
            lastHeartbeat: lastHeartbeat,
            secondsSinceHeartbeat: Int(Date().timeIntervalSince(lastHeartbeat))
        )
        appendEvent(event, to: "vm_lifecycle")
    }

    // MARK: - Heartbeat Events

    /// Log heartbeat received
    public func recordHeartbeat(
        consumerMachineId: String,
        vmIds: [UUID],
        activeVmIds: [UUID]
    ) async {
        let event = HeartbeatEvent(
            timestamp: Date(),
            consumerMachineId: consumerMachineId,
            requestedVmIds: vmIds.map { $0.uuidString },
            confirmedVmIds: activeVmIds.map { $0.uuidString }
        )
        appendEvent(event, to: "heartbeats")
    }

    /// Log heartbeat timeout (no response)
    public func recordHeartbeatTimeout(
        consumerMachineId: String,
        vmIds: [UUID]
    ) async {
        let event = HeartbeatTimeoutEvent(
            timestamp: Date(),
            consumerMachineId: consumerMachineId,
            vmIds: vmIds.map { $0.uuidString }
        )
        appendEvent(event, to: "heartbeats")
    }

    // MARK: - Resource Events

    /// Log resource allocation
    public func recordResourceAllocation(
        vmId: UUID,
        cpuCores: Int,
        memoryMB: Int,
        diskGB: Int
    ) async {
        let event = ResourceAllocationEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            eventType: "allocated",
            cpuCores: cpuCores,
            memoryMB: memoryMB,
            diskGB: diskGB
        )
        appendEvent(event, to: "resources")
    }

    /// Log resource deallocation
    public func recordResourceDeallocation(
        vmId: UUID,
        cpuCores: Int,
        memoryMB: Int,
        diskGB: Int
    ) async {
        let event = ResourceAllocationEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            eventType: "deallocated",
            cpuCores: cpuCores,
            memoryMB: memoryMB,
            diskGB: diskGB
        )
        appendEvent(event, to: "resources")
    }

    /// Log resource snapshot (current state)
    public func recordResourceSnapshot(
        totalCpuCores: Int,
        usedCpuCores: Int,
        totalMemoryMB: Int,
        usedMemoryMB: Int,
        totalDiskGB: Int,
        usedDiskGB: Int,
        activeVMs: Int
    ) async {
        let event = ResourceSnapshotEvent(
            timestamp: Date(),
            totalCpuCores: totalCpuCores,
            usedCpuCores: usedCpuCores,
            totalMemoryMB: totalMemoryMB,
            usedMemoryMB: usedMemoryMB,
            totalDiskGB: totalDiskGB,
            usedDiskGB: usedDiskGB,
            activeVMs: activeVMs
        )
        appendEvent(event, to: "resources")
    }

    // MARK: - VPN Events

    /// Log VPN tunnel created
    public func recordVPNCreated(
        vmId: UUID,
        interface: String,
        consumerEndpoint: String
    ) async {
        let event = VPNEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            eventType: "created",
            interface: interface,
            consumerEndpoint: consumerEndpoint,
            error: nil
        )
        appendEvent(event, to: "vpn")
    }

    /// Log VPN tunnel destroyed
    public func recordVPNDestroyed(
        vmId: UUID,
        interface: String,
        reason: String
    ) async {
        let event = VPNEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            eventType: "destroyed",
            interface: interface,
            consumerEndpoint: nil,
            error: reason
        )
        appendEvent(event, to: "vpn")
    }

    /// Log VPN health check failure
    public func recordVPNHealthFailure(
        vmId: UUID,
        interface: String,
        error: String
    ) async {
        let event = VPNEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            eventType: "health_failure",
            interface: interface,
            consumerEndpoint: nil,
            error: error
        )
        appendEvent(event, to: "vpn")
    }

    // MARK: - Error Events

    /// Log provider error
    public func recordError(
        component: String,
        operation: String,
        errorType: String,
        errorMessage: String,
        vmId: UUID? = nil,
        consumerMachineId: String? = nil
    ) async {
        let event = ProviderErrorEvent(
            timestamp: Date(),
            component: component,
            operation: operation,
            errorType: errorType,
            errorMessage: errorMessage,
            vmId: vmId?.uuidString,
            consumerMachineId: consumerMachineId
        )
        appendEvent(event, to: "errors")
    }
}

// MARK: - Event Types

private struct VMRequestEvent: Codable {
    let timestamp: Date
    let vmId: String
    let consumerMachineId: String
    let cpuCores: Int
    let memoryMB: Int
    let diskGB: Int
}

private struct VMCreatedEvent: Codable {
    let timestamp: Date
    let vmId: String
    let consumerMachineId: String
    let success: Bool
    let error: String?
    let durationMs: Int?
}

private struct VMReleasedEvent: Codable {
    let timestamp: Date
    let vmId: String
    let consumerMachineId: String
    let reason: String
    let durationMs: Int?
}

private struct VMTimeoutEvent: Codable {
    let timestamp: Date
    let vmId: String
    let consumerMachineId: String
    let lastHeartbeat: Date
    let secondsSinceHeartbeat: Int
}

private struct HeartbeatEvent: Codable {
    let timestamp: Date
    let consumerMachineId: String
    let requestedVmIds: [String]
    let confirmedVmIds: [String]
}

private struct HeartbeatTimeoutEvent: Codable {
    let timestamp: Date
    let consumerMachineId: String
    let vmIds: [String]
}

private struct ResourceAllocationEvent: Codable {
    let timestamp: Date
    let vmId: String
    let eventType: String
    let cpuCores: Int
    let memoryMB: Int
    let diskGB: Int
}

private struct ResourceSnapshotEvent: Codable {
    let timestamp: Date
    let totalCpuCores: Int
    let usedCpuCores: Int
    let totalMemoryMB: Int
    let usedMemoryMB: Int
    let totalDiskGB: Int
    let usedDiskGB: Int
    let activeVMs: Int
}

private struct VPNEvent: Codable {
    let timestamp: Date
    let vmId: String
    let eventType: String
    let interface: String
    let consumerEndpoint: String?
    let error: String?
}

private struct ProviderErrorEvent: Codable {
    let timestamp: Date
    let component: String
    let operation: String
    let errorType: String
    let errorMessage: String
    let vmId: String?
    let consumerMachineId: String?
}
