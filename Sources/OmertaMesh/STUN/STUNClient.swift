// STUNClient.swift - STUN client for endpoint discovery

import Foundation
import NIOCore
import NIOPosix
import Logging

/// Result of a STUN binding request
public struct STUNBindingResult: Sendable {
    /// Our public IP address as seen by the STUN server
    public let publicAddress: String

    /// Our public port as seen by the STUN server
    public let publicPort: UInt16

    /// The local port we used
    public let localPort: UInt16

    /// The STUN server we queried
    public let serverAddress: String

    /// Round-trip time for the request
    public let rtt: TimeInterval

    /// Combined endpoint string
    public var endpoint: String {
        "\(publicAddress):\(publicPort)"
    }
}

/// STUN client for discovering public endpoint
public actor STUNClient {
    private let logger: Logger

    /// Default STUN servers (our own relay infrastructure)
    public static let defaultServers: [String] = [
        "stun1.mesh.test:3478",
        "stun2.mesh.test:3479"
    ]

    public init() {
        self.logger = Logger(label: "io.omerta.mesh.stun")
    }

    /// Discover our public endpoint using a single STUN server
    public func discoverEndpoint(
        server: String = "stun1.mesh.test:3478",
        localPort: UInt16 = 0,
        timeout: TimeInterval = 5.0
    ) async throws -> STUNBindingResult {
        let (host, port) = try parseServerAddress(server)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // Ensure cleanup happens even on error/cancellation
        var channel: Channel? = nil
        var timeoutTask: Scheduled<Void>? = nil
        var responsePromise: EventLoopPromise<Data>? = nil

        do {
            // Create response handler with promise for the response
            let eventLoop = group.next()
            responsePromise = eventLoop.makePromise(of: Data.self)
            let handler = STUNResponseHandler(responsePromise: responsePromise!)

            let bootstrap = DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }

            channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(localPort)).get()

            guard let channel = channel else {
                throw STUNError.bindFailed
            }

            // Get actual local port
            guard let localAddr = channel.localAddress, let actualLocalPort = localAddr.port else {
                throw STUNError.bindFailed
            }

            // Schedule timeout on the event loop - this will fail the promise
            timeoutTask = eventLoop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
                responsePromise?.fail(STUNError.timeout)
            }

            // Resolve server address
            let serverSocketAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)

            // Create binding request
            let request = STUNMessage.bindingRequest()
            let requestData = request.encode()

            var buffer = channel.allocator.buffer(capacity: requestData.count)
            buffer.writeBytes(requestData)
            let envelope = AddressedEnvelope(remoteAddress: serverSocketAddress, data: buffer)

            let startTime = Date()
            try await channel.writeAndFlush(envelope)

            // Wait for response (will throw STUNError.timeout if timeout fires first)
            let responseData = try await responsePromise!.futureResult.get()

            // Cancel timeout since we got a response
            timeoutTask?.cancel()
            timeoutTask = nil

            let rtt = Date().timeIntervalSince(startTime)

            // Decode and validate response
            let result = try decodeResponse(
                responseData: responseData,
                expectedTransactionId: request.transactionId,
                localPort: UInt16(actualLocalPort),
                serverAddress: server,
                rtt: rtt
            )

            // Clean up
            try await channel.close()
            try await group.shutdownGracefully()

            return result

        } catch {
            // Clean up on error
            timeoutTask?.cancel()
            // Fail the promise to avoid "leaking promise" assertion
            responsePromise?.fail(error)
            if let channel = channel {
                try? await channel.close()
            }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Query multiple STUN servers and compare results
    public func queryMultipleServers(
        servers: [String] = defaultServers,
        localPort: UInt16 = 0,
        timeout: TimeInterval = 5.0
    ) async throws -> [STUNBindingResult] {
        var results: [STUNBindingResult] = []

        // First query to establish local port
        let first = try await discoverEndpoint(
            server: servers[0],
            localPort: localPort,
            timeout: timeout
        )
        results.append(first)

        // Query remaining servers with same local port
        for server in servers.dropFirst() {
            do {
                let result = try await discoverEndpoint(
                    server: server,
                    localPort: first.localPort,
                    timeout: timeout
                )
                results.append(result)
            } catch {
                logger.debug("Failed to query \(server): \(error)")
            }
        }

        return results
    }

    // MARK: - Private Methods

    private func parseServerAddress(_ server: String) throws -> (host: String, port: Int) {
        let parts = server.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw STUNError.invalidServerAddress(server)
        }
        return (String(parts[0]), port)
    }

    private func decodeResponse(
        responseData: Data,
        expectedTransactionId: Data,
        localPort: UInt16,
        serverAddress: String,
        rtt: TimeInterval
    ) throws -> STUNBindingResult {
        // Decode response
        let response = try STUNMessage.decode(from: responseData)

        // Verify transaction ID
        guard response.transactionId == expectedTransactionId else {
            throw STUNError.transactionIdMismatch
        }

        // Check for error response
        if response.type == .bindingErrorResponse {
            for attr in response.attributes {
                if case .errorCode(let code, let reason) = attr {
                    throw STUNError.serverError(code, reason)
                }
            }
            throw STUNError.invalidResponse
        }

        // Get mapped address (prefer XOR-MAPPED-ADDRESS)
        guard let (address, port) = response.xorMappedAddress ?? response.mappedAddress else {
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
}

// MARK: - Response Handler

/// Handler that receives STUN responses and fulfills a promise
private final class STUNResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let responsePromise: EventLoopPromise<Data>
    private var hasResponded = false
    private let lock = NSLock()

    init(responsePromise: EventLoopPromise<Data>) {
        self.responsePromise = responsePromise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        // Only fulfill the promise once
        guard !hasResponded else { return }
        hasResponded = true

        responsePromise.succeed(Data(bytes))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResponded else { return }
        hasResponded = true

        responsePromise.fail(error)
    }
}
