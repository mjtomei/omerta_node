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

    func testMeshConsumerClientInitialization() async throws {
        // Create a MeshNetwork for testing
        let identity = OmertaMesh.IdentityKeypair()
        let encryptionKey = Data(repeating: 0x42, count: 32)
        let meshConfig = MeshConfig(encryptionKey: encryptionKey)
        let meshNetwork = MeshNetwork(identity: identity, config: meshConfig)

        // Use a unique temp path to avoid interference from other tests/runs
        let tempPath = "/tmp/omerta-test-\(UUID().uuidString)/vms.json"

        // Use a different peer ID than our own
        let providerPeerId = "different-provider-peer-id-1234"

        let client = try await MeshConsumerClient(
            meshNetwork: meshNetwork,
            providerPeerId: providerPeerId,
            networkId: "test-network-id",
            persistencePath: tempPath,
            dryRun: true
        )

        // Client should be initialized without starting a mesh
        let vms = await client.listActiveVMs()
        XCTAssertTrue(vms.isEmpty)

        // Cleanup
        try? FileManager.default.removeItem(atPath: (tempPath as NSString).deletingLastPathComponent)
    }

    func testMeshConsumerClientRejectsSelfRequest() async throws {
        // Create a MeshNetwork for testing
        let identity = OmertaMesh.IdentityKeypair()
        let encryptionKey = Data(repeating: 0x42, count: 32)
        let meshConfig = MeshConfig(encryptionKey: encryptionKey)
        let meshNetwork = MeshNetwork(identity: identity, config: meshConfig)

        // Use our own peer ID as the provider - should be rejected
        let myPeerId = await meshNetwork.peerId

        do {
            _ = try await MeshConsumerClient(
                meshNetwork: meshNetwork,
                providerPeerId: myPeerId,
                networkId: "test-network-id",
                dryRun: true
            )
            XCTFail("Expected selfRequestNotAllowed error")
        } catch let error as MeshConsumerError {
            XCTAssertEqual(error.description, MeshConsumerError.selfRequestNotAllowed.description)
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

    // MARK: - VM Protocol Message Tests

    func testMeshProviderShutdownNotificationEncoding() throws {
        let vmId1 = UUID()
        let vmId2 = UUID()
        let providerPeerId = "test-provider-peer-id"
        let notification = MeshProviderShutdownNotification(providerPeerId: providerPeerId, vmIds: [vmId1, vmId2])

        XCTAssertEqual(notification.type, "provider_shutdown")
        XCTAssertEqual(notification.reason, "provider_shutdown")
        XCTAssertEqual(notification.providerPeerId, providerPeerId)
        XCTAssertEqual(notification.vmIds.count, 2)

        // Test encoding/decoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MeshProviderShutdownNotification.self, from: data)

        XCTAssertEqual(decoded.type, "provider_shutdown")
        XCTAssertEqual(decoded.reason, "provider_shutdown")
        XCTAssertEqual(decoded.providerPeerId, providerPeerId)
        XCTAssertEqual(decoded.vmIds.count, 2)
        XCTAssertTrue(decoded.vmIds.contains(vmId1))
        XCTAssertTrue(decoded.vmIds.contains(vmId2))
    }

    func testMeshProviderShutdownNotificationCustomReason() throws {
        let vmId = UUID()
        let providerPeerId = "test-provider-peer-id"
        let notification = MeshProviderShutdownNotification(providerPeerId: providerPeerId, vmIds: [vmId], reason: "maintenance")

        XCTAssertEqual(notification.type, "provider_shutdown")
        XCTAssertEqual(notification.reason, "maintenance")

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MeshProviderShutdownNotification.self, from: data)

        XCTAssertEqual(decoded.reason, "maintenance")
    }

    func testMeshVMHeartbeatEncoding() throws {
        let vmId1 = UUID()
        let vmId2 = UUID()
        let providerPeerId = "test-provider-peer-id"
        let heartbeat = MeshVMHeartbeat(providerPeerId: providerPeerId, vmIds: [vmId1, vmId2])

        XCTAssertEqual(heartbeat.type, "vm_heartbeat")
        XCTAssertEqual(heartbeat.providerPeerId, providerPeerId)
        XCTAssertEqual(heartbeat.vmIds.count, 2)

        let encoder = JSONEncoder()
        let data = try encoder.encode(heartbeat)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MeshVMHeartbeat.self, from: data)

        XCTAssertEqual(decoded.type, "vm_heartbeat")
        XCTAssertEqual(decoded.providerPeerId, providerPeerId)
        XCTAssertTrue(decoded.vmIds.contains(vmId1))
        XCTAssertTrue(decoded.vmIds.contains(vmId2))
    }

    func testMeshVMHeartbeatResponseEncoding() throws {
        let vmId = UUID()
        let response = MeshVMHeartbeatResponse(activeVmIds: [vmId])

        XCTAssertEqual(response.type, "vm_heartbeat_response")
        XCTAssertEqual(response.activeVmIds.count, 1)

        let encoder = JSONEncoder()
        let data = try encoder.encode(response)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MeshVMHeartbeatResponse.self, from: data)

        XCTAssertEqual(decoded.type, "vm_heartbeat_response")
        XCTAssertTrue(decoded.activeVmIds.contains(vmId))
    }
}
