import Foundation
import Logging
import OmertaCore

/// Simplified peer discovery service for MVP
/// Later phases will implement full DHT functionality
public actor PeerDiscovery {

    // MARK: - State

    private let networkManager: NetworkManager
    private let peerRegistry: PeerRegistry
    private let logger: Logger
    private let localPeerId: String
    private let localEndpoint: String

    private var isRunning: Bool = false
    private var announcementTask: Task<Void, Never>?

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let localPeerId: String
        public let localEndpoint: String  // e.g., "192.168.1.100:50051"
        public let announcementInterval: TimeInterval  // How often to announce
        public let cleanupInterval: TimeInterval  // How often to cleanup stale peers

        public init(
            localPeerId: String,
            localEndpoint: String,
            announcementInterval: TimeInterval = 30.0,
            cleanupInterval: TimeInterval = 60.0
        ) {
            self.localPeerId = localPeerId
            self.localEndpoint = localEndpoint
            self.announcementInterval = announcementInterval
            self.cleanupInterval = cleanupInterval
        }
    }

    private let config: Configuration

    // MARK: - Initialization

    public init(
        config: Configuration,
        networkManager: NetworkManager,
        peerRegistry: PeerRegistry
    ) {
        self.config = config
        self.networkManager = networkManager
        self.peerRegistry = peerRegistry
        self.localPeerId = config.localPeerId
        self.localEndpoint = config.localEndpoint

        var logger = Logger(label: "com.omerta.network.discovery")
        logger.logLevel = .info
        self.logger = logger
    }

    // MARK: - Lifecycle

    /// Start peer discovery
    public func start() async {
        guard !isRunning else {
            logger.warning("Peer discovery already running")
            return
        }

        logger.info("Starting peer discovery")
        logger.info("  Local peer ID: \(localPeerId)")
        logger.info("  Local endpoint: \(localEndpoint)")

        isRunning = true

        // Start periodic announcements
        announcementTask = Task {
            await runAnnouncementLoop()
        }

        // Initial announcement
        await announceToNetworks()
    }

    /// Stop peer discovery
    public func stop() async {
        guard isRunning else {
            return
        }

        logger.info("Stopping peer discovery")

        isRunning = false
        announcementTask?.cancel()
        announcementTask = nil
    }

    // MARK: - Announcement

    /// Announce presence to all enabled networks
    private func announceToNetworks() async {
        let networks = await networkManager.getEnabledNetworks()

        guard !networks.isEmpty else {
            logger.debug("No networks to announce to")
            return
        }

        logger.debug("Announcing to \(networks.count) networks")

        for network in networks {
            await announceToNetwork(network)
        }
    }

    /// Announce to a specific network
    private func announceToNetwork(_ network: Network) async {
        let announcement = PeerAnnouncement.local(
            peerId: localPeerId,
            networkId: network.id,
            endpoint: localEndpoint,
            capabilities: await getLocalCapabilities()
        )

        // For MVP: Store announcement in registry (self-registration)
        // In future: Send to DHT nodes or bootstrap peers
        await peerRegistry.registerPeer(from: announcement)

        logger.debug("Announced to network: \(network.name)")

        // Update last seen for network
        await networkManager.updateLastSeen(networkId: network.id)
    }

    /// Get local resource capabilities
    private func getLocalCapabilities() async -> [ResourceCapability] {
        // TODO: Query actual system resources
        // For MVP, return placeholder capabilities
        [
            ResourceCapability(
                type: .cpuOnly,
                availableCpuCores: 4,  // TODO: Query from system
                availableMemoryMb: 8192,  // TODO: Query from system
                hasGpu: false,  // TODO: Detect GPU
                gpu: nil,
                supportedWorkloadTypes: ["script", "binary"]
            )
        ]
    }

    // MARK: - Periodic Tasks

    /// Run the announcement loop
    private func runAnnouncementLoop() async {
        logger.debug("Starting announcement loop")

        var cleanupCounter = 0

        while !Task.isCancelled && isRunning {
            // Wait for interval
            try? await Task.sleep(for: .seconds(config.announcementInterval))

            if Task.isCancelled || !isRunning {
                break
            }

            // Announce to networks
            await announceToNetworks()

            // Periodic cleanup
            cleanupCounter += 1
            if cleanupCounter * Int(config.announcementInterval) >= Int(config.cleanupInterval) {
                await peerRegistry.cleanupStalePeers()
                cleanupCounter = 0
            }
        }

        logger.debug("Announcement loop stopped")
    }

    // MARK: - Discovery

    /// Find peers in a network matching requirements
    public func findPeers(
        networkId: String,
        requirements: ResourceRequirements,
        maxResults: Int = 10
    ) async -> [PeerRegistry.DiscoveredPeer] {
        logger.debug("Finding peers in network \(networkId)")

        // Check if network is enabled
        guard await networkManager.isNetworkEnabled(networkId) else {
            logger.warning("Network \(networkId) is not enabled")
            return []
        }

        // Query registry
        let peers = await peerRegistry.findPeers(
            networkId: networkId,
            requirements: requirements,
            maxResults: maxResults
        )

        logger.info("Found \(peers.count) matching peers")
        return peers
    }

    /// Get all peers in a network
    public func getPeers(networkId: String) async -> [PeerRegistry.DiscoveredPeer] {
        await peerRegistry.getPeers(networkId: networkId)
    }

    /// Get online peers in a network
    public func getOnlinePeers(networkId: String) async -> [PeerRegistry.DiscoveredPeer] {
        await peerRegistry.getOnlinePeers(networkId: networkId)
    }

    // MARK: - Manual Peer Registration

    /// Manually register a peer from an external announcement
    /// This allows peers to be added from bootstrap nodes or other sources
    public func registerPeer(_ announcement: PeerAnnouncement) async {
        logger.info("Registering peer from external announcement: \(announcement.peerId)")
        await peerRegistry.registerPeer(from: announcement)
    }

    // MARK: - Statistics

    /// Get discovery statistics
    public func getStatistics() async -> DiscoveryStatistics {
        let networkIds = await peerRegistry.getNetworkIds()
        var networkStats: [String: PeerStatistics] = [:]

        for networkId in networkIds {
            networkStats[networkId] = await peerRegistry.getStatistics(networkId: networkId)
        }

        return DiscoveryStatistics(
            isRunning: isRunning,
            totalNetworks: networkIds.count,
            totalPeers: networkStats.values.reduce(0) { $0 + $1.totalPeers },
            onlinePeers: networkStats.values.reduce(0) { $0 + $1.onlinePeers },
            networkStats: networkStats
        )
    }
}

// MARK: - Statistics

public struct DiscoveryStatistics: Sendable {
    public let isRunning: Bool
    public let totalNetworks: Int
    public let totalPeers: Int
    public let onlinePeers: Int
    public let networkStats: [String: PeerStatistics]

    public init(
        isRunning: Bool,
        totalNetworks: Int,
        totalPeers: Int,
        onlinePeers: Int,
        networkStats: [String: PeerStatistics]
    ) {
        self.isRunning = isRunning
        self.totalNetworks = totalNetworks
        self.totalPeers = totalPeers
        self.onlinePeers = onlinePeers
        self.networkStats = networkStats
    }
}
