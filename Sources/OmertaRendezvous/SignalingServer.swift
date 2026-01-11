// SignalingServer.swift
// WebSocket-based signaling server for NAT traversal coordination

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import Logging

/// WebSocket signaling server for coordinating NAT traversal
public actor SignalingServer {
    private let port: Int
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private let registry: PeerRegistry
    private let logger: Logger

    public init(port: Int = 8080) {
        self.port = port
        self.registry = PeerRegistry()
        self.logger = Logger(label: "io.omerta.rendezvous.signaling")
    }

    /// Start the signaling server
    public func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.eventLoopGroup = group

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                let handler = WebSocketHandler(server: self, channel: channel)
                return channel.pipeline.addHandler(handler)
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPServerPipelineHandler()
                let config = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    completionHandler: { _ in }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let chan = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
            self.channel = chan
            logger.info("Signaling server started", metadata: ["port": "\(port)"])
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw error
        }
    }

    /// Stop the signaling server
    public func stop() async {
        if let channel = channel {
            try? await channel.close()
        }
        channel = nil

        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil

        logger.info("Signaling server stopped")
    }

    /// Get the peer registry
    public nonisolated var peerRegistry: PeerRegistry {
        registry
    }

    // MARK: - Message Handling

    /// Handle an incoming client message
    func handleMessage(_ message: ClientMessage, channel: Channel) async {
        switch message {
        case .register(let peerId, let networkId):
            await handleRegister(peerId: peerId, networkId: networkId, channel: channel)

        case .requestConnection(let targetPeerId, let myPublicKey):
            await handleRequestConnection(targetPeerId: targetPeerId, publicKey: myPublicKey, channel: channel)

        case .reportEndpoint(let endpoint, let natType):
            await handleReportEndpoint(endpoint: endpoint, natType: natType, channel: channel)

        case .holePunchReady:
            await handleHolePunchReady(channel: channel)

        case .holePunchSent(let newEndpoint):
            await handleHolePunchSent(newEndpoint: newEndpoint, channel: channel)

        case .holePunchResult(let targetPeerId, let success, let actualEndpoint):
            await handleHolePunchResult(
                targetPeerId: targetPeerId,
                success: success,
                actualEndpoint: actualEndpoint,
                channel: channel
            )

        case .requestRelay(let targetPeerId):
            await handleRequestRelay(targetPeerId: targetPeerId, channel: channel)

        case .ping:
            await handlePing(channel: channel)
        }
    }

    /// Handle peer disconnect
    func handleDisconnect(channel: Channel) async {
        await registry.unregister(channel: channel)
    }

    // MARK: - Message Handlers

    private func handleRegister(peerId: String, networkId: String, channel: Channel) async {
        let success = await registry.register(peerId: peerId, networkId: networkId, channel: channel)

        if success {
            let response = ServerMessage.registered(serverTime: Date())
            await send(response, to: channel)
        } else {
            let response = ServerMessage.error(message: "Peer ID already registered")
            await send(response, to: channel)
        }
    }

    private func handleRequestConnection(targetPeerId: String, publicKey: String, channel: Channel) async {
        guard let requester = await registry.getPeer(channel: channel) else {
            await send(.error(message: "Not registered"), to: channel)
            return
        }

        // Update requester's public key
        await registry.updatePublicKey(peerId: requester.peerId, publicKey: publicKey)

        guard let target = await registry.getPeer(targetPeerId) else {
            await send(.error(message: "Target peer not found"), to: channel)
            return
        }

        // Create connection request
        guard let _ = await registry.createConnectionRequest(
            requesterId: requester.peerId,
            targetId: targetPeerId,
            requesterPublicKey: publicKey
        ) else {
            await send(.error(message: "Failed to create connection request"), to: channel)
            return
        }

        // Determine hole punch strategy based on NAT types
        let strategy = determineStrategy(requesterNAT: requester.natType, targetNAT: target.natType)

        // Send peer info and strategy to both parties
        if let targetEndpoint = target.endpoint, let targetKey = target.publicKey {
            await send(.peerEndpoint(
                peerId: targetPeerId,
                endpoint: targetEndpoint,
                natType: target.natType,
                publicKey: targetKey
            ), to: channel)
        }

        await send(.holePunchStrategy(strategy), to: channel)

        // Notify target peer
        if let targetChannel = await registry.getChannel(for: targetPeerId) {
            if let requesterEndpoint = requester.endpoint {
                await send(.peerEndpoint(
                    peerId: requester.peerId,
                    endpoint: requesterEndpoint,
                    natType: requester.natType,
                    publicKey: publicKey
                ), to: targetChannel)
            }

            // Send complementary strategy to target
            let targetStrategy = complementaryStrategy(strategy)
            await send(.holePunchStrategy(targetStrategy), to: targetChannel)
        }
    }

    private func handleReportEndpoint(endpoint: String, natType: NATType, channel: Channel) async {
        guard let peer = await registry.getPeer(channel: channel) else {
            await send(.error(message: "Not registered"), to: channel)
            return
        }

        await registry.updateEndpoint(peerId: peer.peerId, endpoint: endpoint, natType: natType)
    }

    private func handleHolePunchReady(channel: Channel) async {
        guard let peer = await registry.getPeer(channel: channel) else {
            return
        }

        // Find pending connection for this peer
        // For now, just log - more sophisticated state machine needed for production
        logger.debug("Peer ready for hole punch", metadata: ["peerId": "\(peer.peerId)"])
    }

    private func handleHolePunchSent(newEndpoint: String, channel: Channel) async {
        guard let peer = await registry.getPeer(channel: channel) else {
            return
        }

        // Update the peer's endpoint with the new symmetric NAT mapping
        await registry.updateEndpoint(peerId: peer.peerId, endpoint: newEndpoint, natType: .symmetric)

        // Notify the other peer in the connection to use this new endpoint
        // Find the connection request
        // This would require tracking active hole punch sessions
        logger.debug("Peer sent hole punch", metadata: [
            "peerId": "\(peer.peerId)",
            "newEndpoint": "\(newEndpoint)"
        ])
    }

    private func handleHolePunchResult(
        targetPeerId: String,
        success: Bool,
        actualEndpoint: String?,
        channel: Channel
    ) async {
        guard let peer = await registry.getPeer(channel: channel) else {
            return
        }

        logger.info("Hole punch result", metadata: [
            "from": "\(peer.peerId)",
            "target": "\(targetPeerId)",
            "success": "\(success)",
            "endpoint": "\(actualEndpoint ?? "none")"
        ])

        // Clean up connection request on success
        if success {
            await registry.removeConnectionRequest(peer1: peer.peerId, peer2: targetPeerId)
        }
    }

    private func handleRequestRelay(targetPeerId: String, channel: Channel) async {
        guard let peer = await registry.getPeer(channel: channel) else {
            await send(.error(message: "Not registered"), to: channel)
            return
        }

        guard await registry.getPeer(targetPeerId) != nil else {
            await send(.error(message: "Target peer not found"), to: channel)
            return
        }

        // TODO: Integrate with RelayServer to allocate relay session
        // For now, send a placeholder response
        let relayEndpoint = "relay.omerta.io:3479"
        let relayToken = UUID().uuidString

        await send(.relayAssigned(relayEndpoint: relayEndpoint, relayToken: relayToken), to: channel)

        logger.info("Relay requested", metadata: [
            "from": "\(peer.peerId)",
            "target": "\(targetPeerId)"
        ])
    }

    private func handlePing(channel: Channel) async {
        if let peer = await registry.getPeer(channel: channel) {
            await registry.touch(peerId: peer.peerId)
        }
        await send(.pong, to: channel)
    }

    // MARK: - Strategy Determination

    private func determineStrategy(requesterNAT: NATType, targetNAT: NATType) -> HolePunchStrategy {
        switch (requesterNAT, targetNAT) {
        case (.symmetric, .symmetric):
            return .relay

        case (.symmetric, _):
            return .youInitiate

        case (_, .symmetric):
            return .peerInitiates

        default:
            return .simultaneous
        }
    }

    private func complementaryStrategy(_ strategy: HolePunchStrategy) -> HolePunchStrategy {
        switch strategy {
        case .youInitiate:
            return .peerInitiates
        case .peerInitiates:
            return .youInitiate
        default:
            return strategy
        }
    }

    // MARK: - Sending

    private func send(_ message: ServerMessage, to channel: Channel) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)

        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)

        channel.eventLoop.execute {
            channel.writeAndFlush(frame, promise: nil)
        }
    }
}

// MARK: - HTTP Handler

private final class HTTPServerPipelineHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            // Check for WebSocket upgrade
            if head.uri == "/ws" || head.uri == "/" {
                // Let the upgrader handle it
                context.fireChannelRead(data)
            } else {
                // Return 404 for other paths
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                let head = HTTPResponseHead(version: .http1_1, status: .notFound, headers: headers)
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        case .body, .end:
            context.fireChannelRead(data)
        }
    }

    typealias OutboundOut = HTTPServerResponsePart
}

// MARK: - WebSocket Handler

private final class WebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: SignalingServer
    private let channel: Channel
    private var textBuffer = ""

    init(server: SignalingServer, channel: Channel) {
        self.server = server
        self.channel = channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            var frameData = frame.data
            if let text = frameData.readString(length: frameData.readableBytes) {
                textBuffer += text
                if frame.fin {
                    processMessage(textBuffer)
                    textBuffer = ""
                }
            }

        case .binary:
            // Not expected, ignore
            break

        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.data)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .pong:
            // Ignore pong responses
            break

        case .connectionClose:
            Task {
                await server.handleDisconnect(channel: channel)
            }
            context.close(promise: nil)

        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task {
            await server.handleDisconnect(channel: channel)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Task {
            await server.handleDisconnect(channel: channel)
        }
        context.close(promise: nil)
    }

    private func processMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let message = try? decoder.decode(ClientMessage.self, from: data) else {
            // Send error for invalid message
            Task {
                let error = ServerMessage.error(message: "Invalid message format")
                await sendError(error)
            }
            return
        }

        Task {
            await server.handleMessage(message, channel: channel)
        }
    }

    private func sendError(_ message: ServerMessage) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)

        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)

        channel.eventLoop.execute { [channel] in
            channel.writeAndFlush(frame, promise: nil)
        }
    }
}
