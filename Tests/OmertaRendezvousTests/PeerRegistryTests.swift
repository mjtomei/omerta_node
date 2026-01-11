// PeerRegistryTests.swift
// Tests for peer registry

import XCTest
import NIOCore
import NIOPosix
@testable import OmertaRendezvousLib

final class PeerRegistryTests: XCTestCase {

    var eventLoopGroup: EventLoopGroup!

    override func setUp() {
        super.setUp()
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? eventLoopGroup.syncShutdownGracefully()
        eventLoopGroup = nil
        super.tearDown()
    }

    // MARK: - Registration Tests

    func testRegisterPeer() async throws {
        let registry = PeerRegistry()
        let channel = try await createMockChannel()

        let success = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel)
        XCTAssertTrue(success)

        let peer = await registry.getPeer("peer-1")
        XCTAssertNotNil(peer)
        XCTAssertEqual(peer?.peerId, "peer-1")
        XCTAssertEqual(peer?.networkId, "network-1")

        try await channel.close()
    }

    func testRegisterDuplicatePeerId() async throws {
        let registry = PeerRegistry()
        let channel1 = try await createMockChannel()
        let channel2 = try await createMockChannel()

        let success1 = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel1)
        XCTAssertTrue(success1)

        let success2 = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel2)
        XCTAssertFalse(success2) // Should fail - duplicate peer ID

        try await channel1.close()
        try await channel2.close()
    }

    func testUnregisterPeer() async throws {
        let registry = PeerRegistry()
        let channel = try await createMockChannel()

        _ = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel)
        await registry.unregister(channel: channel)

        let peer = await registry.getPeer("peer-1")
        XCTAssertNil(peer)

        try await channel.close()
    }

    // MARK: - Endpoint Tests

    func testUpdateEndpoint() async throws {
        let registry = PeerRegistry()
        let channel = try await createMockChannel()

        _ = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel)
        await registry.updateEndpoint(peerId: "peer-1", endpoint: "192.168.1.1:5000", natType: .fullCone)

        let peer = await registry.getPeer("peer-1")
        XCTAssertEqual(peer?.endpoint, "192.168.1.1:5000")
        XCTAssertEqual(peer?.natType, .fullCone)

        try await channel.close()
    }

    func testUpdatePublicKey() async throws {
        let registry = PeerRegistry()
        let channel = try await createMockChannel()

        _ = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel)
        await registry.updatePublicKey(peerId: "peer-1", publicKey: "my-public-key-123")

        let peer = await registry.getPeer("peer-1")
        XCTAssertEqual(peer?.publicKey, "my-public-key-123")

        try await channel.close()
    }

    // MARK: - Connection Request Tests

    func testCreateConnectionRequest() async throws {
        let registry = PeerRegistry()
        let channel1 = try await createMockChannel()
        let channel2 = try await createMockChannel()

        _ = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel1)
        _ = await registry.register(peerId: "peer-2", networkId: "network-1", channel: channel2)

        let request = await registry.createConnectionRequest(
            requesterId: "peer-1",
            targetId: "peer-2",
            requesterPublicKey: "pubkey-1"
        )

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.requesterId, "peer-1")
        XCTAssertEqual(request?.targetId, "peer-2")
        XCTAssertEqual(request?.requesterPublicKey, "pubkey-1")

        try await channel1.close()
        try await channel2.close()
    }

    func testRemoveConnectionRequest() async throws {
        let registry = PeerRegistry()
        let channel1 = try await createMockChannel()
        let channel2 = try await createMockChannel()

        _ = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel1)
        _ = await registry.register(peerId: "peer-2", networkId: "network-1", channel: channel2)

        _ = await registry.createConnectionRequest(
            requesterId: "peer-1",
            targetId: "peer-2",
            requesterPublicKey: "pubkey-1"
        )

        await registry.removeConnectionRequest(peer1: "peer-1", peer2: "peer-2")

        // Creating a new request should succeed (old one was removed)
        let newRequest = await registry.createConnectionRequest(
            requesterId: "peer-1",
            targetId: "peer-2",
            requesterPublicKey: "pubkey-1"
        )
        XCTAssertNotNil(newRequest)

        try await channel1.close()
        try await channel2.close()
    }

    // MARK: - Touch Tests

    func testTouchUpdatesLastSeen() async throws {
        let registry = PeerRegistry()
        let channel = try await createMockChannel()

        _ = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel)

        let peer1 = await registry.getPeer("peer-1")
        let lastSeen1 = peer1?.lastSeen

        // Wait a tiny bit
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        await registry.touch(peerId: "peer-1")

        let peer2 = await registry.getPeer("peer-1")
        let lastSeen2 = peer2?.lastSeen

        XCTAssertNotNil(lastSeen1)
        XCTAssertNotNil(lastSeen2)
        XCTAssertGreaterThan(lastSeen2!, lastSeen1!)

        try await channel.close()
    }

    // MARK: - Channel Lookup Tests

    func testGetChannel() async throws {
        let registry = PeerRegistry()
        let channel = try await createMockChannel()

        _ = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel)

        let retrievedChannel = await registry.getChannel(for: "peer-1")
        XCTAssertNotNil(retrievedChannel)

        try await channel.close()
    }

    func testGetPeerByChannel() async throws {
        let registry = PeerRegistry()
        let channel = try await createMockChannel()

        _ = await registry.register(peerId: "peer-1", networkId: "network-1", channel: channel)

        let peer = await registry.getPeer(channel: channel)
        XCTAssertNotNil(peer)
        XCTAssertEqual(peer?.peerId, "peer-1")

        try await channel.close()
    }

    // MARK: - Helper Methods

    private func createMockChannel() async throws -> Channel {
        // Create a simple UDP channel for testing
        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        return try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    }
}
