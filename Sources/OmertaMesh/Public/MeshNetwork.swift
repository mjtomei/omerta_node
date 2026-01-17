// MeshNetwork.swift - Main entry point for the mesh network

import Foundation
import Logging
import NIOCore
import NIOPosix

/// The main entry point for the mesh network
/// This actor wraps all internal components and provides a clean public API
public actor MeshNetwork {
    // MARK: - Properties

    /// Our cryptographic identity
    public let identity: IdentityKeypair

    /// Our peer ID (derived from identity public key)
    public var peerId: PeerId {
        identity.peerId
    }

    /// Configuration
    public let config: MeshConfig

    /// Current state
    public private(set) var state: MeshNetworkState = .stopped

    /// Event publisher for subscribers
    private let eventPublisher = MeshEventPublisher()

    /// Connection tracker
    private let connectionTracker: DirectConnectionTracker

    /// Network store for persistence
    private let networkStore: NetworkStore

    /// Internal mesh node
    private var meshNode: MeshNode?

    /// Detected NAT type
    private var natType: NATType = .unknown

    /// Public endpoint from STUN
    private var publicEndpoint: Endpoint?

    /// Logger
    private let logger: Logger

    /// Event loop group
    private var eventLoopGroup: EventLoopGroup?
    private var ownsEventLoopGroup: Bool = false

    /// Pending message handler (set before start)
    private var pendingMessageHandler: ((PeerId, Data) async -> Void)?

    /// Retry configuration for network operations
    public var retryConfig: RetryConfig = .network

    // MARK: - Initialization

    /// Create a new mesh network with a cryptographic identity
    /// - Parameters:
    ///   - identity: Our cryptographic identity (keypair)
    ///   - config: Network configuration (must include encryption key)
    ///   - networkStore: Store for network memberships (defaults to standard location)
    public init(identity: IdentityKeypair, config: MeshConfig, networkStore: NetworkStore? = nil) {
        self.identity = identity
        self.config = config
        self.connectionTracker = DirectConnectionTracker(staleThreshold: config.recentContactMaxAge)
        self.networkStore = networkStore ?? NetworkStore.defaultStore()
        self.logger = Logger(label: "io.omerta.mesh.network")
    }

    /// Create a new mesh network with auto-generated identity
    /// - Parameter config: Network configuration (must include encryption key)
    /// - Parameter networkStore: Store for network memberships (defaults to standard location)
    public init(config: MeshConfig, networkStore: NetworkStore? = nil) {
        self.identity = IdentityKeypair()
        self.config = config
        self.connectionTracker = DirectConnectionTracker(staleThreshold: config.recentContactMaxAge)
        self.networkStore = networkStore ?? NetworkStore.defaultStore()
        self.logger = Logger(label: "io.omerta.mesh.network")
    }

    // MARK: - Lifecycle

    /// Start the mesh network
    public func start() async throws {
        guard state == .stopped else {
            throw MeshError.alreadyStarted
        }

        state = .starting
        logger.info("Starting mesh network", metadata: ["peerId": "\(peerId.prefix(16))..."])

        do {
            // Validate configuration
            try config.validate()

            // Create event loop group
            let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            self.eventLoopGroup = elg
            self.ownsEventLoopGroup = true

            // Detect NAT type
            state = .detectingNAT
            try await detectNAT()

            // Create internal mesh node
            let nodeConfig = MeshNode.Config(
                encryptionKey: config.encryptionKey,
                port: UInt16(config.port),
                targetRelays: config.targetRelayCount,
                maxRelays: config.maxRelayCount,
                canRelay: config.canRelay,
                canCoordinateHolePunch: config.canCoordinateHolePunch,
                keepaliveInterval: config.keepaliveInterval,
                connectionTimeout: config.connectionTimeout,
                maxCachedPeers: config.maxCachedPeers,
                peerCacheTTL: config.peerCacheTTL,
                cacheCleanupInterval: config.cacheCleanupInterval,
                recentContactMaxAge: config.recentContactMaxAge,
                freshnessQueryInterval: config.freshnessQueryInterval,
                holePunchTimeout: config.holePunchTimeout,
                holePunchProbeCount: config.holePunchProbeCount,
                holePunchProbeInterval: config.holePunchProbeInterval
            )

            let node = try MeshNode(identity: identity, config: nodeConfig)
            self.meshNode = node

            // Start the node
            try await node.start(natType: natType)

            // Apply pending message handler if set before start()
            if let handler = pendingMessageHandler {
                await applyMessageHandler(to: node, handler: handler)
            }

            // Connect to bootstrap peers
            state = .bootstrapping
            await connectToBootstrapPeers()

            state = .running
            await eventPublisher.publish(.started(localPeerId: peerId))
            await eventPublisher.publish(.natDetected(type: natType, publicEndpoint: publicEndpoint))

            logger.info("Mesh network started", metadata: [
                "natType": "\(natType.rawValue)",
                "publicEndpoint": "\(publicEndpoint ?? "none")"
            ])

        } catch {
            state = .stopped
            await cleanup()
            throw error
        }
    }

    /// Stop the mesh network
    public func stop() async {
        guard state != .stopped else { return }

        logger.info("Stopping mesh network")
        state = .stopping

        await cleanup()

        state = .stopped
        await eventPublisher.publish(.stopped)
        await eventPublisher.finish()

        logger.info("Mesh network stopped")
    }

    private func cleanup() async {
        if let node = meshNode {
            await node.stop()
            meshNode = nil
        }

        if ownsEventLoopGroup, let elg = eventLoopGroup {
            try? await elg.shutdownGracefully()
            eventLoopGroup = nil
            ownsEventLoopGroup = false
        }
    }

    // MARK: - Event Subscription

    /// Subscribe to mesh events
    public func events() async -> MeshEventStream {
        await eventPublisher.subscribe()
    }

    // MARK: - Peer Operations

    /// Connect to a peer
    /// - Parameter peerId: The peer's ID
    /// - Returns: The established connection
    public func connect(to targetPeerId: PeerId) async throws -> DirectConnection {
        guard state == .running, let node = meshNode else {
            throw MeshError.notStarted
        }

        // Check if we already have a connection
        if let existing = await connectionTracker.getConnection(for: targetPeerId) {
            return existing
        }

        // Try to get peer info from cache
        guard let peerInfo = await node.getCachedPeer(targetPeerId) else {
            throw MeshError.peerNotFound(peerId: targetPeerId)
        }

        // Determine connection method based on NAT types
        let targetNATType = peerInfo.natType

        // If we have an endpoint (e.g., from bootstrap), try direct connection first
        // This works for LAN connections even when NAT type is unknown
        if !peerInfo.endpoint.isEmpty {
            logger.debug("Trying direct connection to \(targetPeerId) at \(peerInfo.endpoint)")

            // Send a ping to verify the connection works
            let pingSuccess = await node.sendPing(to: targetPeerId)
            if pingSuccess {
                let connection = DirectConnection(
                    peerId: targetPeerId,
                    endpoint: peerInfo.endpoint,
                    isDirect: true,
                    natType: targetNATType,
                    method: .discovery
                )
                await connectionTracker.setConnection(connection)
                await eventPublisher.publish(.directConnectionEstablished(peerId: targetPeerId, endpoint: peerInfo.endpoint))
                return connection
            }
            logger.debug("Direct ping to \(targetPeerId) failed, trying hole punch")
        }

        // Try hole punching if direct failed or NAT types suggest we need it
        let holePunchResult = await node.establishDirectConnection(to: targetPeerId)
        if case .success(let endpoint, let rtt) = holePunchResult {
            let rttMs = rtt * 1000.0
            let connection = DirectConnection(
                peerId: targetPeerId,
                endpoint: endpoint,
                isDirect: true,
                natType: targetNATType,
                rttMs: rttMs,
                method: .holePunch
            )
            await connectionTracker.setConnection(connection)
            await eventPublisher.publish(.holePunchSucceeded(peerId: targetPeerId, endpoint: endpoint, rttMs: rttMs))
            return connection
        }

        // Fall back to relay
        if let relayId = await node.getConnectedRelays().first {
            let connection = DirectConnection(
                peerId: targetPeerId,
                endpoint: peerInfo.endpoint,
                isDirect: false,
                relayPeerId: relayId,
                natType: targetNATType,
                method: .relay
            )
            await connectionTracker.setConnection(connection)
            await eventPublisher.publish(.peerConnected(peerId: targetPeerId, endpoint: peerInfo.endpoint, isDirect: false))
            return connection
        }

        throw MeshError.peerUnreachable(peerId: targetPeerId)
    }

    /// Disconnect from a peer
    public func disconnect(from peerId: PeerId) async {
        await connectionTracker.removeConnection(for: peerId)
        await eventPublisher.publish(.peerDisconnected(peerId: peerId, reason: .peerClosed))
    }

    /// Get connection to a peer
    public func connection(to peerId: PeerId) async -> DirectConnection? {
        await connectionTracker.getConnection(for: peerId)
    }

    /// Get all active connections
    public func activeConnections() async -> [DirectConnection] {
        await connectionTracker.activeConnections
    }

    // MARK: - Messaging

    /// Send data to a peer
    public func send(_ data: Data, to targetPeerId: PeerId) async throws {
        guard state == .running, let node = meshNode else {
            throw MeshError.notStarted
        }

        do {
            try await node.sendToPeer(MeshMessage.data(data), peerId: targetPeerId)
            await connectionTracker.updateLastCommunication(for: targetPeerId)
        } catch {
            await eventPublisher.publish(.messageSendFailed(to: targetPeerId, reason: error.localizedDescription))
            throw MeshError.sendFailed(reason: error.localizedDescription)
        }
    }

    /// Ping a peer and get detailed gossip results
    /// - Parameters:
    ///   - targetPeerId: The peer to ping
    ///   - timeout: Timeout in seconds
    /// - Returns: PingResult with latency and gossip info, or nil if failed
    public func ping(_ targetPeerId: PeerId, timeout: TimeInterval = 3.0) async -> MeshNode.PingResult? {
        guard state == .running, let node = meshNode else {
            return nil
        }
        return await node.sendPingWithDetails(to: targetPeerId, timeout: timeout)
    }

    /// Receive a message handler
    public func setMessageHandler(_ handler: @escaping (PeerId, Data) async -> Void) async {
        // Store handler for later if node doesn't exist yet
        pendingMessageHandler = handler

        // If node exists, apply handler immediately
        guard let node = meshNode else { return }
        await applyMessageHandler(to: node, handler: handler)
    }

    /// Apply message handler to node
    private func applyMessageHandler(to node: MeshNode, handler: @escaping (PeerId, Data) async -> Void) async {
        await node.setMessageHandler { [weak self] message, from in
            guard let self = self else { return }

            if case .data(let data) = message {
                await self.connectionTracker.updateLastCommunication(for: from)
                let connection = await self.connectionTracker.getConnection(for: from)
                await self.eventPublisher.publish(.messageReceived(
                    from: from,
                    data: data,
                    isDirect: connection?.isDirect ?? false
                ))
                await handler(from, data)
            }
        }
    }

    // MARK: - Peer Discovery

    /// Discover peers from bootstrap nodes
    public func discoverPeers() async throws {
        guard state == .running, let node = meshNode else {
            throw MeshError.notStarted
        }

        await node.requestPeers()
    }

    /// Add a peer endpoint manually
    public func addPeer(_ peerId: PeerId, endpoint: Endpoint) async {
        guard let node = meshNode else { return }

        await node.updatePeerEndpoint(peerId, endpoint: endpoint)
        await eventPublisher.publish(.peerDiscovered(peerId: peerId, endpoint: endpoint, viaBootstrap: false))
    }

    /// Get known peers
    public func knownPeers() async -> [PeerId] {
        guard let node = meshNode else { return [] }
        return await node.getCachedPeerIds()
    }

    // MARK: - Relay Operations

    /// Get connected relays
    public func connectedRelays() async -> [PeerId] {
        guard let node = meshNode else { return [] }
        return await node.getConnectedRelays()
    }

    /// Request relay services from a peer
    public func requestRelay(from relayId: PeerId, forTarget targetPeerId: PeerId) async throws {
        guard state == .running, let node = meshNode else {
            throw MeshError.notStarted
        }

        let sessionId = UUID().uuidString
        try await node.sendToPeer(MeshMessage.relayRequest(targetPeerId: targetPeerId, sessionId: sessionId), peerId: relayId)
    }

    // MARK: - Hole Punching

    /// Attempt to establish a direct connection via hole punching
    public func holePunch(to targetPeerId: PeerId) async throws -> DirectConnection {
        guard state == .running, let node = meshNode else {
            throw MeshError.notStarted
        }

        await eventPublisher.publish(.holePunchStarted(peerId: targetPeerId))

        let result = await node.establishDirectConnection(to: targetPeerId)

        switch result {
        case .success(let endpoint, let rtt):
            let rttMs = rtt * 1000.0
            let connection = DirectConnection(
                peerId: targetPeerId,
                endpoint: endpoint,
                isDirect: true,
                natType: .unknown,
                rttMs: rttMs,
                method: .holePunch
            )

            await connectionTracker.setConnection(connection)
            await eventPublisher.publish(.holePunchSucceeded(peerId: targetPeerId, endpoint: endpoint, rttMs: rttMs))
            await eventPublisher.publish(.directConnectionEstablished(peerId: targetPeerId, endpoint: endpoint))

            return connection

        case .failed(let reason):
            await eventPublisher.publish(.holePunchFailed(peerId: targetPeerId, reason: reason))
            throw reason.asMeshError(for: targetPeerId)
        }
    }

    // MARK: - Status

    /// Current NAT type
    public var currentNATType: NATType {
        natType
    }

    /// Current public endpoint
    public var currentPublicEndpoint: Endpoint? {
        publicEndpoint
    }

    /// Number of known peers
    public func peerCount() async -> Int {
        guard let node = meshNode else { return 0 }
        return await node.getCachedPeerIds().count
    }

    /// Number of active connections
    public func connectionCount() async -> Int {
        await connectionTracker.count
    }

    /// Number of direct connections
    public func directConnectionCount() async -> Int {
        await connectionTracker.directCount
    }

    /// Network statistics
    public func statistics() async -> MeshStatistics {
        guard let node = meshNode else {
            return MeshStatistics()
        }

        return MeshStatistics(
            peerCount: await node.getCachedPeerIds().count,
            connectionCount: await connectionTracker.count,
            directConnectionCount: await connectionTracker.directCount,
            relayCount: await node.getConnectedRelays().count,
            natType: natType,
            publicEndpoint: publicEndpoint,
            uptime: state == .running ? Date().timeIntervalSince(Date()) : 0
        )
    }

    // MARK: - Network Management

    /// Join a network using an invite link
    /// - Parameters:
    ///   - inviteLink: The invite link (omerta://join/...)
    ///   - name: Optional custom name for the network
    /// - Returns: The joined network
    public func joinNetwork(inviteLink: String, name: String? = nil) async throws -> Network {
        let networkKey = try NetworkKey.decode(from: inviteLink)
        return try await joinNetwork(key: networkKey, name: name)
    }

    /// Join a network using a NetworkKey
    /// - Parameters:
    ///   - key: The network key
    ///   - name: Optional custom name for the network
    /// - Returns: The joined network
    public func joinNetwork(key: NetworkKey, name: String? = nil) async throws -> Network {
        // Load existing networks first
        try await networkStore.load()

        // Join the network
        let network = try await networkStore.join(key, name: name)

        logger.info("Joined network: \(network.name)", metadata: ["networkId": "\(network.id)"])

        // Add bootstrap peers from the network key and announce to them
        for peer in key.bootstrapPeers {
            let parts = peer.split(separator: "@", maxSplits: 1)
            if parts.count == 2 {
                let bootstrapPeerId = String(parts[0])
                let endpoint = String(parts[1])
                await meshNode?.updatePeerEndpoint(bootstrapPeerId, endpoint: endpoint)
                await eventPublisher.publish(.peerDiscovered(peerId: bootstrapPeerId, endpoint: endpoint, viaBootstrap: true))

                // Send announcement to introduce ourselves
                await meshNode?.announceTo(endpoint: endpoint)
            }
        }

        // Brief delay to allow announcements to be processed
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Request peers from bootstrap nodes (now accepted since we're announced)
        await meshNode?.requestPeers()

        await eventPublisher.publish(.networkJoined(network: network))

        return network
    }

    /// Leave a network
    /// - Parameter networkId: The network ID to leave
    public func leaveNetwork(id networkId: String) async throws {
        try await networkStore.load()
        try await networkStore.leave(networkId)

        logger.info("Left network", metadata: ["networkId": "\(networkId)"])
        await eventPublisher.publish(.networkLeft(networkId: networkId))
    }

    /// Get all joined networks
    public func networks() async -> [Network] {
        try? await networkStore.load()
        return await networkStore.allNetworks()
    }

    /// Get a specific network by ID
    public func network(id: String) async -> Network? {
        try? await networkStore.load()
        return await networkStore.network(id: id)
    }

    /// Create a new network
    /// - Parameters:
    ///   - name: Name for the network
    ///   - bootstrapEndpoint: Optional endpoint for this node as bootstrap
    /// - Returns: The network key for sharing with others
    public func createNetwork(name: String, bootstrapEndpoint: String? = nil) async throws -> NetworkKey {
        var bootstrapPeers: [String] = []

        // Add ourselves as a bootstrap peer if endpoint provided
        if let endpoint = bootstrapEndpoint {
            bootstrapPeers.append("\(peerId)@\(endpoint)")
        } else if let publicEp = publicEndpoint {
            bootstrapPeers.append("\(peerId)@\(publicEp)")
        }

        // Generate network key
        let key = NetworkKey.generate(networkName: name, bootstrapPeers: bootstrapPeers)

        // Auto-join the network we created
        _ = try await joinNetwork(key: key, name: name)

        logger.info("Created network: \(name)", metadata: ["networkId": "\(key.deriveNetworkId())"])

        return key
    }

    // MARK: - Retry-Enabled Operations

    /// Connect to a peer with automatic retry
    /// - Parameters:
    ///   - peerId: The peer's ID
    ///   - retryConfig: Optional custom retry configuration
    /// - Returns: The established connection
    public func connectWithRetry(to targetPeerId: PeerId, retryConfig: RetryConfig? = nil) async throws -> DirectConnection {
        try await withRetry(
            config: retryConfig ?? self.retryConfig,
            operation: "connect to \(targetPeerId.prefix(8))...",
            shouldRetry: { error in
                guard let meshError = error as? MeshError else { return false }
                return meshError.shouldRetry
            }
        ) {
            try await self.connect(to: targetPeerId)
        }
    }

    /// Send data to a peer with automatic retry
    /// - Parameters:
    ///   - data: Data to send
    ///   - peerId: Target peer ID
    ///   - retryConfig: Optional custom retry configuration (ignored - endpoint fallback is used instead)
    /// - Note: Time-based retry is deprecated. Endpoint fallback is now built into send().
    ///   This method is kept for API compatibility but simply calls send().
    @available(*, deprecated, message: "Use send() instead - endpoint fallback is built-in")
    public func sendWithRetry(_ data: Data, to targetPeerId: PeerId, retryConfig: RetryConfig? = nil) async throws {
        try await send(data, to: targetPeerId)
    }

    /// Attempt hole punch with automatic retry
    /// - Parameters:
    ///   - peerId: Target peer ID
    ///   - retryConfig: Optional custom retry configuration
    /// - Returns: The established direct connection
    public func holePunchWithRetry(to targetPeerId: PeerId, retryConfig: RetryConfig? = nil) async throws -> DirectConnection {
        try await withRetry(
            config: retryConfig ?? .persistent,  // Hole punching benefits from more attempts
            operation: "hole punch to \(targetPeerId.prefix(8))...",
            shouldRetry: { error in
                guard let meshError = error as? MeshError else { return false }
                // Retry hole punch failures except for impossible cases
                switch meshError {
                case .holePunchFailed:
                    return true
                case .holePunchImpossible:
                    return false  // Both symmetric NAT, no point retrying
                default:
                    return meshError.shouldRetry
                }
            }
        ) {
            try await self.holePunch(to: targetPeerId)
        }
    }

    // MARK: - Private Methods

    private func detectNAT() async throws {
        let detector = NATDetector(stunServers: config.stunServers)

        do {
            let result = try await detector.detect(timeout: config.natDetectionTimeout)
            self.natType = result.type
            self.publicEndpoint = result.publicEndpoint

            logger.info("NAT detection complete", metadata: [
                "type": "\(result.type.rawValue)",
                "endpoint": "\(result.publicEndpoint ?? "none")"
            ])

            await eventPublisher.publish(.natDetected(type: result.type, publicEndpoint: result.publicEndpoint))
        } catch {
            logger.warning("NAT detection failed: \(error)")
            // Continue with unknown NAT type
            self.natType = .unknown
            await eventPublisher.publish(.warning(message: "NAT detection failed: \(error.localizedDescription)"))
        }
    }

    private func connectToBootstrapPeers() async {
        guard !config.bootstrapPeers.isEmpty else {
            logger.debug("No bootstrap peers configured")
            return
        }

        logger.info("Connecting to \(config.bootstrapPeers.count) bootstrap peer(s): \(config.bootstrapPeers)")

        for peer in config.bootstrapPeers {
            // Parse peer as "peerId@endpoint" or just "endpoint"
            let parts = peer.split(separator: "@", maxSplits: 1)
            if parts.count == 2 {
                let bootstrapPeerId = String(parts[0])
                let endpoint = String(parts[1])

                logger.info("Bootstrap: connecting to \(bootstrapPeerId) at \(endpoint)")

                await meshNode?.updatePeerEndpoint(bootstrapPeerId, endpoint: endpoint)
                await eventPublisher.publish(.peerDiscovered(
                    peerId: bootstrapPeerId,
                    endpoint: endpoint,
                    viaBootstrap: true
                ))

                // Send ping to bootstrap peer (public key is embedded in message)
                // This establishes the connection and gets peer list via recentPeers
                logger.info("Bootstrap: sending ping to \(endpoint)")
                await meshNode?.requestPeers()
            } else {
                logger.warning("Bootstrap: invalid peer format '\(peer)' - expected peerId@endpoint")
            }
        }
    }
}

// MARK: - State

/// State of the mesh network
public enum MeshNetworkState: String, Sendable, Equatable {
    case stopped
    case starting
    case detectingNAT
    case bootstrapping
    case running
    case stopping

    public var isActive: Bool {
        self == .running
    }
}

// MARK: - Statistics

/// Network statistics
public struct MeshStatistics: Sendable {
    public let peerCount: Int
    public let connectionCount: Int
    public let directConnectionCount: Int
    public let relayCount: Int
    public let natType: NATType
    public let publicEndpoint: Endpoint?
    public let uptime: TimeInterval

    public init(
        peerCount: Int = 0,
        connectionCount: Int = 0,
        directConnectionCount: Int = 0,
        relayCount: Int = 0,
        natType: NATType = .unknown,
        publicEndpoint: Endpoint? = nil,
        uptime: TimeInterval = 0
    ) {
        self.peerCount = peerCount
        self.connectionCount = connectionCount
        self.directConnectionCount = directConnectionCount
        self.relayCount = relayCount
        self.natType = natType
        self.publicEndpoint = publicEndpoint
        self.uptime = uptime
    }
}

// MARK: - Convenience Extensions

extension MeshNetwork {
    /// Create a mesh network with a randomly generated identity
    public static func create(config: MeshConfig) -> MeshNetwork {
        MeshNetwork(config: config)
    }

    /// Create a mesh network for a relay node
    public static func createRelay(
        identity: IdentityKeypair,
        encryptionKey: Data,
        bootstrapPeers: [String] = [],
        port: Int = 0
    ) -> MeshNetwork {
        var config = MeshConfig.relayNode(encryptionKey: encryptionKey, bootstrapPeers: bootstrapPeers)
        config.port = port
        return MeshNetwork(identity: identity, config: config)
    }

    /// Create a mesh network for a server
    public static func createServer(
        identity: IdentityKeypair,
        encryptionKey: Data,
        bootstrapPeers: [String] = [],
        port: Int = 0
    ) -> MeshNetwork {
        var config = MeshConfig.server(encryptionKey: encryptionKey, bootstrapPeers: bootstrapPeers)
        config.port = port
        return MeshNetwork(identity: identity, config: config)
    }
}
