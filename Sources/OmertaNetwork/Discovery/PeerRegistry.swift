import Foundation
import Logging
import OmertaCore

/// Registry for tracking discovered peers in networks
public actor PeerRegistry {

    // MARK: - State

    private var peers: [String: DiscoveredPeer] = [:]  // Peer ID -> DiscoveredPeer
    private var peersByNetwork: [String: Set<String>] = [:]  // Network ID -> Set of Peer IDs
    private let logger: Logger

    // MARK: - Types

    /// A discovered peer with metadata
    public struct DiscoveredPeer: Sendable {
        public let peerId: String
        public let networkId: String
        public let endpoint: String
        public var capabilities: [ResourceCapability]
        public var metadata: PeerMetadata
        public var lastSeen: Date
        public var isOnline: Bool

        public init(
            peerId: String,
            networkId: String,
            endpoint: String,
            capabilities: [ResourceCapability],
            metadata: PeerMetadata,
            lastSeen: Date = Date(),
            isOnline: Bool = true
        ) {
            self.peerId = peerId
            self.networkId = networkId
            self.endpoint = endpoint
            self.capabilities = capabilities
            self.metadata = metadata
            self.lastSeen = lastSeen
            self.isOnline = isOnline
        }

        /// Convert from PeerAnnouncement
        public static func from(_ announcement: PeerAnnouncement) -> DiscoveredPeer {
            DiscoveredPeer(
                peerId: announcement.peerId,
                networkId: announcement.networkId,
                endpoint: announcement.endpoint,
                capabilities: announcement.capabilities,
                metadata: announcement.metadata,
                lastSeen: Date(),
                isOnline: true
            )
        }
    }

    // MARK: - Initialization

    public init() {
        var logger = Logger(label: "com.omerta.network.peer-registry")
        logger.logLevel = .info
        self.logger = logger
    }

    // MARK: - Peer Management

    /// Register a peer from an announcement
    public func registerPeer(from announcement: PeerAnnouncement) {
        let peer = DiscoveredPeer.from(announcement)
        let peerId = peer.peerId
        let networkId = peer.networkId

        // Update or add peer
        if let existing = peers[peerId] {
            logger.debug("Updating peer: \(peerId)")
            var updated = existing
            updated.capabilities = peer.capabilities
            updated.metadata = peer.metadata
            updated.lastSeen = Date()
            updated.isOnline = true
            peers[peerId] = updated
        } else {
            logger.info("Registering new peer: \(peerId) in network \(networkId)")
            peers[peerId] = peer
        }

        // Add to network index
        if peersByNetwork[networkId] == nil {
            peersByNetwork[networkId] = []
        }
        peersByNetwork[networkId]?.insert(peerId)
    }

    /// Remove a peer
    public func removePeer(_ peerId: String) {
        guard let peer = peers.removeValue(forKey: peerId) else {
            return
        }

        logger.info("Removed peer: \(peerId)")

        // Remove from network index
        peersByNetwork[peer.networkId]?.remove(peerId)
    }

    /// Mark a peer as offline
    public func markPeerOffline(_ peerId: String) {
        guard var peer = peers[peerId] else { return }
        peer.isOnline = false
        peers[peerId] = peer
        logger.debug("Marked peer offline: \(peerId)")
    }

    /// Update peer's last seen timestamp
    public func updateLastSeen(_ peerId: String) {
        guard var peer = peers[peerId] else { return }
        peer.lastSeen = Date()
        peer.isOnline = true
        peers[peerId] = peer
    }

    // MARK: - Peer Discovery

    /// Get all peers in a network
    public func getPeers(networkId: String) -> [DiscoveredPeer] {
        guard let peerIds = peersByNetwork[networkId] else {
            return []
        }

        return peerIds.compactMap { peers[$0] }
    }

    /// Get online peers in a network
    public func getOnlinePeers(networkId: String) -> [DiscoveredPeer] {
        getPeers(networkId: networkId).filter { $0.isOnline }
    }

    /// Get a specific peer
    public func getPeer(_ peerId: String) -> DiscoveredPeer? {
        peers[peerId]
    }

    /// Find peers matching requirements
    public func findPeers(
        networkId: String,
        requirements: ResourceRequirements,
        maxResults: Int = 10
    ) -> [DiscoveredPeer] {
        let candidates = getOnlinePeers(networkId: networkId)

        // Filter by resource requirements
        let matching = candidates.filter { peer in
            meetsRequirements(peer: peer, requirements: requirements)
        }

        // Sort by reputation score (highest first)
        let sorted = matching.sorted { peer1, peer2 in
            peer1.metadata.reputationScore > peer2.metadata.reputationScore
        }

        return Array(sorted.prefix(maxResults))
    }

    /// Check if a peer meets resource requirements
    private func meetsRequirements(
        peer: DiscoveredPeer,
        requirements: ResourceRequirements
    ) -> Bool {
        // Find capability matching the resource type
        guard let capability = peer.capabilities.first(where: { capability in
            ResourceType(rawValue: capability.type.rawValue) == requirements.type
        }) else {
            return false
        }

        // Check CPU
        if capability.availableCpuCores < requirements.cpuCores {
            return false
        }

        // Check memory
        if capability.availableMemoryMb < requirements.memoryMB {
            return false
        }

        // Check GPU if required
        if let gpuReq = requirements.gpu {
            guard let gpuCap = capability.gpu else {
                return false
            }
            if gpuCap.availableVramMb < gpuReq.vramMB {
                return false
            }
        }

        return true
    }

    // MARK: - Statistics

    /// Get peer statistics for a network
    public func getStatistics(networkId: String) -> PeerStatistics {
        let allPeers = getPeers(networkId: networkId)
        let onlinePeers = allPeers.filter { $0.isOnline }

        let totalCpu = onlinePeers.reduce(UInt32(0)) { sum, peer in
            sum + (peer.capabilities.first?.availableCpuCores ?? 0)
        }

        let totalMemory = onlinePeers.reduce(UInt64(0)) { sum, peer in
            sum + (peer.capabilities.first?.availableMemoryMb ?? 0)
        }

        let averageReputation = onlinePeers.isEmpty ? 0 : onlinePeers.reduce(0) { sum, peer in
            sum + peer.metadata.reputationScore
        } / UInt32(onlinePeers.count)

        return PeerStatistics(
            networkId: networkId,
            totalPeers: allPeers.count,
            onlinePeers: onlinePeers.count,
            totalCpuCores: totalCpu,
            totalMemoryMb: totalMemory,
            averageReputation: averageReputation
        )
    }

    /// Get all network IDs with peers
    public func getNetworkIds() -> [String] {
        Array(peersByNetwork.keys)
    }

    // MARK: - Cleanup

    /// Remove stale peers (not seen for > timeout)
    public func cleanupStalePeers(timeout: TimeInterval = 300) {
        let now = Date()
        var removed = 0

        for (peerId, peer) in peers {
            if now.timeIntervalSince(peer.lastSeen) > timeout {
                removePeer(peerId)
                removed += 1
            }
        }

        if removed > 0 {
            logger.info("Cleaned up \(removed) stale peers")
        }
    }
}

// MARK: - Statistics Types

public struct PeerStatistics: Sendable {
    public let networkId: String
    public let totalPeers: Int
    public let onlinePeers: Int
    public let totalCpuCores: UInt32
    public let totalMemoryMb: UInt64
    public let averageReputation: UInt32

    public init(
        networkId: String,
        totalPeers: Int,
        onlinePeers: Int,
        totalCpuCores: UInt32,
        totalMemoryMb: UInt64,
        averageReputation: UInt32
    ) {
        self.networkId = networkId
        self.totalPeers = totalPeers
        self.onlinePeers = onlinePeers
        self.totalCpuCores = totalCpuCores
        self.totalMemoryMb = totalMemoryMb
        self.averageReputation = averageReputation
    }
}
