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
                capabilities: [
                    ResourceCapability(
                        type: .cpuOnly,
                        availableCpuCores: UInt32(i * 2),
                        availableMemoryMb: UInt64(i * 1024),
                        hasGpu: false,
                        gpu: nil,
                        supportedWorkloadTypes: ["script"]
                    )
                ]
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
            capabilities: [
                ResourceCapability(
                    type: .cpuOnly,
                    availableCpuCores: 4,
                    availableMemoryMb: 8192,
                    hasGpu: false,
                    gpu: nil,
                    supportedWorkloadTypes: ["script"]
                )
            ]
        )
        await registry.registerPeer(from: announcement1)

        // Wait briefly
        try await Task.sleep(for: .milliseconds(100))

        // Re-register with updated capabilities
        let announcement2 = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: [
                ResourceCapability(
                    type: .gpuRequired,
                    availableCpuCores: 8,
                    availableMemoryMb: 16384,
                    hasGpu: true,
                    gpu: GpuCapability(
                        gpuModel: "M1 Max",
                        totalVramMb: 32768,
                        availableVramMb: 16384,
                        supportedApis: ["Metal"],
                        supportsVirtualization: true
                    ),
                    supportedWorkloadTypes: ["script", "binary"]
                )
            ]
        )
        await registry.registerPeer(from: announcement2)

        let peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 1)

        let peer = peers[0]
        XCTAssertEqual(peer.capabilities[0].availableCpuCores, 8)
        XCTAssertEqual(peer.capabilities[0].availableMemoryMb, 16384)
        XCTAssertTrue(peer.capabilities[0].hasGpu)
    }

    // MARK: - Peer Removal Tests

    func testPeerRemoval() async throws {
        let registry = PeerRegistry()

        let announcement = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement)

        var peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 1)

        await registry.removePeer("peer-123")

        peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 0)
    }

    func testRemoveNonexistentPeer() async throws {
        let registry = PeerRegistry()

        // Should not crash
        await registry.removePeer("nonexistent")
    }

    // MARK: - Network Scoping Tests

    func testNetworkScopedPeers() async throws {
        let registry = PeerRegistry()

        // Register peers in different networks
        let announcement1 = PeerAnnouncement.local(
            peerId: "peer-1",
            networkId: "network-A",
            endpoint: "192.168.1.1:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement1)

        let announcement2 = PeerAnnouncement.local(
            peerId: "peer-2",
            networkId: "network-B",
            endpoint: "192.168.1.2:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement2)

        let announcement3 = PeerAnnouncement.local(
            peerId: "peer-3",
            networkId: "network-A",
            endpoint: "192.168.1.3:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement3)

        // Verify network isolation
        let peersA = await registry.getPeers(networkId: "network-A")
        XCTAssertEqual(peersA.count, 2)
        XCTAssertTrue(peersA.contains { $0.peerId == "peer-1" })
        XCTAssertTrue(peersA.contains { $0.peerId == "peer-3" })

        let peersB = await registry.getPeers(networkId: "network-B")
        XCTAssertEqual(peersB.count, 1)
        XCTAssertEqual(peersB[0].peerId, "peer-2")
    }

    func testPeerInMultipleNetworks() async throws {
        let registry = PeerRegistry()

        // Same peer in two networks (different endpoint per network)
        let announcement1 = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-A",
            endpoint: "192.168.1.100:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement1)

        let announcement2 = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-B",
            endpoint: "192.168.1.100:50052",
            capabilities: []
        )
        await registry.registerPeer(from: announcement2)

        let peersA = await registry.getPeers(networkId: "network-A")
        let peersB = await registry.getPeers(networkId: "network-B")

        XCTAssertEqual(peersA.count, 1)
        XCTAssertEqual(peersB.count, 1)
        XCTAssertEqual(peersA[0].peerId, "peer-123")
        XCTAssertEqual(peersB[0].peerId, "peer-123")
    }

    // MARK: - Online/Offline Status Tests

    func testOnlineStatus() async throws {
        let registry = PeerRegistry()

        let announcement = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement)

        // Peer should be online
        let onlinePeers = await registry.getOnlinePeers(networkId: "network-abc")
        XCTAssertEqual(onlinePeers.count, 1)
        XCTAssertEqual(onlinePeers[0].peerId, "peer-123")
    }

    func testMarkPeerOffline() async throws {
        let registry = PeerRegistry()

        let announcement = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement)

        // Mark offline
        await registry.markPeerOffline("peer-123")

        // Should not appear in online peers
        let onlinePeers = await registry.getOnlinePeers(networkId: "network-abc")
        XCTAssertEqual(onlinePeers.count, 0)

        // But should still appear in all peers
        let allPeers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(allPeers.count, 1)
    }

    // MARK: - Finding Peers by Requirements

    func testFindPeersByRequirements() async throws {
        let registry = PeerRegistry()

        // Register peers with different capabilities
        let lowEndPeer = PeerAnnouncement.local(
            peerId: "low-end",
            networkId: "network-abc",
            endpoint: "192.168.1.1:50051",
            capabilities: [
                ResourceCapability(
                    type: .cpuOnly,
                    availableCpuCores: 2,
                    availableMemoryMb: 4096,
                    hasGpu: false,
                    gpu: nil,
                    supportedWorkloadTypes: ["script"]
                )
            ]
        )
        await registry.registerPeer(from: lowEndPeer)

        let highEndPeer = PeerAnnouncement.local(
            peerId: "high-end",
            networkId: "network-abc",
            endpoint: "192.168.1.2:50051",
            capabilities: [
                ResourceCapability(
                    type: .cpuOnly,
                    availableCpuCores: 16,
                    availableMemoryMb: 65536,
                    hasGpu: false,
                    gpu: nil,
                    supportedWorkloadTypes: ["script", "binary"]
                )
            ]
        )
        await registry.registerPeer(from: highEndPeer)

        // Query for high requirements
        let requirements = ResourceRequirements(
            type: .cpuOnly,
            cpuCores: 8,
            memoryMB: 16384,
            gpu: nil,
            maxRuntimeSeconds: 3600
        )

        let matching = await registry.findPeers(
            networkId: "network-abc",
            requirements: requirements,
            maxResults: 10
        )

        // Only high-end peer should match
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching[0].peerId, "high-end")
    }

    func testFindPeersWithGPURequirement() async throws {
        let registry = PeerRegistry()

        // CPU-only peer
        let cpuPeer = PeerAnnouncement.local(
            peerId: "cpu-only",
            networkId: "network-abc",
            endpoint: "192.168.1.1:50051",
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
        await registry.registerPeer(from: cpuPeer)

        // GPU peer
        let gpuPeer = PeerAnnouncement.local(
            peerId: "gpu-enabled",
            networkId: "network-abc",
            endpoint: "192.168.1.2:50051",
            capabilities: [
                ResourceCapability(
                    type: .gpuRequired,
                    availableCpuCores: 8,
                    availableMemoryMb: 16384,
                    hasGpu: true,
                    gpu: GpuCapability(
                        gpuModel: "M1 Max",
                        totalVramMb: 32768,
                        availableVramMb: 16384,
                        supportedApis: ["Metal"],
                        supportsVirtualization: true
                    ),
                    supportedWorkloadTypes: ["script", "binary"]
                )
            ]
        )
        await registry.registerPeer(from: gpuPeer)

        // Query for GPU
        let requirements = ResourceRequirements(
            type: .gpuRequired,
            cpuCores: 4,
            memoryMB: 8192,
            gpu: GPURequirements(
                vramMB: 8192,
                requiredCapabilities: [],
                metalOnly: true
            ),
            maxRuntimeSeconds: 3600
        )

        let matching = await registry.findPeers(
            networkId: "network-abc",
            requirements: requirements,
            maxResults: 10
        )

        // Only GPU peer should match
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching[0].peerId, "gpu-enabled")
    }

    func testFindPeersMaxResults() async throws {
        let registry = PeerRegistry()

        // Register 5 peers
        for i in 1...5 {
            let announcement = PeerAnnouncement.local(
                peerId: "peer-\(i)",
                networkId: "network-abc",
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

        // Request only 3 results
        let matching = await registry.findPeers(
            networkId: "network-abc",
            requirements: requirements,
            maxResults: 3
        )

        XCTAssertEqual(matching.count, 3)
    }

    func testFindPeersSortedByReputation() async throws {
        let registry = PeerRegistry()

        // Register peers with different reputations
        let lowRep = PeerAnnouncement(
            peerId: "low-rep",
            networkId: "network-abc",
            capabilities: [
                ResourceCapability(
                    type: .cpuOnly,
                    availableCpuCores: 8,
                    availableMemoryMb: 16384,
                    hasGpu: false,
                    gpu: nil,
                    supportedWorkloadTypes: ["script"]
                )
            ],
            metadata: PeerMetadata(
                reputationScore: 50,
                jobsCompleted: 10,
                jobsRejected: 5,
                averageResponseTimeMs: 1000.0
            ),
            timestamp: UInt64(Date().timeIntervalSince1970),
            signature: Data(),
            endpoint: "192.168.1.1:50051"
        )
        await registry.registerPeer(from: lowRep)

        let highRep = PeerAnnouncement(
            peerId: "high-rep",
            networkId: "network-abc",
            capabilities: [
                ResourceCapability(
                    type: .cpuOnly,
                    availableCpuCores: 8,
                    availableMemoryMb: 16384,
                    hasGpu: false,
                    gpu: nil,
                    supportedWorkloadTypes: ["script"]
                )
            ],
            metadata: PeerMetadata(
                reputationScore: 95,
                jobsCompleted: 100,
                jobsRejected: 2,
                averageResponseTimeMs: 500.0
            ),
            timestamp: UInt64(Date().timeIntervalSince1970),
            signature: Data(),
            endpoint: "192.168.1.2:50051"
        )
        await registry.registerPeer(from: highRep)

        let requirements = ResourceRequirements(
            type: .cpuOnly,
            cpuCores: 4,
            memoryMB: 8192,
            gpu: nil,
            maxRuntimeSeconds: 3600
        )

        let matching = await registry.findPeers(
            networkId: "network-abc",
            requirements: requirements,
            maxResults: 10
        )

        // High reputation peer should be first
        XCTAssertEqual(matching.count, 2)
        XCTAssertEqual(matching[0].peerId, "high-rep")
        XCTAssertEqual(matching[1].peerId, "low-rep")
    }

    // MARK: - Stale Peer Cleanup Tests

    func testCleanupStalePeers() async throws {
        let registry = PeerRegistry()

        // Register a peer
        let announcement = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement)

        // Verify peer exists
        var peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 1)

        // Clean up immediately (peer is considered stale)
        await registry.cleanupStalePeers(timeout: 0)

        // Peer should be removed
        peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 0)
    }

    func testCleanupDoesNotRemoveRecentPeers() async throws {
        let registry = PeerRegistry()

        let announcement = PeerAnnouncement.local(
            peerId: "peer-123",
            networkId: "network-abc",
            endpoint: "192.168.1.100:50051",
            capabilities: []
        )
        await registry.registerPeer(from: announcement)

        // Clean up peers older than 60 seconds (this peer is fresh)
        await registry.cleanupStalePeers(timeout: 60.0)

        // Peer should still be there
        let peers = await registry.getPeers(networkId: "network-abc")
        XCTAssertEqual(peers.count, 1)
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
