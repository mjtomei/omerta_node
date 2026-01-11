// SignalingMessages.swift
// Protocol messages for signaling server

import Foundation

/// NAT type detected via STUN
public enum NATType: String, Codable, Sendable {
    case fullCone           // Most permissive - any external host can send
    case restrictedCone     // Only IPs we've sent to can reply
    case portRestrictedCone // Only IP:port pairs we've sent to can reply
    case symmetric          // Different port per destination
    case unknown
}

/// Hole punch strategy determined by server
public enum HolePunchStrategy: String, Codable, Sendable {
    case simultaneous   // Both cone: send at same time
    case youInitiate    // You're symmetric, peer is cone: you send first
    case peerInitiates  // You're cone, peer is symmetric: wait then reply
    case relay          // Both symmetric: use relay
}

// MARK: - Client → Server Messages

/// Messages sent from client to signaling server
public enum ClientMessage: Codable, Sendable {
    /// Register this peer with the server
    case register(peerId: String, networkId: String)

    /// Request connection to another peer
    case requestConnection(targetPeerId: String, myPublicKey: String)

    /// Report our discovered public endpoint and NAT type
    case reportEndpoint(endpoint: String, natType: NATType)

    /// Signal that we're ready to receive/send hole punch packets
    case holePunchReady

    /// Report new endpoint after sending (for symmetric NAT)
    case holePunchSent(newEndpoint: String)

    /// Report hole punch result
    case holePunchResult(targetPeerId: String, success: Bool, actualEndpoint: String?)

    /// Request relay allocation (fallback for symmetric NAT)
    case requestRelay(targetPeerId: String)

    /// Heartbeat to keep connection alive
    case ping

    private enum CodingKeys: String, CodingKey {
        case type
        case peerId
        case networkId
        case targetPeerId
        case myPublicKey
        case endpoint
        case natType
        case newEndpoint
        case success
        case actualEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "register":
            let peerId = try container.decode(String.self, forKey: .peerId)
            let networkId = try container.decode(String.self, forKey: .networkId)
            self = .register(peerId: peerId, networkId: networkId)

        case "requestConnection":
            let targetPeerId = try container.decode(String.self, forKey: .targetPeerId)
            let myPublicKey = try container.decode(String.self, forKey: .myPublicKey)
            self = .requestConnection(targetPeerId: targetPeerId, myPublicKey: myPublicKey)

        case "reportEndpoint":
            let endpoint = try container.decode(String.self, forKey: .endpoint)
            let natType = try container.decode(NATType.self, forKey: .natType)
            self = .reportEndpoint(endpoint: endpoint, natType: natType)

        case "holePunchReady":
            self = .holePunchReady

        case "holePunchSent":
            let newEndpoint = try container.decode(String.self, forKey: .newEndpoint)
            self = .holePunchSent(newEndpoint: newEndpoint)

        case "holePunchResult":
            let targetPeerId = try container.decode(String.self, forKey: .targetPeerId)
            let success = try container.decode(Bool.self, forKey: .success)
            let actualEndpoint = try container.decodeIfPresent(String.self, forKey: .actualEndpoint)
            self = .holePunchResult(targetPeerId: targetPeerId, success: success, actualEndpoint: actualEndpoint)

        case "requestRelay":
            let targetPeerId = try container.decode(String.self, forKey: .targetPeerId)
            self = .requestRelay(targetPeerId: targetPeerId)

        case "ping":
            self = .ping

        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown message type: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .register(let peerId, let networkId):
            try container.encode("register", forKey: .type)
            try container.encode(peerId, forKey: .peerId)
            try container.encode(networkId, forKey: .networkId)

        case .requestConnection(let targetPeerId, let myPublicKey):
            try container.encode("requestConnection", forKey: .type)
            try container.encode(targetPeerId, forKey: .targetPeerId)
            try container.encode(myPublicKey, forKey: .myPublicKey)

        case .reportEndpoint(let endpoint, let natType):
            try container.encode("reportEndpoint", forKey: .type)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(natType, forKey: .natType)

        case .holePunchReady:
            try container.encode("holePunchReady", forKey: .type)

        case .holePunchSent(let newEndpoint):
            try container.encode("holePunchSent", forKey: .type)
            try container.encode(newEndpoint, forKey: .newEndpoint)

        case .holePunchResult(let targetPeerId, let success, let actualEndpoint):
            try container.encode("holePunchResult", forKey: .type)
            try container.encode(targetPeerId, forKey: .targetPeerId)
            try container.encode(success, forKey: .success)
            try container.encodeIfPresent(actualEndpoint, forKey: .actualEndpoint)

        case .requestRelay(let targetPeerId):
            try container.encode("requestRelay", forKey: .type)
            try container.encode(targetPeerId, forKey: .targetPeerId)

        case .ping:
            try container.encode("ping", forKey: .type)
        }
    }
}

// MARK: - Server → Client Messages

/// Messages sent from signaling server to client
public enum ServerMessage: Codable, Sendable {
    /// Registration confirmed
    case registered(serverTime: Date)

    /// Peer's endpoint and NAT info
    case peerEndpoint(peerId: String, endpoint: String, natType: NATType, publicKey: String)

    /// Which hole punch strategy to use
    case holePunchStrategy(HolePunchStrategy)

    /// Simultaneous: both send now to this endpoint
    case holePunchNow(targetEndpoint: String)

    /// Asymmetric: you send first to this endpoint
    case holePunchInitiate(targetEndpoint: String)

    /// Asymmetric: wait for incoming packet
    case holePunchWait

    /// Asymmetric: now send to this new endpoint (after peer reported new mapping)
    case holePunchContinue(newEndpoint: String)

    /// Relay allocated for this session
    case relayAssigned(relayEndpoint: String, relayToken: String)

    /// Pong response to ping
    case pong

    /// Error message
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case serverTime
        case peerId
        case endpoint
        case natType
        case publicKey
        case strategy
        case targetEndpoint
        case newEndpoint
        case relayEndpoint
        case relayToken
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "registered":
            let serverTime = try container.decode(Date.self, forKey: .serverTime)
            self = .registered(serverTime: serverTime)

        case "peerEndpoint":
            let peerId = try container.decode(String.self, forKey: .peerId)
            let endpoint = try container.decode(String.self, forKey: .endpoint)
            let natType = try container.decode(NATType.self, forKey: .natType)
            let publicKey = try container.decode(String.self, forKey: .publicKey)
            self = .peerEndpoint(peerId: peerId, endpoint: endpoint, natType: natType, publicKey: publicKey)

        case "holePunchStrategy":
            let strategy = try container.decode(HolePunchStrategy.self, forKey: .strategy)
            self = .holePunchStrategy(strategy)

        case "holePunchNow":
            let targetEndpoint = try container.decode(String.self, forKey: .targetEndpoint)
            self = .holePunchNow(targetEndpoint: targetEndpoint)

        case "holePunchInitiate":
            let targetEndpoint = try container.decode(String.self, forKey: .targetEndpoint)
            self = .holePunchInitiate(targetEndpoint: targetEndpoint)

        case "holePunchWait":
            self = .holePunchWait

        case "holePunchContinue":
            let newEndpoint = try container.decode(String.self, forKey: .newEndpoint)
            self = .holePunchContinue(newEndpoint: newEndpoint)

        case "relayAssigned":
            let relayEndpoint = try container.decode(String.self, forKey: .relayEndpoint)
            let relayToken = try container.decode(String.self, forKey: .relayToken)
            self = .relayAssigned(relayEndpoint: relayEndpoint, relayToken: relayToken)

        case "pong":
            self = .pong

        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message: message)

        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown message type: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .registered(let serverTime):
            try container.encode("registered", forKey: .type)
            try container.encode(serverTime, forKey: .serverTime)

        case .peerEndpoint(let peerId, let endpoint, let natType, let publicKey):
            try container.encode("peerEndpoint", forKey: .type)
            try container.encode(peerId, forKey: .peerId)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(natType, forKey: .natType)
            try container.encode(publicKey, forKey: .publicKey)

        case .holePunchStrategy(let strategy):
            try container.encode("holePunchStrategy", forKey: .type)
            try container.encode(strategy, forKey: .strategy)

        case .holePunchNow(let targetEndpoint):
            try container.encode("holePunchNow", forKey: .type)
            try container.encode(targetEndpoint, forKey: .targetEndpoint)

        case .holePunchInitiate(let targetEndpoint):
            try container.encode("holePunchInitiate", forKey: .type)
            try container.encode(targetEndpoint, forKey: .targetEndpoint)

        case .holePunchWait:
            try container.encode("holePunchWait", forKey: .type)

        case .holePunchContinue(let newEndpoint):
            try container.encode("holePunchContinue", forKey: .type)
            try container.encode(newEndpoint, forKey: .newEndpoint)

        case .relayAssigned(let relayEndpoint, let relayToken):
            try container.encode("relayAssigned", forKey: .type)
            try container.encode(relayEndpoint, forKey: .relayEndpoint)
            try container.encode(relayToken, forKey: .relayToken)

        case .pong:
            try container.encode("pong", forKey: .type)

        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
