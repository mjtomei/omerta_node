// MeshMessage.swift - Protocol messages for mesh network

import Foundation

/// Unique identifier for a peer in the mesh network
public typealias PeerId = String

/// Network endpoint (IP:port)
public typealias Endpoint = String

/// All messages in the mesh protocol
public enum MeshMessage: Codable, Sendable, Equatable {
    // MARK: - Keepalive

    /// Heartbeat with list of recently contacted peers
    case ping(recentPeers: [PeerId])

    /// Heartbeat response
    case pong(recentPeers: [PeerId])

    // MARK: - Discovery

    /// Request peer information
    case findPeer(peerId: PeerId)

    /// Response with peer announcement
    case peerInfo(PeerAnnouncement)

    /// Response when peer is not found
    case peerNotFound(peerId: PeerId)

    /// List of known peers (bootstrap response)
    case peerList([PeerAnnouncement])

    // MARK: - Announcements

    /// Broadcast reachability info
    case announce(PeerAnnouncement)

    /// Advertise relay capacity
    case relayCapacity(peerIds: [PeerId], availableSlots: Int)

    // MARK: - Freshness Queries

    /// Ask who has recent contact with a peer
    case whoHasRecent(peerId: PeerId, maxAgeSeconds: Int)

    /// Response: I have recent contact
    case iHaveRecent(peerId: PeerId, lastSeenSecondsAgo: Int, reachability: ReachabilityPath)

    /// Report a failed path
    case pathFailed(peerId: PeerId, path: ReachabilityPath, failedAt: Date)

    // MARK: - Relay Control

    /// Request relay session to target peer
    case relayRequest(targetPeerId: PeerId, sessionId: String)

    /// Relay request accepted
    case relayAccept(sessionId: String)

    /// Relay request denied
    case relayDeny(sessionId: String, reason: String)

    /// Relay session ended
    case relayEnd(sessionId: String)

    /// Data being relayed
    case relayData(sessionId: String, data: Data)

    // MARK: - Hole Punching

    /// Request hole punch coordination
    case holePunchRequest(targetPeerId: PeerId, myEndpoint: Endpoint, myNATType: NATType)

    /// Invitation to hole punch (from coordinator)
    case holePunchInvite(fromPeerId: PeerId, theirEndpoint: Endpoint, theirNATType: NATType)

    /// Execute hole punch now
    case holePunchExecute(targetEndpoint: Endpoint, strategy: HolePunchStrategy)

    /// Report hole punch result
    case holePunchResult(targetPeerId: PeerId, success: Bool, establishedEndpoint: Endpoint?)

    // MARK: - Application Data

    /// Opaque application data
    case data(Data)

    /// Request-response pattern
    case request(requestId: String, data: Data)
    case response(requestId: String, data: Data)
}

/// How a peer can be reached
public enum ReachabilityPath: Codable, Sendable, Equatable {
    /// Direct connection to public endpoint
    case direct(endpoint: Endpoint)

    /// Via a relay peer
    case relay(relayPeerId: PeerId, relayEndpoint: Endpoint)

    /// Hole-punchable (needs coordination)
    case holePunch(publicIP: String, localPort: UInt16)
}

/// Hole punch execution strategy
public enum HolePunchStrategy: String, Codable, Sendable, Equatable {
    /// Both peers send probes simultaneously
    case simultaneous

    /// This peer sends first
    case initiatorFirst

    /// Other peer sends first
    case responderFirst

    /// Hole punching not possible (both symmetric)
    case impossible
}

/// Signed announcement of a peer's reachability
public struct PeerAnnouncement: Codable, Sendable, Equatable {
    /// Unique peer identifier (derived from public key)
    public let peerId: PeerId

    /// Ed25519 public key (base64)
    public let publicKey: String

    /// How this peer can be reached, ordered by preference
    public let reachability: [ReachabilityPath]

    /// Capabilities: "relay", "provider", etc.
    public let capabilities: [String]

    /// When this announcement was created
    public let timestamp: Date

    /// How long this announcement is valid
    public let ttlSeconds: Int

    /// Ed25519 signature over the announcement (base64)
    public let signature: String

    public init(
        peerId: PeerId,
        publicKey: String,
        reachability: [ReachabilityPath],
        capabilities: [String],
        timestamp: Date = Date(),
        ttlSeconds: Int = 3600,
        signature: String = ""
    ) {
        self.peerId = peerId
        self.publicKey = publicKey
        self.reachability = reachability
        self.capabilities = capabilities
        self.timestamp = timestamp
        self.ttlSeconds = ttlSeconds
        self.signature = signature
    }

    /// Check if this announcement has expired
    public var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > TimeInterval(ttlSeconds)
    }
}

/// Message envelope with routing and authentication
public struct MeshEnvelope: Codable, Sendable {
    /// Unique message ID for deduplication
    public let messageId: String

    /// Sender's peer ID
    public let fromPeerId: PeerId

    /// Recipient's peer ID (nil for broadcast)
    public let toPeerId: PeerId?

    /// Hop count to prevent infinite loops
    public var hopCount: Int

    /// When the message was created
    public let timestamp: Date

    /// The actual message
    public let payload: MeshMessage

    /// Ed25519 signature over the envelope
    public let signature: String

    public init(
        messageId: String = UUID().uuidString,
        fromPeerId: PeerId,
        toPeerId: PeerId?,
        hopCount: Int = 0,
        timestamp: Date = Date(),
        payload: MeshMessage,
        signature: String = ""
    ) {
        self.messageId = messageId
        self.fromPeerId = fromPeerId
        self.toPeerId = toPeerId
        self.hopCount = hopCount
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
    }
}
