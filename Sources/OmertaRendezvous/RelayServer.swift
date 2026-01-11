// RelayServer.swift
// UDP relay server for symmetric NAT fallback

import Foundation
import NIOCore
import NIOPosix
import Logging

/// A relay session between two peers
public struct RelaySession: Sendable {
    public let token: String
    public let peer1: String
    public let peer2: String
    public let createdAt: Date
    public let expiresAt: Date

    /// Endpoints assigned to each peer for this relay session
    public var peer1Endpoint: SocketAddress?
    public var peer2Endpoint: SocketAddress?

    public init(peer1: String, peer2: String, ttl: TimeInterval = 300) {
        self.token = UUID().uuidString
        self.peer1 = peer1
        self.peer2 = peer2
        self.createdAt = Date()
        self.expiresAt = Date().addingTimeInterval(ttl)
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }
}

/// UDP relay server for when direct connection isn't possible
public actor RelayServer {
    private let port: UInt16
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private let logger: Logger

    /// Active relay sessions keyed by token
    private var sessions: [String: RelaySession] = [:]

    /// Map from peer endpoint to session token
    private var endpointToSession: [String: String] = [:]

    /// Session TTL in seconds
    private let sessionTTL: TimeInterval

    public init(port: UInt16 = 3479, sessionTTL: TimeInterval = 300) {
        self.port = port
        self.sessionTTL = sessionTTL
        self.logger = Logger(label: "io.omerta.rendezvous.relay")
    }

    /// Start the relay server
    public func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let handler = RelayHandler(server: self)

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        do {
            let chan = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
            self.channel = chan
            logger.info("Relay server started", metadata: ["port": "\(port)"])

            // Start cleanup task
            startCleanupTask()
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw error
        }
    }

    /// Stop the relay server
    public func stop() async {
        if let channel = channel {
            try? await channel.close()
        }
        channel = nil

        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil

        logger.info("Relay server stopped")
    }

    /// Create a relay session between two peers
    public func createSession(peer1: String, peer2: String) -> RelaySession {
        let session = RelaySession(peer1: peer1, peer2: peer2, ttl: sessionTTL)
        sessions[session.token] = session

        logger.info("Relay session created", metadata: [
            "token": "\(session.token)",
            "peer1": "\(peer1)",
            "peer2": "\(peer2)"
        ])

        return session
    }

    /// Get session by token
    public func getSession(token: String) -> RelaySession? {
        guard let session = sessions[token], !session.isExpired else {
            return nil
        }
        return session
    }

    /// Register peer's endpoint for a session
    public func registerEndpoint(token: String, peerId: String, endpoint: SocketAddress) -> Bool {
        guard var session = sessions[token], !session.isExpired else {
            return false
        }

        let endpointKey = endpointString(endpoint)

        if peerId == session.peer1 {
            session.peer1Endpoint = endpoint
            endpointToSession[endpointKey] = token
        } else if peerId == session.peer2 {
            session.peer2Endpoint = endpoint
            endpointToSession[endpointKey] = token
        } else {
            return false
        }

        sessions[token] = session

        logger.debug("Peer registered for relay", metadata: [
            "token": "\(token)",
            "peerId": "\(peerId)",
            "endpoint": "\(endpointKey)"
        ])

        return true
    }

    /// Handle incoming relay packet
    func handlePacket(from sender: SocketAddress, data: Data) async -> (destination: SocketAddress, data: Data)? {
        let senderKey = endpointString(sender)

        guard let token = endpointToSession[senderKey],
              let session = sessions[token],
              !session.isExpired else {
            return nil
        }

        // Determine destination (relay to the other peer)
        let destination: SocketAddress?
        if let peer1Endpoint = session.peer1Endpoint, endpointString(peer1Endpoint) == senderKey {
            destination = session.peer2Endpoint
        } else if let peer2Endpoint = session.peer2Endpoint, endpointString(peer2Endpoint) == senderKey {
            destination = session.peer1Endpoint
        } else {
            destination = nil
        }

        guard let dest = destination else {
            return nil
        }

        logger.trace("Relaying packet", metadata: [
            "from": "\(senderKey)",
            "to": "\(endpointString(dest))",
            "size": "\(data.count)"
        ])

        return (dest, data)
    }

    /// Get the channel for sending
    nonisolated func getChannel() -> Channel? {
        // This is a workaround - in production we'd need better channel access
        return nil
    }

    /// Send data to a destination (called from handler)
    nonisolated func send(_ data: Data, to destination: SocketAddress, via channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        let envelope = AddressedEnvelope(remoteAddress: destination, data: buffer)

        channel.eventLoop.execute {
            channel.writeAndFlush(envelope, promise: nil)
        }
    }

    // MARK: - Cleanup

    private func startCleanupTask() {
        Task {
            while channel != nil {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                await cleanupExpiredSessions()
            }
        }
    }

    private func cleanupExpiredSessions() {
        var expiredTokens: [String] = []

        for (token, session) in sessions {
            if session.isExpired {
                expiredTokens.append(token)

                // Remove endpoint mappings
                if let ep1 = session.peer1Endpoint {
                    endpointToSession.removeValue(forKey: endpointString(ep1))
                }
                if let ep2 = session.peer2Endpoint {
                    endpointToSession.removeValue(forKey: endpointString(ep2))
                }
            }
        }

        for token in expiredTokens {
            sessions.removeValue(forKey: token)
        }

        if !expiredTokens.isEmpty {
            logger.info("Cleaned up expired relay sessions", metadata: ["count": "\(expiredTokens.count)"])
        }
    }

    // MARK: - Helpers

    private func endpointString(_ address: SocketAddress) -> String {
        guard let port = address.port else {
            return address.description
        }
        switch address {
        case .v4(let addr):
            return "\(addr.host):\(port)"
        case .v6(let addr):
            return "[\(addr.host)]:\(port)"
        default:
            return address.description
        }
    }

    /// Get active session count
    public var sessionCount: Int {
        sessions.values.filter { !$0.isExpired }.count
    }

    /// Get relay endpoint string for clients
    public var relayEndpoint: String {
        "0.0.0.0:\(port)"
    }
}

// MARK: - Relay Channel Handler

private final class RelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let server: RelayServer

    init(server: RelayServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let remoteAddress = envelope.remoteAddress

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let packetData = Data(bytes)
        let channel = context.channel

        Task {
            if let (destination, relayData) = await server.handlePacket(from: remoteAddress, data: packetData) {
                server.send(relayData, to: destination, via: channel)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log but don't close - UDP is connectionless
        print("Relay server error: \(error)")
    }
}

// MARK: - Relay Protocol

/// Relay packet header format
/// First byte: message type
/// Next 36 bytes: session token (UUID string)
/// Remaining: payload
public enum RelayMessageType: UInt8 {
    case register = 0x01   // Client registering for relay
    case data = 0x02       // Data to relay
    case keepalive = 0x03  // Keep session alive
}

public extension RelayServer {
    /// Parse relay protocol header
    static func parseRelayHeader(_ data: Data) -> (type: RelayMessageType, token: String, payload: Data)? {
        guard data.count >= 37 else { return nil }

        guard let messageType = RelayMessageType(rawValue: data[0]) else {
            return nil
        }

        guard let token = String(data: data[1..<37], encoding: .utf8) else {
            return nil
        }

        let payload = data.count > 37 ? Data(data[37...]) : Data()

        return (messageType, token, payload)
    }

    /// Create relay data packet
    static func createRelayPacket(token: String, payload: Data) -> Data {
        var packet = Data()
        packet.append(RelayMessageType.data.rawValue)
        packet.append(token.data(using: .utf8)!)
        packet.append(payload)
        return packet
    }

    /// Create relay register packet
    static func createRegisterPacket(token: String, peerId: String) -> Data {
        var packet = Data()
        packet.append(RelayMessageType.register.rawValue)
        packet.append(token.data(using: .utf8)!)
        packet.append(peerId.data(using: .utf8)!)
        return packet
    }
}
