import XCTest
@testable import OmertaNetwork
@testable import OmertaCore
import Foundation

final class PeerRegistryTests: XCTestCase {

    // MARK: - Peer Registration Tests

    func testPeerRegistration() async throws {
        let registry = PeerRegistry()

        let announcement = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: [TestResourceCapability.cpuOnly()]
        )

        await registry.registerPeer(from: announcement)

        let peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers[0].peerId, "peer-123")
        XCTAssertEqual(peers[0].endpoint, "192.168.1.100:50051")
    }

    func testMultiplePeerRegistration() async throws {
        let registry = PeerRegistry()

        // Register three peers
        for i in 1...3 {
            let announcement = PeerAnnouncement.local(
                peerId: "peer-\(i)",
                networkId: "network-abc",
                endpoint: "192.168.1.\(i):50051",
                capabilities: [TestResourceCapability.cpuOnly(cpuCores: UInt32(i * 2))]
            )
            await registry.registerPeer(from: announcement)
        }

        let peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 3)

        let peerIds = peers.map { $0.peerId }.sorted()
        XCTAssertEqual(peerIds, ["peer-1", "peer-2", "peer-3"])
    }

    func testPeerUpdateOnReRegistration() async throws {
        let registry = PeerRegistry()

        // Register peer
        let announcement1 = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: [TestResourceCapability.cpuOnly(cpuCores: 4)]
        )
        await registry.registerPeer(from: announcement1)

        // Wait briefly
        try await Task.sleep(for: .milliseconds(100))

        // Re-register with updated capabilities
        let announcement2 = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: [TestResourceCapability.withGPU(cpuCores: 8)]
        )
        await registry.registerPeer(from: announcement2)

        let peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 1, "Should still have 1 peer after re-registration")
    }

    // MARK: - Network Isolation Tests

    func testPeersIsolatedByNetwork() async throws {
        let registry = PeerRegistry()

        // Register peer in network A
        let announcementA = PeerAnnouncement.local(
            peerId: "peer-A",
            networkId: "network-A",
            endpoint: "192.168.1.1:50051",
            capabilities: [TestResourceCapability.cpuOnly()]
        )
        await registry.registerPeer(from: announcementA)

        // Register peer in network B
        let announcementB = PeerAnnouncement.local(
            peerId: "peer-B",
            networkId: "network-B",
            endpoint: "192.168.1.2:50051",
            capabilities: [TestResourceCapability.cpuOnly()]
        )
        await registry.registerPeer(from: announcementB)

        // Each network should have exactly 1 peer
        let peersA = await registry.getPeers(networkId: "network-A")
        let peersB = await registry.getPeers(networkId: "network-B")

        XCTAssertEqual(peersA.count, 1)
        XCTAssertEqual(peersA[0].peerId, "peer-A")

        XCTAssertEqual(peersB.count, 1)
        XCTAssertEqual(peersB[0].peerId, "peer-B")
    }

    func testEmptyNetworkReturnsEmpty() async throws {
        let registry = PeerRegistry()

        let peers = await registry.getPeers(networkId: "non-existent-network")
        XCTAssertTrue(peers.isEmpty)
    }

    // MARK: - Peer Removal Tests

    func testPeerRemoval() async throws {
        let registry = PeerRegistry()

        let announcement = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: [TestResourceCapability.cpuOnly()]
        )
        await registry.registerPeer(from: announcement)

        var peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 1)

        // Remove peer
        await registry.removePeer("peer-123")

        peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 0)
    }

    func testRemoveNonExistentPeerDoesNothing() async throws {
        let registry = PeerRegistry()

        // This should not crash or throw
        await registry.removePeer("non-existent")

        let peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertTrue(peers.isEmpty)
    }

    // MARK: - Statistics Tests

    func testPeerStatistics() async throws {
        let registry = PeerRegistry()

        // Register peers in multiple networks
        let announcement1 = PeerAnnouncement.local(
            peerId: "peer-1",
            networkId: "network-A",
            endpoint: "192.168.1.1:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement1)

        let announcement2 = PeerAnnouncement.local(
            peerId: "peer-2",
            networkId: "network-A",
            endpoint: "192.168.1.2:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement2)

        let announcement3 = PeerAnnouncement.local(
            peerId: "peer-3",
            networkId: "network-B",
            endpoint: "192.168.1.3:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement3)

        // Get stats for network A
        let statsA = await registry.getStatistics(networkId: "network-A")
        XCTAssertEqual(statsA.totalPeers, 2)
        XCTAssertEqual(statsA.onlinePeers, 2)

        // Get stats for network B
        let statsB = await registry.getStatistics(networkId: "network-B")
        XCTAssertEqual(statsB.totalPeers, 1)
        XCTAssertEqual(statsB.onlinePeers, 1)
    }
}
