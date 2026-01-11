import Foundation
import OmertaCore
import Crypto

/// Peer announcement stored in the DHT for decentralized peer discovery
public struct DHTPeerAnnouncement: Codable, Sendable {
    public let peerId: String
    public let publicKey: String
    public let capabilities: [String]
    public let signalingAddresses: [String]
    public let timestamp: Date
    public let ttl: TimeInterval
    public var signature: String?

    public init(
        peerId: String,
        publicKey: String,
        capabilities: [String],
        signalingAddresses: [String],
        timestamp: Date = Date(),
        ttl: TimeInterval = 3600,
        signature: String? = nil
    ) {
        self.peerId = peerId
        self.publicKey = publicKey
        self.capabilities = capabilities
        self.signalingAddresses = signalingAddresses
        self.timestamp = timestamp
        self.ttl = ttl
        self.signature = signature
    }

    /// Create an announcement from an identity
    public init(
        identity: PeerIdentity,
        capabilities: [String],
        signalingAddresses: [String],
        ttl: TimeInterval = 3600
    ) {
        self.peerId = identity.peerId
        self.publicKey = identity.publicKey
        self.capabilities = capabilities
        self.signalingAddresses = signalingAddresses
        self.timestamp = Date()
        self.ttl = ttl
        self.signature = nil
    }

    /// Check if the announcement has expired
    public var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > ttl
    }

    /// Time remaining until expiry
    public var timeRemaining: TimeInterval {
        max(0, ttl - Date().timeIntervalSince(timestamp))
    }

    /// Sign the announcement with the identity keypair
    public func signed(with keypair: IdentityKeypair) throws -> DHTPeerAnnouncement {
        var copy = self
        copy.signature = nil

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(copy)

        let sig = try keypair.sign(data)
        copy.signature = sig.base64EncodedString()
        return copy
    }

    /// Verify the signature and that peerId matches publicKey
    public func verify() -> Bool {
        // 1. Verify peerId matches publicKey
        let identity = PeerIdentity(peerId: peerId, publicKey: publicKey)
        guard identity.isValid else { return false }

        // 2. Check expiry
        guard !isExpired else { return false }

        // 3. Verify signature
        guard let sig = signature,
              let sigData = Data(base64Encoded: sig) else { return false }

        var unsigned = self
        unsigned.signature = nil

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(unsigned) else { return false }

        return identity.verify(signature: sigData, for: data)
    }

    /// The DHT key for this announcement (based on peerId)
    public var dhtKey: Data {
        // Extend the 8-byte peerId to 20 bytes for DHT key space
        guard let peerIdData = Data(hexString: peerId) else {
            return Data(repeating: 0, count: 20)
        }
        var key = peerIdData
        while key.count < 20 {
            key.append(0)
        }
        return key.prefix(20)
    }
}

/// Common capability strings
public extension DHTPeerAnnouncement {
    static let capabilityProvider = "provider"
    static let capabilityRelay = "relay"
    static let capabilityConsumer = "consumer"
}

// Note: Data hex string extensions are in OmertaCore/Config/OmertaConfig.swift
