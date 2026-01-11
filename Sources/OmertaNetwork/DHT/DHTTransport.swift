// DHTTransport.swift
// NIO-based UDP transport for DHT protocol

import Foundation
import NIOCore
import NIOPosix
import Logging

/// UDP transport for DHT protocol messages using NIO
public actor DHTTransport {
    private let port: UInt16
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private var isRunning = false
    private let logger: Logger

    /// Handler for incoming messages
    private var messageHandler: ((DHTPacket, DHTNodeInfo) async -> DHTPacket?)?

    /// Set the message handler
    public func setMessageHandler(_ handler: @escaping (DHTPacket, DHTNodeInfo) async -> DHTPacket?) {
        self.messageHandler = handler
    }

    /// The actual bound port
    public private(set) var boundPort: UInt16 = 0

    /// Pending responses keyed by transaction ID
    private var pendingResponses: [String: CheckedContinuation<DHTPacket, Error>] = [:]

    public init(port: UInt16 = 4000) {
        self.port = port
        self.logger = Logger(label: "io.omerta.dht.transport")
    }

    /// Start the UDP transport
    public func start() async throws {
        guard !isRunning else { return }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let handler = DHTChannelHandler(transport: self)

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        do {
            let chan = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
            self.channel = chan

            // Get actual bound port
            if let localAddr = chan.localAddress {
                self.boundPort = UInt16(localAddr.port ?? Int(port))
            }

            isRunning = true
            logger.info("DHT transport started on port \(boundPort)")
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw DHTTransportError.bindFailed(0)
        }
    }

    /// Stop the UDP transport
    public func stop() async {
        guard isRunning else { return }

        isRunning = false

        // Cancel all pending responses
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: DHTTransportError.notRunning)
        }
        pendingResponses.removeAll()

        // Close channel
        if let channel = channel {
            try? await channel.close()
        }
        channel = nil

        // Shutdown event loop
        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil

        logger.info("DHT transport stopped")
    }

    /// Send a packet to a node
    public func send(_ packet: DHTPacket, to node: DHTNodeInfo) async throws {
        guard isRunning, let channel = channel else {
            throw DHTTransportError.notRunning
        }

        let data = try packet.encode()

        guard let remoteAddr = try? SocketAddress(ipAddress: node.address, port: Int(node.port)) else {
            throw DHTTransportError.invalidAddress
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        let envelope = AddressedEnvelope(remoteAddress: remoteAddr, data: buffer)

        try await channel.writeAndFlush(envelope)
        logger.debug("Sent \(data.count) bytes to \(node.fullAddress)")
    }

    /// Send a request and wait for response
    public func sendRequest(_ packet: DHTPacket, to node: DHTNodeInfo, timeout: TimeInterval = 5.0) async throws -> DHTPacket {
        try await send(packet, to: node)

        let transactionId = packet.transactionId

        // Start timeout task on a detached task (so it can run concurrently)
        let timeoutTask = Task.detached { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.cancelPendingResponse(transactionId: transactionId)
        }

        defer {
            timeoutTask.cancel()
        }

        // Wait for response
        return try await waitForResponse(transactionId: transactionId)
    }

    /// Cancel a pending response (called on timeout)
    private func cancelPendingResponse(transactionId: String) {
        if let continuation = pendingResponses.removeValue(forKey: transactionId) {
            continuation.resume(throwing: DHTTransportError.timeout)
        }
    }

    // MARK: - Internal methods called by handler

    /// Called by channel handler when data is received
    nonisolated func handleReceivedData(_ data: Data, from address: String, port: UInt16) {
        Task {
            await self.processReceivedData(data, from: address, port: port)
        }
    }

    private func processReceivedData(_ data: Data, from address: String, port: UInt16) async {
        do {
            let packet = try DHTPacket.decode(from: data)

            // Check if this is a response to a pending request
            if let continuation = pendingResponses.removeValue(forKey: packet.transactionId) {
                continuation.resume(returning: packet)
                return
            }

            // Otherwise, handle as incoming request
            let sender = DHTNodeInfo(
                peerId: extractPeerId(from: packet.message),
                address: address,
                port: port
            )

            if let handler = messageHandler {
                if let response = await handler(packet, sender) {
                    try? await send(response, to: sender)
                }
            }
        } catch {
            logger.warning("Failed to decode DHT packet: \(error)")
        }
    }

    // MARK: - Private

    private func waitForResponse(transactionId: String) async throws -> DHTPacket {
        try await withCheckedThrowingContinuation { continuation in
            pendingResponses[transactionId] = continuation
        }
    }

    private func extractPeerId(from message: DHTMessage) -> String {
        switch message {
        case .ping(let fromId), .pong(let fromId),
             .findNode(_, let fromId), .foundNodes(_, let fromId),
             .store(_, _, let fromId), .stored(_, let fromId),
             .findValue(_, let fromId), .foundValue(_, let fromId),
             .valueNotFound(_, let fromId), .error(_, let fromId):
            return fromId
        }
    }
}

/// NIO channel handler for DHT UDP packets
private final class DHTChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let transport: DHTTransport

    init(transport: DHTTransport) {
        self.transport = transport
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let receivedData = Data(bytes)

        // Extract sender address and port from SocketAddress
        let remoteAddress = envelope.remoteAddress
        guard let senderPort = remoteAddress.port else {
            return
        }

        // Get address string representation
        let senderAddress: String
        switch remoteAddress {
        case .v4(let addr):
            senderAddress = addr.host
        case .v6(let addr):
            senderAddress = addr.host
        default:
            return
        }

        // Process asynchronously
        transport.handleReceivedData(receivedData, from: senderAddress, port: UInt16(senderPort))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log error but don't close - UDP is connectionless
        print("DHT transport error: \(error)")
    }
}

/// DHT transport errors
public enum DHTTransportError: Error, Sendable {
    case socketCreationFailed
    case bindFailed(Int32)
    case sendFailed(Int32)
    case notRunning
    case invalidAddress
    case timeout
}

/// Helper for timeout
private func withTimeout<T: Sendable>(_ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw DHTTransportError.timeout
        }

        guard let result = try await group.next() else {
            throw DHTTransportError.timeout
        }

        group.cancelAll()
        return result
    }
}
