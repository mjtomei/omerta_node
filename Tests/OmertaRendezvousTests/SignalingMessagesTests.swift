// SignalingMessagesTests.swift
// Tests for signaling protocol message encoding/decoding

import XCTest
@testable import OmertaRendezvousLib

final class SignalingMessagesTests: XCTestCase {

    // MARK: - ClientMessage Tests

    func testClientMessageRegisterEncoding() throws {
        let message = ClientMessage.register(peerId: "peer-123", networkId: "network-abc")

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "register")
        XCTAssertEqual(json["peerId"] as? String, "peer-123")
        XCTAssertEqual(json["networkId"] as? String, "network-abc")
    }

    func testClientMessageRegisterDecoding() throws {
        let json = """
        {"type": "register", "peerId": "peer-123", "networkId": "network-abc"}
        """

        let decoder = JSONDecoder()
        let message = try decoder.decode(ClientMessage.self, from: json.data(using: .utf8)!)

        if case .register(let peerId, let networkId) = message {
            XCTAssertEqual(peerId, "peer-123")
            XCTAssertEqual(networkId, "network-abc")
        } else {
            XCTFail("Expected register message")
        }
    }

    func testClientMessageRequestConnectionEncoding() throws {
        let message = ClientMessage.requestConnection(targetPeerId: "target-peer", myPublicKey: "pubkey123")

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "requestConnection")
        XCTAssertEqual(json["targetPeerId"] as? String, "target-peer")
        XCTAssertEqual(json["myPublicKey"] as? String, "pubkey123")
    }

    func testClientMessageReportEndpointEncoding() throws {
        let message = ClientMessage.reportEndpoint(endpoint: "192.168.1.1:5000", natType: .portRestrictedCone)

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "reportEndpoint")
        XCTAssertEqual(json["endpoint"] as? String, "192.168.1.1:5000")
        XCTAssertEqual(json["natType"] as? String, "portRestrictedCone")
    }

    func testClientMessageHolePunchResultEncoding() throws {
        let message = ClientMessage.holePunchResult(targetPeerId: "target", success: true, actualEndpoint: "10.0.0.1:6000")

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "holePunchResult")
        XCTAssertEqual(json["targetPeerId"] as? String, "target")
        XCTAssertEqual(json["success"] as? Bool, true)
        XCTAssertEqual(json["actualEndpoint"] as? String, "10.0.0.1:6000")
    }

    func testClientMessagePingEncoding() throws {
        let message = ClientMessage.ping

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "ping")
    }

    // MARK: - ServerMessage Tests

    func testServerMessageRegisteredEncoding() throws {
        let date = Date(timeIntervalSince1970: 1704067200) // 2024-01-01 00:00:00 UTC
        let message = ServerMessage.registered(serverTime: date)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "registered")
        XCTAssertNotNil(json["serverTime"])
    }

    func testServerMessagePeerEndpointEncoding() throws {
        let message = ServerMessage.peerEndpoint(
            peerId: "peer-456",
            endpoint: "203.0.113.1:8000",
            natType: .symmetric,
            publicKey: "key123"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "peerEndpoint")
        XCTAssertEqual(json["peerId"] as? String, "peer-456")
        XCTAssertEqual(json["endpoint"] as? String, "203.0.113.1:8000")
        XCTAssertEqual(json["natType"] as? String, "symmetric")
        XCTAssertEqual(json["publicKey"] as? String, "key123")
    }

    func testServerMessageHolePunchStrategyEncoding() throws {
        let message = ServerMessage.holePunchStrategy(.simultaneous)

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "holePunchStrategy")
        XCTAssertEqual(json["strategy"] as? String, "simultaneous")
    }

    func testServerMessageRelayAssignedEncoding() throws {
        let message = ServerMessage.relayAssigned(relayEndpoint: "relay.example.com:3479", relayToken: "token-xyz")

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "relayAssigned")
        XCTAssertEqual(json["relayEndpoint"] as? String, "relay.example.com:3479")
        XCTAssertEqual(json["relayToken"] as? String, "token-xyz")
    }

    func testServerMessageErrorEncoding() throws {
        let message = ServerMessage.error(message: "Connection failed")

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "error")
        XCTAssertEqual(json["message"] as? String, "Connection failed")
    }

    // MARK: - NATType Tests

    func testNATTypeValues() {
        XCTAssertEqual(NATType.fullCone.rawValue, "fullCone")
        XCTAssertEqual(NATType.restrictedCone.rawValue, "restrictedCone")
        XCTAssertEqual(NATType.portRestrictedCone.rawValue, "portRestrictedCone")
        XCTAssertEqual(NATType.symmetric.rawValue, "symmetric")
        XCTAssertEqual(NATType.unknown.rawValue, "unknown")
    }

    // MARK: - HolePunchStrategy Tests

    func testHolePunchStrategyValues() {
        XCTAssertEqual(HolePunchStrategy.simultaneous.rawValue, "simultaneous")
        XCTAssertEqual(HolePunchStrategy.youInitiate.rawValue, "youInitiate")
        XCTAssertEqual(HolePunchStrategy.peerInitiates.rawValue, "peerInitiates")
        XCTAssertEqual(HolePunchStrategy.relay.rawValue, "relay")
    }

    // MARK: - Round-trip Tests

    func testClientMessageRoundTrip() throws {
        let messages: [ClientMessage] = [
            .register(peerId: "p1", networkId: "n1"),
            .requestConnection(targetPeerId: "t1", myPublicKey: "k1"),
            .reportEndpoint(endpoint: "1.2.3.4:5000", natType: .fullCone),
            .holePunchReady,
            .holePunchSent(newEndpoint: "5.6.7.8:9000"),
            .holePunchResult(targetPeerId: "t2", success: false, actualEndpoint: nil),
            .requestRelay(targetPeerId: "t3"),
            .ping
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()

        for original in messages {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ClientMessage.self, from: data)

            // Re-encode to compare with sorted keys for deterministic output
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(data, reencoded, "Round-trip failed for \(original)")
        }
    }

    func testServerMessageRoundTrip() throws {
        let date = Date()
        let messages: [ServerMessage] = [
            .registered(serverTime: date),
            .peerEndpoint(peerId: "p1", endpoint: "1.2.3.4:5000", natType: .fullCone, publicKey: "k1"),
            .holePunchStrategy(.simultaneous),
            .holePunchNow(targetEndpoint: "5.6.7.8:9000"),
            .holePunchInitiate(targetEndpoint: "1.1.1.1:2000"),
            .holePunchWait,
            .holePunchContinue(newEndpoint: "2.2.2.2:4000"),
            .relayAssigned(relayEndpoint: "relay:3479", relayToken: "tok"),
            .pong,
            .error(message: "test error")
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for original in messages {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ServerMessage.self, from: data)

            // Re-encode to compare with sorted keys for deterministic output
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(data, reencoded, "Round-trip failed for \(original)")
        }
    }
}
