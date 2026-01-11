// WireGuardRelay.swift
// Encapsulates WireGuard UDP packets for relay transport

import Foundation
import NIOCore
import NIOPosix
import Logging

/// Relay packet header format:
/// [4 bytes: session token] [4 bytes: length] [N bytes: WireGuard packet]
/// Total overhead: 8 bytes per packet

/// WireGuard relay client that encapsulates WireGuard packets for relay transport
public actor WireGuardRelayClient {
    private let relayEndpoint: String
    private let sessionToken: Data
    private let logger: Logger

    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private var localPort: UInt16 = 0
    private var packetHandler: ((Data, String) -> Void)?

    /// Header size for relay encapsulation
    public static let headerSize = 8

    public init(relayEndpoint: String, sessionToken: Data) {
        self.relayEndpoint = relayEndpoint
        self.sessionToken = sessionToken
        self.logger = Logger(label: "io.omerta.network.wg-relay")
    }

    /// Start the relay client and bind to a local port
    /// Returns the local port that WireGuard should connect to
    public func start(preferredPort: UInt16 = 0) async throws -> UInt16 {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let handler = RelayPacketHandler { [weak self] data, source in
            Task {
                await self?.handleIncomingPacket(data, from: source)
            }
        }

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        do {
            let chan = try await bootstrap.bind(host: "127.0.0.1", port: Int(preferredPort)).get()
            self.channel = chan

            // Get the bound port
            if let addr = chan.localAddress, let port = addr.port {
                self.localPort = UInt16(port)
            }

            logger.info("WireGuard relay client started", metadata: [
                "localPort": "\(localPort)",
                "relayEndpoint": "\(relayEndpoint)"
            ])

            return localPort
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw WireGuardRelayError.bindFailed(error)
        }
    }

    /// Stop the relay client
    public func stop() async {
        if let channel = channel {
            try? await channel.close()
        }
        channel = nil

        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil

        logger.info("WireGuard relay client stopped")
    }

    /// The local port WireGuard should connect to
    public var boundPort: UInt16 {
        localPort
    }

    /// Set handler for incoming packets (decapsulated WireGuard packets)
    public func setPacketHandler(_ handler: @escaping (Data, String) -> Void) {
        self.packetHandler = handler
    }

    /// Send a WireGuard packet through the relay
    public func sendPacket(_ packet: Data) async throws {
        guard let channel = channel else {
            throw WireGuardRelayError.notConnected
        }

        // Encapsulate the packet
        let encapsulated = encapsulate(packet)

        // Parse relay endpoint
        let relayAddress = try parseEndpoint(relayEndpoint)

        var buffer = channel.allocator.buffer(capacity: encapsulated.count)
        buffer.writeBytes(encapsulated)

        let envelope = AddressedEnvelope(remoteAddress: relayAddress, data: buffer)
        try await channel.writeAndFlush(envelope)
    }

    /// Encapsulate a WireGuard packet with relay header
    public func encapsulate(_ packet: Data) -> Data {
        var result = Data(capacity: Self.headerSize + packet.count)

        // Session token (4 bytes)
        result.append(contentsOf: sessionToken.prefix(4))

        // Length (4 bytes, big-endian)
        let length = UInt32(packet.count)
        result.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Array($0) })

        // WireGuard packet
        result.append(packet)

        return result
    }

    /// Decapsulate a relay packet to extract WireGuard packet
    public func decapsulate(_ packet: Data) -> Data? {
        guard packet.count >= Self.headerSize else {
            return nil
        }

        // Verify session token matches
        let tokenBytes = Array(packet.prefix(4))
        let expectedToken = Array(sessionToken.prefix(4))
        guard tokenBytes == expectedToken else {
            logger.warning("Invalid session token in relay packet")
            return nil
        }

        // Parse length
        let lengthBytes = Array(packet[4..<8])
        let length = UInt32(lengthBytes[0]) << 24 | UInt32(lengthBytes[1]) << 16 |
                     UInt32(lengthBytes[2]) << 8 | UInt32(lengthBytes[3])

        guard packet.count >= Self.headerSize + Int(length) else {
            logger.warning("Relay packet too short for declared length")
            return nil
        }

        // Extract WireGuard packet
        return Data(packet[Self.headerSize..<(Self.headerSize + Int(length))])
    }

    // MARK: - Private

    private func handleIncomingPacket(_ data: Data, from source: String) async {
        // If packet is from relay, decapsulate it
        if source.hasPrefix(relayEndpoint.split(separator: ":").first ?? "") {
            if let wgPacket = decapsulate(data) {
                packetHandler?(wgPacket, source)
            }
        } else {
            // Packet from local WireGuard - forward to relay
            do {
                try await sendPacket(data)
            } catch {
                logger.warning("Failed to forward packet to relay", metadata: ["error": "\(error)"])
            }
        }
    }

    private func parseEndpoint(_ endpoint: String) throws -> SocketAddress {
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw WireGuardRelayError.invalidEndpoint(endpoint)
        }
        return try SocketAddress.makeAddressResolvingHost(String(parts[0]), port: port)
    }
}

// MARK: - Relay Packet Handler

private final class RelayPacketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let callback: (Data, String) -> Void

    init(callback: @escaping (Data, String) -> Void) {
        self.callback = callback
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let source = formatEndpoint(envelope.remoteAddress)
        callback(Data(bytes), source)
    }

    private func formatEndpoint(_ address: SocketAddress) -> String {
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
}

// MARK: - WireGuard Relay Proxy

/// Proxy that sits between local WireGuard and the relay server
/// WireGuard connects to this proxy locally, proxy forwards to relay
public actor WireGuardRelayProxy {
    private let relayEndpoint: String
    private let sessionToken: Data
    private let peerEndpoint: String  // The actual peer we're communicating with
    private let logger: Logger

    private var localChannel: Channel?
    private var relayChannel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private var localPort: UInt16 = 0

    public init(
        relayEndpoint: String,
        sessionToken: Data,
        peerEndpoint: String
    ) {
        self.relayEndpoint = relayEndpoint
        self.sessionToken = sessionToken
        self.peerEndpoint = peerEndpoint
        self.logger = Logger(label: "io.omerta.network.wg-relay-proxy")
    }

    /// Start the proxy and return the local endpoint WireGuard should use
    public func start(localPort: UInt16 = 0) async throws -> String {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.eventLoopGroup = group

        // Bind local UDP socket for WireGuard to connect to
        let localBootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let localChan = try await localBootstrap.bind(host: "127.0.0.1", port: Int(localPort)).get()
        self.localChannel = localChan

        if let addr = localChan.localAddress, let port = addr.port {
            self.localPort = UInt16(port)
        }

        // Connect to relay server
        let relayBootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let relayChan = try await relayBootstrap.bind(host: "0.0.0.0", port: 0).get()
        self.relayChannel = relayChan

        // Set up packet forwarding
        let localHandler = ProxyHandler(
            direction: .toRelay,
            sessionToken: sessionToken,
            targetEndpoint: relayEndpoint,
            targetChannel: relayChan,
            logger: logger
        )
        try await localChan.pipeline.addHandler(localHandler).get()

        let relayHandler = ProxyHandler(
            direction: .fromRelay,
            sessionToken: sessionToken,
            targetEndpoint: "127.0.0.1:\(self.localPort)",
            targetChannel: localChan,
            logger: logger
        )
        try await relayChan.pipeline.addHandler(relayHandler).get()

        logger.info("WireGuard relay proxy started", metadata: [
            "localPort": "\(self.localPort)",
            "relay": "\(relayEndpoint)"
        ])

        return "127.0.0.1:\(self.localPort)"
    }

    /// Stop the proxy
    public func stop() async {
        if let localChan = localChannel {
            try? await localChan.close()
        }
        if let relayChan = relayChannel {
            try? await relayChan.close()
        }
        localChannel = nil
        relayChannel = nil

        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil

        logger.info("WireGuard relay proxy stopped")
    }

    /// The local endpoint WireGuard should connect to
    public var localEndpoint: String {
        "127.0.0.1:\(localPort)"
    }
}

/// Direction of packet flow in the proxy
private enum ProxyDirection {
    case toRelay    // From local WireGuard to relay
    case fromRelay  // From relay to local WireGuard
}

/// Handler that forwards packets between WireGuard and relay
private final class ProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let direction: ProxyDirection
    private let sessionToken: Data
    private let targetEndpoint: String
    private let targetChannel: Channel
    private let logger: Logger

    init(
        direction: ProxyDirection,
        sessionToken: Data,
        targetEndpoint: String,
        targetChannel: Channel,
        logger: Logger
    ) {
        self.direction = direction
        self.sessionToken = sessionToken
        self.targetEndpoint = targetEndpoint
        self.targetChannel = targetChannel
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let packet = Data(bytes)

        Task {
            do {
                switch direction {
                case .toRelay:
                    // Encapsulate and send to relay
                    let encapsulated = encapsulate(packet)
                    try await sendToTarget(encapsulated)

                case .fromRelay:
                    // Decapsulate and send to WireGuard
                    if let wgPacket = decapsulate(packet) {
                        try await sendToTarget(wgPacket)
                    }
                }
            } catch {
                logger.warning("Failed to forward packet", metadata: ["error": "\(error)"])
            }
        }
    }

    private func encapsulate(_ packet: Data) -> Data {
        var result = Data(capacity: WireGuardRelayClient.headerSize + packet.count)
        result.append(contentsOf: sessionToken.prefix(4))
        let length = UInt32(packet.count)
        result.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Array($0) })
        result.append(packet)
        return result
    }

    private func decapsulate(_ packet: Data) -> Data? {
        guard packet.count >= WireGuardRelayClient.headerSize else {
            return nil
        }

        let tokenBytes = Array(packet.prefix(4))
        let expectedToken = Array(sessionToken.prefix(4))
        guard tokenBytes == expectedToken else {
            return nil
        }

        let lengthBytes = Array(packet[4..<8])
        let length = UInt32(lengthBytes[0]) << 24 | UInt32(lengthBytes[1]) << 16 |
                     UInt32(lengthBytes[2]) << 8 | UInt32(lengthBytes[3])

        guard packet.count >= WireGuardRelayClient.headerSize + Int(length) else {
            return nil
        }

        return Data(packet[WireGuardRelayClient.headerSize..<(WireGuardRelayClient.headerSize + Int(length))])
    }

    private func sendToTarget(_ data: Data) async throws {
        let parts = targetEndpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw WireGuardRelayError.invalidEndpoint(targetEndpoint)
        }

        let address = try SocketAddress.makeAddressResolvingHost(String(parts[0]), port: port)

        var buffer = targetChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)
        try await targetChannel.writeAndFlush(envelope)
    }
}

// MARK: - Errors

public enum WireGuardRelayError: Error, CustomStringConvertible {
    case notConnected
    case bindFailed(Error)
    case invalidEndpoint(String)
    case encapsulationFailed
    case decapsulationFailed

    public var description: String {
        switch self {
        case .notConnected:
            return "Not connected to relay"
        case .bindFailed(let error):
            return "Failed to bind: \(error)"
        case .invalidEndpoint(let endpoint):
            return "Invalid endpoint: \(endpoint)"
        case .encapsulationFailed:
            return "Failed to encapsulate packet"
        case .decapsulationFailed:
            return "Failed to decapsulate packet"
        }
    }
}
