import XCTest
@testable import OmertaNetwork
@testable import OmertaCore

final class NetworkManagerTests: XCTestCase {

    // MARK: - Network Creation Tests

    func testNetworkCreation() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        let key = await manager.createNetwork(
            name: "Test Network",
            bootstrapEndpoint: "192.168.1.100:50051"
        )

        // Verify key can be encoded
        let encoded = try key.encode()
        XCTAssertTrue(encoded.hasPrefix("omerta://join/"))

        // Verify network was added
        let networks = await manager.getNetworks()
        XCTAssertEqual(networks.count, 1)
        XCTAssertEqual(networks[0].name, "Test Network")
        XCTAssertEqual(networks[0].key.bootstrapPeers, ["192.168.1.100:50051"])

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testNetworkKeyEncoding() throws {
        let key = NetworkKey.generate(
            networkName: "My Network",
            bootstrapEndpoint: "localhost:50051"
        )

        // Encode
        let encoded = try key.encode()
        XCTAssertTrue(encoded.hasPrefix("omerta://join/"))

        // Decode
        let decoded = try NetworkKey.decode(from: encoded)
        XCTAssertEqual(decoded.networkName, "My Network")
        XCTAssertEqual(decoded.bootstrapPeers, ["localhost:50051"])

        // Verify network IDs match
        XCTAssertEqual(key.deriveNetworkId(), decoded.deriveNetworkId())
    }

    func testNetworkKeyEncodingWithMultipleBootstrapPeers() throws {
        let key = NetworkKey(
            networkKey: Data(repeating: 0x42, count: 32),
            networkName: "Multi-Peer Network",
            bootstrapPeers: ["peer1:50051", "peer2:50051", "peer3:50051"]
        )

        let encoded = try key.encode()
        let decoded = try NetworkKey.decode(from: encoded)

        XCTAssertEqual(decoded.networkName, "Multi-Peer Network")
        XCTAssertEqual(decoded.bootstrapPeers.count, 3)
        XCTAssertTrue(decoded.bootstrapPeers.contains("peer1:50051"))
        XCTAssertTrue(decoded.bootstrapPeers.contains("peer2:50051"))
        XCTAssertTrue(decoded.bootstrapPeers.contains("peer3:50051"))
    }

    func testNetworkKeyDecodingInvalidFormat() {
        // Invalid prefix
        XCTAssertThrowsError(try NetworkKey.decode(from: "invalid://join/data"))

        // Invalid base64
        XCTAssertThrowsError(try NetworkKey.decode(from: "omerta://join/!!!invalid!!!"))

        // Valid base64 but invalid JSON
        let invalidBase64 = Data("not json".utf8).base64EncodedString()
        XCTAssertThrowsError(try NetworkKey.decode(from: "omerta://join/\(invalidBase64)"))
    }

    // MARK: - Network Joining Tests

    func testJoinNetwork() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        // Create a network key
        let key = NetworkKey.generate(
            networkName: "Join Test Network",
            bootstrapEndpoint: "192.168.1.100:50051"
        )

        // Join the network
        let networkId = try await manager.joinNetwork(key: key, name: nil)

        // Verify network was added
        let networks = await manager.getNetworks()
        XCTAssertEqual(networks.count, 1)
        XCTAssertEqual(networks[0].id, networkId)
        XCTAssertEqual(networks[0].name, "Join Test Network")

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testJoinNetworkWithCustomName() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        let key = NetworkKey.generate(
            networkName: "Original Name",
            bootstrapEndpoint: "localhost:50051"
        )

        // Join with custom name
        _ = try await manager.joinNetwork(key: key, name: "Custom Name")

        let networks = await manager.getNetworks()
        XCTAssertEqual(networks[0].name, "Custom Name")

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testDuplicateJoinPrevention() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        let key = NetworkKey.generate(
            networkName: "Duplicate Test",
            bootstrapEndpoint: "localhost:50051"
        )

        // Join once
        _ = try await manager.joinNetwork(key: key, name: nil)

        // Try to join again - should throw
        do {
            _ = try await manager.joinNetwork(key: key, name: nil)
            XCTFail("Should have thrown duplicate network error")
        } catch NetworkError.alreadyJoined {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Network Leaving Tests

    func testLeaveNetwork() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        // Create and join a network
        let key = await manager.createNetwork(name: "Leave Test", bootstrapEndpoint: "localhost:50051")
        let networkId = key.deriveNetworkId()

        // Verify it exists
        var networks = await manager.getNetworks()
        XCTAssertEqual(networks.count, 1)

        // Leave the network
        try await manager.leaveNetwork(networkId: networkId)

        // Verify it's gone
        networks = await manager.getNetworks()
        XCTAssertEqual(networks.count, 0)

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testLeaveNonexistentNetwork() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        do {
            try await manager.leaveNetwork(networkId: "nonexistent-id")
            XCTFail("Should have thrown network not found error")
        } catch NetworkError.notFound {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Network Enable/Disable Tests

    func testEnableDisableNetwork() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        let key = await manager.createNetwork(name: "Toggle Test", bootstrapEndpoint: "localhost:50051")
        let networkId = key.deriveNetworkId()

        // Should be enabled by default
        var isEnabled = await manager.isNetworkEnabled(networkId)
        XCTAssertTrue(isEnabled)

        // Disable it
        try await manager.setNetworkEnabled(networkId, enabled: false)
        isEnabled = await manager.isNetworkEnabled(networkId)
        XCTAssertFalse(isEnabled)

        // Enable it again
        try await manager.setNetworkEnabled(networkId, enabled: true)
        isEnabled = await manager.isNetworkEnabled(networkId)
        XCTAssertTrue(isEnabled)

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Network Persistence Tests

    func testPersistence() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"

        // Create manager and add networks
        do {
            let manager1 = NetworkManager(configPath: tempPath)

            _ = await manager1.createNetwork(name: "Network 1", bootstrapEndpoint: "peer1:50051")
            _ = await manager1.createNetwork(name: "Network 2", bootstrapEndpoint: "peer2:50051")

            // Wait for async saves
            try await Task.sleep(for: .milliseconds(100))
        }

        // Create new manager instance and load
        let manager2 = NetworkManager(configPath: tempPath)
        try await manager2.loadNetworks()

        let networks = await manager2.getNetworks()
        XCTAssertEqual(networks.count, 2)

        let names = networks.map { $0.name }.sorted()
        XCTAssertEqual(names, ["Network 1", "Network 2"])

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testPersistenceWithDisabledNetwork() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"

        var networkId: String = ""

        // Create and disable
        do {
            let manager1 = NetworkManager(configPath: tempPath)
            let key = await manager1.createNetwork(name: "Disabled Network", bootstrapEndpoint: "localhost:50051")
            networkId = key.deriveNetworkId()

            try await manager1.setNetworkEnabled(networkId, enabled: false)

            // Wait for saves
            try await Task.sleep(for: .milliseconds(100))
        }

        // Reload and verify disabled state
        let manager2 = NetworkManager(configPath: tempPath)
        try await manager2.loadNetworks()

        let isEnabled = await manager2.isNetworkEnabled(networkId)
        XCTAssertFalse(isEnabled)

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testLoadingNonexistentFile() async throws {
        let tempPath = NSTemporaryDirectory() + "nonexistent-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        // Should not throw, just start with empty state
        try await manager.loadNetworks()

        let networks = await manager.getNetworks()
        XCTAssertEqual(networks.count, 0)
    }

    // MARK: - Network Retrieval Tests

    func testGetNetwork() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        let key = await manager.createNetwork(name: "Get Test", bootstrapEndpoint: "localhost:50051")
        let networkId = key.deriveNetworkId()

        // Get existing network
        let network = await manager.getNetwork(id: networkId)
        XCTAssertNotNil(network)
        XCTAssertEqual(network?.name, "Get Test")

        // Get nonexistent network
        let nonexistent = await manager.getNetwork(id: "fake-id")
        XCTAssertNil(nonexistent)

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testGetEnabledNetworks() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        let key1 = await manager.createNetwork(name: "Enabled 1", bootstrapEndpoint: "peer1:50051")
        let key2 = await manager.createNetwork(name: "Enabled 2", bootstrapEndpoint: "peer2:50051")
        let key3 = await manager.createNetwork(name: "Disabled", bootstrapEndpoint: "peer3:50051")

        // Disable one network
        try await manager.setNetworkEnabled(key3.deriveNetworkId(), enabled: false)

        let enabledNetworks = await manager.getEnabledNetworks()
        XCTAssertEqual(enabledNetworks.count, 2)

        let names = enabledNetworks.map { $0.name }.sorted()
        XCTAssertEqual(names, ["Enabled 1", "Enabled 2"])

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Network ID Derivation Tests

    func testNetworkIdDeterministic() {
        let key1 = NetworkKey(
            networkKey: Data(repeating: 0x42, count: 32),
            networkName: "Test",
            bootstrapPeers: ["peer:50051"]
        )

        let key2 = NetworkKey(
            networkKey: Data(repeating: 0x42, count: 32),
            networkName: "Test",
            bootstrapPeers: ["peer:50051"]
        )

        // Same key should derive same ID
        XCTAssertEqual(key1.deriveNetworkId(), key2.deriveNetworkId())
    }

    func testNetworkIdUnique() {
        let key1 = NetworkKey(
            networkKey: Data(repeating: 0x42, count: 32),
            networkName: "Network 1",
            bootstrapPeers: ["peer:50051"]
        )

        let key2 = NetworkKey(
            networkKey: Data(repeating: 0x43, count: 32),
            networkName: "Network 2",
            bootstrapPeers: ["peer:50051"]
        )

        // Different keys should derive different IDs
        XCTAssertNotEqual(key1.deriveNetworkId(), key2.deriveNetworkId())
    }
}
