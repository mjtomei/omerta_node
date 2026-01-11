import XCTest
@testable import OmertaNetwork
@testable import OmertaCore

final class DHTTests: XCTestCase {

    // MARK: - DHTPeerAnnouncement Tests

    func testDHTPeerAnnouncementCreation() throws {
        let (keypair, _) = IdentityKeypair.generate()

        let announcement = DHTPeerAnnouncement(
            identity: keypair.identity,
            capabilities: [DHTPeerAnnouncement.capabilityProvider],
            signalingAddresses: ["wss://signal.example.com"]
        )

        XCTAssertEqual(announcement.peerId, keypair.identity.peerId)
        XCTAssertEqual(announcement.publicKey, keypair.identity.publicKey)
        XCTAssertEqual(announcement.capabilities, [DHTPeerAnnouncement.capabilityProvider])
        XCTAssertFalse(announcement.isExpired)
    }

    func testAnnouncementSignature() throws {
        let (keypair, _) = IdentityKeypair.generate()

        let announcement = DHTPeerAnnouncement(
            identity: keypair.identity,
            capabilities: [DHTPeerAnnouncement.capabilityProvider],
            signalingAddresses: ["wss://signal.example.com"]
        )

        let signed = try announcement.signed(with: keypair)

        XCTAssertNotNil(signed.signature)
        XCTAssertTrue(signed.verify())
    }

    func testInvalidSignatureRejected() throws {
        let (keypair1, _) = IdentityKeypair.generate()
        let (keypair2, _) = IdentityKeypair.generate()

        // Create announcement for keypair1
        let announcement = DHTPeerAnnouncement(
            identity: keypair1.identity,
            capabilities: [DHTPeerAnnouncement.capabilityProvider],
            signalingAddresses: ["wss://signal.example.com"]
        )

        // Sign with keypair2 (wrong key)
        var tampered = announcement
        tampered = try DHTPeerAnnouncement(
            peerId: keypair1.identity.peerId,
            publicKey: keypair1.identity.publicKey,
            capabilities: announcement.capabilities,
            signalingAddresses: announcement.signalingAddresses,
            timestamp: announcement.timestamp,
            ttl: announcement.ttl,
            signature: try keypair2.sign("fake".data(using: .utf8)!).base64EncodedString()
        )

        XCTAssertFalse(tampered.verify())
    }

    func testAnnouncementExpiry() throws {
        let (keypair, _) = IdentityKeypair.generate()

        // Create an already-expired announcement
        let expired = DHTPeerAnnouncement(
            peerId: keypair.identity.peerId,
            publicKey: keypair.identity.publicKey,
            capabilities: [DHTPeerAnnouncement.capabilityProvider],
            signalingAddresses: ["wss://signal.example.com"],
            timestamp: Date().addingTimeInterval(-7200), // 2 hours ago
            ttl: 3600 // 1 hour TTL
        )

        XCTAssertTrue(expired.isExpired)
        XCTAssertEqual(expired.timeRemaining, 0)

        // Valid announcement should not be expired
        let valid = DHTPeerAnnouncement(
            identity: keypair.identity,
            capabilities: [DHTPeerAnnouncement.capabilityProvider],
            signalingAddresses: ["wss://signal.example.com"],
            ttl: 3600
        )

        XCTAssertFalse(valid.isExpired)
        XCTAssertGreaterThan(valid.timeRemaining, 0)
    }

    func testDHTKey() throws {
        let (keypair, _) = IdentityKeypair.generate()

        let announcement = DHTPeerAnnouncement(
            identity: keypair.identity,
            capabilities: [],
            signalingAddresses: []
        )

        let key = announcement.dhtKey
        XCTAssertEqual(key.count, 20) // DHT key is 160 bits = 20 bytes
    }

    // MARK: - KBucket Tests

    func testKBucketAddNode() {
        var bucket = KBucket(k: 3)

        let node1 = DHTNodeInfo(peerId: "a1b2c3d4e5f67890", address: "192.168.1.1", port: 4000)
        let node2 = DHTNodeInfo(peerId: "b1b2c3d4e5f67890", address: "192.168.1.2", port: 4000)
        let node3 = DHTNodeInfo(peerId: "c1b2c3d4e5f67890", address: "192.168.1.3", port: 4000)

        bucket.addOrUpdate(node1)
        bucket.addOrUpdate(node2)
        bucket.addOrUpdate(node3)

        XCTAssertEqual(bucket.count, 3)
        XCTAssertTrue(bucket.isFull)
        XCTAssertTrue(bucket.contains("a1b2c3d4e5f67890"))
    }

    func testKBucketEviction() {
        var bucket = KBucket(k: 2)

        let node1 = DHTNodeInfo(peerId: "a1b2c3d4e5f67890", address: "192.168.1.1", port: 4000)
        let node2 = DHTNodeInfo(peerId: "b1b2c3d4e5f67890", address: "192.168.1.2", port: 4000)
        let node3 = DHTNodeInfo(peerId: "c1b2c3d4e5f67890", address: "192.168.1.3", port: 4000)

        bucket.addOrUpdate(node1)
        bucket.addOrUpdate(node2)
        let evicted = bucket.addOrUpdate(node3)

        XCTAssertEqual(bucket.count, 2)
        XCTAssertEqual(evicted?.peerId, "a1b2c3d4e5f67890") // Oldest node evicted
        XCTAssertFalse(bucket.contains("a1b2c3d4e5f67890"))
        XCTAssertTrue(bucket.contains("c1b2c3d4e5f67890"))
    }

    func testKBucketUpdateMovesToEnd() {
        var bucket = KBucket(k: 3)

        let node1 = DHTNodeInfo(peerId: "a1b2c3d4e5f67890", address: "192.168.1.1", port: 4000)
        let node2 = DHTNodeInfo(peerId: "b1b2c3d4e5f67890", address: "192.168.1.2", port: 4000)

        bucket.addOrUpdate(node1)
        bucket.addOrUpdate(node2)

        // Update node1 - should move to end
        let updatedNode1 = DHTNodeInfo(peerId: "a1b2c3d4e5f67890", address: "192.168.1.100", port: 4001)
        bucket.addOrUpdate(updatedNode1)

        XCTAssertEqual(bucket.count, 2)
        XCTAssertEqual(bucket.nodes.last?.address, "192.168.1.100")
    }

    // MARK: - RoutingTable Tests

    func testRoutingTableXORDistance() {
        let a = Data([0x00, 0x00])
        let b = Data([0xFF, 0x00])

        let distance = RoutingTable.xorDistance(a, b)
        XCTAssertEqual(distance[0], 0xFF)
        XCTAssertEqual(distance[1], 0x00)
    }

    func testRoutingTableBucketIndex() {
        let localId = Data(repeating: 0, count: 20)
        let table = RoutingTable(localId: localId, k: 20)

        // Node with highest bit set in first byte
        var nodeId = Data(repeating: 0, count: 20)
        nodeId[0] = 0x80 // 10000000

        let index = table.bucketIndex(for: nodeId)
        XCTAssertEqual(index, 0) // Distance has bit 0 set (highest)

        // Node with second-highest bit set
        nodeId[0] = 0x40 // 01000000
        let index2 = table.bucketIndex(for: nodeId)
        XCTAssertEqual(index2, 1)
    }

    func testRoutingTableFindClosest() {
        let localId = Data(repeating: 0, count: 20)
        var table = RoutingTable(localId: localId, k: 20)

        // Add some nodes
        let node1 = DHTNodeInfo(peerId: "0100000000000000", address: "1.1.1.1", port: 4000)
        let node2 = DHTNodeInfo(peerId: "0200000000000000", address: "2.2.2.2", port: 4000)
        let node3 = DHTNodeInfo(peerId: "0300000000000000", address: "3.3.3.3", port: 4000)

        table.addOrUpdate(node1)
        table.addOrUpdate(node2)
        table.addOrUpdate(node3)

        // Find closest to 0100...
        var targetKey = Data(hexString: "0100000000000000") ?? Data()
        while targetKey.count < 20 { targetKey.append(0) }

        let closest = table.findClosest(to: targetKey, count: 2)
        XCTAssertEqual(closest.count, 2)
        XCTAssertEqual(closest.first?.peerId, "0100000000000000")
    }

    // MARK: - DHTMessage Tests

    func testDHTMessageEncodeDecode() throws {
        let node = DHTNodeInfo(peerId: "a1b2c3d4e5f67890", address: "192.168.1.1", port: 4000)
        let message = DHTMessage.foundNodes(nodes: [node], fromId: "sender123")
        let packet = DHTPacket(message: message)

        let encoded = try packet.encode()
        let decoded = try DHTPacket.decode(from: encoded)

        if case .foundNodes(let nodes, let fromId) = decoded.message {
            XCTAssertEqual(nodes.count, 1)
            XCTAssertEqual(nodes.first?.peerId, "a1b2c3d4e5f67890")
            XCTAssertEqual(fromId, "sender123")
        } else {
            XCTFail("Decoded message type mismatch")
        }
    }

    func testDHTPacketTransactionId() throws {
        let packet1 = DHTPacket(message: .ping(fromId: "test"))
        let packet2 = DHTPacket(message: .ping(fromId: "test"))

        // Each packet should have a unique transaction ID
        XCTAssertNotEqual(packet1.transactionId, packet2.transactionId)
    }

    // MARK: - DHTNode Tests

    func testDHTNodeCreation() async throws {
        let (keypair, _) = IdentityKeypair.generate()
        let config = DHTConfig(bootstrapNodes: [])

        let node = DHTNode(identity: keypair, config: config)
        let nodePeerId = await node.peerId
        XCTAssertEqual(nodePeerId, keypair.identity.peerId)
    }

    func testDHTNodeStoreAndRetrieve() async throws {
        let (keypair, _) = IdentityKeypair.generate()
        let config = DHTConfig(bootstrapNodes: [])

        let node = DHTNode(identity: keypair, config: config)
        try await node.start()

        // Create and sign an announcement
        let announcement = DHTPeerAnnouncement(
            identity: keypair.identity,
            capabilities: [DHTPeerAnnouncement.capabilityProvider],
            signalingAddresses: ["wss://test.example.com"]
        )
        let signed = try announcement.signed(with: keypair)

        // Store it
        await node.store(signed)

        // Retrieve stored announcements
        let stored = await node.storedAnnouncements
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.peerId, keypair.identity.peerId)

        await node.stop()
    }

    func testDHTNodeHandleMessage() async throws {
        let (keypair, _) = IdentityKeypair.generate()
        let config = DHTConfig(bootstrapNodes: [])

        let node = DHTNode(identity: keypair, config: config)

        let sender = DHTNodeInfo(peerId: "sender12345678", address: "192.168.1.1", port: 4000)
        let pingPacket = DHTPacket(message: .ping(fromId: sender.peerId))

        let response = await node.handleMessage(pingPacket, from: sender)

        XCTAssertNotNil(response)
        if case .pong(let fromId) = response?.message {
            XCTAssertEqual(fromId, keypair.identity.peerId)
        } else {
            XCTFail("Expected pong response")
        }
    }

    // MARK: - DHTTransport Integration Tests

    func testDHTTransportStartStop() async throws {
        let transport = DHTTransport(port: 0) // Use ephemeral port
        try await transport.start()

        let boundPort = await transport.boundPort
        XCTAssertGreaterThan(boundPort, 0)

        await transport.stop()
    }

    func testDHTTransportPingPong() async throws {
        // Create two transports
        let transport1 = DHTTransport(port: 0)
        let transport2 = DHTTransport(port: 0)

        try await transport1.start()
        try await transport2.start()

        let port1 = await transport1.boundPort
        let port2 = await transport2.boundPort

        // Set up message handler on transport2 to respond to pings
        await transport2.setMessageHandler { packet, sender in
            if case .ping(let fromId) = packet.message {
                return DHTPacket(
                    transactionId: packet.transactionId,
                    message: .pong(fromId: "responder")
                )
            }
            return nil
        }

        // Send ping from transport1 to transport2
        let pingPacket = DHTPacket(message: .ping(fromId: "sender"))
        let target = DHTNodeInfo(peerId: "responder", address: "127.0.0.1", port: port2)

        let response = try await transport1.sendRequest(pingPacket, to: target, timeout: 5.0)

        if case .pong(let fromId) = response.message {
            XCTAssertEqual(fromId, "responder")
        } else {
            XCTFail("Expected pong response, got \(response.message)")
        }

        await transport1.stop()
        await transport2.stop()
    }

    // Timeout test temporarily disabled - actor isolation issues with detached tasks
    // func testDHTTransportTimeout() async throws { ... }

    func testTwoNodesPingPong() async throws {
        // Create two DHT nodes
        let (keypair1, _) = IdentityKeypair.generate()
        let (keypair2, _) = IdentityKeypair.generate()

        let config1 = DHTConfig(port: 0, bootstrapNodes: [])
        let config2 = DHTConfig(port: 0, bootstrapNodes: [])

        let node1 = DHTNode(identity: keypair1, config: config1)
        let node2 = DHTNode(identity: keypair2, config: config2)

        try await node1.start()
        try await node2.start()

        let port1 = await node1.boundPort
        let port2 = await node2.boundPort

        XCTAssertGreaterThan(port1, 0)
        XCTAssertGreaterThan(port2, 0)

        // Ping from node1 to node2
        let node2Info = DHTNodeInfo(
            peerId: keypair2.identity.peerId,
            address: "127.0.0.1",
            port: port2
        )

        let success = await node1.ping(node2Info)
        XCTAssertTrue(success, "Ping from node1 to node2 should succeed")

        // Check that node1 added node2 to its routing table
        let routingTableCount = await node1.routingTableNodeCount
        XCTAssertEqual(routingTableCount, 1, "Node2 should be in node1's routing table")

        await node1.stop()
        await node2.stop()
    }

}
