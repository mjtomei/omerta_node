// ProviderEventLoggerTests.swift - Tests for ProviderEventLogger

import XCTest
@testable import OmertaProvider

final class ProviderEventLoggerTests: XCTestCase {

    var tempDir: String!
    var logger: ProviderEventLogger!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "ProviderEventLoggerTests-\(UUID().uuidString)"
        logger = try ProviderEventLogger(logDir: tempDir)
    }

    override func tearDown() async throws {
        await logger?.stop()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - Initialization Tests

    func testInitializationCreatesDirectory() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir))
    }

    // MARK: - VM Request Tests

    func testRecordVMRequest() async throws {
        let vmId = UUID()

        await logger.recordVMRequest(
            vmId: vmId,
            consumerMachineId: "consumer-123",
            cpuCores: 2,
            memoryMB: 4096,
            diskGB: 50
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_requests.jsonl")
        XCTAssertTrue(content.contains(vmId.uuidString))
        XCTAssertTrue(content.contains("consumer-123"))
        XCTAssertTrue(content.contains("\"cpuCores\":2"))
        XCTAssertTrue(content.contains("\"memoryMB\":4096"))
        XCTAssertTrue(content.contains("\"diskGB\":50"))
    }

    // MARK: - VM Lifecycle Tests

    func testRecordVMCreatedSuccess() async throws {
        let vmId = UUID()

        await logger.recordVMCreated(
            vmId: vmId,
            consumerMachineId: "consumer-456",
            success: true,
            error: nil,
            durationMs: 5000
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_lifecycle.jsonl")
        XCTAssertTrue(content.contains(vmId.uuidString))
        XCTAssertTrue(content.contains("\"success\":true"))
        XCTAssertTrue(content.contains("\"durationMs\":5000"))
    }

    func testRecordVMCreatedFailure() async throws {
        let vmId = UUID()

        await logger.recordVMCreated(
            vmId: vmId,
            consumerMachineId: "consumer-789",
            success: false,
            error: "Insufficient resources",
            durationMs: 100
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_lifecycle.jsonl")
        XCTAssertTrue(content.contains("\"success\":false"))
        XCTAssertTrue(content.contains("Insufficient resources"))
    }

    func testRecordVMReleased() async throws {
        let vmId = UUID()

        await logger.recordVMReleased(
            vmId: vmId,
            consumerMachineId: "consumer-abc",
            reason: "user_requested",
            durationMs: 3600000
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_lifecycle.jsonl")
        XCTAssertTrue(content.contains("user_requested"))
        XCTAssertTrue(content.contains("3600000"))
    }

    func testRecordVMTimeout() async throws {
        let vmId = UUID()
        let lastHeartbeat = Date().addingTimeInterval(-300) // 5 minutes ago

        await logger.recordVMTimeout(
            vmId: vmId,
            consumerMachineId: "dead-consumer",
            lastHeartbeat: lastHeartbeat
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_lifecycle.jsonl")
        XCTAssertTrue(content.contains("dead-consumer"))
        XCTAssertTrue(content.contains("secondsSinceHeartbeat"))
    }

    // MARK: - Heartbeat Tests

    func testRecordHeartbeat() async throws {
        let vmIds = [UUID(), UUID()]
        let activeIds = [vmIds[0]]

        await logger.recordHeartbeat(
            consumerMachineId: "heartbeat-consumer",
            vmIds: vmIds,
            activeVmIds: activeIds
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/heartbeats.jsonl")
        XCTAssertTrue(content.contains("heartbeat-consumer"))
        XCTAssertTrue(content.contains("requestedVmIds"))
        XCTAssertTrue(content.contains("confirmedVmIds"))
    }

    func testRecordHeartbeatTimeout() async throws {
        let vmIds = [UUID(), UUID(), UUID()]

        await logger.recordHeartbeatTimeout(
            consumerMachineId: "timeout-consumer",
            vmIds: vmIds
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/heartbeats.jsonl")
        XCTAssertTrue(content.contains("timeout-consumer"))
        XCTAssertTrue(content.contains(vmIds[0].uuidString))
    }

    // MARK: - Resource Tests

    func testRecordResourceAllocation() async throws {
        let vmId = UUID()

        await logger.recordResourceAllocation(
            vmId: vmId,
            cpuCores: 4,
            memoryMB: 8192,
            diskGB: 100
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/resources.jsonl")
        XCTAssertTrue(content.contains("allocated"))
        XCTAssertTrue(content.contains("\"cpuCores\":4"))
        XCTAssertTrue(content.contains("\"memoryMB\":8192"))
    }

    func testRecordResourceDeallocation() async throws {
        let vmId = UUID()

        await logger.recordResourceDeallocation(
            vmId: vmId,
            cpuCores: 4,
            memoryMB: 8192,
            diskGB: 100
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/resources.jsonl")
        XCTAssertTrue(content.contains("deallocated"))
    }

    func testRecordResourceSnapshot() async throws {
        await logger.recordResourceSnapshot(
            totalCpuCores: 16,
            usedCpuCores: 8,
            totalMemoryMB: 65536,
            usedMemoryMB: 32000,
            totalDiskGB: 1000,
            usedDiskGB: 400,
            activeVMs: 4
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/resources.jsonl")
        XCTAssertTrue(content.contains("\"totalCpuCores\":16"))
        XCTAssertTrue(content.contains("\"usedCpuCores\":8"))
        XCTAssertTrue(content.contains("\"activeVMs\":4"))
    }

    // MARK: - VPN Tests

    func testRecordVPNCreated() async throws {
        let vmId = UUID()

        await logger.recordVPNCreated(
            vmId: vmId,
            interface: "wg-test0",
            consumerEndpoint: "10.0.0.1:51820"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vpn.jsonl")
        XCTAssertTrue(content.contains("created"))
        XCTAssertTrue(content.contains("wg-test0"))
        XCTAssertTrue(content.contains("10.0.0.1:51820"))
    }

    func testRecordVPNDestroyed() async throws {
        let vmId = UUID()

        await logger.recordVPNDestroyed(
            vmId: vmId,
            interface: "wg-test0",
            reason: "VM terminated"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vpn.jsonl")
        XCTAssertTrue(content.contains("destroyed"))
        XCTAssertTrue(content.contains("VM terminated"))
    }

    func testRecordVPNHealthFailure() async throws {
        let vmId = UUID()

        await logger.recordVPNHealthFailure(
            vmId: vmId,
            interface: "wg-test0",
            error: "No handshake in 120 seconds"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vpn.jsonl")
        XCTAssertTrue(content.contains("health_failure"))
        XCTAssertTrue(content.contains("No handshake"))
    }

    // MARK: - Error Tests

    func testRecordError() async throws {
        let vmId = UUID()

        await logger.recordError(
            component: "VMManager",
            operation: "createVM",
            errorType: "resource_exhaustion",
            errorMessage: "No available CPU cores",
            vmId: vmId,
            consumerMachineId: "consumer-xyz"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/errors.jsonl")
        XCTAssertTrue(content.contains("VMManager"))
        XCTAssertTrue(content.contains("createVM"))
        XCTAssertTrue(content.contains("resource_exhaustion"))
        XCTAssertTrue(content.contains("No available CPU cores"))
        XCTAssertTrue(content.contains("consumer-xyz"))
    }

    func testRecordErrorWithoutOptionalFields() async throws {
        await logger.recordError(
            component: "Network",
            operation: "bind",
            errorType: "socket_error",
            errorMessage: "Address already in use"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/errors.jsonl")
        XCTAssertTrue(content.contains("Network"))
        XCTAssertTrue(content.contains("Address already in use"))
    }

    // MARK: - Multiple Events Tests

    func testMultipleEventsAppend() async throws {
        let vmId1 = UUID()
        let vmId2 = UUID()
        let vmId3 = UUID()

        await logger.recordVMRequest(vmId: vmId1, consumerMachineId: "c1", cpuCores: 1, memoryMB: 1024, diskGB: 10)
        await logger.recordVMRequest(vmId: vmId2, consumerMachineId: "c2", cpuCores: 2, memoryMB: 2048, diskGB: 20)
        await logger.recordVMRequest(vmId: vmId3, consumerMachineId: "c3", cpuCores: 4, memoryMB: 4096, diskGB: 40)

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_requests.jsonl")
        let lines = content.split(separator: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(content.contains(vmId1.uuidString))
        XCTAssertTrue(content.contains(vmId2.uuidString))
        XCTAssertTrue(content.contains(vmId3.uuidString))
    }
}
