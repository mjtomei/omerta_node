// RelayServerTests.swift
// Tests for relay server

import XCTest
@testable import OmertaRendezvousLib

final class RelayServerTests: XCTestCase {

    // MARK: - Relay Session Tests

    func testRelaySessionCreation() {
        let session = RelaySession(peer1: "peer-1", peer2: "peer-2", ttl: 300)

        XCTAssertFalse(session.token.isEmpty)
        XCTAssertEqual(session.peer1, "peer-1")
        XCTAssertEqual(session.peer2, "peer-2")
        XCTAssertFalse(session.isExpired)
        XCTAssertNil(session.peer1Endpoint)
        XCTAssertNil(session.peer2Endpoint)
    }

    func testRelaySessionExpiration() {
        // Create session with very short TTL
        let session = RelaySession(peer1: "peer-1", peer2: "peer-2", ttl: -1) // Already expired

        XCTAssertTrue(session.isExpired)
    }

    func testRelaySessionTokenUniqueness() {
        let session1 = RelaySession(peer1: "peer-1", peer2: "peer-2")
        let session2 = RelaySession(peer1: "peer-1", peer2: "peer-2")

        XCTAssertNotEqual(session1.token, session2.token)
    }

    // MARK: - Relay Protocol Tests

    func testParseRelayHeaderRegister() {
        var packet = Data()
        packet.append(0x01) // Register message type
        let token = "12345678-1234-1234-1234-123456789012" // 36 character UUID
        packet.append(token.data(using: .utf8)!)
        packet.append("peer-id".data(using: .utf8)!)

        let result = RelayServer.parseRelayHeader(packet)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .register)
        XCTAssertEqual(result?.token, token)
        XCTAssertEqual(String(data: result!.payload, encoding: .utf8), "peer-id")
    }

    func testParseRelayHeaderData() {
        var packet = Data()
        packet.append(0x02) // Data message type
        let token = "12345678-1234-1234-1234-123456789012"
        packet.append(token.data(using: .utf8)!)
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        packet.append(payload)

        let result = RelayServer.parseRelayHeader(packet)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .data)
        XCTAssertEqual(result?.token, token)
        XCTAssertEqual(result?.payload, payload)
    }

    func testParseRelayHeaderKeepalive() {
        var packet = Data()
        packet.append(0x03) // Keepalive message type
        let token = "12345678-1234-1234-1234-123456789012"
        packet.append(token.data(using: .utf8)!)

        let result = RelayServer.parseRelayHeader(packet)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .keepalive)
        XCTAssertEqual(result?.token, token)
        XCTAssertTrue(result?.payload.isEmpty ?? false)
    }

    func testParseRelayHeaderTooShort() {
        let packet = Data([0x01, 0x02, 0x03]) // Only 3 bytes, need at least 37

        let result = RelayServer.parseRelayHeader(packet)
        XCTAssertNil(result)
    }

    func testParseRelayHeaderInvalidType() {
        var packet = Data()
        packet.append(0xFF) // Invalid message type
        let token = "12345678-1234-1234-1234-123456789012"
        packet.append(token.data(using: .utf8)!)

        let result = RelayServer.parseRelayHeader(packet)
        XCTAssertNil(result)
    }

    // MARK: - Relay Packet Creation Tests

    func testCreateRelayPacket() {
        let token = "12345678-1234-1234-1234-123456789012"
        let payload = Data([0x01, 0x02, 0x03, 0x04])

        let packet = RelayServer.createRelayPacket(token: token, payload: payload)

        XCTAssertEqual(packet.count, 1 + 36 + 4) // type + token + payload
        XCTAssertEqual(packet[0], 0x02) // Data type

        // Verify token
        let tokenData = packet[1..<37]
        XCTAssertEqual(String(data: tokenData, encoding: .utf8), token)

        // Verify payload
        let payloadData = packet[37...]
        XCTAssertEqual(Data(payloadData), payload)
    }

    func testCreateRegisterPacket() {
        let token = "12345678-1234-1234-1234-123456789012"
        let peerId = "my-peer-id"

        let packet = RelayServer.createRegisterPacket(token: token, peerId: peerId)

        XCTAssertEqual(packet[0], 0x01) // Register type

        // Verify token
        let tokenData = packet[1..<37]
        XCTAssertEqual(String(data: tokenData, encoding: .utf8), token)

        // Verify peer ID
        let peerIdData = packet[37...]
        XCTAssertEqual(String(data: peerIdData, encoding: .utf8), peerId)
    }

    // MARK: - Round-trip Tests

    func testRelayPacketRoundTrip() {
        let token = "12345678-1234-1234-1234-123456789012"
        let originalPayload = Data([0xCA, 0xFE, 0xBA, 0xBE])

        let packet = RelayServer.createRelayPacket(token: token, payload: originalPayload)
        let parsed = RelayServer.parseRelayHeader(packet)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.type, .data)
        XCTAssertEqual(parsed?.token, token)
        XCTAssertEqual(parsed?.payload, originalPayload)
    }

    func testRegisterPacketRoundTrip() {
        let token = "12345678-1234-1234-1234-123456789012"
        let peerId = "test-peer-123"

        let packet = RelayServer.createRegisterPacket(token: token, peerId: peerId)
        let parsed = RelayServer.parseRelayHeader(packet)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.type, .register)
        XCTAssertEqual(parsed?.token, token)
        XCTAssertEqual(String(data: parsed!.payload, encoding: .utf8), peerId)
    }

    // MARK: - Relay Server Actor Tests

    func testRelayServerCreateSession() async {
        let server = RelayServer(port: 0, sessionTTL: 300)

        let session = await server.createSession(peer1: "peer-1", peer2: "peer-2")

        XCTAssertEqual(session.peer1, "peer-1")
        XCTAssertEqual(session.peer2, "peer-2")
        XCTAssertFalse(session.token.isEmpty)
    }

    func testRelayServerGetSession() async {
        let server = RelayServer(port: 0, sessionTTL: 300)

        let created = await server.createSession(peer1: "peer-1", peer2: "peer-2")
        let retrieved = await server.getSession(token: created.token)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.token, created.token)
        XCTAssertEqual(retrieved?.peer1, created.peer1)
        XCTAssertEqual(retrieved?.peer2, created.peer2)
    }

    func testRelayServerGetInvalidSession() async {
        let server = RelayServer(port: 0, sessionTTL: 300)

        let session = await server.getSession(token: "invalid-token")
        XCTAssertNil(session)
    }

    func testRelayServerSessionCount() async {
        let server = RelayServer(port: 0, sessionTTL: 300)

        let count1 = await server.sessionCount
        XCTAssertEqual(count1, 0)

        _ = await server.createSession(peer1: "peer-1", peer2: "peer-2")
        let count2 = await server.sessionCount
        XCTAssertEqual(count2, 1)

        _ = await server.createSession(peer1: "peer-3", peer2: "peer-4")
        let count3 = await server.sessionCount
        XCTAssertEqual(count3, 2)
    }
}
