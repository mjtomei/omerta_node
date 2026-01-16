// ConsumerEventLogger.swift - JSON Lines-based event logging for OmertaConsumer

import Foundation
import Logging

/// Actor responsible for logging consumer events to JSON Lines files
public actor ConsumerEventLogger {
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
        var log = Logger(label: "io.omerta.consumer.eventlogger")
        log.logLevel = .info
        self.logger = log

        let dir = logDir ?? ConsumerEventLogger.defaultLogDir()
        self.logDir = dir

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        logger.info("Consumer event logger initialized", metadata: ["path": "\(dir)"])
    }

    public func stop() async {
        for (_, handle) in fileHandles {
            try? handle.synchronize()
            try? handle.close()
        }
        fileHandles.removeAll()
    }

    private static func defaultLogDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/OmertaConsumer/logs"
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

    // MARK: - VM Request Events

    /// Log VM request sent
    public func recordVMRequest(
        vmId: UUID,
        providerPeerId: String,
        cpuCores: Int,
        memoryMB: Int,
        diskGB: Int,
        timeoutMinutes: Int
    ) async {
        let event = VMRequestSentEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            providerPeerId: providerPeerId,
            cpuCores: cpuCores,
            memoryMB: memoryMB,
            diskGB: diskGB,
            timeoutMinutes: timeoutMinutes
        )
        appendEvent(event, to: "vm_requests")
    }

    /// Log VM request response received
    public func recordVMResponse(
        vmId: UUID,
        providerPeerId: String,
        success: Bool,
        error: String? = nil,
        vmIP: String? = nil,
        responseTimeMs: Int
    ) async {
        let event = VMResponseEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            providerPeerId: providerPeerId,
            success: success,
            error: error,
            vmIP: vmIP,
            responseTimeMs: responseTimeMs
        )
        appendEvent(event, to: "vm_requests")
    }

    /// Log VM release sent
    public func recordVMRelease(
        vmId: UUID,
        providerPeerId: String,
        reason: String
    ) async {
        let event = VMReleaseEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            providerPeerId: providerPeerId,
            reason: reason
        )
        appendEvent(event, to: "vm_lifecycle")
    }

    // MARK: - Connection Events

    /// Log SSH connection attempt
    public func recordSSHConnection(
        vmId: UUID,
        vmIP: String,
        success: Bool,
        error: String? = nil,
        connectionTimeMs: Int? = nil
    ) async {
        let event = SSHConnectionEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            vmIP: vmIP,
            success: success,
            error: error,
            connectionTimeMs: connectionTimeMs
        )
        appendEvent(event, to: "connections")
    }

    /// Log VPN tunnel status
    public func recordVPNStatus(
        vmId: UUID,
        interface: String,
        status: String,
        providerEndpoint: String? = nil,
        error: String? = nil
    ) async {
        let event = VPNStatusEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            interface: interface,
            status: status,
            providerEndpoint: providerEndpoint,
            error: error
        )
        appendEvent(event, to: "vpn")
    }

    // MARK: - Usage Events

    /// Log VM usage session
    public func recordUsageSession(
        vmId: UUID,
        providerPeerId: String,
        startTime: Date,
        endTime: Date,
        durationMinutes: Int
    ) async {
        let event = UsageSessionEvent(
            timestamp: Date(),
            vmId: vmId.uuidString,
            providerPeerId: providerPeerId,
            startTime: startTime,
            endTime: endTime,
            durationMinutes: durationMinutes
        )
        appendEvent(event, to: "usage")
    }

    // MARK: - Provider Events

    /// Log provider discovered
    public func recordProviderDiscovered(
        providerPeerId: String,
        endpoint: String,
        discoveryMethod: String
    ) async {
        let event = ProviderDiscoveredEvent(
            timestamp: Date(),
            providerPeerId: providerPeerId,
            endpoint: endpoint,
            discoveryMethod: discoveryMethod
        )
        appendEvent(event, to: "providers")
    }

    /// Log provider connection status change
    public func recordProviderStatus(
        providerPeerId: String,
        status: String,
        latencyMs: Int? = nil,
        error: String? = nil
    ) async {
        let event = ProviderStatusEvent(
            timestamp: Date(),
            providerPeerId: providerPeerId,
            status: status,
            latencyMs: latencyMs,
            error: error
        )
        appendEvent(event, to: "providers")
    }

    // MARK: - Error Events

    /// Log consumer error
    public func recordError(
        component: String,
        operation: String,
        errorType: String,
        errorMessage: String,
        vmId: UUID? = nil,
        providerPeerId: String? = nil
    ) async {
        let event = ConsumerErrorEvent(
            timestamp: Date(),
            component: component,
            operation: operation,
            errorType: errorType,
            errorMessage: errorMessage,
            vmId: vmId?.uuidString,
            providerPeerId: providerPeerId
        )
        appendEvent(event, to: "errors")
    }
}

// MARK: - Event Types

private struct VMRequestSentEvent: Codable {
    let timestamp: Date
    let vmId: String
    let providerPeerId: String
    let cpuCores: Int
    let memoryMB: Int
    let diskGB: Int
    let timeoutMinutes: Int
}

private struct VMResponseEvent: Codable {
    let timestamp: Date
    let vmId: String
    let providerPeerId: String
    let success: Bool
    let error: String?
    let vmIP: String?
    let responseTimeMs: Int
}

private struct VMReleaseEvent: Codable {
    let timestamp: Date
    let vmId: String
    let providerPeerId: String
    let reason: String
}

private struct SSHConnectionEvent: Codable {
    let timestamp: Date
    let vmId: String
    let vmIP: String
    let success: Bool
    let error: String?
    let connectionTimeMs: Int?
}

private struct VPNStatusEvent: Codable {
    let timestamp: Date
    let vmId: String
    let interface: String
    let status: String
    let providerEndpoint: String?
    let error: String?
}

private struct UsageSessionEvent: Codable {
    let timestamp: Date
    let vmId: String
    let providerPeerId: String
    let startTime: Date
    let endTime: Date
    let durationMinutes: Int
}

private struct ProviderDiscoveredEvent: Codable {
    let timestamp: Date
    let providerPeerId: String
    let endpoint: String
    let discoveryMethod: String
}

private struct ProviderStatusEvent: Codable {
    let timestamp: Date
    let providerPeerId: String
    let status: String
    let latencyMs: Int?
    let error: String?
}

private struct ConsumerErrorEvent: Codable {
    let timestamp: Date
    let component: String
    let operation: String
    let errorType: String
    let errorMessage: String
    let vmId: String?
    let providerPeerId: String?
}
