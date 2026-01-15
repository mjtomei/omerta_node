// UDPSocket.swift - Async/await UDP socket wrapper using SwiftNIO

import Foundation
import NIOCore
import NIOPosix
import Logging

/// Async/await wrapper for UDP sockets using SwiftNIO
public actor UDPSocket {
    /// The NIO event loop group
    private let group: EventLoopGroup

    /// The bound channel
    private var channel: Channel?

    /// The local address we're bound to
    public private(set) var localAddress: SocketAddress?

    /// Handler for incoming datagrams
    private var incomingHandler: ((Data, SocketAddress) async -> Void)?

    /// Whether the socket is running
    private var isRunning = false

    /// Logger
    private let logger = Logger(label: "io.omerta.mesh.udp")

    /// Bootstrap for creating datagram channels
    private var bootstrap: DatagramBootstrap {
        DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(UDPInboundHandler(socket: self))
            }
    }

    public init(eventLoopGroup: EventLoopGroup? = nil) {
        self.group = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    // MARK: - Lifecycle

    /// Bind to a specific port
    public func bind(host: String = "0.0.0.0", port: Int) async throws {
        guard !isRunning else {
            throw UDPSocketError.alreadyRunning
        }

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel
        self.localAddress = channel.localAddress
        self.isRunning = true

        logger.info("UDP socket bound to \(channel.localAddress?.description ?? "unknown")")
    }

    /// Close the socket
    public func close() async {
        guard isRunning else { return }

        isRunning = false
        try? await channel?.close()
        channel = nil
        localAddress = nil

        logger.info("UDP socket closed")
    }

    // MARK: - Sending

    /// Send data to a specific address
    public func send(_ data: Data, to address: SocketAddress) async throws {
        guard let channel = channel, isRunning else {
            throw UDPSocketError.notRunning
        }

        let buffer = channel.allocator.buffer(bytes: data)
        let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)

        try await channel.writeAndFlush(envelope)
    }

    /// Send data to a host:port string
    public func send(_ data: Data, to endpoint: String) async throws {
        let address = try parseEndpoint(endpoint)
        try await send(data, to: address)
    }

    // MARK: - Receiving

    /// Set a handler for incoming datagrams
    public func onReceive(_ handler: @escaping (Data, SocketAddress) async -> Void) {
        self.incomingHandler = handler
    }

    /// Called by the inbound handler when data arrives
    fileprivate func handleIncoming(data: Data, from address: SocketAddress) async {
        await incomingHandler?(data, address)
    }

    // MARK: - Utilities

    /// Parse an endpoint string like "127.0.0.1:5000" into a SocketAddress
    private func parseEndpoint(_ endpoint: String) throws -> SocketAddress {
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2,
              let port = Int(parts[1]) else {
            throw UDPSocketError.invalidEndpoint(endpoint)
        }

        let host = String(parts[0])
        return try SocketAddress.makeAddressResolvingHost(host, port: port)
    }

    /// Get the port we're bound to
    public var port: Int? {
        localAddress?.port
    }
}

/// Errors from UDPSocket
public enum UDPSocketError: Error, CustomStringConvertible {
    case alreadyRunning
    case notRunning
    case invalidEndpoint(String)
    case sendFailed(Error)

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "UDP socket is already running"
        case .notRunning:
            return "UDP socket is not running"
        case .invalidEndpoint(let endpoint):
            return "Invalid endpoint: \(endpoint)"
        case .sendFailed(let error):
            return "Send failed: \(error)"
        }
    }
}

/// NIO channel handler for incoming UDP datagrams
private final class UDPInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let socket: UDPSocket

    init(socket: UDPSocket) {
        self.socket = socket
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            print("[UDP] channelRead: Failed to read bytes from buffer")
            return
        }

        let data = Data(bytes)
        let address = envelope.remoteAddress

        print("[UDP] channelRead: Received \(data.count) bytes from \(address)")

        // Handle on a Task to allow async processing
        Task {
            await socket.handleIncoming(data: data, from: address)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log but don't close - UDP is connectionless
        print("UDP error: \(error)")
    }
}
