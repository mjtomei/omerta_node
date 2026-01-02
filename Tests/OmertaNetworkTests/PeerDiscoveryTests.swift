import XCTest
@testable import OmertaNetwork
@testable import OmertaCore
import Foundation

final class PeerDiscoveryTests: XCTestCase {

    // MARK: - Discovery Start/Stop Tests

    func testDiscoveryStartStop() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)
        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 1.0,
            cleanupInterval: 2.0
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        // Start discovery
        await discovery.start()

        var stats = await discovery.getStatistics()
        XCTAssertTrue(stats.isRunning)

        // Stop discovery
        await discovery.stop()

        stats = await discovery.getStatistics()
        XCTAssertFalse(stats.isRunning)

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testDiscoveryMultipleStartCalls() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)
        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 1.0,
            cleanupInterval: 2.0
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        // Start multiple times (should be idempotent)
        await discovery.start()
        await discovery.start()
        await discovery.start()

        let stats = await discovery.getStatistics()
        XCTAssertTrue(stats.isRunning)

        await discovery.stop()

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testDiscoveryStopWhenNotRunning() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)
        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 1.0,
            cleanupInterval: 2.0
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        // Stop without starting (should not crash)
        await discovery.stop()

        let stats = await discovery.getStatistics()
        XCTAssertFalse(stats.isRunning)

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Announcement Tests

    func testAnnouncement() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        // Create a network
        _ = await manager.createNetwork(name: "Test Network", bootstrapEndpoint: "localhost:50051")
        try await Task.sleep(for: .milliseconds(100))

        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 0.5,
            cleanupInterval: 2.0
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        await discovery.start()

        // Wait for announcement to run
        try await Task.sleep(for: .milliseconds(600))

        let stats = await discovery.getStatistics()
        // Stats should show discovery is running
        XCTAssertTrue(stats.isRunning)

        await discovery.stop()

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testPeriodicAnnouncements() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        _ = await manager.createNetwork(name: "Test Network", bootstrapEndpoint: "localhost:50051")
        try await Task.sleep(for: .milliseconds(100))

        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 0.3,  // Very short interval for testing
            cleanupInterval: 5.0
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        await discovery.start()

        // Wait for multiple announcement cycles
        try await Task.sleep(for: .milliseconds(1000))

        let stats = await discovery.getStatistics()
        // Should be running and tracking stats
        XCTAssertTrue(stats.isRunning)

        await discovery.stop()

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testAnnouncementOnlyForEnabledNetworks() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        // Create two networks
        let key1 = await manager.createNetwork(name: "Enabled Network", bootstrapEndpoint: "localhost:50051")
        let key2 = await manager.createNetwork(name: "Disabled Network", bootstrapEndpoint: "localhost:50052")

        // Disable one
        try await manager.setNetworkEnabled(key2.deriveNetworkId(), enabled: false)

        try await Task.sleep(for: .milliseconds(100))

        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 0.5,
            cleanupInterval: 2.0
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        await discovery.start()

        try await Task.sleep(for: .milliseconds(600))

        let stats = await discovery.getStatistics()
        // Should be running and tracking one enabled network
        XCTAssertTrue(stats.isRunning)
        XCTAssertEqual(stats.totalNetworks, 1)

        await discovery.stop()

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Peer Registration Tests

    func testPeerRegistrationFromAnnouncement() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        let key = await manager.createNetwork(name: "Test Network", bootstrapEndpoint: "localhost:50051")
        let networkId = key.deriveNetworkId()
        try await Task.sleep(for: .milliseconds(100))

        let registry = PeerRegistry()

        // Manually register a peer (simulating receiving an announcement)
        let announcement = PeerAnnouncement.local(
            peerId: "remote-peer",
            networkId: networkId,
            endpoint: "192.168.1.100:50051",
            capabilities: [
                ResourceCapability(
                    type: .cpuOnly,
                    availableCpuCores: 8,
                    availableMemoryMb: 16384,
                    hasGpu: false,
                    gpu: nil,
                    supportedWorkloadTypes: ["script"]
                )
            ]
        )
        await registry.registerPeer(from: announcement)

        // Verify peer is registered
        let peers = await registry.getPeers(networkId: networkId)
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers[0].peerId, "remote-peer")

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Finding Peers Tests

    func testFindPeersInNetwork() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        let key = await manager.createNetwork(name: "Test Network", bootstrapEndpoint: "localhost:50051")
        let networkId = key.deriveNetworkId()
        try await Task.sleep(for: .milliseconds(100))

        let registry = PeerRegistry()

        // Register multiple peers
        for i in 1...3 {
            let announcement = PeerAnnouncement.local(
                peerId: "peer-\(i)",
                networkId: networkId,
                endpoint: "192.168.1.\(i):50051",
                capabilities: [
                    ResourceCapability(
                        type: .cpuOnly,
                        availableCpuCores: 8,
                        availableMemoryMb: 16384,
                        hasGpu: false,
                        gpu: nil,
                        supportedWorkloadTypes: ["script"]
                    )
                ]
            )
            await registry.registerPeer(from: announcement)
        }

        let requirements = ResourceRequirements(
            type: .cpuOnly,
            cpuCores: 4,
            memoryMB: 8192,
            gpu: nil,
            maxRuntimeSeconds: 3600
        )

        let matching = await registry.findPeers(
            networkId: networkId,
            requirements: requirements,
            maxResults: 10
        )

        XCTAssertEqual(matching.count, 3)

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Cleanup Tests

    func testPeriodicCleanup() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)
        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 0.2,
            cleanupInterval: 0.5  // Very short cleanup interval
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        await discovery.start()

        // Wait for cleanup to run at least once
        try await Task.sleep(for: .milliseconds(600))

        let stats = await discovery.getStatistics()
        // Cleanup should have run, stats should be available
        XCTAssertTrue(stats.isRunning)

        await discovery.stop()

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func testCleanupRemovesStalePeers() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)
        let registry = PeerRegistry()

        let key = await manager.createNetwork(name: "Test Network", bootstrapEndpoint: "localhost:50051")
        let networkId = key.deriveNetworkId()
        try await Task.sleep(for: .milliseconds(100))

        // Register a peer
        let announcement = PeerAnnouncement.local(
            peerId: "stale-peer",
            networkId: networkId,
            endpoint: "192.168.1.100:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement)

        // Verify peer exists
        var peers = await registry.getPeers(networkId: networkId)
        XCTAssertEqual(peers.count, 1)

        // Clean up stale peers (immediately)
        await registry.cleanupStalePeers(timeout: 0)

        // Peer should be removed
        peers = await registry.getPeers(networkId: networkId)
        XCTAssertEqual(peers.count, 0)

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Statistics Tests

    func testStatistics() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)
        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 0.3,
            cleanupInterval: 0.6
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        // Initially not running
        var stats = await discovery.getStatistics()
        XCTAssertFalse(stats.isRunning)
        XCTAssertEqual(stats.totalNetworks, 0)

        // Start and let it run
        await discovery.start()
        try await Task.sleep(for: .milliseconds(700))

        stats = await discovery.getStatistics()
        XCTAssertTrue(stats.isRunning)

        await discovery.stop()

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Configuration Tests

    func testCustomConfiguration() async throws {
        let customConfig = PeerDiscovery.Configuration(
            localPeerId: "custom-peer-id",
            localEndpoint: "10.0.0.1:9999",
            announcementInterval: 60.0,
            cleanupInterval: 120.0
        )

        XCTAssertEqual(customConfig.localPeerId, "custom-peer-id")
        XCTAssertEqual(customConfig.localEndpoint, "10.0.0.1:9999")
        XCTAssertEqual(customConfig.announcementInterval, 60.0)
        XCTAssertEqual(customConfig.cleanupInterval, 120.0)
    }

    func testDefaultConfiguration() {
        let defaultConfig = PeerDiscovery.Configuration(
            localPeerId: "test",
            localEndpoint: "localhost:50051"
        )

        // Should use default intervals
        XCTAssertEqual(defaultConfig.announcementInterval, 30.0)
        XCTAssertEqual(defaultConfig.cleanupInterval, 60.0)
    }

    // MARK: - Multi-Network Tests

    func testDiscoveryAcrossMultipleNetworks() async throws {
        let tempPath = NSTemporaryDirectory() + "test-networks-\(UUID().uuidString).json"
        let manager = NetworkManager(configPath: tempPath)

        // Create two networks
        let key1 = await manager.createNetwork(name: "Network 1", bootstrapEndpoint: "localhost:50051")
        let key2 = await manager.createNetwork(name: "Network 2", bootstrapEndpoint: "localhost:50052")
        try await Task.sleep(for: .milliseconds(100))

        let registry = PeerRegistry()

        let config = PeerDiscovery.Configuration(
            localPeerId: "test-peer",
            localEndpoint: "localhost:50051",
            announcementInterval: 0.5,
            cleanupInterval: 2.0
        )

        let discovery = PeerDiscovery(
            config: config,
            networkManager: manager,
            peerRegistry: registry
        )

        await discovery.start()

        // Wait for announcements
        try await Task.sleep(for: .milliseconds(600))

        let stats = await discovery.getStatistics()
        // Should be tracking both networks
        XCTAssertEqual(stats.totalNetworks, 2)

        await discovery.stop()

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    // MARK: - Resource Capability Tests

    func testAnnouncementIncludesResourceCapabilities() async throws {
        let announcement = PeerAnnouncement.local(
            peerId: "test-peer",
            networkId: "test-network",
            endpoint: "localhost:50051",
            capabilities: [
                ResourceCapability(
                    type: .cpuOnly,
                    availableCpuCores: 8,
                    availableMemoryMb: 16384,
                    hasGpu: false,
                    gpu: nil,
                    supportedWorkloadTypes: ["script", "binary"]
                )
            ]
        )

        XCTAssertEqual(announcement.peerId, "test-peer")
        XCTAssertEqual(announcement.networkId, "test-network")
        XCTAssertEqual(announcement.endpoint, "localhost:50051")
        XCTAssertEqual(announcement.capabilities.count, 1)
        XCTAssertEqual(announcement.capabilities[0].availableCpuCores, 8)
        XCTAssertEqual(announcement.capabilities[0].availableMemoryMb, 16384)
    }

    func testAnnouncementWithGPUCapability() async throws {
        let gpuCapability = GpuCapability(
            gpuModel: "M1 Max",
            totalVramMb: 32768,
            availableVramMb: 16384,
            supportedApis: ["Metal"],
            supportsVirtualization: true
        )

        let announcement = PeerAnnouncement.local(
            peerId: "gpu-peer",
            networkId: "test-network",
            endpoint: "localhost:50051",
            capabilities: [
                ResourceCapability(
                    type: .gpuRequired,
                    availableCpuCores: 8,
                    availableMemoryMb: 16384,
                    hasGpu: true,
                    gpu: gpuCapability,
                    supportedWorkloadTypes: ["script", "binary"]
                )
            ]
        )

        XCTAssertTrue(announcement.capabilities[0].hasGpu)
        XCTAssertNotNil(announcement.capabilities[0].gpu)
        XCTAssertEqual(announcement.capabilities[0].gpu?.gpuModel, "M1 Max")
        XCTAssertEqual(announcement.capabilities[0].gpu?.totalVramMb, 32768)
    }
}
