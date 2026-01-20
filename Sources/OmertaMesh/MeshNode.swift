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

        /// Network ID derived from encryption key (used for storage scoping)
        /// This ensures each network has isolated persistent storage
        public var networkId: String {
            // Hash the encryption key and take first 16 hex chars for a readable ID
            let hash = SHA256.hash(data: encryptionKey)
            return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        }

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

        /// Endpoint validation mode (default: strict for production)
        /// Use .permissive for LAN testing, .allowAll for localhost testing
        public let endpointValidationMode: EndpointValidator.ValidationMode

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
            holePunchProbeInterval: TimeInterval = 0.2,
            endpointValidationMode: EndpointValidator.ValidationMode = .strict
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
            self.endpointValidationMode = endpointValidationMode
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

    /// Result of a ping with gossip details
    public struct PingResult: Sendable {
        /// Peer ID we pinged
        public let peerId: PeerId
        /// Endpoint we pinged
        public let endpoint: String
        /// Round-trip latency in milliseconds
        public let latencyMs: Int
        /// Peers we shared (includes machineId for proper tracking)
        public let sentPeers: [PeerEndpointInfo]
        /// Peers they shared (includes machineId for proper tracking)
        public let receivedPeers: [PeerEndpointInfo]
        /// Peers that were new to us (includes machineId)
        public let newPeers: [PeerEndpointInfo]
    }

    // MARK: - Properties

    /// This node's identity keypair
    public let identity: IdentityKeypair

    /// This node's peer ID (derived from identity public key)
    public var peerId: PeerId {
        identity.peerId
    }

    /// This node's machine ID (identifies this physical machine)
    public let machineId: MachineId

    /// Node configuration
    public let config: Config

    /// Endpoint manager for multi-endpoint tracking by (peerId, machineId)
    public let endpointManager: PeerEndpointManager

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

    /// Potential relays for symmetric NAT peers
    /// Maps symmetric NAT peer ID -> list of potential relays (most recent first)
    private var potentialRelays: [PeerId: [(relayPeerId: PeerId, lastSeen: Date)]] = [:]
    private let maxRelaysPerPeer = 10

    /// Message IDs we've seen (for deduplication)
    private var seenMessageIds: Set<String> = []
    private let maxSeenMessages = 10000

    /// Gossip propagation queue - peer info to forward to other peers
    /// Each item has a count that decrements on each forward, removed when exhausted
    /// Internal for testing
    var peerPropagationQueue: [PeerId: (info: PeerEndpointInfo, count: Int)] = [:]
    let gossipFanout = 5  // Number of peers to forward each new peer info to

    /// Our observed public endpoint as reported by peers (no STUN needed)
    private var observedPublicEndpoint: String?

    /// Callback when our observed public endpoint changes
    private var endpointChangeHandler: ((String, String?) async -> Void)?

    /// Handler for incoming messages
    private var messageHandler: ((MeshMessage, PeerId) async -> MeshMessage?)?

    /// Pending responses for request/response pattern
    private var pendingResponses: [String: (continuation: CheckedContinuation<MeshMessage, Error>, timer: Task<Void, Never>)] = [:]

    /// Whether the node is running
    private var isRunning = false

    /// Logger
    private let logger: Logger

    /// Event logger for persistent event storage (optional)
    private let eventLogger: MeshEventLogger?

    /// Freshness manager for tracking recent contacts and handling stale info
    public let freshnessManager: FreshnessManager

    /// Hole punch manager for NAT traversal
    public let holePunchManager: HolePunchManager

    /// Connection keepalive manager for maintaining NAT mappings
    public let connectionKeepalive: ConnectionKeepalive

    /// NAT type predictor using peer-reported endpoint observations
    private let natPredictor: NATPredictor

    /// Set of known bootstrap peer IDs (for weighted NAT predictions)
    private var bootstrapPeers: Set<PeerId> = []

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
    ///   - eventLogger: Optional event logger for persistent storage
    public init(identity: IdentityKeypair, config: Config, eventLogger: MeshEventLogger? = nil) throws {
        self.identity = identity
        self.machineId = try getOrCreateMachineId()
        self.config = config
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.socket = UDPSocket(eventLoopGroup: self.eventLoopGroup)
        self.logger = Logger(label: "io.omerta.mesh.node.\(identity.peerId.prefix(8))")
        self.eventLogger = eventLogger
        self.endpointManager = PeerEndpointManager(
            networkId: config.networkId,
            validationMode: config.endpointValidationMode,
            logger: Logger(label: "io.omerta.mesh.endpoints")
        )
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
        self.natPredictor = NATPredictor()
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
                // Return first connected relay as coordinator (they have public IPs)
                guard let self = self else { return nil }
                if let relay = await self.getConnectedRelays().first {
                    return relay
                }
                // Fall back to first known peer
                return await self.endpointManager.allPeerIds.first
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
        // Log the failure - endpointManager handles endpoint lifecycle via activity tracking
        logger.info("Keepalive failure for \(peerId) at \(endpoint)")

        // Notify freshness manager about the failure
        let _ = await freshnessManager.pathFailureReporter.reportFailure(
            peerId: peerId,
            path: .direct(endpoint: endpoint)
        )
    }

    /// Get endpoint for a peer (returns best endpoint from any machine)
    private func getEndpoint(for peerId: PeerId) async -> String? {
        await endpointManager.getAllEndpoints(peerId: peerId).first
    }

    /// Broadcast a message to all known peers with hop count tracking
    public func broadcast(_ message: MeshMessage, maxHops: Int) async {
        // Get all known peer IDs and their best endpoints
        for peerId in await endpointManager.allPeerIds {
            guard peerId != self.peerId else { continue }

            guard let endpoint = await endpointManager.getAllEndpoints(peerId: peerId).first else {
                continue
            }

            do {
                let envelope = try MeshEnvelope.signed(
                    from: identity,
                    machineId: machineId,
                    to: nil,
                    payload: message
                )

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

        // Start event logger if provided
        await eventLogger?.start()

        // Start endpoint manager for persistence and cleanup
        await endpointManager.start()

        // Start freshness manager
        await freshnessManager.start()

        // Start hole punch manager
        let boundPort = await socket.port ?? 0
        logger.debug("MeshNode.start() - boundPort after start: \(boundPort)")
        await holePunchManager.start(natType: natType, localPort: UInt16(boundPort))

        // Start connection keepalive
        await connectionKeepalive.start()

        // Note: Cache cleanup is now handled by endpointManager

        logger.info("Mesh node started on port \(boundPort)")
    }

    /// Stop the node
    public func stop() async {
        guard isRunning else { return }
        isRunning = false

        // Stop event logger
        await eventLogger?.stop()

        // Stop endpoint manager (saves to disk)
        await endpointManager.stop()

        // Stop freshness manager
        await freshnessManager.stop()

        // Stop hole punch manager
        await holePunchManager.stop()

        // Stop connection keepalive
        await connectionKeepalive.stop()

        // Note: Cache cleanup is now handled by endpointManager (stopped above)

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

        // Verify signature using embedded public key (also verifies peer ID derivation)
        guard envelope.verifySignature() else {
            logger.warning("Rejecting message with invalid signature",
                          metadata: ["from": "\(envelope.fromPeerId.prefix(8))..."])

            // Log signature error
            await eventLogger?.recordError(
                component: MeshComponent.meshNode.rawValue,
                operation: "verifySignature",
                errorType: MeshErrorCategory.signature.rawValue,
                errorMessage: "Invalid signature on incoming message",
                peerId: envelope.fromPeerId
            )

            return
        }

        // Update peer info and track endpoint
        let endpointString = formatEndpoint(address)
        await updatePeerConnectionFromMessage(peerId: envelope.fromPeerId, endpoint: endpointString)

        // Record in endpoint manager for multi-endpoint tracking
        logger.info("Recording endpoint for peer \(envelope.fromPeerId.prefix(16))... machine \(envelope.machineId.prefix(16))... at \(endpointString)")
        await endpointManager.recordMessageReceived(
            from: envelope.fromPeerId,
            machineId: envelope.machineId,
            endpoint: endpointString
        )

        // Log peer seen event
        await eventLogger?.recordPeerSeen(
            peerId: envelope.fromPeerId,
            endpoint: endpointString,
            natType: nil
        )

        // Check if this is a response to a pending request
        if case .pong(_, _, _) = envelope.payload {
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

        // Check if we should attempt direct connection (Phase 8: Direct connection on relayed message)
        // If the message came via relay (source endpoint doesn't match known endpoints for sender)
        // and sender's NAT type allows direct connection, try to establish direct path
        await attemptDirectConnectionIfNeeded(
            fromPeerId: envelope.fromPeerId,
            sourceEndpoint: endpointString
        )
    }

    /// Default message handling for basic protocol
    private func handleDefaultMessage(_ message: MeshMessage, from peerId: PeerId, endpoint: String, hopCount: Int = 0) async {
        switch message {
        case .ping(let recentPeers, let theirNATType):
            // Check if this is a NEW or RECONNECTING peer BEFORE recording
            // A peer is considered "reconnecting" if we haven't heard from them in 60+ seconds
            // (4 missed keepalives at 15s interval)
            let hasEndpoints = !(await endpointManager.getAllEndpoints(peerId: peerId).isEmpty)
            let hasRecentContact = await freshnessManager.hasRecentContact(peerId, maxAgeSeconds: 60)
            let isNewOrReconnecting = !hasEndpoints || !hasRecentContact

            // Track sender's NAT type
            await endpointManager.updateNATType(peerId: peerId, natType: theirNATType)

            // Record this contact first so we're included in the response
            await freshnessManager.recordContact(
                peerId: peerId,
                reachability: .direct(endpoint: endpoint),
                latencyMs: 0,
                connectionType: .inboundDirect
            )

            // Build response - if NEW or RECONNECTING peer, send ALL known peers; otherwise send recent subset
            let myPeers: [PeerEndpointInfo]
            if isNewOrReconnecting {
                // New/reconnecting peer gets full peer list to bootstrap their view of the network
                myPeers = await buildPeerEndpointInfoList()
                if hasEndpoints {
                    logger.info("Reconnecting peer \(peerId.prefix(8))... - sending \(myPeers.count) known peers")
                } else {
                    logger.info("New peer \(peerId.prefix(8))... contacted us - sending \(myPeers.count) known peers")
                }
            } else {
                // Known peer gets recent peers + propagation queue items
                myPeers = await buildPeerEndpointInfoListWithPropagation(excluding: peerId)
            }

            // Get our predicted NAT type (unknown until integrated with NATPredictor in Phase 2)
            let myNATType = await getPredictedNATType().type
            await send(.pong(recentPeers: myPeers, yourEndpoint: endpoint, myNATType: myNATType), to: endpoint)

            // Learn about new peers from the ping WITH machineId and NAT type
            for peerInfo in recentPeers where peerInfo.peerId != self.peerId {
                // Check if we already know about this peer's endpoint
                let existingEndpoints = await endpointManager.getAllEndpoints(peerId: peerInfo.peerId)
                let isNewlyLearnedPeer = existingEndpoints.isEmpty

                if !existingEndpoints.contains(peerInfo.endpoint) {
                    logger.info("Learned about peer \(peerInfo.peerId.prefix(16))... at \(peerInfo.endpoint) from gossip")
                }

                // Record in endpointManager (handles deduplication and priority)
                await endpointManager.recordMessageReceived(
                    from: peerInfo.peerId,
                    machineId: peerInfo.machineId,
                    endpoint: peerInfo.endpoint
                )

                // Track peer's NAT type from gossip
                await endpointManager.updateNATType(peerId: peerInfo.peerId, natType: peerInfo.natType)

                // RELAY DISCOVERY: If this peer is behind symmetric NAT, the sender becomes a potential relay
                if peerInfo.natType == .symmetric {
                    recordPotentialRelay(for: peerInfo.peerId, via: peerId)
                }

                // GOSSIP: If this is a newly learned peer, add to propagation queue
                if isNewlyLearnedPeer {
                    addToPropagationQueue(peerInfo)
                }
            }

            // GOSSIP: If the sender is a new or reconnecting peer, add them to propagation queue
            if isNewOrReconnecting {
                // Get the sender's machineId from endpointManager (was just recorded in handleIncomingData)
                let senderMachines = await endpointManager.getAllMachines(peerId: peerId)
                if let senderMachine = senderMachines.first(where: { $0.bestEndpoint == endpoint }) {
                    let senderInfo = PeerEndpointInfo(
                        peerId: peerId,
                        machineId: senderMachine.machineId,
                        endpoint: endpoint,
                        natType: theirNATType
                    )
                    addToPropagationQueue(senderInfo)
                }
            }

        case .pong(let recentPeers, let yourEndpoint, let theirNATType):
            // Pong sender is already recorded in handleIncomingData via endpointManager.recordMessageReceived
            logger.info("Received pong from: \(peerId.prefix(8))... at \(endpoint)")

            // Track sender's NAT type
            await endpointManager.updateNATType(peerId: peerId, natType: theirNATType)

            // Update our observed public endpoint based on what the peer sees
            await updateObservedEndpoint(yourEndpoint, reportedBy: peerId)

            // Learn about new peers from the pong WITH machineId and NAT type
            for peerInfo in recentPeers where peerInfo.peerId != self.peerId {
                // Check if we already know about this peer's endpoint
                let existingEndpoints = await endpointManager.getAllEndpoints(peerId: peerInfo.peerId)
                let isNewlyLearnedPeer = existingEndpoints.isEmpty

                if !existingEndpoints.contains(peerInfo.endpoint) {
                    logger.info("Learned about peer \(peerInfo.peerId.prefix(16))... at \(peerInfo.endpoint) from pong")
                }

                // Record in endpointManager (handles deduplication and priority)
                await endpointManager.recordMessageReceived(
                    from: peerInfo.peerId,
                    machineId: peerInfo.machineId,
                    endpoint: peerInfo.endpoint
                )

                // Track peer's NAT type from gossip
                await endpointManager.updateNATType(peerId: peerInfo.peerId, natType: peerInfo.natType)

                // RELAY DISCOVERY: If this peer is behind symmetric NAT, the sender becomes a potential relay
                if peerInfo.natType == .symmetric {
                    recordPotentialRelay(for: peerInfo.peerId, via: peerId)
                }

                // GOSSIP: If this is a newly learned peer, add to propagation queue
                if isNewlyLearnedPeer {
                    addToPropagationQueue(peerInfo)
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
                logger.info("Passing .data(\(payload.count) bytes) to application handler from \(peerId.prefix(16))...")
                await handler(.data(payload), peerId)
            } else {
                logger.warning("No applicationMessageHandler set for .data message from \(peerId.prefix(16))...")
            }

        case .peerInfo:
            // Record this contact when receiving a peer announcement
            await freshnessManager.recordContact(
                peerId: peerId,
                reachability: .direct(endpoint: endpoint),
                latencyMs: 0,
                connectionType: .inboundDirect
            )
            // Note: endpoint is already recorded in handleIncomingData via endpointManager.recordMessageReceived
            logger.info("Received peer announcement: \(peerId.prefix(8))... at \(endpoint)")

        case .relayForward(let targetPeerId, let payload):
            // Handle relay forward request - forward the payload to the target peer
            logger.info("Relay forward request from \(peerId.prefix(8))... to \(targetPeerId.prefix(8))...")
            await handleRelayForward(targetPeerId: targetPeerId, payload: payload, from: peerId, senderEndpoint: endpoint)

        case .relayForwardResult(let targetPeerId, let success):
            // Log relay forward result (the continuation mechanism handles response matching)
            if success {
                logger.debug("Relay forward to \(targetPeerId.prefix(8))... succeeded")
            } else {
                logger.warning("Relay forward to \(targetPeerId.prefix(8))... failed")
            }

        default:
            break
        }
    }

    /// Forward a message to other peers (for gossip propagation)
    private func forwardMessage(_ message: MeshMessage, from originalSender: PeerId, hopCount: Int) async {
        for peerId in await endpointManager.allPeerIds {
            // Don't forward back to sender or to ourselves
            guard peerId != originalSender && peerId != self.peerId else { continue }

            guard let endpoint = await endpointManager.getAllEndpoints(peerId: peerId).first else {
                continue
            }

            do {
                let envelope = try MeshEnvelope.signed(
                    from: identity,
                    machineId: machineId,
                    to: nil,
                    payload: message
                )

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
            // Create signed envelope with embedded public key
            let envelope = try MeshEnvelope.signed(
                from: identity,
                machineId: machineId,
                to: nil,
                payload: message
            )

            // Encode to JSON then encrypt
            let jsonData = try JSONEncoder().encode(envelope)
            let encryptedData = try MessageEncryption.encrypt(jsonData, key: config.encryptionKey)
            logger.info("Sending \(encryptedData.count) bytes to \(endpoint)")
            try await socket.send(encryptedData, to: endpoint)

            logger.info("Sent \(type(of: message)) (\(encryptedData.count) bytes) to \(endpoint)")
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

    /// Update a peer's endpoint from incoming message
    /// Note: endpointManager is updated separately in handleIncomingData
    private func updatePeerConnectionFromMessage(peerId: PeerId, endpoint: String) async {
        // Update PeerConnection if we have one
        if let peer = peers[peerId] {
            await peer.setActiveEndpoint(endpoint)
            await peer.updateLastSeen()
        }
    }

    /// Add a peer with known public key
    public func addPeer(publicKeyBase64: String) throws {
        let connection = try PeerConnection(publicKeyBase64: publicKeyBase64)
        peers[connection.peerId] = connection
    }

    /// Get known peer IDs
    public var knownPeerIds: [PeerId] {
        Array(peers.keys)
    }


    // MARK: - MeshNetwork API Methods

    /// Get cached peer info
    public func getCachedPeer(_ peerId: PeerId) async -> CachedPeerInfo? {
        // Build CachedPeerInfo from endpointManager
        guard let endpoint = await endpointManager.getAllEndpoints(peerId: peerId).first else {
            return nil
        }
        // Get last seen from the machine endpoints
        let machines = await endpointManager.getAllMachines(peerId: peerId)
        let lastSeen = machines.map { $0.lastActivity }.max() ?? Date()
        return CachedPeerInfo(peerId: peerId, endpoint: endpoint, natType: .unknown, lastSeen: lastSeen)
    }

    /// Get list of cached peer IDs
    public func getCachedPeerIds() async -> [PeerId] {
        await endpointManager.allPeerIds
    }

    /// Get connected relay peer IDs
    public func getConnectedRelays() async -> [PeerId] {
        Array(connectedRelays)
    }

    /// Update a peer's endpoint (public API for MeshNetwork)
    /// Note: Uses a generated machineId since we don't know the actual machineId yet
    public func updatePeerEndpoint(_ peerId: PeerId, endpoint: Endpoint) async {
        // Don't add ourselves as a peer
        guard peerId != self.peerId else { return }
        // Use a placeholder machineId - will be updated when we receive a message from them
        let placeholderMachineId = "bootstrap-\(peerId.prefix(16))"
        await endpointManager.recordMessageReceived(from: peerId, machineId: placeholderMachineId, endpoint: endpoint)
    }

    /// Request peer list from known peers
    public func requestPeers() async {
        // Build our peer list to share (with machineId and NAT type)
        let myPeers = await buildPeerEndpointInfoList()
        let myNATType = await getPredictedNATType().type

        // Send ping to all known peers
        for peerId in await endpointManager.allPeerIds {
            guard peerId != self.peerId else { continue }
            guard let endpoint = await endpointManager.getAllEndpoints(peerId: peerId).first else {
                continue
            }
            await send(.ping(recentPeers: myPeers, myNATType: myNATType), to: endpoint)
        }
    }

    // MARK: - Observed Endpoint (Peer-Reported)

    /// Get our observed public endpoint as reported by peers
    /// This is determined from pong messages without requiring STUN
    public var getObservedEndpoint: String? {
        observedPublicEndpoint
    }

    /// Set callback for when our observed public endpoint changes
    public func setEndpointChangeHandler(_ handler: @escaping (String, String?) async -> Void) {
        endpointChangeHandler = handler
    }

    /// Update our observed public endpoint based on peer reports
    /// Called when we receive a pong message that tells us our endpoint
    private func updateObservedEndpoint(_ newEndpoint: String, reportedBy peerId: PeerId) async {
        let oldEndpoint = observedPublicEndpoint

        // Record observation for NAT prediction
        let isBootstrap = bootstrapPeers.contains(peerId)
        await natPredictor.recordObservation(endpoint: newEndpoint, from: peerId, isBootstrap: isBootstrap)

        // Only log if endpoint changed or is first report
        if oldEndpoint != newEndpoint {
            if let old = oldEndpoint {
                logger.info("Observed endpoint changed from \(old) to \(newEndpoint) (reported by \(peerId.prefix(8))...)")
            } else {
                logger.info("Observed endpoint set to \(newEndpoint) (reported by \(peerId.prefix(8))...)")
            }

            observedPublicEndpoint = newEndpoint

            // Notify handler if set
            if let handler = endpointChangeHandler {
                await handler(newEndpoint, oldEndpoint)
            }
        }
    }

    // MARK: - NAT Prediction

    /// Get our predicted NAT type based on peer observations
    /// Returns (type, publicEndpoint, confidence) where confidence is number of observations
    public func getPredictedNATType() async -> (type: NATType, publicEndpoint: String?, confidence: Int) {
        await natPredictor.predictNATType()
    }

    /// Get the NAT type of a specific peer
    public func getNATType(for peerId: PeerId) async -> NATType? {
        await endpointManager.getNATType(peerId: peerId)
    }

    /// Register a peer as a bootstrap node (for weighted NAT predictions)
    public func registerBootstrapPeer(_ peerId: PeerId) {
        bootstrapPeers.insert(peerId)
    }

    /// Reset NAT prediction (e.g., after network change)
    public func resetNATPrediction() async {
        await natPredictor.reset()
    }

    /// Wait for endpoint observations from bootstrap peers
    /// - Parameters:
    ///   - minimumObservations: Minimum number of observations to wait for (default: 2)
    ///   - timeout: Maximum time to wait in seconds (default: 2.0)
    /// - Returns: Number of observations received before timeout
    public func waitForBootstrapObservations(minimum: Int = 2, timeout: TimeInterval = 2.0) async -> Int {
        let startTime = Date()
        let pollInterval: UInt64 = 50_000_000 // 50ms

        while Date().timeIntervalSince(startTime) < timeout {
            let count = await natPredictor.observationCount
            if count >= minimum {
                logger.debug("Received \(count) bootstrap observations")
                return count
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        let finalCount = await natPredictor.observationCount
        logger.debug("Bootstrap observation wait timed out with \(finalCount) observations")
        return finalCount
    }

    // MARK: - Relay Discovery

    /// Record a potential relay for a symmetric NAT peer
    /// Called when we receive gossip about a symmetric NAT peer - the sender becomes a potential relay
    public func recordPotentialRelay(for symmetricPeerId: PeerId, via relayPeerId: PeerId) {
        // Don't record ourselves as a relay
        guard relayPeerId != peerId else { return }
        // Don't record the symmetric peer as its own relay
        guard relayPeerId != symmetricPeerId else { return }

        var relays = potentialRelays[symmetricPeerId] ?? []

        // Remove existing entry for this relay (to move to front)
        relays.removeAll { $0.relayPeerId == relayPeerId }

        // Add at front (most recent)
        relays.insert((relayPeerId: relayPeerId, lastSeen: Date()), at: 0)

        // Keep only max relays
        potentialRelays[symmetricPeerId] = Array(relays.prefix(maxRelaysPerPeer))

        logger.debug("Recorded potential relay \(relayPeerId.prefix(8))... for symmetric peer \(symmetricPeerId.prefix(8))...")
    }

    /// Get potential relays for a symmetric NAT peer
    /// Returns relays ordered by most recent contact
    public func getPotentialRelays(for symmetricPeerId: PeerId) -> [(relayPeerId: PeerId, lastSeen: Date)] {
        potentialRelays[symmetricPeerId] ?? []
    }

    /// Clear potential relays for a peer (e.g., when direct connection established)
    public func clearPotentialRelays(for peerId: PeerId) {
        potentialRelays.removeValue(forKey: peerId)
    }

    // MARK: - Relay Forwarding

    /// Handle a relay forward request - forward payload to target peer
    private func handleRelayForward(targetPeerId: PeerId, payload: Data, from senderPeerId: PeerId, senderEndpoint: String) async {
        // Check if we know an endpoint for the target
        guard let targetEndpoint = await endpointManager.getAllEndpoints(peerId: targetPeerId).first else {
            logger.warning("Relay forward failed: no endpoint for target \(targetPeerId.prefix(8))...")
            await send(.relayForwardResult(targetPeerId: targetPeerId, success: false), to: senderEndpoint)
            return
        }

        // Forward the raw payload directly to the target
        // The payload is already an encrypted MeshEnvelope from the original sender
        do {
            try await socket.send(payload, to: targetEndpoint)
            logger.info("Relayed \(payload.count) bytes to \(targetPeerId.prefix(8))... at \(targetEndpoint)")
            await send(.relayForwardResult(targetPeerId: targetPeerId, success: true), to: senderEndpoint)
        } catch {
            logger.error("Relay forward to \(targetPeerId.prefix(8))... failed: \(error)")
            await send(.relayForwardResult(targetPeerId: targetPeerId, success: false), to: senderEndpoint)
        }
    }

    /// Attempt direct connection to a peer if message appears to have been relayed
    /// Called after receiving any message to establish direct bidirectional paths
    private func attemptDirectConnectionIfNeeded(fromPeerId: PeerId, sourceEndpoint: String) async {
        // Don't try to connect to ourselves
        guard fromPeerId != peerId else { return }

        // Get sender's known NAT type
        let senderNATType = await endpointManager.getNATType(peerId: fromPeerId) ?? .unknown

        // Only attempt direct connection if sender is NOT behind symmetric NAT
        // Symmetric NAT requires relay because their port mapping changes per destination
        if senderNATType == .symmetric {
            logger.debug("Not attempting direct connection to \(fromPeerId.prefix(8))... - symmetric NAT")
            return
        }

        // Get sender's known endpoints
        let knownEndpoints = await endpointManager.getAllEndpoints(peerId: fromPeerId)

        // If the source endpoint is NOT in our known endpoints for this peer,
        // the message likely came via relay. Try to establish direct connection.
        if !knownEndpoints.contains(sourceEndpoint) && !knownEndpoints.isEmpty {
            // We have a different endpoint for this peer - message was relayed
            // Try pinging their known endpoint to establish direct path
            if let directEndpoint = knownEndpoints.first {
                logger.info("Relayed message detected from \(fromPeerId.prefix(8))... - attempting direct connection to \(directEndpoint)")

                // Send ping to establish direct bidirectional communication
                // Use a background task to avoid blocking message processing
                Task {
                    let _ = await self.sendPing(to: fromPeerId, timeout: 5.0)
                }
            }
        }

        // If we received directly (sourceEndpoint IS in knownEndpoints), no action needed
        // The direct path is already working
    }

    /// Send a message via relay to a peer behind symmetric NAT
    /// Uses the most recently contacted relay that knows the target peer
    public func sendViaRelay(_ message: MeshMessage, to targetPeerId: PeerId) async throws {
        // Get potential relays for this symmetric NAT peer
        let relays = getPotentialRelays(for: targetPeerId)
        guard !relays.isEmpty else {
            logger.warning("sendViaRelay: No potential relays for \(targetPeerId.prefix(8))...")
            throw MeshNodeError.noRelayAvailable
        }

        // Create the envelope we want to send to the target
        let envelope = try MeshEnvelope.signed(
            from: identity,
            machineId: machineId,
            to: targetPeerId,
            payload: message
        )

        // Encode the envelope
        let jsonData = try JSONEncoder().encode(envelope)

        // Encrypt the payload with our network encryption key
        let encryptedPayload = try MessageEncryption.encrypt(jsonData, key: config.encryptionKey)

        // Try relays in order (most recent first)
        for relay in relays {
            guard let relayEndpoint = await endpointManager.getAllEndpoints(peerId: relay.relayPeerId).first else {
                continue
            }

            logger.info("Sending via relay \(relay.relayPeerId.prefix(8))... to \(targetPeerId.prefix(8))...")
            await send(.relayForward(targetPeerId: targetPeerId, payload: encryptedPayload), to: relayEndpoint)
            return // Successfully sent to relay
        }

        throw MeshNodeError.noRelayAvailable
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
            var capabilities: [String] = []
            if config.canRelay { capabilities.append("relay") }
            if config.canCoordinateHolePunch { capabilities.append("holePunchCoordinator") }
            let announcement = try Gossip.createAnnouncement(
                identity: identity,
                reachability: reachability,
                capabilities: capabilities
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
        for peerId in await endpointManager.allPeerIds {
            guard peerId != self.peerId else { continue }
            guard let endpoint = await endpointManager.getAllEndpoints(peerId: peerId).first else {
                continue
            }
            await announceTo(endpoint: endpoint)
        }
    }

    /// Send a message to a peer by ID (NAT-aware routing)
    /// Automatically routes via relay for symmetric NAT peers, direct otherwise
    public func sendToPeer(_ message: MeshMessage, peerId: PeerId) async throws {
        // Check peer's NAT type for routing decision
        let peerNATType = await endpointManager.getNATType(peerId: peerId) ?? .unknown

        // Symmetric NAT peers require relay (their port mapping changes per destination)
        if peerNATType == .symmetric {
            let relays = getPotentialRelays(for: peerId)
            if !relays.isEmpty {
                logger.info("sendToPeer: Routing to symmetric NAT peer \(peerId.prefix(16))... via relay")
                try await sendViaRelay(message, to: peerId)
                return
            }
            // Fall through to try direct if no relays available
            logger.warning("sendToPeer: Symmetric NAT peer \(peerId.prefix(16))... but no relays, trying direct")
        }

        // Direct send for non-symmetric NAT peers (or fallback for symmetric)
        let endpoints = await endpointManager.getAllEndpoints(peerId: peerId)
        guard !endpoints.isEmpty else {
            logger.warning("sendToPeer: No endpoints found for peer \(peerId.prefix(16))...")
            throw MeshNodeError.peerNotFound
        }

        logger.info("sendToPeer: Sending to \(peerId.prefix(16))... via \(endpoints[0])")
        // For fire-and-forget sends, try the best endpoint only
        // Use sendToPeerWithFallback for request-response patterns
        await send(message, to: endpoints[0])
    }

    /// Send to peer with fallback through multiple endpoints
    ///
    /// Tries endpoints in priority order (best first) until one succeeds.
    /// On success, promotes the working endpoint to highest priority.
    ///
    /// - Parameters:
    ///   - message: The message to send
    ///   - peerId: Target peer ID
    ///   - machineId: Target machine ID
    ///   - timeout: Timeout per endpoint attempt
    /// - Returns: The response message
    /// - Throws: MeshNodeError.peerNotFound if no endpoints, last error if all fail
    public func sendToPeerWithFallback(
        _ message: MeshMessage,
        peerId: PeerId,
        machineId: MachineId,
        timeout: TimeInterval = 5.0
    ) async throws -> MeshMessage {
        let endpoints = await endpointManager.getEndpoints(peerId: peerId, machineId: machineId)
        guard !endpoints.isEmpty else {
            throw MeshNodeError.peerNotFound
        }

        var lastError: Error = MeshNodeError.peerNotFound

        for endpoint in endpoints {
            do {
                let response = try await sendAndReceive(message, to: endpoint, timeout: timeout)
                // Success - promote this endpoint to highest priority
                await endpointManager.recordSendSuccess(to: peerId, machineId: machineId, endpoint: endpoint)
                return response
            } catch {
                lastError = error
                logger.debug("Send to \(endpoint) failed, trying next: \(error)")
            }
        }

        throw lastError
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
        let result = await sendPingWithDetails(to: targetPeerId, timeout: timeout)
        return result != nil
    }

    /// Send a ping to a peer and return detailed results including gossip info
    /// Returns nil if timeout or error
    public func sendPingWithDetails(to targetPeerId: PeerId, timeout: TimeInterval = 3.0) async -> PingResult? {
        // Get the endpoint for this peer
        guard let endpoint = await endpointManager.getAllEndpoints(peerId: targetPeerId).first else {
            logger.debug("sendPing: No endpoint for peer \(targetPeerId)")
            return nil
        }

        // Build our recentPeers to send (with machineId and NAT type)
        let peerInfoList = await buildPeerEndpointInfoList()
        let sentPeers = Array(peerInfoList.prefix(5))
        let myNATType = await getPredictedNATType().type
        let ping = MeshMessage.ping(recentPeers: sentPeers, myNATType: myNATType)

        let startTime = Date()
        do {
            let response = try await sendAndReceive(ping, to: endpoint, timeout: timeout)
            if case .pong(let receivedPeers, _, _) = response {
                let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
                logger.debug("sendPing: Got pong from \(targetPeerId) in \(latencyMs)ms")

                // Find new peers (ones we didn't know about)
                var newPeers: [PeerEndpointInfo] = []
                for peerInfo in receivedPeers {
                    let existingEndpoints = await endpointManager.getAllEndpoints(peerId: peerInfo.peerId)
                    if !existingEndpoints.contains(peerInfo.endpoint) && peerInfo.peerId != identity.peerId {
                        newPeers.append(peerInfo)
                    }
                }

                // Record this as a recent contact
                await freshnessManager.recordContact(
                    peerId: targetPeerId,
                    reachability: .direct(endpoint: endpoint),
                    latencyMs: latencyMs,
                    connectionType: .direct
                )

                // Log latency sample
                await eventLogger?.recordLatencySample(peerId: targetPeerId, latencyMs: Double(latencyMs))

                // Add to keepalive monitoring if not already monitored
                if await !connectionKeepalive.isMonitoring(peerId: targetPeerId) {
                    await connectionKeepalive.addConnection(peerId: targetPeerId, endpoint: endpoint)
                } else {
                    await connectionKeepalive.recordSuccessfulCommunication(peerId: targetPeerId)
                }

                return PingResult(
                    peerId: targetPeerId,
                    endpoint: endpoint,
                    latencyMs: latencyMs,
                    sentPeers: sentPeers,
                    receivedPeers: receivedPeers,
                    newPeers: newPeers
                )
            }
            return nil
        } catch {
            logger.debug("sendPing: Failed to ping \(targetPeerId): \(error)")

            // Log latency loss
            await eventLogger?.recordLatencyLoss(peerId: targetPeerId)

            return nil
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

    // MARK: - Helpers

    /// Build a list of peer endpoint info for gossip (includes machineId and natType)
    func buildPeerEndpointInfoList() async -> [PeerEndpointInfo] {
        var result: [PeerEndpointInfo] = []
        for peerId in await endpointManager.allPeerIds {
            guard peerId != self.peerId else { continue }
            let natType = await endpointManager.getNATType(peerId: peerId) ?? .unknown
            for machine in await endpointManager.getAllMachines(peerId: peerId) {
                if let endpoint = machine.bestEndpoint {
                    result.append(PeerEndpointInfo(
                        peerId: machine.peerId,
                        machineId: machine.machineId,
                        endpoint: endpoint,
                        natType: natType
                    ))
                }
            }
            if result.count >= 10 { break }
        }
        return result
    }

    /// Build peer list including propagation queue items, decrementing their counts
    /// Used for regular keepalive responses to existing peers
    func buildPeerEndpointInfoListWithPropagation(excluding excludePeerId: PeerId) async -> [PeerEndpointInfo] {
        var result: [PeerEndpointInfo] = []

        // Add known peers (up to 5)
        for peerId in await endpointManager.allPeerIds {
            guard peerId != self.peerId else { continue }
            let natType = await endpointManager.getNATType(peerId: peerId) ?? .unknown
            for machine in await endpointManager.getAllMachines(peerId: peerId) {
                if let endpoint = machine.bestEndpoint {
                    result.append(PeerEndpointInfo(
                        peerId: machine.peerId,
                        machineId: machine.machineId,
                        endpoint: endpoint,
                        natType: natType
                    ))
                }
            }
            if result.count >= 5 { break }
        }

        // Add propagation queue items (gossip) - don't include the peer we're sending to
        var keysToRemove: [PeerId] = []
        for (key, var item) in peerPropagationQueue {
            guard item.info.peerId != excludePeerId else { continue }

            // Add to result if not already present
            if !result.contains(where: { $0.peerId == item.info.peerId }) {
                result.append(item.info)
                logger.debug("Gossiping peer \(item.info.peerId.prefix(8))... (count: \(item.count - 1) remaining)")
            }

            // Decrement count
            item.count -= 1
            if item.count <= 0 {
                keysToRemove.append(key)
            } else {
                peerPropagationQueue[key] = item
            }
        }

        // Remove exhausted items
        for key in keysToRemove {
            peerPropagationQueue.removeValue(forKey: key)
        }

        return result
    }

    /// Add peer info to the gossip propagation queue
    func addToPropagationQueue(_ peerInfo: PeerEndpointInfo) {
        // Don't add ourselves
        guard peerInfo.peerId != self.peerId else { return }

        // Don't add if already in queue (but could update endpoint)
        if peerPropagationQueue[peerInfo.peerId] != nil {
            // Update with fresh info but keep existing count
            let existingCount = peerPropagationQueue[peerInfo.peerId]!.count
            peerPropagationQueue[peerInfo.peerId] = (info: peerInfo, count: existingCount)
            return
        }

        peerPropagationQueue[peerInfo.peerId] = (info: peerInfo, count: gossipFanout)
        logger.info("Added peer \(peerInfo.peerId.prefix(8))... to gossip queue (fanout: \(gossipFanout))")
    }

    /// Set propagation count for a peer (internal for testing)
    func setPropagationCount(for peerId: PeerId, count: Int) {
        guard var item = peerPropagationQueue[peerId] else { return }
        item.count = count
        peerPropagationQueue[peerId] = item
    }

    /// Get propagation count for a peer (internal for testing)
    func getPropagationCount(for peerId: PeerId) -> Int? {
        peerPropagationQueue[peerId]?.count
    }

    /// Get propagation info for a peer (internal for testing)
    func getPropagationInfo(for peerId: PeerId) -> PeerEndpointInfo? {
        peerPropagationQueue[peerId]?.info
    }

    /// Get propagation queue size (internal for testing)
    var propagationQueueCount: Int {
        peerPropagationQueue.count
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
    /// Receive an envelope directly (for testing)
    /// Verifies signature using embedded public key
    public func receiveEnvelope(_ envelope: MeshEnvelope) async -> Bool {
        // Verify signature using embedded public key (also verifies peer ID derivation)
        guard envelope.verifySignature() else {
            logger.warning("Rejected message with invalid signature from \(envelope.fromPeerId.prefix(8))...")
            return false
        }

        // Check for duplicates
        if seenMessageIds.contains(envelope.messageId) {
            return false
        }
        markMessageSeen(envelope.messageId)

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
    case noRelayAvailable

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
        case .noRelayAvailable:
            return "No relay available for symmetric NAT peer"
        }
    }
}
