import Foundation

/// DHT protocol messages for Kademlia-style peer discovery
public enum DHTMessage: Codable, Sendable {
    /// Ping to check if node is alive
    case ping(fromId: String)
    case pong(fromId: String)

    /// Find nodes close to a key
    case findNode(targetId: String, fromId: String)
    case foundNodes(nodes: [DHTNodeInfo], fromId: String)

    /// Store a value
    case store(key: String, value: DHTPeerAnnouncement, fromId: String)
    case stored(key: String, fromId: String)

    /// Retrieve a value
    case findValue(key: String, fromId: String)
    case foundValue(value: DHTPeerAnnouncement, fromId: String)
    case valueNotFound(closerNodes: [DHTNodeInfo], fromId: String)

    /// Error response
    case error(message: String, fromId: String)
}

/// Information about a DHT node
public struct DHTNodeInfo: Codable, Sendable, Equatable, Hashable {
    public let peerId: String
    public let address: String
    public let port: UInt16

    public init(peerId: String, address: String, port: UInt16) {
        self.peerId = peerId
        self.address = address
        self.port = port
    }

    /// Full address string for UDP
    public var fullAddress: String {
        "\(address):\(port)"
    }
}

/// DHT-related errors
public enum DHTError: Error, Sendable {
    case invalidAnnouncement
    case announcementExpired
    case nodeNotFound
    case networkError(String)
    case timeout
    case invalidResponse
    case bootstrapFailed
    case notStarted
}

/// DHT configuration
public struct DHTConfig: Sendable {
    /// Number of nodes per k-bucket (Kademlia K parameter)
    public let k: Int

    /// Number of parallel lookups (Kademlia alpha parameter)
    public let alpha: Int

    /// Default TTL for announcements in seconds
    public let defaultTTL: TimeInterval

    /// Interval between bucket refreshes
    public let refreshInterval: TimeInterval

    /// Timeout for RPC calls
    public let rpcTimeout: TimeInterval

    /// UDP port for DHT
    public let port: UInt16

    /// Bootstrap nodes
    public let bootstrapNodes: [String]

    public init(
        k: Int = 20,
        alpha: Int = 3,
        defaultTTL: TimeInterval = 3600,
        refreshInterval: TimeInterval = 3600,
        rpcTimeout: TimeInterval = 5,
        port: UInt16 = 4000,
        bootstrapNodes: [String] = []
    ) {
        self.k = k
        self.alpha = alpha
        self.defaultTTL = defaultTTL
        self.refreshInterval = refreshInterval
        self.rpcTimeout = rpcTimeout
        self.port = port
        self.bootstrapNodes = bootstrapNodes
    }

    /// Default configuration with standard bootstrap nodes
    public static var `default`: DHTConfig {
        DHTConfig(
            bootstrapNodes: [
                "bootstrap1.omerta.io:4000",
                "bootstrap2.omerta.io:4000"
            ]
        )
    }
}

/// Wrapper for DHT message with transaction ID for request/response matching
public struct DHTPacket: Codable, Sendable {
    public let transactionId: String
    public let message: DHTMessage

    public init(transactionId: String = UUID().uuidString, message: DHTMessage) {
        self.transactionId = transactionId
        self.message = message
    }

    /// Encode to JSON data for transmission
    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decode from JSON data
    public static func decode(from data: Data) throws -> DHTPacket {
        try JSONDecoder().decode(DHTPacket.self, from: data)
    }
}
