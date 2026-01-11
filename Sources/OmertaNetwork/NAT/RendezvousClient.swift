// RendezvousClient.swift
// WebSocket client for signaling server communication

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import Logging

/// Client for connecting to the rendezvous signaling server
public actor RendezvousClient {
    private let serverURL: URL
    private let peerId: String
    private let networkId: String
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private let logger: Logger

    /// Delegate for receiving server messages
    private var messageHandler: ((ServerMessage) -> Void)?

    /// Connection state
    public private(set) var isConnected: Bool = false

    /// Our registered endpoint (after reportEndpoint)
    public private(set) var registeredEndpoint: String?

    /// Server time from registration
    public private(set) var serverTime: Date?

    public init(serverURL: URL, peerId: String, networkId: String) {
        self.serverURL = serverURL
        self.peerId = peerId
        self.networkId = networkId
        self.logger = Logger(label: "io.omerta.network.rendezvous.client")
    }

    /// Set handler for incoming server messages
    public func setMessageHandler(_ handler: @escaping (ServerMessage) -> Void) {
        self.messageHandler = handler
    }

    /// Connect to the signaling server
    public func connect() async throws {
        guard !isConnected else { return }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let host = serverURL.host ?? "localhost"
        let port = serverURL.port ?? (serverURL.scheme == "wss" ? 443 : 8080)

        do {
            let channel = try await connectWebSocket(group: group, host: host, port: port)
            self.channel = channel
            self.isConnected = true

            logger.info("Connected to rendezvous server", metadata: [
                "host": "\(host)",
                "port": "\(port)"
            ])
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw error
        }
    }

    /// Disconnect from the server
    public func disconnect() async {
        if let channel = channel {
            // Send close frame
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: channel.allocator.buffer(capacity: 0))
            try? await channel.writeAndFlush(closeFrame)
            try? await channel.close()
        }
        channel = nil
        isConnected = false

        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil

        logger.info("Disconnected from rendezvous server")
    }

    // MARK: - Client Messages

    /// Register with the signaling server
    public func register() async throws {
        try await send(.register(peerId: peerId, networkId: networkId))
    }

    /// Report our discovered endpoint and NAT type
    public func reportEndpoint(_ endpoint: String, natType: NATType) async throws {
        registeredEndpoint = endpoint
        try await send(.reportEndpoint(endpoint: endpoint, natType: natType))
    }

    /// Request connection to a peer
    public func requestConnection(targetPeerId: String, myPublicKey: String) async throws {
        try await send(.requestConnection(targetPeerId: targetPeerId, myPublicKey: myPublicKey))
    }

    /// Signal that we're ready for hole punching
    public func holePunchReady() async throws {
        try await send(.holePunchReady)
    }

    /// Report new endpoint after sending (for symmetric NAT)
    public func holePunchSent(newEndpoint: String) async throws {
        try await send(.holePunchSent(newEndpoint: newEndpoint))
    }

    /// Report hole punch result
    public func holePunchResult(targetPeerId: String, success: Bool, actualEndpoint: String?) async throws {
        try await send(.holePunchResult(targetPeerId: targetPeerId, success: success, actualEndpoint: actualEndpoint))
    }

    /// Request relay allocation
    public func requestRelay(targetPeerId: String) async throws {
        try await send(.requestRelay(targetPeerId: targetPeerId))
    }

    /// Send ping to keep connection alive
    public func ping() async throws {
        try await send(.ping)
    }

    // MARK: - Message Streaming

    /// Wait for next server message (with timeout)
    public func waitForMessage(timeout: TimeInterval = 30.0) async throws -> ServerMessage {
        try await withThrowingTaskGroup(of: ServerMessage?.self) { group in
            group.addTask {
                // Wait for message from handler
                // This is a simplified implementation - in production use AsyncStream
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            for try await result in group {
                if let message = result {
                    group.cancelAll()
                    return message
                }
            }

            throw RendezvousError.timeout
        }
    }

    // MARK: - Private Methods

    private func send(_ message: ClientMessage) async throws {
        guard let channel = channel, isConnected else {
            throw RendezvousError.notConnected
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RendezvousError.encodingFailed
        }

        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)

        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)

        try await channel.writeAndFlush(frame)

        logger.debug("Sent message", metadata: ["type": "\(type(of: message))"])
    }

    private func connectWebSocket(group: EventLoopGroup, host: String, port: Int) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.connect(host: host, port: port).get()

        // Add HTTP handlers for upgrade
        let httpHandler = HTTPClientHandler(host: host, uri: "/ws")
        let upgrader = NIOWebSocketClientUpgrader(
            upgradePipelineHandler: { channel, _ in
                let wsHandler = WebSocketClientHandler(client: self)
                return channel.pipeline.addHandler(wsHandler)
            }
        )

        let config = NIOHTTPClientUpgradeConfiguration(
            upgraders: [upgrader],
            completionHandler: { context in
                // Remove HTTP handlers after upgrade
                context.pipeline.removeHandler(httpHandler, promise: nil)
            }
        )

        try await channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).get()
        try await channel.pipeline.addHandler(httpHandler).get()

        // Wait for upgrade to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms for upgrade

        return channel
    }

    /// Handle received message from WebSocket
    nonisolated func handleMessage(_ message: ServerMessage) {
        Task {
            await self.processMessage(message)
        }
    }

    private func processMessage(_ message: ServerMessage) {
        switch message {
        case .registered(let time):
            serverTime = time
            logger.info("Registered with server", metadata: ["serverTime": "\(time)"])

        case .error(let errorMessage):
            logger.error("Server error: \(errorMessage)")

        case .pong:
            logger.trace("Received pong")

        default:
            break
        }

        // Call user's message handler
        messageHandler?(message)
    }
}

// MARK: - HTTP Client Handler

private final class HTTPClientHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let host: String
    private let uri: String

    init(host: String, uri: String) {
        self.host = host
        self.uri = uri
    }

    func channelActive(context: ChannelHandlerContext) {
        // Send WebSocket upgrade request
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        headers.add(name: "Upgrade", value: "websocket")
        headers.add(name: "Connection", value: "Upgrade")
        headers.add(name: "Sec-WebSocket-Key", value: generateWebSocketKey())
        headers.add(name: "Sec-WebSocket-Version", value: "13")

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Let the upgrader handle the response
        context.fireChannelRead(data)
    }

    private func generateWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
    }
}

// MARK: - WebSocket Client Handler

private final class WebSocketClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let client: RendezvousClient
    private var textBuffer = ""

    init(client: RendezvousClient) {
        self.client = client
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
            // Not expected
            break

        case .ping:
            var pongData = frame.data
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .pong:
            // Ignore
            break

        case .connectionClose:
            context.close(promise: nil)

        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("WebSocket client error: \(error)")
        context.close(promise: nil)
    }

    private func processMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let message = try? decoder.decode(ServerMessage.self, from: data) else {
            return
        }

        client.handleMessage(message)
    }
}

// MARK: - Client Messages

/// Messages sent from client to signaling server
public enum ClientMessage: Codable, Sendable {
    case register(peerId: String, networkId: String)
    case requestConnection(targetPeerId: String, myPublicKey: String)
    case reportEndpoint(endpoint: String, natType: NATType)
    case holePunchReady
    case holePunchSent(newEndpoint: String)
    case holePunchResult(targetPeerId: String, success: Bool, actualEndpoint: String?)
    case requestRelay(targetPeerId: String)
    case ping

    private enum CodingKeys: String, CodingKey {
        case type
        case peerId, networkId
        case targetPeerId, myPublicKey
        case endpoint, natType
        case newEndpoint
        case success, actualEndpoint
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .register(let peerId, let networkId):
            try container.encode("register", forKey: .type)
            try container.encode(peerId, forKey: .peerId)
            try container.encode(networkId, forKey: .networkId)

        case .requestConnection(let targetPeerId, let myPublicKey):
            try container.encode("requestConnection", forKey: .type)
            try container.encode(targetPeerId, forKey: .targetPeerId)
            try container.encode(myPublicKey, forKey: .myPublicKey)

        case .reportEndpoint(let endpoint, let natType):
            try container.encode("reportEndpoint", forKey: .type)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(natType, forKey: .natType)

        case .holePunchReady:
            try container.encode("holePunchReady", forKey: .type)

        case .holePunchSent(let newEndpoint):
            try container.encode("holePunchSent", forKey: .type)
            try container.encode(newEndpoint, forKey: .newEndpoint)

        case .holePunchResult(let targetPeerId, let success, let actualEndpoint):
            try container.encode("holePunchResult", forKey: .type)
            try container.encode(targetPeerId, forKey: .targetPeerId)
            try container.encode(success, forKey: .success)
            try container.encodeIfPresent(actualEndpoint, forKey: .actualEndpoint)

        case .requestRelay(let targetPeerId):
            try container.encode("requestRelay", forKey: .type)
            try container.encode(targetPeerId, forKey: .targetPeerId)

        case .ping:
            try container.encode("ping", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "register":
            let peerId = try container.decode(String.self, forKey: .peerId)
            let networkId = try container.decode(String.self, forKey: .networkId)
            self = .register(peerId: peerId, networkId: networkId)

        case "requestConnection":
            let targetPeerId = try container.decode(String.self, forKey: .targetPeerId)
            let myPublicKey = try container.decode(String.self, forKey: .myPublicKey)
            self = .requestConnection(targetPeerId: targetPeerId, myPublicKey: myPublicKey)

        case "reportEndpoint":
            let endpoint = try container.decode(String.self, forKey: .endpoint)
            let natType = try container.decode(NATType.self, forKey: .natType)
            self = .reportEndpoint(endpoint: endpoint, natType: natType)

        case "holePunchReady":
            self = .holePunchReady

        case "holePunchSent":
            let newEndpoint = try container.decode(String.self, forKey: .newEndpoint)
            self = .holePunchSent(newEndpoint: newEndpoint)

        case "holePunchResult":
            let targetPeerId = try container.decode(String.self, forKey: .targetPeerId)
            let success = try container.decode(Bool.self, forKey: .success)
            let actualEndpoint = try container.decodeIfPresent(String.self, forKey: .actualEndpoint)
            self = .holePunchResult(targetPeerId: targetPeerId, success: success, actualEndpoint: actualEndpoint)

        case "requestRelay":
            let targetPeerId = try container.decode(String.self, forKey: .targetPeerId)
            self = .requestRelay(targetPeerId: targetPeerId)

        case "ping":
            self = .ping

        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown type: \(type)")
            )
        }
    }
}

// MARK: - Server Messages

/// Messages received from signaling server
public enum ServerMessage: Codable, Sendable {
    case registered(serverTime: Date)
    case peerEndpoint(peerId: String, endpoint: String, natType: NATType, publicKey: String)
    case holePunchStrategy(HolePunchStrategy)
    case holePunchNow(targetEndpoint: String)
    case holePunchInitiate(targetEndpoint: String)
    case holePunchWait
    case holePunchContinue(newEndpoint: String)
    case relayAssigned(relayEndpoint: String, relayToken: String)
    case pong
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case serverTime
        case peerId, endpoint, natType, publicKey
        case strategy
        case targetEndpoint, newEndpoint
        case relayEndpoint, relayToken
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "registered":
            let serverTime = try container.decode(Date.self, forKey: .serverTime)
            self = .registered(serverTime: serverTime)

        case "peerEndpoint":
            let peerId = try container.decode(String.self, forKey: .peerId)
            let endpoint = try container.decode(String.self, forKey: .endpoint)
            let natType = try container.decode(NATType.self, forKey: .natType)
            let publicKey = try container.decode(String.self, forKey: .publicKey)
            self = .peerEndpoint(peerId: peerId, endpoint: endpoint, natType: natType, publicKey: publicKey)

        case "holePunchStrategy":
            let strategy = try container.decode(HolePunchStrategy.self, forKey: .strategy)
            self = .holePunchStrategy(strategy)

        case "holePunchNow":
            let targetEndpoint = try container.decode(String.self, forKey: .targetEndpoint)
            self = .holePunchNow(targetEndpoint: targetEndpoint)

        case "holePunchInitiate":
            let targetEndpoint = try container.decode(String.self, forKey: .targetEndpoint)
            self = .holePunchInitiate(targetEndpoint: targetEndpoint)

        case "holePunchWait":
            self = .holePunchWait

        case "holePunchContinue":
            let newEndpoint = try container.decode(String.self, forKey: .newEndpoint)
            self = .holePunchContinue(newEndpoint: newEndpoint)

        case "relayAssigned":
            let relayEndpoint = try container.decode(String.self, forKey: .relayEndpoint)
            let relayToken = try container.decode(String.self, forKey: .relayToken)
            self = .relayAssigned(relayEndpoint: relayEndpoint, relayToken: relayToken)

        case "pong":
            self = .pong

        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message: message)

        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown type: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .registered(let serverTime):
            try container.encode("registered", forKey: .type)
            try container.encode(serverTime, forKey: .serverTime)

        case .peerEndpoint(let peerId, let endpoint, let natType, let publicKey):
            try container.encode("peerEndpoint", forKey: .type)
            try container.encode(peerId, forKey: .peerId)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(natType, forKey: .natType)
            try container.encode(publicKey, forKey: .publicKey)

        case .holePunchStrategy(let strategy):
            try container.encode("holePunchStrategy", forKey: .type)
            try container.encode(strategy, forKey: .strategy)

        case .holePunchNow(let targetEndpoint):
            try container.encode("holePunchNow", forKey: .type)
            try container.encode(targetEndpoint, forKey: .targetEndpoint)

        case .holePunchInitiate(let targetEndpoint):
            try container.encode("holePunchInitiate", forKey: .type)
            try container.encode(targetEndpoint, forKey: .targetEndpoint)

        case .holePunchWait:
            try container.encode("holePunchWait", forKey: .type)

        case .holePunchContinue(let newEndpoint):
            try container.encode("holePunchContinue", forKey: .type)
            try container.encode(newEndpoint, forKey: .newEndpoint)

        case .relayAssigned(let relayEndpoint, let relayToken):
            try container.encode("relayAssigned", forKey: .type)
            try container.encode(relayEndpoint, forKey: .relayEndpoint)
            try container.encode(relayToken, forKey: .relayToken)

        case .pong:
            try container.encode("pong", forKey: .type)

        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}

// MARK: - Hole Punch Strategy

public enum HolePunchStrategy: String, Codable, Sendable {
    case simultaneous   // Both cone: send at same time
    case youInitiate    // You're symmetric, peer is cone: you send first
    case peerInitiates  // You're cone, peer is symmetric: wait then reply
    case relay          // Both symmetric: use relay
}

// MARK: - Errors

public enum RendezvousError: Error, CustomStringConvertible {
    case notConnected
    case encodingFailed
    case timeout
    case connectionFailed(String)

    public var description: String {
        switch self {
        case .notConnected:
            return "Not connected to rendezvous server"
        case .encodingFailed:
            return "Failed to encode message"
        case .timeout:
            return "Operation timed out"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        }
    }
}
