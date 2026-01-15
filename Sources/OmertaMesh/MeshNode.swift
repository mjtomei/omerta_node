// MeshNode.swift - Main mesh network node actor

import Foundation
import NIOCore
import NIOPosix
import Crypto
import Logging

/// A node in the mesh network
public actor MeshNode {
    // MARK: - Configuration

    /// Configuration for MeshNode
    public struct Config: Sendable {
        /// 256-bit symmetric key for message encryption (required)
        public let encryptionKey: Data
        public let port: UInt16
        public let targetRelays: Int
        public let maxRelays: Int
        public let canRelay: Bool
        public let canCoordinateHolePunch: Bool
        public let keepaliveInterval: TimeInterval
        public let connectionTimeout: TimeInterval
        public let maxCachedPeers: Int
        public let peerCacheTTL: TimeInterval
        public let cacheCleanupInterval: TimeInterval
        public let recentContactMaxAge: TimeInterval
        public let freshnessQueryInterval: TimeInterval
        public let holePunchTimeout: TimeInterval
        public let holePunchProbeCount: Int
        public let holePunchProbeInterval: TimeInterval

        public init(
            encryptionKey: Data,
            port: UInt16 = 0,
            targetRelays: Int = 3,
            maxRelays: Int = 5,
            canRelay: Bool = false,
            canCoordinateHolePunch: Bool = false,
            keepaliveInterval: TimeInterval = 15,
            connectionTimeout: TimeInterval = 10,
            maxCachedPeers: Int = 500,
            peerCacheTTL: TimeInterval = 3600,
            cacheCleanupInterval: TimeInterval = 60,
            recentContactMaxAge: TimeInterval = 300,
            freshnessQueryInterval: TimeInterval = 30,
            holePunchTimeout: TimeInterval = 10,
            holePunchProbeCount: Int = 5,
            holePunchProbeInterval: TimeInterval = 0.2
        ) {
            self.encryptionKey = encryptionKey
            self.port = port
            self.targetRelays = targetRelays
            self.maxRelays = maxRelays
            self.canRelay = canRelay
            self.canCoordinateHolePunch = canCoordinateHolePunch
            self.keepaliveInterval = keepaliveInterval
            self.connectionTimeout = connectionTimeout
            self.maxCachedPeers = maxCachedPeers
            self.peerCacheTTL = peerCacheTTL
            self.cacheCleanupInterval = cacheCleanupInterval
            self.recentContactMaxAge = recentContactMaxAge
            self.freshnessQueryInterval = freshnessQueryInterval
            self.holePunchTimeout = holePunchTimeout
            self.holePunchProbeCount = holePunchProbeCount
            self.holePunchProbeInterval = holePunchProbeInterval
        }
    }

    /// Cached peer information
    public struct CachedPeerInfo: Sendable {
        public let peerId: PeerId
        public let endpoint: Endpoint
        public let natType: NATType
        public let lastSeen: Date

        public init(peerId: PeerId, endpoint: Endpoint, natType: NATType = .unknown, lastSeen: Date = Date()) {
            self.peerId = peerId
            self.endpoint = endpoint
            self.natType = natType
            self.lastSeen = lastSeen
        }
    }

    // MARK: - Properties

    /// This node's identity keypair
    public let identity: IdentityKeypair

    /// This node's peer ID (derived from identity public key)
    public var peerId: PeerId {
        identity.peerId
    }

    /// Node configuration
    public let config: Config

    /// Cached peer info
    private var peerCache: [PeerId: CachedPeerInfo] = [:]

    /// Connected relay peer IDs
    private var connectedRelays: Set<PeerId> = []

    /// Application message handler
    private var applicationMessageHandler: ((MeshMessage, PeerId) async -> Void)?

    /// The UDP socket for network communication
    private let socket: UDPSocket

    /// Event loop group for NIO
    private let eventLoopGroup: EventLoopGroup

    /// Known peer connections
    private var peers: [PeerId: PeerConnection] = [:]

    /// Peer endpoints for broadcasting
    private var peerEndpoints: [PeerId: String] = [:]

    /// Known peer public keys (peer ID → base64 public key) for signature verification
    private var peerPublicKeys: [PeerId: String] = [:]

    /// Message IDs we've seen (for deduplication)
    private var seenMessageIds: Set<String> = []
    private let maxSeenMessages = 10000

    /// Handler for incoming messages
    private var messageHandler: ((MeshMessage, PeerId) async -> MeshMessage?)?

    /// Pending responses for request/response pattern
    private var pendingResponses: [String: (continuation: CheckedContinuation<MeshMessage, Error>, timer: Task<Void, Never>)] = [:]

    /// Whether the node is running
    private var isRunning = false

    /// Logger
    private let logger: Logger

    /// Freshness manager for tracking recent contacts and handling stale info
    public let freshnessManager: FreshnessManager

    /// Hole punch manager for NAT traversal
    public let holePunchManager: HolePunchManager

    /// Connection keepalive manager for maintaining NAT mappings
    public let connectionKeepalive: ConnectionKeepalive

    /// Background task for cache cleanup
    private var cacheCleanupTask: Task<Void, Never>?

    /// The port we're listening on
    public var port: Int? {
        get async {
            await socket.port
        }
    }

    // MARK: - Initialization

    /// Create a new mesh node with a cryptographic identity and config
    /// - Parameters:
    ///   - identity: The cryptographic identity (peer ID is derived from this)
    ///   - config: Node configuration (must include encryption key)
    public init(identity: IdentityKeypair, config: Config) {
        self.identity = identity
        self.config = config
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.socket = UDPSocket(eventLoopGroup: self.eventLoopGroup)
        self.logger = Logger(label: "io.omerta.mesh.node.\(identity.peerId.prefix(8))")
        self.freshnessManager = FreshnessManager()
        self.holePunchManager = HolePunchManager(
            peerId: identity.peerId,
            config: HolePunchManager.Config(
                holePunchConfig: HolePunchConfig(
                    probeCount: config.holePunchProbeCount,
                    probeInterval: config.holePunchProbeInterval,
                    timeout: config.holePunchTimeout
                ),
                canCoordinate: config.canCoordinateHolePunch
            )
        )
        self.connectionKeepalive = ConnectionKeepalive(
            config: ConnectionKeepalive.Config(interval: config.keepaliveInterval)
        )
    }

    /// Set up the hole punch manager callbacks
    private func setupHolePunchManager() async {
        await holePunchManager.setCallbacks(
            sendMessage: { [weak self] (message: MeshMessage, toPeerId: PeerId) in
                guard let self = self else { return }
                if let endpoint = await self.getEndpoint(for: toPeerId) {
                    await self.send(message, to: endpoint)
                }
            },
            getPeerEndpoint: { [weak self] (peerId: PeerId) -> Endpoint? in
                guard let self = self else { return nil }
                return await self.getEndpoint(for: peerId)
            },
            getPeerNATType: { (_: PeerId) -> NATType? in
                // For now, return unknown - could be enhanced with peer NAT tracking
                return NATType.unknown
            },
            getCoordinatorPeerId: { [weak self] () -> PeerId? in
                // Return first known public peer as coordinator
                // In production, this would use a smarter selection
                guard let self = self else { return nil }
                return await self.peerEndpoints.keys.first
            }
        )
    }

    /// Set up the freshness manager callbacks
    private func setupFreshnessManager() async {
        await freshnessManager.setCallbacks(
            sendMessage: { [weak self] (message: MeshMessage, toPeerId: PeerId?) in
                guard let self = self else { return }
                if let toPeerId = toPeerId,
                   let endpoint = await self.getEndpoint(for: toPeerId) {
                    await self.send(message, to: endpoint)
                }
            },
            broadcastMessage: { [weak self] (message: MeshMessage, maxHops: Int) in
                guard let self = self else { return }
                await self.broadcast(message, maxHops: maxHops)
            },
            invalidateCache: { [weak self] (peerId: PeerId, path: ReachabilityPath) in
                // Cache invalidation can be handled by higher layers
                // For now, just log it
                guard let self = self else { return }
                self.logger.debug("Cache invalidation requested for \(peerId)")
            }
        )
    }

    /// Set up the connection keepalive callbacks
    private func setupConnectionKeepalive() async {
        await connectionKeepalive.setPingSender { [weak self] (peerId: PeerId, endpoint: String) -> Bool in
            guard let self = self else { return false }
            return await self.sendPing(to: peerId, timeout: 5.0)
        }

        await connectionKeepalive.setFailureHandler { [weak self] (peerId: PeerId, endpoint: String) in
            guard let self = self else { return }
            self.logger.warning("Connection to \(peerId) failed keepalive check")
            // Remove from direct connections - could trigger reconnection or relay fallback
            await self.handleKeepaliveFailure(peerId: peerId, endpoint: endpoint)
        }
    }

    /// Handle a keepalive failure for a peer
    private func handleKeepaliveFailure(peerId: PeerId, endpoint: String) async {
        // Remove from peer endpoints if still pointing to the failed endpoint
        if peerEndpoints[peerId] == endpoint {
            logger.info("Removing stale endpoint for \(peerId) due to keepalive failure")
            // Don't remove the endpoint entirely - just mark as potentially stale
            // Higher layers can decide whether to try relay or re-punch
        }

        // Notify freshness manager about the failure
        let _ = await freshnessManager.pathFailureReporter.reportFailure(
            peerId: peerId,
            path: .direct(endpoint: endpoint)
        )
    }

    /// Get endpoint for a peer
    private func getEndpoint(for peerId: PeerId) -> String? {
        peerEndpoints[peerId]
    }

    /// Broadcast a message to all known peers with hop count tracking
    public func broadcast(_ message: MeshMessage, maxHops: Int) async {
        for (peerId, endpoint) in peerEndpoints {
            guard peerId != self.peerId else { continue }

            do {
                var envelope = MeshEnvelope(
                    fromPeerId: self.peerId,
                    toPeerId: nil,
                    hopCount: 0,
                    payload: message
                )

                let dataToSign = try envelope.dataToSign()
                let sig = try identity.sign(dataToSign)
                envelope.signature = sig.base64

                let data = try JSONEncoder().encode(envelope)
                try await socket.send(data, to: endpoint)
            } catch {
                logger.debug("Failed to broadcast to \(peerId): \(error)")
            }
        }
    }

    /// Set up the receive handler for incoming datagrams
    private func setupReceiveHandler() async {
        await socket.onReceive { [weak self] data, address in
            guard let self = self else { return }
            await self.handleIncomingData(data, from: address)
        }
    }

    // MARK: - Lifecycle

    /// Start the node
    public func start(natType: NATType = .unknown) async throws {
        guard !isRunning else { return }

        // Bind socket if not already bound
        let currentPort = await socket.port
        logger.debug("MeshNode.start() - current socket port: \(currentPort?.description ?? "nil"), config.port: \(config.port)")

        if currentPort == nil {
            logger.debug("MeshNode.start() - binding socket to port \(config.port)")
            try await socket.bind(port: Int(config.port))
            logger.debug("MeshNode.start() - socket bound successfully")
            await setupReceiveHandler()
            await setupFreshnessManager()
            await setupHolePunchManager()
            await setupConnectionKeepalive()
        } else {
            logger.debug("MeshNode.start() - socket already bound to port \(currentPort!)")
        }

        isRunning = true

        // Start freshness manager
        await freshnessManager.start()

        // Start hole punch manager
        let boundPort = await socket.port ?? 0
        logger.debug("MeshNode.start() - boundPort after start: \(boundPort)")
        await holePunchManager.start(natType: natType, localPort: UInt16(boundPort))

        // Start connection keepalive
        await connectionKeepalive.start()

        // Start cache cleanup
        startCacheCleanup()

        logger.info("Mesh node started on port \(boundPort)")
    }

    /// Stop the node
    public func stop() async {
        guard isRunning else { return }
        isRunning = false

        // Stop freshness manager
        await freshnessManager.stop()

        // Stop hole punch manager
        await holePunchManager.stop()

        // Stop connection keepalive
        await connectionKeepalive.stop()

        // Stop cache cleanup
        cacheCleanupTask?.cancel()
        cacheCleanupTask = nil

        // Cancel all pending responses
        for (_, pending) in pendingResponses {
            pending.timer.cancel()
            pending.continuation.resume(throwing: MeshNodeError.stopped)
        }
        pendingResponses.removeAll()

        await socket.close()
        logger.info("Mesh node stopped")
    }

    // MARK: - Message Handling

    /// Register a handler for incoming messages
    public func onMessage(_ handler: @escaping (MeshMessage, PeerId) async -> MeshMessage?) {
        self.messageHandler = handler
    }

    /// Handle incoming UDP data
    private func handleIncomingData(_ data: Data, from address: NIOCore.SocketAddress) async {
        logger.info("Received \(data.count) bytes from \(address)")

        // Decrypt the data first
        guard let decryptedData = try? MessageEncryption.decrypt(data, key: config.encryptionKey) else {
            logger.warning("Failed to decrypt message from \(address) (\(data.count) bytes)")
            return
        }

        // Decode the envelope
        guard let envelope = try? JSONDecoder().decode(MeshEnvelope.self, from: decryptedData) else {
            logger.debug("Failed to decode message from \(address)")
            return
        }

        // Check for duplicates
        if seenMessageIds.contains(envelope.messageId) {
            logger.debug("Ignoring duplicate message \(envelope.messageId)")
            return
        }
        markMessageSeen(envelope.messageId)

        // Get the sender's public key from registry or connected peers
        let senderPublicKey: String?
        if let registeredKey = peerPublicKeys[envelope.fromPeerId] {
            senderPublicKey = registeredKey
        } else if let peer = peers[envelope.fromPeerId] {
            senderPublicKey = await peer.publicKey.rawRepresentation.base64EncodedString()
        } else {
            senderPublicKey = nil
        }

        // Handle unknown sender (only PeerAnnouncements are self-authenticating)
        guard let senderKey = senderPublicKey else {
            await handleUnknownSender(envelope, from: address)
            return
        }

        // Verify signature - REQUIRED for all messages from known peers
        guard envelope.verifySignature(publicKeyBase64: senderKey) else {
            logger.warning("Rejecting message with invalid signature",
                          metadata: ["from": "\(envelope.fromPeerId.prefix(8))..."])
            return
        }

        // Update peer info and track endpoint
        let endpointString = formatEndpoint(address)
        await updatePeerEndpointFromMessage(peerId: envelope.fromPeerId, endpoint: endpointString)

        // Check if this is a response to a pending request
        if case .pong = envelope.payload {
            // Find any pending ping request
            for (requestId, pending) in pendingResponses {
                if requestId.hasPrefix("ping-") {
                    pendingResponses.removeValue(forKey: requestId)
                    pending.timer.cancel()
                    pending.continuation.resume(returning: envelope.payload)
                    return
                }
            }
        }

        if case .response(let requestId, _) = envelope.payload {
            if let pending = pendingResponses.removeValue(forKey: requestId) {
                pending.timer.cancel()
                pending.continuation.resume(returning: envelope.payload)
                return
            }
        }

        // Handle through message handler or default
        if let handler = messageHandler {
            if let response = await handler(envelope.payload, envelope.fromPeerId) {
                await send(response, to: endpointString)
            }
        } else {
            await handleDefaultMessage(envelope.payload, from: envelope.fromPeerId, endpoint: endpointString, hopCount: envelope.hopCount)
        }
    }

    /// Handle messages from unknown senders (not in peer registry)
    /// Only PeerAnnouncement messages are self-authenticating and can be accepted
    private func handleUnknownSender(_ envelope: MeshEnvelope, from address: NIOCore.SocketAddress) async {
        // Only PeerAnnouncement messages are self-authenticating
        guard case .peerInfo(let announcement) = envelope.payload else {
            logger.debug("Rejecting non-announcement from unknown peer",
                        metadata: ["from": "\(envelope.fromPeerId.prefix(8))..."])
            return
        }

        // Verify the announcement signature using its embedded public key
        guard envelope.verifySignature(publicKeyBase64: announcement.publicKey) else {
            logger.warning("Rejecting announcement with invalid signature",
                          metadata: ["from": "\(envelope.fromPeerId.prefix(8))..."])
            return
        }

        // Verify peer ID is correctly derived from public key
        guard IdentityKeypair.verifyPeerIdDerivation(peerId: announcement.peerId, publicKeyBase64: announcement.publicKey) else {
            logger.warning("Rejecting announcement with mismatched peer ID",
                          metadata: ["claimed": "\(announcement.peerId.prefix(8))..."])
            return
        }

        // Now we can trust this peer - register their public key
        peerPublicKeys[announcement.peerId] = announcement.publicKey
        logger.info("Registered new peer from announcement",
                    metadata: ["peerId": "\(announcement.peerId.prefix(8))..."])

        // Process the announcement as a regular message
        let endpointString = formatEndpoint(address)
        await handleDefaultMessage(envelope.payload, from: envelope.fromPeerId, endpoint: endpointString, hopCount: envelope.hopCount)
    }

    /// Default message handling for basic protocol
    private func handleDefaultMessage(_ message: MeshMessage, from peerId: PeerId, endpoint: String, hopCount: Int = 0) async {
        switch message {
        case .ping(let recentPeers):
            // Record this contact first so we're included in the response
            await freshnessManager.recordContact(
                peerId: peerId,
                reachability: .direct(endpoint: endpoint),
                latencyMs: 0,
                connectionType: .inboundDirect
            )

            // Also update our peer endpoint cache
            peerEndpoints[peerId] = endpoint
            peerCache[peerId] = CachedPeerInfo(peerId: peerId, endpoint: endpoint)

            // Respond with pong including our recent peers with endpoints
            var myRecentPeers = await freshnessManager.recentPeersWithEndpoints
            // Also include peers from our cache that may not be in freshness yet
            for (id, ep) in peerEndpoints where id != self.peerId {
                if myRecentPeers[id] == nil {
                    myRecentPeers[id] = ep
                }
            }
            // Limit to 10 peers
            var limitedPeers: [String: String] = [:]
            for (id, ep) in myRecentPeers {
                limitedPeers[id] = ep
                if limitedPeers.count >= 10 { break }
            }
            await send(.pong(recentPeers: limitedPeers), to: endpoint)

            // Learn about new peers from the ping
            for (peerIdFromPing, peerEndpoint) in recentPeers {
                if peerIdFromPing != self.peerId && peerEndpoints[peerIdFromPing] == nil {
                    logger.info("Learned about peer \(peerIdFromPing) at \(peerEndpoint) from \(peerId)")
                    peerEndpoints[peerIdFromPing] = peerEndpoint
                    peerCache[peerIdFromPing] = CachedPeerInfo(peerId: peerIdFromPing, endpoint: peerEndpoint)
                }
            }

        case .pong(let recentPeers):
            // Cache the pong sender's endpoint - CRITICAL for connect() to work
            peerEndpoints[peerId] = endpoint
            peerCache[peerId] = CachedPeerInfo(peerId: peerId, endpoint: endpoint)
            logger.info("Cached pong sender: \(peerId.prefix(8))... at \(endpoint)")

            // Learn about new peers from the pong
            for (peerIdFromPong, peerEndpoint) in recentPeers {
                if peerIdFromPong != self.peerId && peerEndpoints[peerIdFromPong] == nil {
                    logger.info("Learned about peer \(peerIdFromPong) at \(peerEndpoint) from pong")
                    peerEndpoints[peerIdFromPong] = peerEndpoint
                    peerCache[peerIdFromPong] = CachedPeerInfo(peerId: peerIdFromPong, endpoint: peerEndpoint)
                }
            }

            // Record this as a recent contact
            await freshnessManager.recordContact(
                peerId: peerId,
                reachability: .direct(endpoint: endpoint),
                latencyMs: 0,
                connectionType: .direct
            )

            // Update keepalive monitoring - pong means connection is healthy
            if await connectionKeepalive.isMonitoring(peerId: peerId) {
                await connectionKeepalive.recordSuccessfulCommunication(peerId: peerId)
            }

        case .whoHasRecent, .iHaveRecent, .pathFailed:
            // Handle freshness messages
            let (response, shouldForward) = await freshnessManager.handleMessage(
                message,
                from: peerId,
                hopCount: hopCount
            )

            // Send response if any
            if let response = response {
                await send(response, to: endpoint)
            }

            // Forward if needed
            if shouldForward {
                await forwardMessage(message, from: peerId, hopCount: hopCount + 1)
            }

        case .holePunchRequest, .holePunchInvite, .holePunchExecute, .holePunchResult:
            // Handle hole punch messages
            if let response = await holePunchManager.handleMessage(message, from: peerId) {
                await send(response, to: endpoint)
            }

        case .data(let payload):
            // Pass application data to the handler
            if let handler = applicationMessageHandler {
                await handler(.data(payload), peerId)
            }

        case .peerInfo:
            // Record this contact when receiving a peer announcement
            await freshnessManager.recordContact(
                peerId: peerId,
                reachability: .direct(endpoint: endpoint),
                latencyMs: 0,
                connectionType: .inboundDirect
            )

            // Update our peer endpoint cache - CRITICAL for connect() to work
            peerEndpoints[peerId] = endpoint
            peerCache[peerId] = CachedPeerInfo(peerId: peerId, endpoint: endpoint)
            logger.info("Cached peer endpoint: \(peerId.prefix(8))... at \(endpoint)")

        default:
            break
        }
    }

    /// Forward a message to other peers (for gossip propagation)
    private func forwardMessage(_ message: MeshMessage, from originalSender: PeerId, hopCount: Int) async {
        for (peerId, endpoint) in peerEndpoints {
            // Don't forward back to sender or to ourselves
            guard peerId != originalSender && peerId != self.peerId else { continue }

            do {
                var envelope = MeshEnvelope(
                    fromPeerId: self.peerId,
                    toPeerId: nil,
                    hopCount: hopCount,
                    payload: message
                )

                let dataToSign = try envelope.dataToSign()
                let sig = try identity.sign(dataToSign)
                envelope.signature = sig.base64

                let data = try JSONEncoder().encode(envelope)
                try await socket.send(data, to: endpoint)
            } catch {
                logger.debug("Failed to forward to \(peerId): \(error)")
            }
        }
    }

    // MARK: - Sending Messages

    /// Send a message to an endpoint
    public func send(_ message: MeshMessage, to endpoint: String) async {
        do {
            // Create envelope with CLI-specified peerId (not cryptographic ID)
            var envelope = MeshEnvelope(
                fromPeerId: peerId,  // Use self.peerId, not identity.peerId
                toPeerId: nil,
                payload: message
            )

            // Sign with our identity
            let dataToSign = try envelope.dataToSign()
            let sig = try identity.sign(dataToSign)
            envelope.signature = sig.base64

            // Encode to JSON then encrypt
            let jsonData = try JSONEncoder().encode(envelope)
            let encryptedData = try MessageEncryption.encrypt(jsonData, key: config.encryptionKey)
            try await socket.send(encryptedData, to: endpoint)

            logger.debug("Sent \(type(of: message)) to \(endpoint)")
        } catch {
            logger.error("Failed to send message: \(error)")
        }
    }

    /// Send a message and wait for a response
    public func sendAndReceive(
        _ message: MeshMessage,
        to endpoint: String,
        timeout: TimeInterval = 5.0
    ) async throws -> MeshMessage {
        let requestId: String

        switch message {
        case .ping:
            requestId = "ping-\(UUID().uuidString)"
        case .request(let rid, _):
            requestId = rid
        default:
            requestId = UUID().uuidString
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Create timeout task
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = self.pendingResponses.removeValue(forKey: requestId) {
                    pending.continuation.resume(throwing: MeshNodeError.timeout)
                }
            }

            // Store continuation
            self.pendingResponses[requestId] = (continuation, timeoutTask)

            // Send the message
            Task {
                await self.send(message, to: endpoint)
            }
        }
    }

    // MARK: - Peer Management

    /// Update a peer's endpoint
    private func updatePeerEndpointFromMessage(peerId: PeerId, endpoint: String) async {
        // Update PeerConnection if we have one
        if let peer = peers[peerId] {
            await peer.setActiveEndpoint(endpoint)
            await peer.updateLastSeen()
        }

        // Always update the endpoint cache so getCachedPeer works
        peerEndpoints[peerId] = endpoint
        peerCache[peerId] = CachedPeerInfo(peerId: peerId, endpoint: endpoint)
    }

    /// Add a peer with known public key
    public func addPeer(publicKeyBase64: String, endpoints: [String] = []) throws {
        let connection = try PeerConnection(publicKeyBase64: publicKeyBase64, endpoints: endpoints)
        peers[connection.peerId] = connection
    }

    /// Get known peer IDs
    public var knownPeerIds: [PeerId] {
        Array(peers.keys)
    }

    /// Get all tracked peer endpoints
    public var trackedEndpoints: [PeerId: String] {
        peerEndpoints
    }

    // MARK: - MeshNetwork API Methods

    /// Get cached peer info
    public func getCachedPeer(_ peerId: PeerId) async -> CachedPeerInfo? {
        peerCache[peerId]
    }

    /// Get list of cached peer IDs
    public func getCachedPeerIds() async -> [PeerId] {
        Array(peerCache.keys) + Array(peerEndpoints.keys)
    }

    /// Get connected relay peer IDs
    public func getConnectedRelays() async -> [PeerId] {
        Array(connectedRelays)
    }

    /// Update a peer's endpoint (public API for MeshNetwork)
    public func updatePeerEndpoint(_ peerId: PeerId, endpoint: Endpoint) async {
        peerEndpoints[peerId] = endpoint
        peerCache[peerId] = CachedPeerInfo(peerId: peerId, endpoint: endpoint)
    }

    /// Request peer list from known peers
    public func requestPeers() async {
        // Build our peer list to share
        var myPeers: [String: String] = [:]
        for (id, ep) in peerEndpoints where id != self.peerId {
            myPeers[id] = ep
            if myPeers.count >= 10 { break }
        }

        for (peerId, endpoint) in peerEndpoints {
            guard peerId != self.peerId else { continue }
            await send(.ping(recentPeers: myPeers), to: endpoint)
        }
    }

    /// Send a self-announcement to a specific endpoint
    /// This is used during bootstrap to introduce ourselves before sending pings
    /// The announcement is self-authenticating (contains our public key)
    public func announceTo(endpoint: Endpoint) async {
        // Determine our reachability
        var reachability: [ReachabilityPath] = []
        if let boundPort = await socket.port {
            // We don't know our public IP, but we can be reached on our bound port
            // The receiver will use the source address of the UDP packet
            reachability.append(.direct(endpoint: "0.0.0.0:\(boundPort)"))
        }

        // Create signed announcement
        do {
            let announcement = try Gossip.createAnnouncement(
                identity: identity,
                reachability: reachability,
                capabilities: config.canRelay ? ["relay"] : []
            )

            // Send as peerInfo message (self-authenticating)
            await send(.peerInfo(announcement), to: endpoint)
            logger.info("Sent announcement to \(endpoint) (peerId=\(identity.peerId))")
        } catch {
            logger.error("Failed to create announcement: \(error)")
        }
    }

    /// Announce to all known peers (bootstrap introduction)
    public func announceToAllPeers() async {
        for (peerId, endpoint) in peerEndpoints {
            guard peerId != self.peerId else { continue }
            await announceTo(endpoint: endpoint)
        }
    }

    /// Send a message to a peer by ID
    public func sendToPeer(_ message: MeshMessage, peerId: PeerId) async throws {
        guard let endpoint = peerEndpoints[peerId] else {
            throw MeshNodeError.peerNotFound
        }
        await send(message, to: endpoint)
    }

    /// Set the application message handler
    public func setMessageHandler(_ handler: @escaping (MeshMessage, PeerId) async -> Void) async {
        self.applicationMessageHandler = handler
    }

    // MARK: - Freshness Operations

    /// Query the network for fresh information about a peer
    public func findFreshPeerInfo(_ peerId: PeerId) async -> FreshnessQueryResult {
        await freshnessManager.queryFreshInfo(for: peerId)
    }

    /// Report a connection failure for a peer
    public func reportConnectionFailure(
        to peerId: PeerId,
        via path: ReachabilityPath
    ) async {
        await freshnessManager.reportConnectionFailure(peerId: peerId, path: path)
    }

    /// Check if a path is known to have failed
    public func isPathFailed(_ peerId: PeerId, path: ReachabilityPath) async -> Bool {
        await freshnessManager.isPathFailed(peerId: peerId, path: path)
    }

    /// Get recent contacts
    public var recentContacts: [PeerId: RecentContact] {
        get async {
            var result: [PeerId: RecentContact] = [:]
            for contact in await freshnessManager.recentContacts.allContacts {
                result[contact.peerId] = contact
            }
            return result
        }
    }

    // MARK: - Hole Punch Operations

    /// Establish a direct connection to a peer via hole punching
    public func establishDirectConnection(to targetPeerId: PeerId) async -> HolePunchResult {
        await holePunchManager.establishDirectConnection(to: targetPeerId)
    }

    /// Update our known NAT type
    public func updateNATType(_ natType: NATType) async {
        await holePunchManager.updateNATType(natType)
    }

    /// Send a ping to a peer and wait for pong response
    /// Returns true if pong received, false if timeout or error
    public func sendPing(to targetPeerId: PeerId, timeout: TimeInterval = 3.0) async -> Bool {
        // Get the endpoint for this peer
        guard let endpoint = peerEndpoints[targetPeerId] else {
            logger.debug("sendPing: No endpoint for peer \(targetPeerId)")
            return false
        }

        // Send ping and wait for pong
        let recentPeers = await freshnessManager.recentPeersWithEndpoints
        var limitedPeers: [String: String] = [:]
        for (id, ep) in recentPeers.prefix(5) {
            limitedPeers[id] = ep
        }
        let ping = MeshMessage.ping(recentPeers: limitedPeers)

        let startTime = Date()
        do {
            let response = try await sendAndReceive(ping, to: endpoint, timeout: timeout)
            if case .pong = response {
                let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
                logger.debug("sendPing: Got pong from \(targetPeerId) in \(latencyMs)ms")
                // Record this as a recent contact
                await freshnessManager.recordContact(
                    peerId: targetPeerId,
                    reachability: .direct(endpoint: endpoint),
                    latencyMs: latencyMs,
                    connectionType: .direct
                )
                // Add to keepalive monitoring if not already monitored
                if await !connectionKeepalive.isMonitoring(peerId: targetPeerId) {
                    await connectionKeepalive.addConnection(peerId: targetPeerId, endpoint: endpoint)
                } else {
                    // Update successful communication
                    await connectionKeepalive.recordSuccessfulCommunication(peerId: targetPeerId)
                }
                return true
            }
            return false
        } catch {
            logger.debug("sendPing: Failed to ping \(targetPeerId): \(error)")
            return false
        }
    }

    // MARK: - Keepalive Management

    /// Add a direct connection to keepalive monitoring
    public func addToKeepalive(peerId: PeerId, endpoint: String) async {
        await connectionKeepalive.addConnection(peerId: peerId, endpoint: endpoint)
    }

    /// Remove a connection from keepalive monitoring
    public func removeFromKeepalive(peerId: PeerId) async {
        await connectionKeepalive.removeConnection(peerId: peerId)
    }

    /// Check if a peer is being monitored for keepalive
    public func isMonitoringKeepalive(peerId: PeerId) async -> Bool {
        await connectionKeepalive.isMonitoring(peerId: peerId)
    }

    /// Get keepalive statistics
    public func keepaliveStatistics() async -> ConnectionKeepalive.Statistics {
        await connectionKeepalive.statistics
    }

    /// Get all connections being monitored for keepalive
    public func monitoredConnections() async -> [ConnectionKeepalive.ConnectionState] {
        await connectionKeepalive.monitoredConnections
    }

    // MARK: - Cache Cleanup

    /// Start the periodic cache cleanup task
    private func startCacheCleanup() {
        guard cacheCleanupTask == nil else { return }

        cacheCleanupTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(config.cacheCleanupInterval * 1_000_000_000))
                    cleanupExpiredPeers()
                } catch {
                    // Task cancelled
                    break
                }
            }
        }

        logger.debug("Cache cleanup started with interval \(config.cacheCleanupInterval)s, TTL \(config.peerCacheTTL)s")
    }

    /// Remove peers that haven't been seen within the TTL
    private func cleanupExpiredPeers() {
        let now = Date()
        let ttl = config.peerCacheTTL
        var expiredPeers: [PeerId] = []

        for (peerId, info) in peerCache {
            let age = now.timeIntervalSince(info.lastSeen)
            if age > ttl {
                expiredPeers.append(peerId)
            }
        }

        // Remove expired peers from cache and endpoints
        for peerId in expiredPeers {
            peerCache.removeValue(forKey: peerId)
            peerEndpoints.removeValue(forKey: peerId)
        }

        if !expiredPeers.isEmpty {
            logger.debug("Cleaned up \(expiredPeers.count) expired peers from cache")
        }

        // Also enforce maxCachedPeers limit
        if peerCache.count > config.maxCachedPeers {
            // Sort by lastSeen and remove oldest
            let sortedPeers = peerCache.sorted { $0.value.lastSeen < $1.value.lastSeen }
            let toRemove = sortedPeers.prefix(peerCache.count - config.maxCachedPeers)
            for (peerId, _) in toRemove {
                peerCache.removeValue(forKey: peerId)
                peerEndpoints.removeValue(forKey: peerId)
            }
            if toRemove.count > 0 {
                logger.debug("Evicted \(toRemove.count) oldest peers to enforce max cache size")
            }
        }
    }

    // MARK: - Message Deduplication

    /// Mark a message ID as seen
    private func markMessageSeen(_ messageId: String) {
        seenMessageIds.insert(messageId)

        // Prune if too large
        if seenMessageIds.count > maxSeenMessages {
            let toRemove = seenMessageIds.prefix(maxSeenMessages / 2)
            for id in toRemove {
                seenMessageIds.remove(id)
            }
        }
    }

    /// Check if a message has been seen
    public func hasSeenMessage(_ messageId: String) -> Bool {
        seenMessageIds.contains(messageId)
    }

    /// Register a peer's public key (for testing and bootstrap)
    /// Once registered, messages from this peer must be signed with this key
    public func registerPeerPublicKey(_ peerId: PeerId, publicKey: String) {
        // Verify the peer ID matches the public key derivation
        guard IdentityKeypair.verifyPeerIdDerivation(peerId: peerId, publicKeyBase64: publicKey) else {
            logger.warning("Refused to register peer with mismatched ID",
                          metadata: ["peerId": "\(peerId.prefix(8))..."])
            return
        }
        peerPublicKeys[peerId] = publicKey
    }

    /// Get the registered public key for a peer (for testing)
    public func getPublicKey(for peerId: PeerId) -> String? {
        peerPublicKeys[peerId]
    }

    /// Receive an envelope directly (for testing)
    /// Requires sender to be registered in peerPublicKeys or peers
    public func receiveEnvelope(_ envelope: MeshEnvelope) async -> Bool {
        // Get sender's public key from registry or connected peers
        let senderPublicKey: String?
        if let registeredKey = peerPublicKeys[envelope.fromPeerId] {
            senderPublicKey = registeredKey
        } else if let peer = peers[envelope.fromPeerId] {
            senderPublicKey = await peer.publicKey.rawRepresentation.base64EncodedString()
        } else {
            // For PeerAnnouncements, use embedded key (self-authenticating)
            if case .peerInfo(let announcement) = envelope.payload {
                // Verify peer ID derivation first
                guard IdentityKeypair.verifyPeerIdDerivation(peerId: announcement.peerId, publicKeyBase64: announcement.publicKey) else {
                    logger.warning("Rejected announcement with mismatched peer ID")
                    return false
                }
                senderPublicKey = announcement.publicKey
            } else {
                logger.warning("Rejected message from unknown peer: \(envelope.fromPeerId.prefix(8))...")
                return false
            }
        }

        // Verify signature - REQUIRED for all messages
        guard let key = senderPublicKey, envelope.verifySignature(publicKeyBase64: key) else {
            logger.warning("Rejected message with invalid signature from \(envelope.fromPeerId.prefix(8))...")
            return false
        }

        // Check for duplicates
        if seenMessageIds.contains(envelope.messageId) {
            return false
        }
        markMessageSeen(envelope.messageId)

        // If this was a valid announcement, register the peer
        if case .peerInfo(let announcement) = envelope.payload {
            peerPublicKeys[announcement.peerId] = announcement.publicKey
        }

        return true
    }

    // MARK: - Utilities

    /// Format a SocketAddress as "host:port" string
    private nonisolated func formatEndpoint(_ address: NIOCore.SocketAddress) -> String {
        guard let port = address.port else {
            return "\(address)"
        }
        switch address {
        case .v4(let addr):
            return "\(addr.host):\(port)"
        case .v6(let addr):
            return "[\(addr.host)]:\(port)"
        case .unixDomainSocket:
            return "unix:\(address)"
        }
    }
}

/// Errors from MeshNode operations
public enum MeshNodeError: Error, CustomStringConvertible {
    case stopped
    case timeout
    case peerNotFound
    case sendFailed(Error)

    public var description: String {
        switch self {
        case .stopped:
            return "Node has stopped"
        case .timeout:
            return "Request timed out"
        case .peerNotFound:
            return "Peer not found"
        case .sendFailed(let error):
            return "Send failed: \(error)"
        }
    }
}
