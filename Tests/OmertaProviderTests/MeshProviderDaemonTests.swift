import XCTest
@testable import OmertaProvider
@testable import OmertaCore
@testable import OmertaMesh

final class MeshProviderDaemonTests: XCTestCase {

    /// Helper to create a test mesh config with encryption key
    private func makeTestMeshConfig(port: Int = 0) -> MeshConfig {
        let testKey = Data(repeating: 0x42, count: 32)
        return MeshConfig(
            encryptionKey: testKey,
            port: port
        )
    }

    // MARK: - Configuration Tests

    func testConfigurationDefaultValues() {
        let identity = IdentityKeypair()
        let meshConfig = makeTestMeshConfig()

        let config = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig
        )

        XCTAssertEqual(config.identity.peerId, identity.peerId)
        XCTAssertFalse(config.dryRun)
    }

    func testConfigurationWithAllOptions() {
        let identity = IdentityKeypair()
        let meshConfig = makeTestMeshConfig(port: 9000)

        let config = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
            dryRun: true
        )

        XCTAssertEqual(config.identity.peerId, identity.peerId)
        XCTAssertEqual(config.meshConfig.port, 9000)
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
            port: 9000,
            canRelay: true
        )

        let daemonConfig = try MeshProviderDaemon.Configuration.from(config: config)

        // Peer ID is now derived from identity, so just verify it's a valid hex string
        XCTAssertEqual(daemonConfig.identity.peerId.count, 16)
        XCTAssertTrue(daemonConfig.identity.peerId.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(daemonConfig.meshConfig.port, 9000)
    }

    func testConfigurationPeerIdIsDerivedFromIdentity() throws {
        var config = OmertaConfig()
        config.localKey = OmertaConfig.generateLocalKey()
        config.mesh = MeshConfigOptions(enabled: true)

        let daemonConfig = try MeshProviderDaemon.Configuration.from(config: config)

        // Peer ID should be 16 hex chars derived from public key
        XCTAssertEqual(daemonConfig.identity.peerId.count, 16)
        XCTAssertTrue(daemonConfig.identity.peerId.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Initialization Tests

    func testDaemonInitialization() async {
        let identity = IdentityKeypair()
        let meshConfig = makeTestMeshConfig()

        let config = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
            dryRun: true
        )

        let daemon = MeshProviderDaemon(config: config)

        let status = await daemon.getStatus()
        XCTAssertEqual(status.peerId, identity.peerId)
        XCTAssertFalse(status.isRunning)
    }

    func testDaemonInitializationFromOmertaConfig() async throws {
        var config = OmertaConfig()
        config.localKey = OmertaConfig.generateLocalKey()
        config.mesh = MeshConfigOptions(
            enabled: true
        )

        let daemon = try MeshProviderDaemon(config: config)

        let status = await daemon.getStatus()
        // Peer ID is derived from identity, verify format
        XCTAssertEqual(status.peerId.count, 16)
        XCTAssertTrue(status.peerId.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Lifecycle Tests

    func testDaemonStartStop() async throws {
        let identity = IdentityKeypair()
        let meshConfig = makeTestMeshConfig()

        let config = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
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
        let identity = IdentityKeypair()
        let meshConfig = makeTestMeshConfig()

        let config = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
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
        let identity = IdentityKeypair()
        let meshConfig = makeTestMeshConfig()

        let config = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
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
        let identity = IdentityKeypair()
        let meshConfig = makeTestMeshConfig()

        let config = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
            dryRun: true
        )

        let daemon = MeshProviderDaemon(config: config)
        try await daemon.start()

        let status = await daemon.getStatus()

        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.peerId, identity.peerId)
        XCTAssertEqual(status.activeVMs, 0)
        XCTAssertEqual(status.totalVMRequests, 0)
        XCTAssertEqual(status.totalVMsCreated, 0)
        XCTAssertEqual(status.totalVMsReleased, 0)
        XCTAssertNotNil(status.uptime)
        XCTAssertGreaterThanOrEqual(status.uptime ?? -1, 0)

        await daemon.stop()
    }

    func testListActiveVMsEmpty() async throws {
        let identity = IdentityKeypair()
        let meshConfig = makeTestMeshConfig()

        let config = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
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
            MeshProviderError.noNetworkKey.description,
            "No network key configured (required for encryption)"
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
            peerId: "abcdef0123456789",
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
            peerId: "abcdef0123456789",
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
            consumerMachineId: "consumer-123",
            vmIP: "10.99.0.2",
            createdAt: fiveMinutesAgo,
            uptimeSeconds: 300
        )

        XCTAssertEqual(vmInfo.uptimeSeconds, 300)
        XCTAssertEqual(vmInfo.vmIP, "10.99.0.2")
    }
}
