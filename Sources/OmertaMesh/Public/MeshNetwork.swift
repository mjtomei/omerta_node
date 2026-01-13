// MeshNetwork.swift - Main entry point for the mesh network

import Foundation
import Logging
import NIOCore
import NIOPosix

/// The main entry point for the mesh network
/// This actor wraps all internal components and provides a clean public API
public actor MeshNetwork {
    // MARK: - Properties

    /// Our peer ID (public key)
    public let peerId: PeerId

    /// Configuration
    public let config: MeshConfig

    /// Current state
    public private(set) var state: MeshNetworkState = .stopped

    /// Event publisher for subscribers
    private let eventPublisher = MeshEventPublisher()

    /// Connection tracker
    private let connectionTracker: DirectConnectionTracker

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

    // MARK: - Initialization

    /// Create a new mesh network
    /// - Parameters:
    ///   - peerId: Our peer ID (usually a public key)
    ///   - config: Network configuration
    public init(peerId: PeerId, config: MeshConfig = .default) {
        self.peerId = peerId
        self.config = config
        self.connectionTracker = DirectConnectionTracker(staleThreshold: config.recentContactMaxAge)
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

            let node = MeshNode(peerId: peerId, config: nodeConfig)
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

        for peer in config.bootstrapPeers {
            // Parse peer as "peerId@endpoint" or just "endpoint"
            let parts = peer.split(separator: "@", maxSplits: 1)
            if parts.count == 2 {
                let bootstrapPeerId = String(parts[0])
                let endpoint = String(parts[1])

                await meshNode?.updatePeerEndpoint(bootstrapPeerId, endpoint: endpoint)
                await eventPublisher.publish(.peerDiscovered(
                    peerId: bootstrapPeerId,
                    endpoint: endpoint,
                    viaBootstrap: true
                ))

                // Request peer list from bootstrap
                await meshNode?.requestPeers()
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
    /// Create a mesh network with a randomly generated peer ID
    public static func create(config: MeshConfig = .default) -> MeshNetwork {
        let peerId = UUID().uuidString
        return MeshNetwork(peerId: peerId, config: config)
    }

    /// Create a mesh network for a relay node
    public static func createRelay(peerId: PeerId, port: Int = 0) -> MeshNetwork {
        var config = MeshConfig.relayNode
        config.port = port
        return MeshNetwork(peerId: peerId, config: config)
    }

    /// Create a mesh network for a mobile device
    public static func createMobile(peerId: PeerId) -> MeshNetwork {
        MeshNetwork(peerId: peerId, config: .mobile)
    }

    /// Create a mesh network for a server
    public static func createServer(peerId: PeerId, port: Int = 0) -> MeshNetwork {
        var config = MeshConfig.server
        config.port = port
        return MeshNetwork(peerId: peerId, config: config)
    }
}
