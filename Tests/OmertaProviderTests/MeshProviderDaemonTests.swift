import XCTest
@testable import OmertaProvider
@testable import OmertaCore
@testable import OmertaMesh

final class MeshProviderDaemonTests: XCTestCase {

    // MARK: - Configuration Tests

    func testConfigurationDefaultValues() {
        let config = MeshProviderDaemon.Configuration(
            peerId: "test-provider"
        )

        XCTAssertEqual(config.peerId, "test-provider")
        XCTAssertNil(config.networkKey)
        XCTAssertTrue(config.enableActivityLogging)
        XCTAssertFalse(config.dryRun)
    }

    func testConfigurationWithAllOptions() {
        let networkKey = Data(repeating: 0x42, count: 32)
        let meshConfig = MeshConfig.server

        let config = MeshProviderDaemon.Configuration(
            peerId: "custom-provider",
            meshConfig: meshConfig,
            networkKey: networkKey,
            enableActivityLogging: false,
            dryRun: true
        )

        XCTAssertEqual(config.peerId, "custom-provider")
        XCTAssertEqual(config.networkKey, networkKey)
        XCTAssertFalse(config.enableActivityLogging)
        XCTAssertTrue(config.dryRun)
    }

    func testConfigurationFromOmertaConfigRequiresMesh() throws {
        var config = OmertaConfig()
        config.localKey = OmertaConfig.generateLocalKey()
        // mesh is nil

        XCTAssertThrowsError(try MeshProviderDaemon.Configuration.from(config: config)) { error in
            guard let meshError = error as? MeshProviderError else {
                XCTFail("Expected MeshProviderError")
                return
            }
            XCTAssertEqual(meshError.description, "Mesh networking is not enabled in config")
        }
    }

    func testConfigurationFromOmertaConfigSuccess() throws {
        var config = OmertaConfig()
        config.localKey = OmertaConfig.generateLocalKey()
        config.mesh = MeshConfigOptions(
            enabled: true,
            peerId: "my-provider",
            port: 9000,
            canRelay: true
        )

        let daemonConfig = try MeshProviderDaemon.Configuration.from(config: config)

        XCTAssertEqual(daemonConfig.peerId, "my-provider")
        XCTAssertEqual(daemonConfig.meshConfig.port, 9000)
        XCTAssertNotNil(daemonConfig.networkKey)
    }

    func testConfigurationGeneratesPeerIdIfNotSet() throws {
        var config = OmertaConfig()
        config.localKey = OmertaConfig.generateLocalKey()
        config.mesh = MeshConfigOptions(enabled: true)
        // peerId is nil

        let daemonConfig = try MeshProviderDaemon.Configuration.from(config: config)

        XCTAssertTrue(daemonConfig.peerId.hasPrefix("provider-"))
    }

    // MARK: - Initialization Tests

    func testDaemonInitialization() {
        let config = MeshProviderDaemon.Configuration(
            peerId: "init-test",
            dryRun: true
        )

        let daemon = MeshProviderDaemon(config: config)

        // Verify daemon was created (check mesh peer ID)
        Task {
            let status = await daemon.getStatus()
            XCTAssertEqual(status.peerId, "init-test")
            XCTAssertFalse(status.isRunning)
        }
    }

    func testDaemonInitializationFromOmertaConfig() async throws {
        var config = OmertaConfig()
        config.localKey = OmertaConfig.generateLocalKey()
        config.mesh = MeshConfigOptions(
            enabled: true,
            peerId: "omerta-config-test"
        )

        let daemon = try MeshProviderDaemon(config: config)

        let status = await daemon.getStatus()
        XCTAssertEqual(status.peerId, "omerta-config-test")
    }

    // MARK: - Lifecycle Tests

    func testDaemonStartStop() async throws {
        let config = MeshProviderDaemon.Configuration(
            peerId: "lifecycle-test",
            dryRun: true
        )

        let daemon = MeshProviderDaemon(config: config)

        // Initially not running
        var status = await daemon.getStatus()
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.startedAt)

        // Start
        try await daemon.start()

        status = await daemon.getStatus()
        XCTAssertTrue(status.isRunning)
        XCTAssertNotNil(status.startedAt)

        // Stop
        await daemon.stop()

        status = await daemon.getStatus()
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.startedAt)
    }

    func testDaemonDoubleStartIsNoOp() async throws {
        let config = MeshProviderDaemon.Configuration(
            peerId: "double-start-test",
            dryRun: true
        )

        let daemon = MeshProviderDaemon(config: config)

        try await daemon.start()
        try await daemon.start()  // Should not throw

        let status = await daemon.getStatus()
        XCTAssertTrue(status.isRunning)

        await daemon.stop()
    }

    func testDaemonDoubleStopIsNoOp() async throws {
        let config = MeshProviderDaemon.Configuration(
            peerId: "double-stop-test",
            dryRun: true
        )

        let daemon = MeshProviderDaemon(config: config)

        try await daemon.start()
        await daemon.stop()
        await daemon.stop()  // Should not throw or warn excessively

        let status = await daemon.getStatus()
        XCTAssertFalse(status.isRunning)
    }

    // MARK: - Status Tests

    func testDaemonStatusAfterStart() async throws {
        let config = MeshProviderDaemon.Configuration(
            peerId: "status-test",
            dryRun: true
        )

        let daemon = MeshProviderDaemon(config: config)
        try await daemon.start()

        let status = await daemon.getStatus()

        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.peerId, "status-test")
        XCTAssertEqual(status.activeVMs, 0)
        XCTAssertEqual(status.totalVMRequests, 0)
        XCTAssertEqual(status.totalVMsCreated, 0)
        XCTAssertEqual(status.totalVMsReleased, 0)
        XCTAssertNotNil(status.uptime)
        XCTAssertGreaterThanOrEqual(status.uptime ?? -1, 0)

        await daemon.stop()
    }

    func testListActiveVMsEmpty() async throws {
        let config = MeshProviderDaemon.Configuration(
            peerId: "list-vms-test",
            dryRun: true
        )

        let daemon = MeshProviderDaemon(config: config)
        try await daemon.start()

        let vms = await daemon.listActiveVMs()
        XCTAssertTrue(vms.isEmpty)

        await daemon.stop()
    }

    // MARK: - Error Description Tests

    func testMeshProviderErrorDescriptions() {
        XCTAssertEqual(
            MeshProviderError.meshNotEnabled.description,
            "Mesh networking is not enabled in config"
        )
        XCTAssertEqual(
            MeshProviderError.notStarted.description,
            "Mesh provider daemon not started"
        )
        XCTAssertEqual(
            MeshProviderError.vmCreationFailed("disk full").description,
            "VM creation failed: disk full"
        )
        XCTAssertEqual(
            MeshProviderError.vmNotFound(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!).description,
            "VM not found: 12345678-1234-1234-1234-123456789ABC"
        )
    }

    // MARK: - MeshDaemonStatus Tests

    func testMeshDaemonStatusUptime() {
        let now = Date()
        let fiveMinutesAgo = now.addingTimeInterval(-300)

        let status = MeshDaemonStatus(
            isRunning: true,
            startedAt: fiveMinutesAgo,
            peerId: "test",
            natType: .fullCone,
            publicEndpoint: "1.2.3.4:9000",
            peerCount: 5,
            activeVMs: 2,
            totalVMRequests: 10,
            totalVMsCreated: 8,
            totalVMsReleased: 6
        )

        XCTAssertNotNil(status.uptime)
        XCTAssertGreaterThanOrEqual(status.uptime ?? 0, 299)  // At least 299 seconds
        XCTAssertLessThanOrEqual(status.uptime ?? 1000, 301)  // At most 301 seconds
    }

    func testMeshDaemonStatusUptimeNilWhenNotStarted() {
        let status = MeshDaemonStatus(
            isRunning: false,
            startedAt: nil,
            peerId: "test",
            natType: .unknown,
            publicEndpoint: nil,
            peerCount: 0,
            activeVMs: 0,
            totalVMRequests: 0,
            totalVMsCreated: 0,
            totalVMsReleased: 0
        )

        XCTAssertNil(status.uptime)
    }

    // MARK: - MeshVMInfo Tests

    func testMeshVMInfoUptimeCalculation() {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)

        let vmInfo = MeshVMInfo(
            vmId: UUID(),
            consumerPeerId: "consumer-123",
            vmIP: "10.99.0.2",
            createdAt: fiveMinutesAgo,
            uptimeSeconds: 300
        )

        XCTAssertEqual(vmInfo.uptimeSeconds, 300)
        XCTAssertEqual(vmInfo.vmIP, "10.99.0.2")
    }
}
