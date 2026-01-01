import Foundation

/// Represents a network membership
public struct Network: Identifiable, Sendable {
    public let id: String  // Derived from network key hash
    public let name: String
    public let key: NetworkKey
    public let joinedAt: Date
    public let isActive: Bool

    public init(
        id: String,
        name: String,
        key: NetworkKey,
        joinedAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.key = key
        self.joinedAt = joinedAt
        self.isActive = isActive
    }
}

/// Network key structure (encoded as JSON, then base64)
public struct NetworkKey: Sendable, Codable {
    public let networkKey: Data  // 256-bit symmetric key
    public let networkName: String
    public let bootstrapPeers: [String]  // Array of "host:port" strings
    public let createdAt: Date

    public init(
        networkKey: Data,
        networkName: String,
        bootstrapPeers: [String],
        createdAt: Date = Date()
    ) {
        self.networkKey = networkKey
        self.networkName = networkName
        self.bootstrapPeers = bootstrapPeers
        self.createdAt = createdAt
    }

    /// Encode network key as base64 string with omerta:// prefix
    public func encode() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(self)
        let base64 = jsonData.base64EncodedString()
        return "omerta://join/\(base64)"
    }

    /// Decode network key from omerta:// string
    public static func decode(from string: String) throws -> NetworkKey {
        guard string.hasPrefix("omerta://join/") else {
            throw NetworkKeyError.invalidFormat
        }

        let base64 = String(string.dropFirst("omerta://join/".count))
        guard let jsonData = Data(base64Encoded: base64) else {
            throw NetworkKeyError.invalidBase64
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NetworkKey.self, from: jsonData)
    }

    /// Generate a new random network key
    public static func generate(
        networkName: String,
        bootstrapEndpoint: String
    ) -> NetworkKey {
        var keyData = Data(count: 32)  // 256 bits
        _ = keyData.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }

        return NetworkKey(
            networkKey: keyData,
            networkName: networkName,
            bootstrapPeers: [bootstrapEndpoint]
        )
    }

    /// Derive network ID from key (SHA256 hash)
    public func deriveNetworkId() -> String {
        // Simple SHA256 hash for now, will use Crypto framework properly later
        let hash = networkKey.withUnsafeBytes { bytes in
            var result = [UInt8](repeating: 0, count: 32)
            // Placeholder - will use CryptoKit properly
            for (i, byte) in bytes.enumerated() {
                result[i % 32] ^= byte
            }
            return Data(result)
        }
        return hash.base64EncodedString()
    }
}

/// Network key errors
public enum NetworkKeyError: Error {
    case invalidFormat
    case invalidBase64
    case decodingFailed
}

/// Network statistics
public struct NetworkStats: Sendable {
    public let networkId: String
    public let peerCount: Int
    public let jobsSubmitted: UInt64
    public let jobsCompleted: UInt64
    public let averageLatencyMs: Double

    public init(
        networkId: String,
        peerCount: Int,
        jobsSubmitted: UInt64,
        jobsCompleted: UInt64,
        averageLatencyMs: Double
    ) {
        self.networkId = networkId
        self.peerCount = peerCount
        self.jobsSubmitted = jobsSubmitted
        self.jobsCompleted = jobsCompleted
        self.averageLatencyMs = averageLatencyMs
    }
}
