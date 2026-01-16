// DaemonEventLogger.swift - JSON Lines-based event logging for OmertaDaemon

import Foundation
import Logging

/// Actor responsible for logging daemon events to JSON Lines files
public actor DaemonEventLogger {
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
        var log = Logger(label: "io.omerta.daemon.eventlogger")
        log.logLevel = .info
        self.logger = log

        let dir = logDir ?? DaemonEventLogger.defaultLogDir()
        self.logDir = dir

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        logger.info("Daemon event logger initialized", metadata: ["path": "\(dir)"])
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
        return "\(home)/.config/OmertaDaemon/logs"
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

    // MARK: - Lifecycle Events

    /// Log daemon startup
    public func recordStartup(
        version: String,
        configPath: String?,
        port: Int,
        meshEnabled: Bool,
        relayEnabled: Bool
    ) async {
        let event = StartupEvent(
            timestamp: Date(),
            eventType: "startup",
            version: version,
            configPath: configPath,
            port: port,
            meshEnabled: meshEnabled,
            relayEnabled: relayEnabled
        )
        appendEvent(event, to: "lifecycle")
    }

    /// Log daemon shutdown
    public func recordShutdown(
        reason: String,
        graceful: Bool,
        uptimeSeconds: Int
    ) async {
        let event = ShutdownEvent(
            timestamp: Date(),
            eventType: "shutdown",
            reason: reason,
            graceful: graceful,
            uptimeSeconds: uptimeSeconds
        )
        appendEvent(event, to: "lifecycle")
    }

    /// Log daemon restart
    public func recordRestart(
        reason: String,
        previousUptimeSeconds: Int
    ) async {
        let event = RestartEvent(
            timestamp: Date(),
            eventType: "restart",
            reason: reason,
            previousUptimeSeconds: previousUptimeSeconds
        )
        appendEvent(event, to: "lifecycle")
    }

    // MARK: - Configuration Events

    /// Log configuration loaded
    public func recordConfigLoaded(
        configPath: String,
        success: Bool,
        error: String? = nil
    ) async {
        let event = ConfigEvent(
            timestamp: Date(),
            eventType: "config_loaded",
            configPath: configPath,
            success: success,
            error: error,
            changes: nil
        )
        appendEvent(event, to: "config")
    }

    /// Log configuration change
    public func recordConfigChange(
        configPath: String,
        changes: [String: String]
    ) async {
        let event = ConfigEvent(
            timestamp: Date(),
            eventType: "config_changed",
            configPath: configPath,
            success: true,
            error: nil,
            changes: changes
        )
        appendEvent(event, to: "config")
    }

    // MARK: - Control Events

    /// Log control command received
    public func recordControlCommand(
        command: String,
        source: String,
        success: Bool,
        error: String? = nil,
        responseTimeMs: Int? = nil
    ) async {
        let event = ControlCommandEvent(
            timestamp: Date(),
            command: command,
            source: source,
            success: success,
            error: error,
            responseTimeMs: responseTimeMs
        )
        appendEvent(event, to: "control")
    }

    /// Log control socket connection
    public func recordControlConnection(
        clientAddress: String,
        eventType: String
    ) async {
        let event = ControlConnectionEvent(
            timestamp: Date(),
            clientAddress: clientAddress,
            eventType: eventType
        )
        appendEvent(event, to: "control")
    }

    // MARK: - Mesh Events

    /// Log mesh network status change
    public func recordMeshStatus(
        status: String,
        connectedPeers: Int,
        bootstrapNodes: Int,
        natType: String?
    ) async {
        let event = MeshStatusEvent(
            timestamp: Date(),
            status: status,
            connectedPeers: connectedPeers,
            bootstrapNodes: bootstrapNodes,
            natType: natType
        )
        appendEvent(event, to: "mesh")
    }

    /// Log bootstrap connection
    public func recordBootstrapConnection(
        bootstrapAddress: String,
        success: Bool,
        error: String? = nil,
        peersDiscovered: Int? = nil
    ) async {
        let event = BootstrapConnectionEvent(
            timestamp: Date(),
            bootstrapAddress: bootstrapAddress,
            success: success,
            error: error,
            peersDiscovered: peersDiscovered
        )
        appendEvent(event, to: "mesh")
    }

    // MARK: - Resource Events

    /// Log system resource snapshot
    public func recordResourceSnapshot(
        cpuUsagePercent: Double,
        memoryUsedMB: Int,
        memoryTotalMB: Int,
        diskUsedGB: Int,
        diskTotalGB: Int,
        activeVMs: Int,
        networkBytesIn: Int64,
        networkBytesOut: Int64
    ) async {
        let event = SystemResourceEvent(
            timestamp: Date(),
            cpuUsagePercent: cpuUsagePercent,
            memoryUsedMB: memoryUsedMB,
            memoryTotalMB: memoryTotalMB,
            diskUsedGB: diskUsedGB,
            diskTotalGB: diskTotalGB,
            activeVMs: activeVMs,
            networkBytesIn: networkBytesIn,
            networkBytesOut: networkBytesOut
        )
        appendEvent(event, to: "resources")
    }

    // MARK: - Error Events

    /// Log daemon error
    public func recordError(
        component: String,
        operation: String,
        errorType: String,
        errorMessage: String,
        fatal: Bool = false
    ) async {
        let event = DaemonErrorEvent(
            timestamp: Date(),
            component: component,
            operation: operation,
            errorType: errorType,
            errorMessage: errorMessage,
            fatal: fatal
        )
        appendEvent(event, to: "errors")
    }
}

// MARK: - Event Types

private struct StartupEvent: Codable {
    let timestamp: Date
    let eventType: String
    let version: String
    let configPath: String?
    let port: Int
    let meshEnabled: Bool
    let relayEnabled: Bool
}

private struct ShutdownEvent: Codable {
    let timestamp: Date
    let eventType: String
    let reason: String
    let graceful: Bool
    let uptimeSeconds: Int
}

private struct RestartEvent: Codable {
    let timestamp: Date
    let eventType: String
    let reason: String
    let previousUptimeSeconds: Int
}

private struct ConfigEvent: Codable {
    let timestamp: Date
    let eventType: String
    let configPath: String
    let success: Bool
    let error: String?
    let changes: [String: String]?
}

private struct ControlCommandEvent: Codable {
    let timestamp: Date
    let command: String
    let source: String
    let success: Bool
    let error: String?
    let responseTimeMs: Int?
}

private struct ControlConnectionEvent: Codable {
    let timestamp: Date
    let clientAddress: String
    let eventType: String
}

private struct MeshStatusEvent: Codable {
    let timestamp: Date
    let status: String
    let connectedPeers: Int
    let bootstrapNodes: Int
    let natType: String?
}

private struct BootstrapConnectionEvent: Codable {
    let timestamp: Date
    let bootstrapAddress: String
    let success: Bool
    let error: String?
    let peersDiscovered: Int?
}

private struct SystemResourceEvent: Codable {
    let timestamp: Date
    let cpuUsagePercent: Double
    let memoryUsedMB: Int
    let memoryTotalMB: Int
    let diskUsedGB: Int
    let diskTotalGB: Int
    let activeVMs: Int
    let networkBytesIn: Int64
    let networkBytesOut: Int64
}

private struct DaemonErrorEvent: Codable {
    let timestamp: Date
    let component: String
    let operation: String
    let errorType: String
    let errorMessage: String
    let fatal: Bool
}
