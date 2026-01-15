// STUNClient.swift
// STUN client for discovering public endpoint and NAT type

import Foundation
import NIOCore
import NIOPosix
import Logging

/// Result of a STUN binding request
public struct STUNBindingResult: Sendable {
    public let publicAddress: String
    public let publicPort: UInt16
    public let localPort: UInt16
    public let serverAddress: String
    public let rtt: TimeInterval

    public var endpoint: String {
        "\(publicAddress):\(publicPort)"
    }
}

/// STUN client for NAT detection and endpoint discovery
public actor STUNClient {
    private let logger: Logger
    private var eventLoopGroup: EventLoopGroup?

    /// STUN magic cookie (RFC 5389)
    private static let magicCookie: UInt32 = 0x2112A442

    /// Default STUN servers (our own relay infrastructure)
    public static let defaultServers: [String] = [
        "stun.l.google.com:19302",
        "stun1.l.google.com:19302"
    ]

    public init() {
        self.logger = Logger(label: "io.omerta.network.stun.client")
    }

    /// Discover our public endpoint using STUN
    public func discoverEndpoint(
        server: String = "stun.l.google.com:19302",
        localPort: UInt16 = 0,
        timeout: TimeInterval = 5.0
    ) async throws -> STUNBindingResult {
        let (host, port) = try parseServerAddress(server)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(localPort)).get()
        defer {
            try? channel.close().wait()
        }

        // Get actual local port
        guard let localAddr = channel.localAddress, let actualLocalPort = localAddr.port else {
            throw STUNError.bindFailed
        }

        // Resolve server address
        let serverAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)

        // Create and send binding request
        let request = createBindingRequest()
        let transactionId = Data(request[8..<20])

        var buffer = channel.allocator.buffer(capacity: request.count)
        buffer.writeBytes(request)
        let envelope = AddressedEnvelope(remoteAddress: serverAddress, data: buffer)

        let startTime = Date()
        try await channel.writeAndFlush(envelope)

        // Wait for response with timeout
        let response = try await withThrowingTaskGroup(of: STUNBindingResult?.self) { group in
            group.addTask {
                try await self.receiveResponse(
                    channel: channel,
                    expectedTransactionId: transactionId,
                    localPort: UInt16(actualLocalPort),
                    serverAddress: server,
                    startTime: startTime
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            for try await result in group {
                if let result = result {
                    group.cancelAll()
                    return result
                }
            }

            throw STUNError.timeout
        }

        return response
    }

    /// Detect NAT type by testing with multiple servers/ports
    public func detectNATType(
        servers: [String] = defaultServers,
        timeout: TimeInterval = 5.0
    ) async throws -> (natType: NATType, endpoint: STUNBindingResult) {
        guard servers.count >= 2 else {
            throw STUNError.insufficientServers
        }

        // Test 1: Get mapping from first server
        let result1 = try await discoverEndpoint(server: servers[0], timeout: timeout)

        // Test 2: Get mapping from second server (different IP)
        let result2 = try await discoverEndpoint(server: servers[1], localPort: result1.localPort, timeout: timeout)

        // Compare mappings to determine NAT type
        let natType: NATType
        if result1.publicPort == result2.publicPort && result1.publicAddress == result2.publicAddress {
            // Same mapping to different servers - cone NAT
            // To distinguish full cone from restricted, we'd need hairpin test
            // For simplicity, assume port-restricted cone (most common)
            natType = .portRestrictedCone
        } else if result1.publicAddress == result2.publicAddress {
            // Same IP but different port - symmetric NAT with port variation
            natType = .symmetric
        } else {
            // Different IP mapping - definitely symmetric
            natType = .symmetric
        }

        logger.info("NAT type detected", metadata: [
            "type": "\(natType.rawValue)",
            "endpoint": "\(result1.endpoint)",
            "secondMapping": "\(result2.endpoint)"
        ])

        return (natType, result1)
    }

    // MARK: - Private Methods

    private func parseServerAddress(_ server: String) throws -> (host: String, port: Int) {
        let parts = server.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw STUNError.invalidServerAddress(server)
        }
        return (String(parts[0]), port)
    }

    private func createBindingRequest() -> Data {
        var request = Data()

        // Message type: Binding Request (0x0001)
        request.append(contentsOf: [0x00, 0x01])

        // Message length: 0 (no attributes)
        request.append(contentsOf: [0x00, 0x00])

        // Magic cookie
        request.append(contentsOf: withUnsafeBytes(of: Self.magicCookie.bigEndian) { Array($0) })

        // Transaction ID (12 random bytes)
        var transactionId = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 {
            transactionId[i] = UInt8.random(in: 0...255)
        }
        request.append(contentsOf: transactionId)

        return request
    }

    private func receiveResponse(
        channel: Channel,
        expectedTransactionId: Data,
        localPort: UInt16,
        serverAddress: String,
        startTime: Date
    ) async throws -> STUNBindingResult {
        // Read response from channel
        let handler = STUNResponseHandler()

        try await channel.pipeline.addHandler(handler).get()

        guard let response = await handler.waitForResponse() else {
            throw STUNError.noResponse
        }

        let rtt = Date().timeIntervalSince(startTime)

        // Verify transaction ID
        guard response.count >= 20 else {
            throw STUNError.invalidResponse
        }

        let responseTransactionId = Data(response[8..<20])
        guard responseTransactionId == expectedTransactionId else {
            throw STUNError.transactionIdMismatch
        }

        // Parse XOR-MAPPED-ADDRESS
        guard let (address, port) = parseMappedAddress(from: response) else {
            throw STUNError.noMappedAddress
        }

        return STUNBindingResult(
            publicAddress: address,
            publicPort: port,
            localPort: localPort,
            serverAddress: serverAddress,
            rtt: rtt
        )
    }

    private func parseMappedAddress(from data: Data) -> (host: String, port: UInt16)? {
        guard data.count >= 20 else { return nil }

        // Verify message type is binding response (0x0101)
        let messageType = UInt16(data[0]) << 8 | UInt16(data[1])
        guard messageType == 0x0101 else { return nil }

        // Get message length
        let messageLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        guard data.count >= 20 + messageLength else { return nil }

        // Parse attributes looking for XOR-MAPPED-ADDRESS (0x0020)
        var offset = 20
        while offset + 4 <= 20 + messageLength {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))

            if attrType == 0x0020 { // XOR-MAPPED-ADDRESS
                guard offset + 4 + attrLength <= data.count else { break }

                let family = data[offset + 5]

                if family == 0x01 { // IPv4
                    let xorPort = UInt16(data[offset + 6]) << 8 | UInt16(data[offset + 7])
                    let port = xorPort ^ UInt16(Self.magicCookie >> 16)

                    let xorAddr = UInt32(data[offset + 8]) << 24 | UInt32(data[offset + 9]) << 16 |
                                  UInt32(data[offset + 10]) << 8 | UInt32(data[offset + 11])
                    let addr = xorAddr ^ Self.magicCookie

                    let host = "\(addr >> 24).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
                    return (host, port)
                }
            }

            // Move to next attribute (with padding to 4-byte boundary)
            offset += 4 + ((attrLength + 3) & ~3)
        }

        return nil
    }
}

// MARK: - STUN Response Handler

private final class STUNResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private var responseData: Data?
    private var continuation: CheckedContinuation<Data?, Never>?
    private let lock = NSLock()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        lock.lock()
        responseData = Data(bytes)
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: responseData)
        } else {
            lock.unlock()
        }
    }

    func waitForResponse() async -> Data? {
        lock.lock()
        if let data = responseData {
            lock.unlock()
            return data
        }

        return await withCheckedContinuation { cont in
            continuation = cont
            lock.unlock()
        }
    }
}

// MARK: - Errors

public enum STUNError: Error, CustomStringConvertible {
    case bindFailed
    case invalidServerAddress(String)
    case timeout
    case noResponse
    case invalidResponse
    case transactionIdMismatch
    case noMappedAddress
    case insufficientServers

    public var description: String {
        switch self {
        case .bindFailed:
            return "Failed to bind UDP socket"
        case .invalidServerAddress(let addr):
            return "Invalid server address: \(addr)"
        case .timeout:
            return "STUN request timed out"
        case .noResponse:
            return "No response received"
        case .invalidResponse:
            return "Invalid STUN response"
        case .transactionIdMismatch:
            return "Transaction ID mismatch"
        case .noMappedAddress:
            return "No mapped address in response"
        case .insufficientServers:
            return "Need at least 2 STUN servers for NAT detection"
        }
    }
}

// MARK: - Re-export NATType

// NATType is defined in OmertaRendezvousLib, re-export or define locally
public enum NATType: String, Codable, Sendable {
    case fullCone           // Most permissive - any external host can send
    case restrictedCone     // Only IPs we've sent to can reply
    case portRestrictedCone // Only IP:port pairs we've sent to can reply
    case symmetric          // Different port per destination
    case unknown
}
