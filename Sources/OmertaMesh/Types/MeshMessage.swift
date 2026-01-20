// MeshMessage.swift - Protocol messages for mesh network

import Foundation

/// Unique identifier for a peer in the mesh network
public typealias PeerId = String

/// Network endpoint (IP:port)
public typealias Endpoint = String

/// Peer endpoint info shared in gossip (includes machineId and natType for proper tracking)
public struct PeerEndpointInfo: Codable, Sendable, Equatable {
    public let peerId: PeerId
    public let machineId: MachineId
    public let endpoint: String
    public let natType: NATType
    /// Whether the sender has direct contact with this peer (first-hand knowledge)
    public let isFirstHand: Bool

    public init(peerId: PeerId, machineId: MachineId, endpoint: String, natType: NATType = .unknown, isFirstHand: Bool = false) {
        self.peerId = peerId
        self.machineId = machineId
        self.endpoint = endpoint
        self.natType = natType
        self.isFirstHand = isFirstHand
    }
}

/// All messages in the mesh protocol
public enum MeshMessage: Codable, Sendable, Equatable {
    // MARK: - Keepalive

    /// Heartbeat with list of recently contacted peers (includes machineId and sender's NAT type)
    /// - Parameters:
    ///   - recentPeers: Peers we know about (delta or full list depending on context)
    ///   - myNATType: Sender's NAT type
    ///   - requestFullList: If true, responder should send their full peer list (for bootstrap/reconnection)
    case ping(recentPeers: [PeerEndpointInfo], myNATType: NATType, requestFullList: Bool = false)

    /// Heartbeat response (includes machineId, sender's NAT type, and tells sender their observed endpoint)
    case pong(recentPeers: [PeerEndpointInfo], yourEndpoint: String, myNATType: NATType)

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

    // MARK: - Simple Relay Forwarding (for symmetric NAT peers)

    /// Request peer to forward message to another peer (simple store-and-forward)
    /// Used when direct communication isn't possible (e.g., target behind symmetric NAT)
    case relayForward(targetPeerId: PeerId, payload: Data)

    /// Response from relay indicating forward result
    case relayForwardResult(targetPeerId: PeerId, success: Bool)

    // MARK: - Hole Punching

    /// Request hole punch coordination
    case holePunchRequest(targetPeerId: PeerId, myEndpoint: Endpoint, myNATType: NATType)

    /// Invitation to hole punch (from coordinator)
    case holePunchInvite(fromPeerId: PeerId, theirEndpoint: Endpoint, theirNATType: NATType)

    /// Execute hole punch now (bidirectional - sent to both parties)
    /// - Parameters:
    ///   - targetEndpoint: The endpoint we should send probes to
    ///   - peerEndpoint: Our own endpoint (for reference/logging)
    ///   - simultaneousSend: If true, both parties should send probes simultaneously
    case holePunchExecute(targetEndpoint: Endpoint, peerEndpoint: Endpoint? = nil, simultaneousSend: Bool = false)

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

    /// Sender's Ed25519 public key (base64) - enables stateless verification
    public let publicKey: String

    /// Sender's machine ID - identifies which physical machine sent this
    public let machineId: MachineId

    /// Recipient's peer ID (nil for broadcast)
    public let toPeerId: PeerId?

    /// Hop count to prevent infinite loops
    public var hopCount: Int

    /// When the message was created
    public let timestamp: Date

    /// The actual message
    public let payload: MeshMessage

    /// Ed25519 signature over the envelope (base64)
    public var signature: String

    public init(
        messageId: String = UUID().uuidString,
        fromPeerId: PeerId,
        publicKey: String,
        machineId: MachineId,
        toPeerId: PeerId?,
        hopCount: Int = 0,
        timestamp: Date = Date(),
        payload: MeshMessage,
        signature: String = ""
    ) {
        self.messageId = messageId
        self.fromPeerId = fromPeerId
        self.publicKey = publicKey
        self.machineId = machineId
        self.toPeerId = toPeerId
        self.hopCount = hopCount
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
    }

    /// Get the data that should be signed (everything except signature)
    public func dataToSign() throws -> Data {
        // Create a copy without signature for signing
        let signable = SignableEnvelope(
            messageId: messageId,
            fromPeerId: fromPeerId,
            publicKey: publicKey,
            machineId: machineId,
            toPeerId: toPeerId,
            hopCount: hopCount,
            timestamp: timestamp,
            payload: payload
        )
        // Use sorted keys for deterministic JSON encoding
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(signable)
    }

    /// Create a signed envelope using the given keypair
    public static func signed(
        messageId: String = UUID().uuidString,
        from keypair: IdentityKeypair,
        machineId: MachineId,
        to toPeerId: PeerId?,
        payload: MeshMessage
    ) throws -> MeshEnvelope {
        var envelope = MeshEnvelope(
            messageId: messageId,
            fromPeerId: keypair.peerId,
            publicKey: keypair.publicKeyBase64,
            machineId: machineId,
            toPeerId: toPeerId,
            payload: payload
        )

        let dataToSign = try envelope.dataToSign()
        let sig = try keypair.sign(dataToSign)
        envelope.signature = sig.base64

        return envelope
    }

    /// Verify the signature using the embedded public key
    /// Also verifies that fromPeerId is correctly derived from the public key
    public func verifySignature() -> Bool {
        // First verify peer ID is derived from the public key
        guard IdentityKeypair.verifyPeerIdDerivation(peerId: fromPeerId, publicKeyBase64: publicKey) else {
            return false
        }

        guard let sigData = Data(base64Encoded: signature),
              let dataToSign = try? dataToSign() else {
            return false
        }

        let sig = Signature(data: sigData)
        return sig.verify(dataToSign, publicKeyBase64: publicKey)
    }
}

/// Internal struct for signing (excludes signature field)
private struct SignableEnvelope: Codable {
    let messageId: String
    let fromPeerId: PeerId
    let publicKey: String
    let machineId: MachineId
    let toPeerId: PeerId?
    let hopCount: Int
    let timestamp: Date
    let payload: MeshMessage
}
