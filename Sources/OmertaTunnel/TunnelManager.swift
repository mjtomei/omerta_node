// TunnelManager.swift - Peer session management for mesh networks
//
// This utility manages peer-to-peer sessions over a mesh network.
// It is agnostic to how the network was created (Cloister, manual key, etc.)
// and assumes a simple topology: two endpoints (optionally with relay).

import Foundation
import OmertaMesh
import Logging

/// TunnelManager provides session management for peer communication over a mesh.
///
/// Usage:
/// ```swift
/// // Higher level code creates the mesh network (e.g., via Cloister)
/// let mesh = MeshNetwork(config: config)
/// try await mesh.start()
///
/// // Create tunnel manager on that network
/// let manager = TunnelManager(provider: mesh)
/// try await manager.start()
///
/// // Create session with the remote peer
/// let session = try await manager.createSession(with: remotePeerId)
///
/// // Send data
/// try await session.send(data)
///
/// // Receive data
/// for await data in session.receive() {
///     print("Received \(data.count) bytes")
/// }
/// ```
public actor TunnelManager {
    private let provider: any ChannelProvider
    private let logger: Logger

    /// The current session (only one peer expected)
    private var session: TunnelSession?

    /// Whether the manager is running
    private var isRunning: Bool = false

    /// Callback when remote peer initiates a session
    private var sessionRequestHandler: ((PeerId) async -> Bool)?

    /// Callback when session is established
    private var sessionEstablishedHandler: ((TunnelSession) async -> Void)?

    /// Channel for session handshake
    private let handshakeChannel = "tunnel-handshake"

    /// Initialize the tunnel manager
    /// - Parameter provider: The channel provider (e.g., MeshNetwork) to use for communication
    public init(provider: any ChannelProvider) {
        self.provider = provider
        self.logger = Logger(label: "io.omerta.tunnel.manager")
    }

    /// Start the tunnel manager
    public func start() async throws {
        guard !isRunning else { return }

        // Register handshake handler for incoming session requests
        try await provider.onChannel(handshakeChannel) { [weak self] peerId, data in
            await self?.handleHandshake(from: peerId, data: data)
        }

        isRunning = true
        logger.info("Tunnel manager started")
    }

    /// Stop the tunnel manager
    public func stop() async {
        guard isRunning else { return }

        await provider.offChannel(handshakeChannel)

        if let session = session {
            await session.leave()
            self.session = nil
        }

        isRunning = false
        logger.info("Tunnel manager stopped")
    }

    /// Set handler for incoming session requests
    /// - Parameter handler: Callback that returns true to accept, false to reject
    public func setSessionRequestHandler(_ handler: @escaping (PeerId) async -> Bool) {
        self.sessionRequestHandler = handler
    }

    /// Set handler called when a session is established
    public func setSessionEstablishedHandler(_ handler: @escaping (TunnelSession) async -> Void) {
        self.sessionEstablishedHandler = handler
    }

    // MARK: - Session Management

    /// Create a session with a remote peer
    /// - Parameter peer: The peer to create the session with
    /// - Returns: The tunnel session
    public func createSession(with peer: PeerId) async throws -> TunnelSession {
        guard isRunning else {
            throw TunnelError.notConnected
        }

        // Only one session at a time in this simple model
        if let existing = session {
            await existing.leave()
        }

        logger.info("Creating session", metadata: ["peer": "\(peer)"])

        // Send handshake to peer
        let handshake = SessionHandshake(type: .request)
        let data = try JSONEncoder().encode(handshake)
        try await provider.sendOnChannel(data, to: peer, channel: handshakeChannel)

        // Create session (don't wait for ack in simple model)
        let newSession = TunnelSession(
            remotePeer: peer,
            provider: provider
        )

        await newSession.activate()
        self.session = newSession

        logger.info("Session created", metadata: ["peer": "\(peer)"])
        return newSession
    }

    /// Get the current session
    public func currentSession() -> TunnelSession? {
        return session
    }

    /// Close the current session
    public func closeSession() async {
        if let session = session {
            // Notify peer
            let handshake = SessionHandshake(type: .close)
            if let data = try? JSONEncoder().encode(handshake) {
                let peer = session.remotePeer
                try? await provider.sendOnChannel(data, to: peer, channel: handshakeChannel)
            }

            await session.leave()
            self.session = nil
            logger.info("Session closed")
        }
    }

    // MARK: - Private

    private func handleHandshake(from peerId: PeerId, data: Data) async {
        guard let handshake = try? JSONDecoder().decode(SessionHandshake.self, from: data) else {
            logger.warning("Invalid handshake from \(peerId.prefix(8))...")
            return
        }

        switch handshake.type {
        case .request:
            // Remote peer wants to start a session
            let accept: Bool
            if let handler = sessionRequestHandler {
                accept = await handler(peerId)
            } else {
                // Accept by default
                accept = true
            }

            if accept {
                // Close existing session if any
                if let existing = session {
                    await existing.leave()
                }

                // Create new session
                let newSession = TunnelSession(
                    remotePeer: peerId,
                    provider: provider
                )
                await newSession.activate()
                self.session = newSession

                // Send ack
                let ack = SessionHandshake(type: .ack)
                if let ackData = try? JSONEncoder().encode(ack) {
                    try? await provider.sendOnChannel(ackData, to: peerId, channel: handshakeChannel)
                }

                logger.info("Session accepted", metadata: ["peer": "\(peerId)"])

                if let handler = sessionEstablishedHandler {
                    await handler(newSession)
                }
            } else {
                // Send reject
                let reject = SessionHandshake(type: .reject)
                if let rejectData = try? JSONEncoder().encode(reject) {
                    try? await provider.sendOnChannel(rejectData, to: peerId, channel: handshakeChannel)
                }
                logger.info("Session rejected", metadata: ["peer": "\(peerId)"])
            }

        case .ack:
            logger.debug("Session ack received", metadata: ["peer": "\(peerId)"])

        case .reject:
            logger.info("Session rejected by peer", metadata: ["peer": "\(peerId)"])

        case .close:
            if let session = session, session.remotePeer == peerId {
                await session.leave()
                self.session = nil
                logger.info("Session closed by peer", metadata: ["peer": "\(peerId)"])
            }
        }
    }
}

// MARK: - Internal Types

struct SessionHandshake: Codable, Sendable {
    enum HandshakeType: String, Codable, Sendable {
        case request
        case ack
        case reject
        case close
    }

    let type: HandshakeType
}
