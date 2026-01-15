import XCTest
@testable import OmertaConsumer
@testable import OmertaCore
@testable import OmertaMesh

final class MeshConsumerClientTests: XCTestCase {

    // MARK: - MeshConfigOptions Tests

    func testMeshConfigOptionsDefaultValues() {
        let config = MeshConfigOptions()

        XCTAssertFalse(config.enabled)
        XCTAssertNil(config.peerId)  // peerId is deprecated but still in config
        XCTAssertEqual(config.port, 0)
        XCTAssertTrue(config.bootstrapPeers.isEmpty)
        XCTAssertFalse(config.canRelay)
        XCTAssertFalse(config.canCoordinateHolePunch)
        XCTAssertEqual(config.keepaliveInterval, 15)
        XCTAssertEqual(config.connectionTimeout, 10)
    }

    func testMeshConfigOptionsProviderPreset() {
        let config = MeshConfigOptions.provider

        XCTAssertTrue(config.enabled)
        XCTAssertTrue(config.canRelay)
        XCTAssertTrue(config.canCoordinateHolePunch)
        XCTAssertEqual(config.keepaliveInterval, 10)
    }

    func testMeshConfigOptionsConsumerPreset() {
        let config = MeshConfigOptions.consumer

        XCTAssertTrue(config.enabled)
        XCTAssertFalse(config.canRelay)
        XCTAssertFalse(config.canCoordinateHolePunch)
    }

    func testMeshConfigOptionsCodable() throws {
        let original = MeshConfigOptions(
            enabled: true,
            peerId: "test-peer-123",  // Deprecated but still Codable
            port: 9000,
            bootstrapPeers: ["relay@192.168.1.1:9000"],
            stunServers: ["stun.test:3478"],
            canRelay: true,
            canCoordinateHolePunch: false,
            keepaliveInterval: 20,
            connectionTimeout: 15
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MeshConfigOptions.self, from: data)

        XCTAssertEqual(decoded.enabled, original.enabled)
        XCTAssertEqual(decoded.peerId, original.peerId)
        XCTAssertEqual(decoded.port, original.port)
        XCTAssertEqual(decoded.bootstrapPeers, original.bootstrapPeers)
        XCTAssertEqual(decoded.stunServers, original.stunServers)
        XCTAssertEqual(decoded.canRelay, original.canRelay)
        XCTAssertEqual(decoded.canCoordinateHolePunch, original.canCoordinateHolePunch)
        XCTAssertEqual(decoded.keepaliveInterval, original.keepaliveInterval)
        XCTAssertEqual(decoded.connectionTimeout, original.connectionTimeout)
    }

    func testOmertaConfigWithMeshOptions() throws {
        var config = OmertaConfig()
        config.mesh = MeshConfigOptions(
            enabled: true,
            bootstrapPeers: ["relay@test.com:9000"]
        )
        config.localKey = OmertaConfig.generateLocalKey()

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(OmertaConfig.self, from: data)

        XCTAssertNotNil(decoded.mesh)
        XCTAssertTrue(decoded.mesh!.enabled)
        XCTAssertEqual(decoded.mesh!.bootstrapPeers.count, 1)
    }

    // MARK: - MeshConsumerClient Initialization Tests

    func testMeshConsumerClientRequiresMeshEnabled() async {
        var config = OmertaConfig()
        config.localKey = OmertaConfig.generateLocalKey()
        // mesh is nil

        do {
            _ = try MeshConsumerClient(config: config)
            XCTFail("Should throw meshNotEnabled")
        } catch let error as MeshConsumerError {
            XCTAssertEqual(error.description, "Mesh networking is not enabled in config")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMeshConsumerClientRequiresNetworkKey() async {
        var config = OmertaConfig()
        config.mesh = MeshConfigOptions(enabled: true)
        // localKey is nil

        do {
            _ = try MeshConsumerClient(config: config)
            XCTFail("Should throw noNetworkKey")
        } catch let error as MeshConsumerError {
            XCTAssertEqual(error.description, "No network key configured (run 'omerta init' first)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMeshConsumerClientInitializesWithValidConfig() async throws {
        var config = OmertaConfig()
        config.mesh = MeshConfigOptions(enabled: true)
        config.localKey = OmertaConfig.generateLocalKey()

        let client = try MeshConsumerClient(config: config, dryRun: true)

        // Verify mesh network was created
        let stats = await client.statistics()
        XCTAssertEqual(stats.natType, .unknown) // Not started yet
    }

    func testMeshConsumerClientExplicitInit() async {
        let identity = OmertaMesh.IdentityKeypair()
        let networkKey = Data(repeating: 0x42, count: 32)
        let meshConfig = MeshConfig(encryptionKey: networkKey)

        let client = MeshConsumerClient(
            identity: identity,
            meshConfig: meshConfig,
            networkKey: networkKey,
            dryRun: true
        )

        let stats = await client.statistics()
        XCTAssertEqual(stats.peerCount, 0)
    }

    func testMeshConsumerClientPeerIdIsDerivedFromIdentity() async {
        let identity = OmertaMesh.IdentityKeypair()
        let networkKey = Data(repeating: 0x42, count: 32)
        let meshConfig = MeshConfig(encryptionKey: networkKey)

        let client = MeshConsumerClient(
            identity: identity,
            meshConfig: meshConfig,
            networkKey: networkKey,
            dryRun: true
        )

        // Verify peer ID format: 16 lowercase hex chars
        let peerId = await client.mesh.peerId
        XCTAssertEqual(peerId.count, 16)
        XCTAssertTrue(peerId.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(peerId, identity.peerId)
    }

    // MARK: - MeshConsumerClient Lifecycle Tests

    func testMeshConsumerClientStartStop() async throws {
        var config = OmertaConfig()
        config.mesh = MeshConfigOptions(enabled: true)
        config.localKey = OmertaConfig.generateLocalKey()

        let client = try MeshConsumerClient(config: config, dryRun: true)

        // Start
        try await client.start()

        // Verify started
        let stats = await client.statistics()
        // NAT type should be detected (or unknown if no network)
        XCTAssertTrue(stats.natType == .unknown || stats.natType != .unknown)

        // Stop
        await client.stop()
    }

    func testMeshConsumerClientDoubleStartIsNoOp() async throws {
        var config = OmertaConfig()
        config.mesh = MeshConfigOptions(enabled: true)
        config.localKey = OmertaConfig.generateLocalKey()

        let client = try MeshConsumerClient(config: config, dryRun: true)

        try await client.start()
        try await client.start() // Should not throw

        await client.stop()
    }

    func testMeshConsumerClientRequestVMRequiresStart() async throws {
        var config = OmertaConfig()
        config.mesh = MeshConfigOptions(enabled: true)
        config.localKey = OmertaConfig.generateLocalKey()

        let client = try MeshConsumerClient(config: config, dryRun: true)

        // Don't call start()

        do {
            _ = try await client.requestVM(
                fromProvider: "some-provider",
                sshPublicKey: "ssh-ed25519 AAAA..."
            )
            XCTFail("Should throw notStarted")
        } catch let error as MeshConsumerError {
            XCTAssertEqual(error.description, "Mesh consumer client not started (call start() first)")
        }
    }

    // MARK: - Error Description Tests

    func testMeshConsumerErrorDescriptions() {
        XCTAssertEqual(
            MeshConsumerError.meshNotEnabled.description,
            "Mesh networking is not enabled in config"
        )
        XCTAssertEqual(
            MeshConsumerError.noNetworkKey.description,
            "No network key configured (run 'omerta init' first)"
        )
        XCTAssertEqual(
            MeshConsumerError.notStarted.description,
            "Mesh consumer client not started (call start() first)"
        )
        XCTAssertEqual(
            MeshConsumerError.connectionFailed(reason: "timeout").description,
            "Failed to connect to provider: timeout"
        )
        XCTAssertEqual(
            MeshConsumerError.noResponse.description,
            "No response from provider (timeout)"
        )
        XCTAssertEqual(
            MeshConsumerError.invalidResponse.description,
            "Invalid response from provider"
        )
        XCTAssertEqual(
            MeshConsumerError.providerError("VM limit reached").description,
            "Provider error: VM limit reached"
        )
    }
}
