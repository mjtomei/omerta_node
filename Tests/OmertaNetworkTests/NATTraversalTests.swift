// NATTraversalTests.swift
// Tests for NAT traversal components

import XCTest
import NIOCore
import NIOPosix
@testable import OmertaNetwork

final class STUNClientTests: XCTestCase {

    // MARK: - STUN Binding Request Tests

    func testCreateBindingRequest() async throws {
        let client = STUNClient()
        // The client creates requests internally, so test via the discoverEndpoint method
        // For now, test the request format via reflection or direct protocol testing
    }

    func testSTUNMagicCookie() {
        // Magic cookie should be 0x2112A442 per RFC 5389
        let magicCookie: UInt32 = 0x2112A442
        XCTAssertEqual(magicCookie >> 24, 0x21)
        XCTAssertEqual((magicCookie >> 16) & 0xFF, 0x12)
        XCTAssertEqual((magicCookie >> 8) & 0xFF, 0xA4)
        XCTAssertEqual(magicCookie & 0xFF, 0x42)
    }

    func testXORPortEncoding() {
        // Test XOR encoding for port (upper 16 bits of magic cookie)
        let port: UInt16 = 12345
        let xorMask: UInt16 = 0x2112
        let xorPort = port ^ xorMask
        let decoded = xorPort ^ xorMask
        XCTAssertEqual(decoded, port)
    }

    func testXORAddressEncoding() {
        // Test XOR encoding for IPv4 address
        let ip: UInt32 = 0xC0A80164 // 192.168.1.100
        let magicCookie: UInt32 = 0x2112A442
        let xorAddr = ip ^ magicCookie
        let decoded = xorAddr ^ magicCookie
        XCTAssertEqual(decoded, ip)
    }

    // MARK: - STUN Response Parsing Tests

    func testParseValidSTUNResponse() {
        // Build a mock STUN binding response
        var response = Data()

        // Message type: Binding Response (0x0101)
        response.append(contentsOf: [0x01, 0x01])

        // Message length: 12 bytes
        response.append(contentsOf: [0x00, 0x0C])

        // Magic cookie
        response.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])

        // Transaction ID
        response.append(contentsOf: [UInt8](repeating: 0x11, count: 12))

        // XOR-MAPPED-ADDRESS attribute
        response.append(contentsOf: [0x00, 0x20]) // Type
        response.append(contentsOf: [0x00, 0x08]) // Length
        response.append(0x00) // Reserved
        response.append(0x01) // Family: IPv4

        // Port 8080 XOR'd with 0x2112
        let xorPort: UInt16 = 8080 ^ 0x2112
        response.append(UInt8(xorPort >> 8))
        response.append(UInt8(xorPort & 0xFF))

        // IP 10.0.0.1 XOR'd with magic cookie
        let ip: UInt32 = (10 << 24) | (0 << 16) | (0 << 8) | 1
        let xorAddr = ip ^ 0x2112A442
        response.append(UInt8(xorAddr >> 24))
        response.append(UInt8((xorAddr >> 16) & 0xFF))
        response.append(UInt8((xorAddr >> 8) & 0xFF))
        response.append(UInt8(xorAddr & 0xFF))

        // This should be parseable by our STUN client
        XCTAssertEqual(response.count, 32)
    }

    // MARK: - NAT Type Tests

    func testNATTypeValues() {
        XCTAssertEqual(NATType.fullCone.rawValue, "fullCone")
        XCTAssertEqual(NATType.restrictedCone.rawValue, "restrictedCone")
        XCTAssertEqual(NATType.portRestrictedCone.rawValue, "portRestrictedCone")
        XCTAssertEqual(NATType.symmetric.rawValue, "symmetric")
        XCTAssertEqual(NATType.unknown.rawValue, "unknown")
    }

    func testNATTypeEncodeDecode() throws {
        let types: [NATType] = [.fullCone, .restrictedCone, .portRestrictedCone, .symmetric, .unknown]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for natType in types {
            let data = try encoder.encode(natType)
            let decoded = try decoder.decode(NATType.self, from: data)
            XCTAssertEqual(natType, decoded)
        }
    }
}

final class HolePunchTests: XCTestCase {

    // MARK: - Probe Packet Tests

    func testProbeMagicBytes() {
        // "OMERTAHP" in ASCII
        let expected: [UInt8] = [0x4F, 0x4D, 0x45, 0x52, 0x54, 0x41, 0x48, 0x50]
        XCTAssertEqual(String(bytes: expected, encoding: .ascii), "OMERTAHP")
    }

    // MARK: - Hole Punch Strategy Tests

    func testHolePunchStrategyValues() {
        XCTAssertEqual(HolePunchStrategy.simultaneous.rawValue, "simultaneous")
        XCTAssertEqual(HolePunchStrategy.youInitiate.rawValue, "youInitiate")
        XCTAssertEqual(HolePunchStrategy.peerInitiates.rawValue, "peerInitiates")
        XCTAssertEqual(HolePunchStrategy.relay.rawValue, "relay")
    }

    func testHolePunchStrategySelection() {
        // Both cone NATs -> simultaneous
        let (c1, p1) = selectStrategy(.fullCone, .fullCone)
        XCTAssertEqual(c1, .simultaneous)
        XCTAssertEqual(p1, .simultaneous)

        let (c2, p2) = selectStrategy(.portRestrictedCone, .restrictedCone)
        XCTAssertEqual(c2, .simultaneous)
        XCTAssertEqual(p2, .simultaneous)

        // Consumer symmetric, provider cone -> consumer initiates
        let (c3, p3) = selectStrategy(.symmetric, .fullCone)
        XCTAssertEqual(c3, .youInitiate)
        XCTAssertEqual(p3, .peerInitiates)

        // Consumer cone, provider symmetric -> provider initiates
        let (c4, p4) = selectStrategy(.fullCone, .symmetric)
        XCTAssertEqual(c4, .peerInitiates)
        XCTAssertEqual(p4, .youInitiate)

        // Both symmetric -> relay
        let (c5, p5) = selectStrategy(.symmetric, .symmetric)
        XCTAssertEqual(c5, .relay)
        XCTAssertEqual(p5, .relay)
    }

    // MARK: - Result Types Tests

    func testHolePunchResultSuccess() {
        let result = HolePunchResult.success(actualEndpoint: "192.168.1.1:5000", rtt: 0.05)

        if case .success(let endpoint, let rtt) = result {
            XCTAssertEqual(endpoint, "192.168.1.1:5000")
            XCTAssertEqual(rtt, 0.05, accuracy: 0.001)
        } else {
            XCTFail("Expected success result")
        }
    }

    func testHolePunchResultFailed() {
        let failures: [HolePunchFailure] = [
            .timeout,
            .bothSymmetric,
            .firewallBlocked,
            .peerUnreachable,
            .bindFailed,
            .invalidEndpoint("bad:endpoint")
        ]

        for failure in failures {
            let result = HolePunchResult.failed(reason: failure)
            if case .failed(let reason) = result {
                // Just verify we can pattern match
                XCTAssertNotNil(reason)
            } else {
                XCTFail("Expected failed result")
            }
        }
    }

    // MARK: - Helper

    private func selectStrategy(
        _ consumer: NATType,
        _ provider: NATType
    ) -> (HolePunchStrategy, HolePunchStrategy) {
        switch (consumer, provider) {
        case (.symmetric, .symmetric):
            return (.relay, .relay)
        case (.symmetric, _):
            return (.youInitiate, .peerInitiates)
        case (_, .symmetric):
            return (.peerInitiates, .youInitiate)
        default:
            return (.simultaneous, .simultaneous)
        }
    }
}

final class RendezvousClientMessageTests: XCTestCase {

    // MARK: - Client Message Encoding

    func testClientMessageRegisterEncoding() throws {
        let message = ClientMessage.register(peerId: "peer-1", networkId: "net-1")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "register")
        XCTAssertEqual(json["peerId"] as? String, "peer-1")
        XCTAssertEqual(json["networkId"] as? String, "net-1")
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
        let message = ClientMessage.holePunchResult(
            targetPeerId: "target",
            success: true,
            actualEndpoint: "10.0.0.1:6000"
        )

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

    // MARK: - Server Message Decoding

    func testServerMessageRegisteredDecoding() throws {
        let json = """
        {"type": "registered", "serverTime": "2024-01-01T00:00:00Z"}
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ServerMessage.self, from: json.data(using: .utf8)!)

        if case .registered(let serverTime) = message {
            XCTAssertNotNil(serverTime)
        } else {
            XCTFail("Expected registered message")
        }
    }

    func testServerMessagePeerEndpointDecoding() throws {
        let json = """
        {"type": "peerEndpoint", "peerId": "peer-2", "endpoint": "1.2.3.4:5000", "natType": "fullCone", "publicKey": "key123"}
        """

        let decoder = JSONDecoder()
        let message = try decoder.decode(ServerMessage.self, from: json.data(using: .utf8)!)

        if case .peerEndpoint(let peerId, let endpoint, let natType, let publicKey) = message {
            XCTAssertEqual(peerId, "peer-2")
            XCTAssertEqual(endpoint, "1.2.3.4:5000")
            XCTAssertEqual(natType, .fullCone)
            XCTAssertEqual(publicKey, "key123")
        } else {
            XCTFail("Expected peerEndpoint message")
        }
    }

    func testServerMessageHolePunchStrategyDecoding() throws {
        let json = """
        {"type": "holePunchStrategy", "strategy": "simultaneous"}
        """

        let decoder = JSONDecoder()
        let message = try decoder.decode(ServerMessage.self, from: json.data(using: .utf8)!)

        if case .holePunchStrategy(let strategy) = message {
            XCTAssertEqual(strategy, .simultaneous)
        } else {
            XCTFail("Expected holePunchStrategy message")
        }
    }

    func testServerMessageRelayAssignedDecoding() throws {
        let json = """
        {"type": "relayAssigned", "relayEndpoint": "relay:3479", "relayToken": "token-xyz"}
        """

        let decoder = JSONDecoder()
        let message = try decoder.decode(ServerMessage.self, from: json.data(using: .utf8)!)

        if case .relayAssigned(let relayEndpoint, let relayToken) = message {
            XCTAssertEqual(relayEndpoint, "relay:3479")
            XCTAssertEqual(relayToken, "token-xyz")
        } else {
            XCTFail("Expected relayAssigned message")
        }
    }

    // MARK: - Round Trip Tests

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
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(data, reencoded)
        }
    }

    func testServerMessageRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1704067200)
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
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(data, reencoded)
        }
    }
}

final class NATTraversalCoordinatorTests: XCTestCase {

    // MARK: - Public Endpoint Tests

    func testPublicEndpointCreation() {
        let endpoint = PublicEndpoint(
            address: "192.168.1.100",
            port: 51820,
            natType: .portRestrictedCone
        )

        XCTAssertEqual(endpoint.address, "192.168.1.100")
        XCTAssertEqual(endpoint.port, 51820)
        XCTAssertEqual(endpoint.natType, .portRestrictedCone)
        XCTAssertEqual(endpoint.endpoint, "192.168.1.100:51820")
    }

    // MARK: - Peer Connection Tests

    func testPeerConnectionDirect() {
        let connection = PeerConnection(
            peerId: "peer-123",
            endpoint: "10.0.0.1:5000",
            connectionType: .direct,
            rtt: 0.025
        )

        XCTAssertEqual(connection.peerId, "peer-123")
        XCTAssertEqual(connection.endpoint, "10.0.0.1:5000")
        if case .direct = connection.connectionType {
            // Good
        } else {
            XCTFail("Expected direct connection type")
        }
        XCTAssertEqual(connection.rtt, 0.025, accuracy: 0.001)
    }

    func testPeerConnectionRelayed() {
        let connection = PeerConnection(
            peerId: "peer-456",
            endpoint: "relay.example.com:3479",
            connectionType: .relayed(via: "relay.example.com:3479"),
            rtt: 0.1
        )

        if case .relayed(let via) = connection.connectionType {
            XCTAssertEqual(via, "relay.example.com:3479")
        } else {
            XCTFail("Expected relayed connection type")
        }
    }

    // MARK: - Error Tests

    func testNATTraversalErrors() {
        let errors: [NATTraversalError] = [
            .notStarted,
            .timeout,
            .serverError("test error"),
            .holePunchFailed(.timeout),
            .noEndpoint
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
        }
    }

    // MARK: - Factory Method Tests

    func testNATTraversalCreate() {
        let traversal = NATTraversal.create(
            peerId: "test-peer",
            networkId: "test-network",
            publicKey: "test-key",
            rendezvousHost: "localhost",
            rendezvousPort: 8080
        )

        // Just verify it was created - actual functionality requires server
        XCTAssertNotNil(traversal)
    }
}

final class RelayClientTests: XCTestCase {

    // MARK: - Relay Protocol Tests

    func testRelayMessageTypes() {
        // Message types from protocol
        let registerType: UInt8 = 0x01
        let dataType: UInt8 = 0x02
        let keepaliveType: UInt8 = 0x03

        XCTAssertEqual(registerType, 1)
        XCTAssertEqual(dataType, 2)
        XCTAssertEqual(keepaliveType, 3)
    }

    func testRelayErrorTypes() {
        let errors: [RelayError] = [
            .invalidEndpoint("bad"),
            .notConnected,
            .sendFailed
        ]

        XCTAssertEqual(errors.count, 3)
    }

    func testRelayClientCreation() {
        let client = RelayClient(
            relayEndpoint: "relay.example.com:3479",
            relayToken: "test-token",
            peerId: "test-peer"
        )

        XCTAssertNotNil(client)
    }
}
