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

    /// Default STUN servers
    public static let defaultServers: [String] = [
        "stun.l.google.com:19302",
        "stun1.l.google.com:19302",
        "stun2.l.google.com:19302",
        "stun3.l.google.com:19302"
    ]

    public init() {
        self.logger = Logger(label: "io.omerta.mesh.stun")
    }

    /// Discover our public endpoint using a single STUN server
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

        // Create response handler before bootstrap
        let handler = STUNResponseHandler()

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(localPort)).get()
        defer {
            try? channel.close().wait()
        }

        // Get actual local port
        guard let localAddr = channel.localAddress, let actualLocalPort = localAddr.port else {
            throw STUNError.bindFailed
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

        // Wait for response with timeout
        let response = try await withThrowingTaskGroup(of: STUNBindingResult?.self) { group in
            group.addTask {
                try await self.waitForResponse(
                    handler: handler,
                    expectedTransactionId: request.transactionId,
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
                // Always cancel remaining tasks when first result arrives
                group.cancelAll()
                if let result = result {
                    return result
                }
                // Timeout fired (nil result) - break to throw timeout
                break
            }

            throw STUNError.timeout
        }

        return response
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

    private func waitForResponse(
        handler: STUNResponseHandler,
        expectedTransactionId: Data,
        localPort: UInt16,
        serverAddress: String,
        startTime: Date
    ) async throws -> STUNBindingResult {
        guard let responseData = await handler.waitForResponse() else {
            throw STUNError.noResponse
        }

        let rtt = Date().timeIntervalSince(startTime)

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

private final class STUNResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private var responseData: Data?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var isCancelled = false
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

        // Check if already cancelled before we start waiting
        if Task.isCancelled {
            lock.unlock()
            return nil
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                // Check if cancelled while we were setting up
                if self.isCancelled {
                    self.lock.unlock()
                    cont.resume(returning: nil)
                } else {
                    self.continuation = cont
                    self.lock.unlock()
                }
            }
        } onCancel: {
            // Mark as cancelled and resume continuation if set
            self.lock.lock()
            self.isCancelled = true
            if let cont = self.continuation {
                self.continuation = nil
                self.lock.unlock()
                cont.resume(returning: nil)
            } else {
                self.lock.unlock()
            }
        }
    }
}
