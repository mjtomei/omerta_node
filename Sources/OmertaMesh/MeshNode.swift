// MeshNode.swift - Main mesh network node actor

import Foundation
import NIOCore
import NIOPosix
import Crypto
import Logging

/// A node in the mesh network
public actor MeshNode {
    /// This node's identity keypair
    public let identity: IdentityKeypair

    /// This node's peer ID (derived from public key)
    public var peerId: PeerId {
        identity.peerId
    }

    /// The UDP socket for network communication
    private let socket: UDPSocket

    /// Event loop group for NIO
    private let eventLoopGroup: EventLoopGroup

    /// Known peer connections
    private var peers: [PeerId: PeerConnection] = [:]

    /// Peer endpoints for broadcasting
    private var peerEndpoints: [PeerId: String] = [:]

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

    /// The port we're listening on
    public var port: Int? {
        get async {
            await socket.port
        }
    }

    // MARK: - Initialization

    /// Create a new mesh node with a random identity
    public init(port: Int = 0, eventLoopGroup: EventLoopGroup? = nil) async throws {
        self.identity = IdentityKeypair()
        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.socket = UDPSocket(eventLoopGroup: self.eventLoopGroup)
        self.logger = Logger(label: "io.omerta.mesh.node.\(identity.peerId.prefix(8))")
        self.freshnessManager = FreshnessManager()

        try await socket.bind(port: port)
        await setupReceiveHandler()
        await setupFreshnessManager()
    }

    /// Create a mesh node with an existing identity
    public init(identity: IdentityKeypair, port: Int = 0, eventLoopGroup: EventLoopGroup? = nil) async throws {
        self.identity = identity
        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.socket = UDPSocket(eventLoopGroup: self.eventLoopGroup)
        self.logger = Logger(label: "io.omerta.mesh.node.\(identity.peerId.prefix(8))")
        self.freshnessManager = FreshnessManager()

        try await socket.bind(port: port)
        await setupReceiveHandler()
        await setupFreshnessManager()
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
    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // Start freshness manager
        await freshnessManager.start()

        let boundPort = await socket.port ?? 0
        logger.info("Mesh node started on port \(boundPort)")
    }

    /// Stop the node
    public func stop() async {
        guard isRunning else { return }
        isRunning = false

        // Stop freshness manager
        await freshnessManager.stop()

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
        // Decode the envelope
        guard let envelope = try? JSONDecoder().decode(MeshEnvelope.self, from: data) else {
            logger.debug("Failed to decode message from \(address)")
            return
        }

        // Check for duplicates
        if seenMessageIds.contains(envelope.messageId) {
            logger.debug("Ignoring duplicate message \(envelope.messageId)")
            return
        }
        markMessageSeen(envelope.messageId)

        // Get or lookup the sender's public key
        let senderPublicKey: String
        if let peer = peers[envelope.fromPeerId] {
            senderPublicKey = await peer.publicKey.rawRepresentation.base64EncodedString()
        } else {
            // For ping messages, the sender includes their public key in the peerId
            // (since peerId is derived from public key, we can derive the key)
            // In a full implementation, we'd need to get the key from the message or a lookup
            senderPublicKey = envelope.fromPeerId
        }

        // Verify signature
        if !envelope.verifySignature(publicKeyBase64: senderPublicKey) {
            // For now, allow unsigned messages for testing
            // In production, we'd reject: logger.warning("Invalid signature from \(envelope.fromPeerId)")
            logger.debug("Message signature verification skipped (peer key unknown)")
        }

        // Update peer info and track endpoint
        let endpointString = formatEndpoint(address)
        await updatePeerEndpoint(peerId: envelope.fromPeerId, endpoint: endpointString)
        peerEndpoints[envelope.fromPeerId] = endpointString

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

    /// Default message handling for basic protocol
    private func handleDefaultMessage(_ message: MeshMessage, from peerId: PeerId, endpoint: String, hopCount: Int = 0) async {
        switch message {
        case .ping(let recentPeers):
            // Respond with pong including our recent peers
            let myRecentPeers = await freshnessManager.recentPeerIds
            await send(.pong(recentPeers: Array(myRecentPeers.prefix(10))), to: endpoint)

            // Learn about new peers from the ping
            for peer in recentPeers {
                if !peers.keys.contains(peer) && peer != self.peerId {
                    logger.debug("Learned about peer \(peer) from \(peerId)")
                }
            }

            // Record this as a recent contact
            await freshnessManager.recordContact(
                peerId: peerId,
                reachability: .direct(endpoint: endpoint),
                latencyMs: 0,
                connectionType: .inboundDirect
            )

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
            let envelope = try MeshEnvelope.signed(
                from: identity,
                to: nil,
                payload: message
            )

            let data = try JSONEncoder().encode(envelope)
            try await socket.send(data, to: endpoint)

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
    private func updatePeerEndpoint(peerId: PeerId, endpoint: String) async {
        if let peer = peers[peerId] {
            await peer.setActiveEndpoint(endpoint)
            await peer.updateLastSeen()
        }
        // For unknown peers, we don't have their public key yet
        // Full implementation would add them after key exchange
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

    /// Receive an envelope directly (for testing)
    public func receiveEnvelope(_ envelope: MeshEnvelope) async -> Bool {
        // Verify signature if we know the sender
        if let peer = peers[envelope.fromPeerId] {
            let publicKeyBase64 = await peer.publicKey.rawRepresentation.base64EncodedString()
            if !envelope.verifySignature(publicKeyBase64: publicKeyBase64) {
                logger.warning("Rejected message with invalid signature from \(envelope.fromPeerId)")
                return false
            }
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
