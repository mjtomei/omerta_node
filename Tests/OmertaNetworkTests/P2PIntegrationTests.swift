// P2PIntegrationTests.swift
// Tests for P2P session, WireGuard relay, and VPN integration

import XCTest
@testable import OmertaNetwork
import OmertaCore

final class P2PIntegrationTests: XCTestCase {

    // MARK: - P2PConnectionMethod Tests

    func testConnectionMethodDescription() {
        let direct = P2PConnectionMethod.direct(endpoint: "1.2.3.4:51820")
        XCTAssertEqual(direct.description, "direct(1.2.3.4:51820)")
        XCTAssertEqual(direct.endpoint, "1.2.3.4:51820")
        XCTAssertFalse(direct.isRelayed)

        let holePunched = P2PConnectionMethod.holePunched(endpoint: "5.6.7.8:51821")
        XCTAssertEqual(holePunched.description, "hole-punched(5.6.7.8:51821)")
        XCTAssertEqual(holePunched.endpoint, "5.6.7.8:51821")
        XCTAssertFalse(holePunched.isRelayed)

        let relayed = P2PConnectionMethod.relayed(relayEndpoint: "relay.example.com:8080")
        XCTAssertEqual(relayed.description, "relayed(relay.example.com:8080)")
        XCTAssertEqual(relayed.endpoint, "relay.example.com:8080")
        XCTAssertTrue(relayed.isRelayed)
    }

    func testP2PConnectionResult() {
        let result = P2PConnectionResult(
            method: .holePunched(endpoint: "1.2.3.4:51820"),
            localEndpoint: "0.0.0.0:51820",
            remoteEndpoint: "1.2.3.4:51820",
            rtt: 0.025,
            natType: .fullCone
        )

        XCTAssertEqual(result.localEndpoint, "0.0.0.0:51820")
        XCTAssertEqual(result.remoteEndpoint, "1.2.3.4:51820")
        XCTAssertEqual(result.rtt, 0.025)
        XCTAssertEqual(result.natType, .fullCone)
        XCTAssertFalse(result.method.isRelayed)
    }

    // MARK: - P2PSessionConfig Tests

    func testP2PSessionConfigDefaults() {
        let config = P2PSessionConfig(
            peerId: "test-peer",
            networkId: "test-network",
            publicKey: "testkey123"
        )

        XCTAssertEqual(config.peerId, "test-peer")
        XCTAssertEqual(config.networkId, "test-network")
        XCTAssertEqual(config.publicKey, "testkey123")
        XCTAssertNil(config.rendezvousURL)
        XCTAssertEqual(config.localPort, 51820)
        XCTAssertTrue(config.enableNATTraversal)
        XCTAssertEqual(config.holePunchTimeout, 30.0)
        XCTAssertTrue(config.fallbackToRelay)
    }

    func testP2PSessionConfigWithRendezvous() {
        let url = URL(string: "ws://rendezvous.example.com:8080")!
        let config = P2PSessionConfig(
            peerId: "test-peer",
            networkId: "test-network",
            publicKey: "testkey123",
            rendezvousURL: url,
            localPort: 51821,
            enableNATTraversal: true,
            holePunchTimeout: 60.0,
            fallbackToRelay: false
        )

        XCTAssertEqual(config.rendezvousURL, url)
        XCTAssertEqual(config.localPort, 51821)
        XCTAssertTrue(config.enableNATTraversal)
        XCTAssertEqual(config.holePunchTimeout, 60.0)
        XCTAssertFalse(config.fallbackToRelay)
    }

    // MARK: - P2PSession Tests

    func testP2PSessionWithoutNATTraversal() async throws {
        let config = P2PSessionConfig(
            peerId: "test-peer",
            networkId: "test-network",
            publicKey: "testkey123",
            rendezvousURL: nil,
            enableNATTraversal: false
        )

        let session = P2PSession(config: config)

        // Should return placeholder endpoint when NAT traversal is disabled
        let endpoint = try await session.start()
        XCTAssertEqual(endpoint.address, "0.0.0.0")
        XCTAssertEqual(endpoint.port, 51820)
        XCTAssertEqual(endpoint.natType, .unknown)

        await session.stop()
    }

    func testP2PSessionDirectConnection() async throws {
        let config = P2PSessionConfig(
            peerId: "test-peer",
            networkId: "test-network",
            publicKey: "testkey123",
            rendezvousURL: nil,
            enableNATTraversal: false
        )

        let session = P2PSession(config: config)
        _ = try await session.start()

        // Connect with direct endpoint (no NAT traversal)
        let result = try await session.connectToPeer(
            peerId: "target-peer",
            directEndpoint: "192.168.1.100:51820"
        )

        XCTAssertEqual(result.remoteEndpoint, "192.168.1.100:51820")
        if case .direct(let endpoint) = result.method {
            XCTAssertEqual(endpoint, "192.168.1.100:51820")
        } else {
            XCTFail("Expected direct connection method")
        }

        // Verify connection is cached
        let cached = await session.getConnection(peerId: "target-peer")
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.remoteEndpoint, "192.168.1.100:51820")

        // Disconnect
        await session.disconnect(peerId: "target-peer")
        let afterDisconnect = await session.getConnection(peerId: "target-peer")
        XCTAssertNil(afterDisconnect)

        await session.stop()
    }

    // MARK: - P2PSessionError Tests

    func testP2PSessionErrorDescriptions() {
        XCTAssertEqual(
            P2PSessionError.notStarted.description,
            "P2P session not started"
        )
        XCTAssertEqual(
            P2PSessionError.peerNotFound("peer123").description,
            "Peer not found: peer123"
        )
        XCTAssertEqual(
            P2PSessionError.connectionFailed("timeout").description,
            "Connection failed: timeout"
        )
        XCTAssertEqual(
            P2PSessionError.relayRequired.description,
            "Relay required but not available"
        )
    }

    // MARK: - WireGuard Relay Tests

    func testRelayPacketEncapsulation() async {
        let sessionToken = Data([0x01, 0x02, 0x03, 0x04])
        let client = WireGuardRelayClient(
            relayEndpoint: "127.0.0.1:8080",
            sessionToken: sessionToken
        )

        // Test encapsulation
        let wgPacket = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        let encapsulated = await client.encapsulate(wgPacket)

        // Verify header
        XCTAssertEqual(encapsulated.count, WireGuardRelayClient.headerSize + wgPacket.count)
        XCTAssertEqual(Array(encapsulated.prefix(4)), [0x01, 0x02, 0x03, 0x04])  // Token

        // Verify length (big-endian)
        let lengthBytes = Array(encapsulated[4..<8])
        let length = UInt32(lengthBytes[0]) << 24 | UInt32(lengthBytes[1]) << 16 |
                     UInt32(lengthBytes[2]) << 8 | UInt32(lengthBytes[3])
        XCTAssertEqual(length, 5)

        // Verify payload
        XCTAssertEqual(Array(encapsulated[8...]), [0x10, 0x20, 0x30, 0x40, 0x50])
    }

    func testRelayPacketDecapsulation() async {
        let sessionToken = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let client = WireGuardRelayClient(
            relayEndpoint: "127.0.0.1:8080",
            sessionToken: sessionToken
        )

        // Create a valid encapsulated packet
        var packet = Data()
        packet.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])  // Token
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x03])  // Length = 3
        packet.append(contentsOf: [0x11, 0x22, 0x33])        // Payload

        let decapsulated = await client.decapsulate(packet)
        XCTAssertNotNil(decapsulated)
        XCTAssertEqual(Array(decapsulated!), [0x11, 0x22, 0x33])
    }

    func testRelayPacketDecapsulationInvalidToken() async {
        let sessionToken = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let client = WireGuardRelayClient(
            relayEndpoint: "127.0.0.1:8080",
            sessionToken: sessionToken
        )

        // Create packet with wrong token
        var packet = Data()
        packet.append(contentsOf: [0x11, 0x22, 0x33, 0x44])  // Wrong token
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x03])  // Length
        packet.append(contentsOf: [0x11, 0x22, 0x33])        // Payload

        let decapsulated = await client.decapsulate(packet)
        XCTAssertNil(decapsulated)
    }

    func testRelayPacketDecapsulationTooShort() async {
        let sessionToken = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let client = WireGuardRelayClient(
            relayEndpoint: "127.0.0.1:8080",
            sessionToken: sessionToken
        )

        // Packet too short (less than header size)
        let shortPacket = Data([0xAA, 0xBB, 0xCC])
        let decapsulated = await client.decapsulate(shortPacket)
        XCTAssertNil(decapsulated)
    }

    func testRelayPacketRoundTrip() async {
        let sessionToken = Data([0x12, 0x34, 0x56, 0x78])
        let client = WireGuardRelayClient(
            relayEndpoint: "127.0.0.1:8080",
            sessionToken: sessionToken
        )

        // Original WireGuard packet
        let original = Data((0..<100).map { UInt8($0) })

        // Encapsulate then decapsulate
        let encapsulated = await client.encapsulate(original)
        let decapsulated = await client.decapsulate(encapsulated)

        XCTAssertNotNil(decapsulated)
        XCTAssertEqual(decapsulated, original)
    }

    func testRelayHeaderSize() {
        XCTAssertEqual(WireGuardRelayClient.headerSize, 8)
    }

    // MARK: - WireGuardRelayError Tests

    func testWireGuardRelayErrorDescriptions() {
        XCTAssertEqual(
            WireGuardRelayError.notConnected.description,
            "Not connected to relay"
        )
        XCTAssertEqual(
            WireGuardRelayError.invalidEndpoint("bad:endpoint:format").description,
            "Invalid endpoint: bad:endpoint:format"
        )
        XCTAssertEqual(
            WireGuardRelayError.encapsulationFailed.description,
            "Failed to encapsulate packet"
        )
        XCTAssertEqual(
            WireGuardRelayError.decapsulationFailed.description,
            "Failed to decapsulate packet"
        )
    }

    // MARK: - P2PVPNConfiguration Tests

    func testP2PVPNConfiguration() {
        let baseConfig = VPNConfiguration(
            consumerPublicKey: "consumer-key-123",
            consumerEndpoint: "192.168.1.1:51820",
            consumerVPNIP: "10.0.0.1",
            vmVPNIP: "10.0.0.2",
            vpnSubnet: "10.0.0.0/24"
        )

        let p2pConfig = P2PVPNConfiguration(
            baseConfig: baseConfig,
            connectionMethod: .holePunched(endpoint: "5.6.7.8:51820"),
            actualEndpoint: "5.6.7.8:51820",
            natType: .restrictedCone
        )

        XCTAssertEqual(p2pConfig.consumerPublicKey, "consumer-key-123")
        XCTAssertEqual(p2pConfig.consumerEndpoint, "5.6.7.8:51820")
        XCTAssertEqual(p2pConfig.consumerVPNIP, "10.0.0.1")
        XCTAssertEqual(p2pConfig.vmVPNIP, "10.0.0.2")
        XCTAssertEqual(p2pConfig.vpnSubnet, "10.0.0.0/24")
        XCTAssertEqual(p2pConfig.natType, .restrictedCone)
        XCTAssertFalse(p2pConfig.isRelayed)
    }

    func testP2PVPNConfigurationRelayed() {
        let baseConfig = VPNConfiguration(
            consumerPublicKey: "consumer-key-123",
            consumerEndpoint: "192.168.1.1:51820",
            consumerVPNIP: "10.0.0.1",
            vmVPNIP: "10.0.0.2",
            vpnSubnet: "10.0.0.0/24"
        )

        let p2pConfig = P2PVPNConfiguration(
            baseConfig: baseConfig,
            connectionMethod: .relayed(relayEndpoint: "relay.example.com:8080"),
            actualEndpoint: "127.0.0.1:51900",
            natType: .symmetric
        )

        XCTAssertTrue(p2pConfig.isRelayed)
        XCTAssertEqual(p2pConfig.consumerEndpoint, "127.0.0.1:51900")
        XCTAssertEqual(p2pConfig.natType, .symmetric)
    }

    // MARK: - P2PVPNManager Tests

    func testP2PVPNManagerCreation() async {
        let manager = P2PVPNManager(basePort: 52000, dryRun: true)

        // Without P2P session, should return unknown NAT type
        let natType = await manager.natType
        XCTAssertEqual(natType, .unknown)

        // No public endpoint without session
        let endpoint = await manager.publicEndpoint
        XCTAssertNil(endpoint)
    }

    // MARK: - Integration Scenarios

    func testDirectConnectionScenario() async throws {
        // Scenario: Consumer connects directly to provider (no NAT)
        let config = P2PSessionConfig(
            peerId: "consumer-123",
            networkId: "network-abc",
            publicKey: "consumer-pubkey",
            enableNATTraversal: false
        )

        let session = P2PSession(config: config)
        _ = try await session.start()

        // Simulate provider endpoint discovery
        let providerEndpoint = "10.0.0.100:51820"

        let result = try await session.connectToPeer(
            peerId: "provider-456",
            directEndpoint: providerEndpoint
        )

        XCTAssertEqual(result.remoteEndpoint, providerEndpoint)
        if case .direct(let endpoint) = result.method {
            XCTAssertEqual(endpoint, providerEndpoint)
        } else {
            XCTFail("Expected direct connection")
        }

        await session.stop()
    }

    func testMultiplePeerConnections() async throws {
        // Test connecting to multiple peers
        let config = P2PSessionConfig(
            peerId: "consumer-123",
            networkId: "network-abc",
            publicKey: "consumer-pubkey",
            enableNATTraversal: false
        )

        let session = P2PSession(config: config)
        _ = try await session.start()

        // Connect to peer 1
        let result1 = try await session.connectToPeer(
            peerId: "provider-1",
            directEndpoint: "10.0.0.1:51820"
        )
        XCTAssertEqual(result1.remoteEndpoint, "10.0.0.1:51820")

        // Connect to peer 2
        let result2 = try await session.connectToPeer(
            peerId: "provider-2",
            directEndpoint: "10.0.0.2:51820"
        )
        XCTAssertEqual(result2.remoteEndpoint, "10.0.0.2:51820")

        // Both connections should be cached
        let cached1 = await session.getConnection(peerId: "provider-1")
        let cached2 = await session.getConnection(peerId: "provider-2")
        XCTAssertNotNil(cached1)
        XCTAssertNotNil(cached2)

        // Reusing existing connection should return same result
        let reused = try await session.connectToPeer(
            peerId: "provider-1",
            directEndpoint: "10.0.0.1:51820"
        )
        XCTAssertEqual(reused.remoteEndpoint, result1.remoteEndpoint)

        await session.stop()
    }

    // MARK: - Relay Packet Stress Test

    func testRelayPacketVariousSizes() async {
        let sessionToken = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let client = WireGuardRelayClient(
            relayEndpoint: "127.0.0.1:8080",
            sessionToken: sessionToken
        )

        // Test various packet sizes
        let sizes = [0, 1, 100, 1000, 1500, 65535]

        for size in sizes {
            let original = Data((0..<size).map { UInt8($0 % 256) })
            let encapsulated = await client.encapsulate(original)
            let decapsulated = await client.decapsulate(encapsulated)

            XCTAssertNotNil(decapsulated, "Failed for size \(size)")
            XCTAssertEqual(decapsulated?.count, size, "Size mismatch for \(size)")
            if size > 0 {
                XCTAssertEqual(decapsulated, original, "Content mismatch for size \(size)")
            }
        }
    }
}

// MARK: - NATType Extension for Testing

extension NATType: Equatable {
    public static func == (lhs: NATType, rhs: NATType) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}
