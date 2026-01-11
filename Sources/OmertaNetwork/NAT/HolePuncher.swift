// HolePuncher.swift
// UDP hole punch coordination for NAT traversal

import Foundation
import NIOCore
import NIOPosix
import Logging

/// Result of a hole punch attempt
public enum HolePunchResult: Sendable {
    case success(actualEndpoint: String, rtt: TimeInterval)
    case failed(reason: HolePunchFailure)
}

/// Reasons for hole punch failure
public enum HolePunchFailure: Error, Sendable {
    case timeout
    case bothSymmetric
    case firewallBlocked
    case peerUnreachable
    case bindFailed
    case invalidEndpoint(String)
}

/// UDP hole puncher for establishing direct connections through NAT
public actor HolePuncher {
    private let logger: Logger
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?

    /// Hole punch probe packet magic bytes
    private static let probeMagic: [UInt8] = [0x4F, 0x4D, 0x45, 0x52, 0x54, 0x41, 0x48, 0x50] // "OMERTAHP"

    /// Default timeout for hole punch attempts
    public static let defaultTimeout: TimeInterval = 10.0

    /// Number of probe packets to send
    public static let probeCount: Int = 5

    /// Interval between probe packets
    public static let probeInterval: TimeInterval = 0.2

    public init() {
        self.logger = Logger(label: "io.omerta.network.holepuncher")
    }

    /// Execute hole punch based on strategy
    public func execute(
        localPort: UInt16,
        targetEndpoint: String,
        strategy: HolePunchStrategy,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> HolePunchResult {
        switch strategy {
        case .simultaneous:
            return try await simultaneousPunch(
                localPort: localPort,
                targetEndpoint: targetEndpoint,
                timeout: timeout
            )

        case .youInitiate:
            let (result, _) = try await initiatePunch(
                localPort: localPort,
                targetEndpoint: targetEndpoint,
                timeout: timeout
            )
            return result

        case .peerInitiates:
            let sourceEndpoint = try await waitForPunch(
                localPort: localPort,
                timeout: timeout
            )
            // After receiving, send response to establish bidirectional hole
            return try await simultaneousPunch(
                localPort: localPort,
                targetEndpoint: sourceEndpoint,
                timeout: timeout / 2
            )

        case .relay:
            return .failed(reason: .bothSymmetric)
        }
    }

    /// Strategy: simultaneous - both send at coordinated time
    public func simultaneousPunch(
        localPort: UInt16,
        targetEndpoint: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> HolePunchResult {
        let channel = try await bindChannel(localPort: localPort)
        defer { cleanup() }

        guard let targetAddress = try? parseEndpoint(targetEndpoint) else {
            return .failed(reason: .invalidEndpoint(targetEndpoint))
        }

        let startTime = Date()

        // Start receiver
        let handler = HolePunchHandler()
        try await channel.pipeline.addHandler(handler).get()

        // Send multiple probe packets
        for i in 0..<Self.probeCount {
            try await sendProbe(to: targetAddress, channel: channel, sequence: UInt32(i))
            if i < Self.probeCount - 1 {
                try await Task.sleep(nanoseconds: UInt64(Self.probeInterval * 1_000_000_000))
            }
        }

        // Wait for response
        let result = await withTaskGroup(of: HolePunchResult.self) { group in
            group.addTask {
                if let (endpoint, sequence) = await handler.waitForProbe(timeout: timeout) {
                    let rtt = Date().timeIntervalSince(startTime)
                    return .success(actualEndpoint: endpoint, rtt: rtt)
                }
                return .failed(reason: .timeout)
            }

            for await result in group {
                return result
            }

            return .failed(reason: .timeout)
        }

        if case .success(let endpoint, let rtt) = result {
            logger.info("Hole punch succeeded", metadata: [
                "endpoint": "\(endpoint)",
                "rtt": "\(String(format: "%.2f", rtt * 1000))ms"
            ])
        }

        return result
    }

    /// Strategy: youInitiate - we're symmetric, send first to cone peer
    public func initiatePunch(
        localPort: UInt16,
        targetEndpoint: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> (result: HolePunchResult, newEndpoint: String) {
        let channel = try await bindChannel(localPort: localPort)
        defer { cleanup() }

        guard let targetAddress = try? parseEndpoint(targetEndpoint) else {
            return (.failed(reason: .invalidEndpoint(targetEndpoint)), "")
        }

        let startTime = Date()

        // Add handler to receive responses
        let handler = HolePunchHandler()
        try await channel.pipeline.addHandler(handler).get()

        // Send probes - this creates our NAT mapping
        for i in 0..<Self.probeCount {
            try await sendProbe(to: targetAddress, channel: channel, sequence: UInt32(i))
            if i < Self.probeCount - 1 {
                try await Task.sleep(nanoseconds: UInt64(Self.probeInterval * 1_000_000_000))
            }
        }

        // Our new endpoint is the source address the peer sees
        // We need STUN to discover this, or the peer reports it back
        // For now, assume we get a response from the peer

        let result = await withTaskGroup(of: HolePunchResult.self) { group in
            group.addTask {
                if let (endpoint, _) = await handler.waitForProbe(timeout: timeout) {
                    let rtt = Date().timeIntervalSince(startTime)
                    return .success(actualEndpoint: endpoint, rtt: rtt)
                }
                return .failed(reason: .timeout)
            }

            for await result in group {
                return result
            }

            return .failed(reason: .timeout)
        }

        // The newEndpoint would be discovered via STUN after sending
        // For simplicity, return the local binding info
        let localEndpoint = channel.localAddress?.description ?? "unknown"

        return (result, localEndpoint)
    }

    /// Strategy: peerInitiates - we're cone, wait for symmetric peer
    public func waitForPunch(
        localPort: UInt16,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        let channel = try await bindChannel(localPort: localPort)
        defer { cleanup() }

        let handler = HolePunchHandler()
        try await channel.pipeline.addHandler(handler).get()

        logger.info("Waiting for hole punch probe", metadata: ["port": "\(localPort)"])

        guard let (endpoint, _) = await handler.waitForProbe(timeout: timeout) else {
            throw HolePunchFailure.timeout
        }

        logger.info("Received hole punch probe", metadata: ["from": "\(endpoint)"])

        // Send response back to open the hole in our direction
        if let sourceAddress = try? parseEndpoint(endpoint) {
            for i in 0..<3 {
                try await sendProbe(to: sourceAddress, channel: channel, sequence: UInt32(100 + i))
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }

        return endpoint
    }

    /// Send probe packets to both sides rapidly (for debugging/testing)
    public func probeEndpoint(
        localPort: UInt16,
        targetEndpoint: String,
        count: Int = 10
    ) async throws -> Bool {
        let channel = try await bindChannel(localPort: localPort)
        defer { cleanup() }

        guard let targetAddress = try? parseEndpoint(targetEndpoint) else {
            return false
        }

        let handler = HolePunchHandler()
        try await channel.pipeline.addHandler(handler).get()

        // Send probes
        for i in 0..<count {
            try await sendProbe(to: targetAddress, channel: channel, sequence: UInt32(i))
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            // Check if we got a response
            if await handler.hasReceivedProbe() {
                return true
            }
        }

        return await handler.hasReceivedProbe()
    }

    // MARK: - Private Methods

    private func bindChannel(localPort: UInt16) async throws -> Channel {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let chan = try await bootstrap.bind(host: "0.0.0.0", port: Int(localPort)).get()
            self.channel = chan
            return chan
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw HolePunchFailure.bindFailed
        }
    }

    private func cleanup() {
        if let channel = channel {
            try? channel.close().wait()
        }
        channel = nil

        if let group = eventLoopGroup {
            try? group.syncShutdownGracefully()
        }
        eventLoopGroup = nil
    }

    private func parseEndpoint(_ endpoint: String) throws -> SocketAddress {
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw HolePunchFailure.invalidEndpoint(endpoint)
        }
        return try SocketAddress.makeAddressResolvingHost(String(parts[0]), port: port)
    }

    private func sendProbe(to address: SocketAddress, channel: Channel, sequence: UInt32) async throws {
        var packet = Data(Self.probeMagic)
        // Add sequence number
        packet.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian) { Array($0) })
        // Add timestamp
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        packet.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian) { Array($0) })

        var buffer = channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)

        let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)
        try await channel.writeAndFlush(envelope)
    }
}

// MARK: - Hole Punch Handler

private final class HolePunchHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private var receivedProbe: (endpoint: String, sequence: UInt32)?
    private var continuation: CheckedContinuation<(String, UInt32)?, Never>?
    private let lock = NSLock()

    /// Magic bytes to identify hole punch probes
    private static let probeMagic: [UInt8] = [0x4F, 0x4D, 0x45, 0x52, 0x54, 0x41, 0x48, 0x50]

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let remoteAddress = envelope.remoteAddress

        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
              bytes.count >= 12,
              Array(bytes.prefix(8)) == Self.probeMagic else {
            return
        }

        // Parse sequence number
        let sequence = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 |
                       UInt32(bytes[10]) << 8 | UInt32(bytes[11])

        let endpoint = formatEndpoint(remoteAddress)

        lock.lock()
        receivedProbe = (endpoint, sequence)
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: (endpoint, sequence))
        } else {
            lock.unlock()
        }
    }

    func waitForProbe(timeout: TimeInterval) async -> (String, UInt32)? {
        lock.lock()
        if let probe = receivedProbe {
            lock.unlock()
            return probe
        }

        return await withCheckedContinuation { cont in
            continuation = cont
            lock.unlock()

            // Set up timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                lock.lock()
                if continuation != nil {
                    continuation = nil
                    lock.unlock()
                    cont.resume(returning: nil)
                } else {
                    lock.unlock()
                }
            }
        }
    }

    func hasReceivedProbe() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedProbe != nil
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

// MARK: - Relay Client

/// Client for using UDP relay when direct connection isn't possible
public actor RelayClient {
    private let relayEndpoint: String
    private let relayToken: String
    private let peerId: String
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private let logger: Logger

    /// Relay protocol message types
    private enum MessageType: UInt8 {
        case register = 0x01
        case data = 0x02
        case keepalive = 0x03
    }

    public init(relayEndpoint: String, relayToken: String, peerId: String) {
        self.relayEndpoint = relayEndpoint
        self.relayToken = relayToken
        self.peerId = peerId
        self.logger = Logger(label: "io.omerta.network.relay.client")
    }

    /// Connect to the relay server
    public func connect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let parts = relayEndpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw RelayError.invalidEndpoint(relayEndpoint)
        }

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let chan = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
            self.channel = chan

            // Register with relay
            try await register()

            logger.info("Connected to relay", metadata: ["endpoint": "\(relayEndpoint)"])
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw error
        }
    }

    /// Disconnect from relay
    public func disconnect() async {
        if let channel = channel {
            try? await channel.close()
        }
        channel = nil

        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil
    }

    /// Send data through relay
    public func send(_ data: Data) async throws {
        guard let channel = channel else {
            throw RelayError.notConnected
        }

        var packet = Data()
        packet.append(MessageType.data.rawValue)
        packet.append(relayToken.data(using: .utf8)!)
        packet.append(data)

        let relayAddress = try parseEndpoint(relayEndpoint)

        var buffer = channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)

        let envelope = AddressedEnvelope(remoteAddress: relayAddress, data: buffer)
        try await channel.writeAndFlush(envelope)
    }

    /// Send keepalive
    public func keepalive() async throws {
        guard let channel = channel else {
            throw RelayError.notConnected
        }

        var packet = Data()
        packet.append(MessageType.keepalive.rawValue)
        packet.append(relayToken.data(using: .utf8)!)

        let relayAddress = try parseEndpoint(relayEndpoint)

        var buffer = channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)

        let envelope = AddressedEnvelope(remoteAddress: relayAddress, data: buffer)
        try await channel.writeAndFlush(envelope)
    }

    // MARK: - Private

    private func register() async throws {
        guard let channel = channel else {
            throw RelayError.notConnected
        }

        var packet = Data()
        packet.append(MessageType.register.rawValue)
        packet.append(relayToken.data(using: .utf8)!)
        packet.append(peerId.data(using: .utf8)!)

        let relayAddress = try parseEndpoint(relayEndpoint)

        var buffer = channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)

        let envelope = AddressedEnvelope(remoteAddress: relayAddress, data: buffer)
        try await channel.writeAndFlush(envelope)
    }

    private func parseEndpoint(_ endpoint: String) throws -> SocketAddress {
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw RelayError.invalidEndpoint(endpoint)
        }
        return try SocketAddress.makeAddressResolvingHost(String(parts[0]), port: port)
    }
}

public enum RelayError: Error {
    case invalidEndpoint(String)
    case notConnected
    case sendFailed
}
