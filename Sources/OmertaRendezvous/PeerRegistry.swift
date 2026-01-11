// PeerRegistry.swift
// Track connected peers and their state

import Foundation
import NIOCore
import Logging

/// Information about a connected peer
public struct PeerInfo: Sendable {
    public let peerId: String
    public let networkId: String
    public var endpoint: String?
    public var natType: NATType
    public var publicKey: String?
    public let connectedAt: Date
    public var lastSeen: Date

    public init(
        peerId: String,
        networkId: String,
        endpoint: String? = nil,
        natType: NATType = .unknown,
        publicKey: String? = nil
    ) {
        self.peerId = peerId
        self.networkId = networkId
        self.endpoint = endpoint
        self.natType = natType
        self.publicKey = publicKey
        self.connectedAt = Date()
        self.lastSeen = Date()
    }
}

/// Pending connection request between two peers
public struct ConnectionRequest: Sendable {
    public let requesterId: String
    public let targetId: String
    public let requesterPublicKey: String
    public let createdAt: Date

    public init(requesterId: String, targetId: String, requesterPublicKey: String) {
        self.requesterId = requesterId
        self.targetId = targetId
        self.requesterPublicKey = requesterPublicKey
        self.createdAt = Date()
    }
}

/// Registry of all connected peers
public actor PeerRegistry {
    private var peers: [String: PeerInfo] = [:]
    private var channelToPeer: [ObjectIdentifier: String] = [:]
    private var peerToChannel: [String: Channel] = [:]
    private var pendingConnections: [String: ConnectionRequest] = [:]
    private let logger: Logger

    public init() {
        self.logger = Logger(label: "io.omerta.rendezvous.registry")
    }

    // MARK: - Peer Management

    /// Register a new peer
    public func register(peerId: String, networkId: String, channel: Channel) -> Bool {
        // Check if peer already registered
        if let existing = peers[peerId] {
            logger.warning("Peer already registered", metadata: [
                "peerId": "\(peerId)",
                "existingNetwork": "\(existing.networkId)",
                "newNetwork": "\(networkId)"
            ])
            return false
        }

        let info = PeerInfo(peerId: peerId, networkId: networkId)
        peers[peerId] = info
        channelToPeer[ObjectIdentifier(channel)] = peerId
        peerToChannel[peerId] = channel

        logger.info("Peer registered", metadata: [
            "peerId": "\(peerId)",
            "networkId": "\(networkId)"
        ])

        return true
    }

    /// Unregister a peer (on disconnect)
    public func unregister(channel: Channel) {
        let channelId = ObjectIdentifier(channel)
        guard let peerId = channelToPeer.removeValue(forKey: channelId) else {
            return
        }

        peers.removeValue(forKey: peerId)
        peerToChannel.removeValue(forKey: peerId)

        // Clean up pending connections involving this peer
        pendingConnections = pendingConnections.filter { _, request in
            request.requesterId != peerId && request.targetId != peerId
        }

        logger.info("Peer unregistered", metadata: ["peerId": "\(peerId)"])
    }

    /// Get peer info by ID
    public func getPeer(_ peerId: String) -> PeerInfo? {
        return peers[peerId]
    }

    /// Get peer info by channel
    public func getPeer(channel: Channel) -> PeerInfo? {
        let channelId = ObjectIdentifier(channel)
        guard let peerId = channelToPeer[channelId] else {
            return nil
        }
        return peers[peerId]
    }

    /// Get channel for a peer
    public func getChannel(for peerId: String) -> Channel? {
        return peerToChannel[peerId]
    }

    /// Update peer's endpoint and NAT type
    public func updateEndpoint(peerId: String, endpoint: String, natType: NATType) {
        guard var info = peers[peerId] else { return }
        info.endpoint = endpoint
        info.natType = natType
        info.lastSeen = Date()
        peers[peerId] = info

        logger.debug("Peer endpoint updated", metadata: [
            "peerId": "\(peerId)",
            "endpoint": "\(endpoint)",
            "natType": "\(natType.rawValue)"
        ])
    }

    /// Update peer's public key
    public func updatePublicKey(peerId: String, publicKey: String) {
        guard var info = peers[peerId] else { return }
        info.publicKey = publicKey
        peers[peerId] = info
    }

    /// Update last seen time
    public func touch(peerId: String) {
        guard var info = peers[peerId] else { return }
        info.lastSeen = Date()
        peers[peerId] = info
    }

    /// Get all peers in a network
    public func peersInNetwork(_ networkId: String) -> [PeerInfo] {
        return peers.values.filter { $0.networkId == networkId }
    }

    /// Get count of connected peers
    public var peerCount: Int {
        return peers.count
    }

    // MARK: - Connection Requests

    /// Create a connection request
    public func createConnectionRequest(
        requesterId: String,
        targetId: String,
        requesterPublicKey: String
    ) -> ConnectionRequest? {
        // Check both peers exist
        guard peers[requesterId] != nil else {
            logger.warning("Requester not found", metadata: ["requesterId": "\(requesterId)"])
            return nil
        }
        guard peers[targetId] != nil else {
            logger.warning("Target not found", metadata: ["targetId": "\(targetId)"])
            return nil
        }

        // Create unique key for this connection pair
        let key = connectionKey(requesterId, targetId)

        let request = ConnectionRequest(
            requesterId: requesterId,
            targetId: targetId,
            requesterPublicKey: requesterPublicKey
        )
        pendingConnections[key] = request

        logger.info("Connection request created", metadata: [
            "requesterId": "\(requesterId)",
            "targetId": "\(targetId)"
        ])

        return request
    }

    /// Get pending connection request
    public func getConnectionRequest(peer1: String, peer2: String) -> ConnectionRequest? {
        let key = connectionKey(peer1, peer2)
        return pendingConnections[key]
    }

    /// Remove connection request (on completion or timeout)
    public func removeConnectionRequest(peer1: String, peer2: String) {
        let key = connectionKey(peer1, peer2)
        pendingConnections.removeValue(forKey: key)
    }

    // MARK: - Cleanup

    /// Remove stale peers (no activity for given interval)
    public func cleanupStale(olderThan interval: TimeInterval) -> [String] {
        let cutoff = Date().addingTimeInterval(-interval)
        var removed: [String] = []

        for (peerId, info) in peers {
            if info.lastSeen < cutoff {
                peers.removeValue(forKey: peerId)
                if let channel = peerToChannel.removeValue(forKey: peerId) {
                    channelToPeer.removeValue(forKey: ObjectIdentifier(channel))
                }
                removed.append(peerId)
            }
        }

        if !removed.isEmpty {
            logger.info("Cleaned up stale peers", metadata: ["count": "\(removed.count)"])
        }

        return removed
    }

    // MARK: - Private

    private func connectionKey(_ peer1: String, _ peer2: String) -> String {
        // Create consistent key regardless of order
        return [peer1, peer2].sorted().joined(separator: ":")
    }
}
