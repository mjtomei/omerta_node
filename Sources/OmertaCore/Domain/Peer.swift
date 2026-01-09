import Foundation

/// Represents a peer in the network
public struct Peer: Identifiable, Sendable {
    public let id: String  // Public key hash
    public let networkId: String
    public let endpoint: String  // IP:port for direct connection
    public let capabilities: [ResourceCapability]
    public let metadata: PeerMetadata
    public let lastSeen: Date

    public init(
        id: String,
        networkId: String,
        endpoint: String,
        capabilities: [ResourceCapability],
        metadata: PeerMetadata,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.networkId = networkId
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.metadata = metadata
        self.lastSeen = lastSeen
    }
}

/// Peer metadata and reputation
public struct PeerMetadata: Sendable {
    public let reputationScore: UInt32  // 0-100, computed locally
    public let jobsCompleted: UInt64
    public let jobsRejected: UInt64
    public let averageResponseTimeMs: Double

    public init(
        reputationScore: UInt32 = 50,  // Start neutral
        jobsCompleted: UInt64 = 0,
        jobsRejected: UInt64 = 0,
        averageResponseTimeMs: Double = 0
    ) {
        self.reputationScore = reputationScore
        self.jobsCompleted = jobsCompleted
        self.jobsRejected = jobsRejected
        self.averageResponseTimeMs = averageResponseTimeMs
    }
}

/// Peer announcement for discovery
public struct PeerAnnouncement: Sendable {
    public let peerId: String
    public let networkId: String
    public let endpoint: String
    public let capabilities: [ResourceCapability]
    public let metadata: PeerMetadata
    public let timestamp: Date
    public let signature: Data

    public init(
        peerId: String,
        networkId: String,
        endpoint: String,
        capabilities: [ResourceCapability],
        metadata: PeerMetadata,
        timestamp: Date = Date(),
        signature: Data
    ) {
        self.peerId = peerId
        self.networkId = networkId
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.metadata = metadata
        self.timestamp = timestamp
        self.signature = signature
    }

    /// Create a local announcement for testing (unsigned)
    public static func local(
        peerId: String,
        networkId: String,
        endpoint: String,
        capabilities: [ResourceCapability],
        metadata: PeerMetadata = PeerMetadata(),
        timestamp: Date = Date()
    ) -> PeerAnnouncement {
        PeerAnnouncement(
            peerId: peerId,
            networkId: networkId,
            endpoint: endpoint,
            capabilities: capabilities,
            metadata: metadata,
            timestamp: timestamp,
            signature: Data()  // Empty signature for local/testing use
        )
    }
}

/// Peer query for discovery
public struct PeerQuery: Sendable {
    public let networkId: String
    public let requirements: ResourceRequirements
    public let maxResults: UInt32

    public init(
        networkId: String,
        requirements: ResourceRequirements,
        maxResults: UInt32 = 20
    ) {
        self.networkId = networkId
        self.requirements = requirements
        self.maxResults = maxResults
    }
}
