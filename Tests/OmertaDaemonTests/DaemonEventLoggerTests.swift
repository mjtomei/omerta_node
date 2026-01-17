// DaemonEventLoggerTests.swift - Tests for DaemonEventLogger

import XCTest
@testable import OmertaDaemon

final class DaemonEventLoggerTests: XCTestCase {

    var tempDir: String!
    var logger: DaemonEventLogger!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "DaemonEventLoggerTests-\(UUID().uuidString)"
        logger = try DaemonEventLogger(logDir: tempDir)
    }

    override func tearDown() async throws {
        await logger?.stop()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - Initialization Tests

    func testInitializationCreatesDirectory() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir))
    }

    // MARK: - Lifecycle Tests

    func testRecordStartup() async throws {
        await logger.recordStartup(
            version: "1.0.0",
            configPath: "/etc/omerta/config.yaml",
            port: 9999,
            meshEnabled: true,
            relayEnabled: true
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/lifecycle.jsonl")
        XCTAssertTrue(content.contains("startup"))
        XCTAssertTrue(content.contains("1.0.0"))
        XCTAssertTrue(content.contains("config.yaml")) // Check partial path (slashes may be escaped)
        XCTAssertTrue(content.contains("\"port\":9999"))
        XCTAssertTrue(content.contains("\"meshEnabled\":true"))
    }

    func testRecordShutdown() async throws {
        await logger.recordShutdown(
            reason: "user_requested",
            graceful: true,
            uptimeSeconds: 86400
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/lifecycle.jsonl")
        XCTAssertTrue(content.contains("shutdown"))
        XCTAssertTrue(content.contains("user_requested"))
        XCTAssertTrue(content.contains("\"graceful\":true"))
        XCTAssertTrue(content.contains("86400"))
    }

    func testRecordShutdownUngraceful() async throws {
        await logger.recordShutdown(
            reason: "crash",
            graceful: false,
            uptimeSeconds: 1234
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/lifecycle.jsonl")
        XCTAssertTrue(content.contains("\"graceful\":false"))
        XCTAssertTrue(content.contains("crash"))
    }

    func testRecordRestart() async throws {
        await logger.recordRestart(
            reason: "config_reload",
            previousUptimeSeconds: 7200
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/lifecycle.jsonl")
        XCTAssertTrue(content.contains("restart"))
        XCTAssertTrue(content.contains("config_reload"))
        XCTAssertTrue(content.contains("7200"))
    }

    // MARK: - Configuration Tests

    func testRecordConfigLoaded() async throws {
        await logger.recordConfigLoaded(
            configPath: "/etc/omerta/daemon.conf",
            success: true,
            error: nil
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/config.jsonl")
        XCTAssertTrue(content.contains("config_loaded"))
        XCTAssertTrue(content.contains("daemon.conf")) // Check partial path (slashes may be escaped)
        XCTAssertTrue(content.contains("\"success\":true"))
    }

    func testRecordConfigLoadedFailure() async throws {
        await logger.recordConfigLoaded(
            configPath: "/nonexistent/config.yaml",
            success: false,
            error: "File not found"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/config.jsonl")
        XCTAssertTrue(content.contains("\"success\":false"))
        XCTAssertTrue(content.contains("File not found"))
    }

    func testRecordConfigChange() async throws {
        await logger.recordConfigChange(
            configPath: "/etc/omerta/daemon.conf",
            changes: [
                "port": "9999 -> 8888",
                "meshEnabled": "false -> true"
            ]
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/config.jsonl")
        XCTAssertTrue(content.contains("config_changed"))
        XCTAssertTrue(content.contains("9999 -> 8888"))
    }

    // MARK: - Control Tests

    func testRecordControlCommand() async throws {
        await logger.recordControlCommand(
            command: "vm_request",
            source: "cli",
            success: true,
            error: nil,
            responseTimeMs: 150
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/control.jsonl")
        XCTAssertTrue(content.contains("vm_request"))
        XCTAssertTrue(content.contains("cli"))
        XCTAssertTrue(content.contains("\"success\":true"))
        XCTAssertTrue(content.contains("150"))
    }

    func testRecordControlCommandFailure() async throws {
        await logger.recordControlCommand(
            command: "vm_release",
            source: "api",
            success: false,
            error: "VM not found",
            responseTimeMs: 10
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/control.jsonl")
        XCTAssertTrue(content.contains("\"success\":false"))
        XCTAssertTrue(content.contains("VM not found"))
    }

    func testRecordControlConnection() async throws {
        await logger.recordControlConnection(
            clientAddress: "127.0.0.1:54321",
            eventType: "connected"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/control.jsonl")
        XCTAssertTrue(content.contains("127.0.0.1:54321"))
        XCTAssertTrue(content.contains("connected"))
    }

    // MARK: - Mesh Tests

    func testRecordMeshStatus() async throws {
        await logger.recordMeshStatus(
            status: "healthy",
            connectedPeers: 12,
            bootstrapNodes: 3,
            natType: "full_cone"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/mesh.jsonl")
        XCTAssertTrue(content.contains("healthy"))
        XCTAssertTrue(content.contains("\"connectedPeers\":12"))
        XCTAssertTrue(content.contains("\"bootstrapNodes\":3"))
        XCTAssertTrue(content.contains("full_cone"))
    }

    func testRecordBootstrapConnection() async throws {
        await logger.recordBootstrapConnection(
            bootstrapAddress: "bootstrap.omerta.io:9999",
            success: true,
            error: nil,
            peersDiscovered: 5
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/mesh.jsonl")
        XCTAssertTrue(content.contains("bootstrap.omerta.io:9999"))
        XCTAssertTrue(content.contains("\"success\":true"))
        XCTAssertTrue(content.contains("\"peersDiscovered\":5"))
    }

    func testRecordBootstrapConnectionFailure() async throws {
        await logger.recordBootstrapConnection(
            bootstrapAddress: "dead.bootstrap.io:9999",
            success: false,
            error: "Connection timed out",
            peersDiscovered: nil
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/mesh.jsonl")
        XCTAssertTrue(content.contains("\"success\":false"))
        XCTAssertTrue(content.contains("Connection timed out"))
    }

    // MARK: - Resource Tests

    func testRecordResourceSnapshot() async throws {
        await logger.recordResourceSnapshot(
            cpuUsagePercent: 45.5,
            memoryUsedMB: 8192,
            memoryTotalMB: 16384,
            diskUsedGB: 200,
            diskTotalGB: 500,
            activeVMs: 3,
            networkBytesIn: 1_000_000_000,
            networkBytesOut: 500_000_000
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/resources.jsonl")
        XCTAssertTrue(content.contains("45.5"))
        XCTAssertTrue(content.contains("\"memoryUsedMB\":8192"))
        XCTAssertTrue(content.contains("\"activeVMs\":3"))
        XCTAssertTrue(content.contains("1000000000"))
    }

    // MARK: - Error Tests

    func testRecordError() async throws {
        await logger.recordError(
            component: "MeshNetwork",
            operation: "connect",
            errorType: "network_error",
            errorMessage: "Socket bind failed: address in use",
            fatal: false
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/errors.jsonl")
        XCTAssertTrue(content.contains("MeshNetwork"))
        XCTAssertTrue(content.contains("connect"))
        XCTAssertTrue(content.contains("network_error"))
        XCTAssertTrue(content.contains("Socket bind failed"))
        XCTAssertTrue(content.contains("\"fatal\":false"))
    }

    func testRecordFatalError() async throws {
        await logger.recordError(
            component: "Startup",
            operation: "initialize",
            errorType: "configuration",
            errorMessage: "Missing required network key",
            fatal: true
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/errors.jsonl")
        XCTAssertTrue(content.contains("\"fatal\":true"))
        XCTAssertTrue(content.contains("Missing required network key"))
    }

    // MARK: - Full Lifecycle Test

    func testFullDaemonLifecycle() async throws {
        // Startup
        await logger.recordStartup(
            version: "1.2.3",
            configPath: "/etc/omerta/config.yaml",
            port: 9999,
            meshEnabled: true,
            relayEnabled: false
        )

        // Config loaded
        await logger.recordConfigLoaded(
            configPath: "/etc/omerta/config.yaml",
            success: true
        )

        // Mesh status
        await logger.recordMeshStatus(
            status: "initializing",
            connectedPeers: 0,
            bootstrapNodes: 2,
            natType: nil
        )

        // Bootstrap
        await logger.recordBootstrapConnection(
            bootstrapAddress: "bootstrap1.omerta.io:9999",
            success: true,
            peersDiscovered: 10
        )

        // Mesh healthy
        await logger.recordMeshStatus(
            status: "healthy",
            connectedPeers: 8,
            bootstrapNodes: 2,
            natType: "restricted_cone"
        )

        // Resource snapshot
        await logger.recordResourceSnapshot(
            cpuUsagePercent: 5.0,
            memoryUsedMB: 512,
            memoryTotalMB: 16384,
            diskUsedGB: 10,
            diskTotalGB: 500,
            activeVMs: 0,
            networkBytesIn: 0,
            networkBytesOut: 0
        )

        // Control command
        await logger.recordControlCommand(
            command: "status",
            source: "cli",
            success: true,
            responseTimeMs: 5
        )

        // Shutdown
        await logger.recordShutdown(
            reason: "SIGTERM",
            graceful: true,
            uptimeSeconds: 3600
        )

        await logger.stop()

        // Verify all log files exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/lifecycle.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/config.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/mesh.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/control.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/resources.jsonl"))

        // Verify lifecycle has startup and shutdown
        let lifecycleContent = try String(contentsOfFile: "\(tempDir!)/lifecycle.jsonl")
        let lifecycleLines = lifecycleContent.split(separator: "\n")
        XCTAssertEqual(lifecycleLines.count, 2) // startup + shutdown
    }
}
