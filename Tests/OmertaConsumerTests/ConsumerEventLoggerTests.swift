// ConsumerEventLoggerTests.swift - Tests for ConsumerEventLogger

import XCTest
@testable import OmertaConsumer

final class ConsumerEventLoggerTests: XCTestCase {

    var tempDir: String!
    var logger: ConsumerEventLogger!

    override func setUp() async throws {
        tempDir = NSTemporaryDirectory() + "ConsumerEventLoggerTests-\(UUID().uuidString)"
        logger = try ConsumerEventLogger(logDir: tempDir)
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
            providerPeerId: "provider-123",
            cpuCores: 2,
            memoryMB: 4096,
            diskGB: 50,
            timeoutMinutes: 10
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_requests.jsonl")
        XCTAssertTrue(content.contains(vmId.uuidString))
        XCTAssertTrue(content.contains("provider-123"))
        XCTAssertTrue(content.contains("\"cpuCores\":2"))
        XCTAssertTrue(content.contains("\"timeoutMinutes\":10"))
    }

    func testRecordVMResponseSuccess() async throws {
        let vmId = UUID()

        await logger.recordVMResponse(
            vmId: vmId,
            providerPeerId: "provider-456",
            success: true,
            error: nil,
            vmIP: "10.0.0.5",
            responseTimeMs: 2500
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_requests.jsonl")
        XCTAssertTrue(content.contains("\"success\":true"))
        XCTAssertTrue(content.contains("10.0.0.5"))
        XCTAssertTrue(content.contains("2500"))
    }

    func testRecordVMResponseFailure() async throws {
        let vmId = UUID()

        await logger.recordVMResponse(
            vmId: vmId,
            providerPeerId: "provider-789",
            success: false,
            error: "Provider busy",
            vmIP: nil,
            responseTimeMs: 100
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_requests.jsonl")
        XCTAssertTrue(content.contains("\"success\":false"))
        XCTAssertTrue(content.contains("Provider busy"))
    }

    func testRecordVMRelease() async throws {
        let vmId = UUID()

        await logger.recordVMRelease(
            vmId: vmId,
            providerPeerId: "provider-abc",
            reason: "user_terminated"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vm_lifecycle.jsonl")
        XCTAssertTrue(content.contains(vmId.uuidString))
        XCTAssertTrue(content.contains("user_terminated"))
    }

    // MARK: - Connection Tests

    func testRecordSSHConnectionSuccess() async throws {
        let vmId = UUID()

        await logger.recordSSHConnection(
            vmId: vmId,
            vmIP: "10.0.0.10",
            success: true,
            error: nil,
            connectionTimeMs: 1200
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/connections.jsonl")
        XCTAssertTrue(content.contains("10.0.0.10"))
        XCTAssertTrue(content.contains("\"success\":true"))
        XCTAssertTrue(content.contains("1200"))
    }

    func testRecordSSHConnectionFailure() async throws {
        let vmId = UUID()

        await logger.recordSSHConnection(
            vmId: vmId,
            vmIP: "10.0.0.20",
            success: false,
            error: "Connection refused",
            connectionTimeMs: nil
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/connections.jsonl")
        XCTAssertTrue(content.contains("\"success\":false"))
        XCTAssertTrue(content.contains("Connection refused"))
    }

    func testRecordVPNStatus() async throws {
        let vmId = UUID()

        await logger.recordVPNStatus(
            vmId: vmId,
            interface: "wg-consumer0",
            status: "connected",
            providerEndpoint: "1.2.3.4:51820",
            error: nil
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vpn.jsonl")
        XCTAssertTrue(content.contains("wg-consumer0"))
        XCTAssertTrue(content.contains("connected"))
        XCTAssertTrue(content.contains("1.2.3.4:51820"))
    }

    func testRecordVPNStatusError() async throws {
        let vmId = UUID()

        await logger.recordVPNStatus(
            vmId: vmId,
            interface: "wg-consumer0",
            status: "failed",
            providerEndpoint: nil,
            error: "Handshake timeout"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/vpn.jsonl")
        XCTAssertTrue(content.contains("failed"))
        XCTAssertTrue(content.contains("Handshake timeout"))
    }

    // MARK: - Usage Tests

    func testRecordUsageSession() async throws {
        let vmId = UUID()
        let startTime = Date().addingTimeInterval(-3600) // 1 hour ago
        let endTime = Date()

        await logger.recordUsageSession(
            vmId: vmId,
            providerPeerId: "provider-xyz",
            startTime: startTime,
            endTime: endTime,
            durationMinutes: 60
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/usage.jsonl")
        XCTAssertTrue(content.contains(vmId.uuidString))
        XCTAssertTrue(content.contains("provider-xyz"))
        XCTAssertTrue(content.contains("\"durationMinutes\":60"))
    }

    // MARK: - Provider Tests

    func testRecordProviderDiscovered() async throws {
        await logger.recordProviderDiscovered(
            providerPeerId: "new-provider",
            endpoint: "5.6.7.8:9999",
            discoveryMethod: "gossip"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/providers.jsonl")
        XCTAssertTrue(content.contains("new-provider"))
        XCTAssertTrue(content.contains("5.6.7.8:9999"))
        XCTAssertTrue(content.contains("gossip"))
    }

    func testRecordProviderStatusOnline() async throws {
        await logger.recordProviderStatus(
            providerPeerId: "active-provider",
            status: "online",
            latencyMs: 50,
            error: nil
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/providers.jsonl")
        XCTAssertTrue(content.contains("online"))
        XCTAssertTrue(content.contains("\"latencyMs\":50"))
    }

    func testRecordProviderStatusOffline() async throws {
        await logger.recordProviderStatus(
            providerPeerId: "dead-provider",
            status: "offline",
            latencyMs: nil,
            error: "No response to ping"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/providers.jsonl")
        XCTAssertTrue(content.contains("offline"))
        XCTAssertTrue(content.contains("No response to ping"))
    }

    // MARK: - Error Tests

    func testRecordError() async throws {
        let vmId = UUID()

        await logger.recordError(
            component: "VPNClient",
            operation: "createTunnel",
            errorType: "permission_denied",
            errorMessage: "Cannot create WireGuard interface",
            vmId: vmId,
            providerPeerId: "provider-error"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/errors.jsonl")
        XCTAssertTrue(content.contains("VPNClient"))
        XCTAssertTrue(content.contains("createTunnel"))
        XCTAssertTrue(content.contains("permission_denied"))
        XCTAssertTrue(content.contains("Cannot create WireGuard interface"))
    }

    func testRecordErrorMinimal() async throws {
        await logger.recordError(
            component: "General",
            operation: "startup",
            errorType: "configuration",
            errorMessage: "Missing config file"
        )

        await logger.stop()

        let content = try String(contentsOfFile: "\(tempDir!)/errors.jsonl")
        XCTAssertTrue(content.contains("Missing config file"))
    }

    // MARK: - Multiple Events Tests

    func testMultipleEventsInSequence() async throws {
        let vmId = UUID()

        // Simulate a full VM lifecycle
        await logger.recordProviderDiscovered(
            providerPeerId: "p1",
            endpoint: "1.1.1.1:1111",
            discoveryMethod: "bootstrap"
        )

        await logger.recordVMRequest(
            vmId: vmId,
            providerPeerId: "p1",
            cpuCores: 2,
            memoryMB: 2048,
            diskGB: 20,
            timeoutMinutes: 10
        )

        await logger.recordVMResponse(
            vmId: vmId,
            providerPeerId: "p1",
            success: true,
            vmIP: "10.0.0.1",
            responseTimeMs: 3000
        )

        await logger.recordVPNStatus(
            vmId: vmId,
            interface: "wg0",
            status: "connected",
            providerEndpoint: "1.1.1.1:51820"
        )

        await logger.recordSSHConnection(
            vmId: vmId,
            vmIP: "10.0.0.1",
            success: true,
            connectionTimeMs: 500
        )

        await logger.stop()

        // Verify all files were created
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/providers.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/vm_requests.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/vpn.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir!)/connections.jsonl"))
    }
}
