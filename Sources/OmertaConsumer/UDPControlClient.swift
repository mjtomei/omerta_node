import Foundation
import NIOCore
import NIOPosix
import Crypto
import OmertaCore

/// Client for sending encrypted UDP control messages to provider daemons
/// Uses SwiftNIO for cross-platform UDP support (macOS and Linux)
public actor UDPControlClient {
    private let networkKey: Data
    private let localPort: UInt16
    private let maxRetries: Int = 3
    private let retryTimeout: TimeInterval = 2.0

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init(networkKey: Data, localPort: UInt16 = 0) {
        self.networkKey = networkKey
        self.localPort = localPort
    }

    // MARK: - VM Lifecycle

    /// Request VM creation from provider
    public func requestVM(
        providerEndpoint: String,
        vmId: UUID,
        requirements: ResourceRequirements,
        vpnConfig: VPNConfiguration,
        consumerEndpoint: String,
        sshPublicKey: String,
        sshUser: String = "omerta"
    ) async throws -> VMCreatedResponse {
        let request = RequestVMMessage(
            vmId: vmId,
            requirements: requirements,
            vpnConfig: vpnConfig,
            consumerEndpoint: consumerEndpoint,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser
        )

        let message = ControlMessage(action: .requestVM(request))
        let response = try await sendWithRetry(message, to: providerEndpoint)

        guard case .vmCreated(let vmResponse) = response.action else {
            throw ConsumerError.invalidResponse("Expected vmCreated, got \(response.action)")
        }

        return vmResponse
    }

    /// Request VM release/termination
    public func releaseVM(
        providerEndpoint: String,
        vmId: UUID
    ) async throws {
        let request = ReleaseVMMessage(vmId: vmId)
        let message = ControlMessage(action: .releaseVM(request))
        let response = try await sendWithRetry(message, to: providerEndpoint)

        guard case .vmReleased = response.action else {
            throw ConsumerError.invalidResponse("Expected vmReleased, got \(response.action)")
        }
    }

    /// Query VM status from provider
    public func queryVMStatus(
        providerEndpoint: String,
        vmId: UUID? = nil
    ) async throws -> VMStatusResponse {
        let request = VMStatusRequest(vmId: vmId)
        let message = ControlMessage(action: .queryVMStatus(request))
        let response = try await sendWithRetry(message, to: providerEndpoint)

        guard case .vmStatus(let statusResponse) = response.action else {
            throw ConsumerError.invalidResponse("Expected vmStatus, got \(response.action)")
        }

        return statusResponse
    }

    // MARK: - Notification Listener

    /// Listen for async notifications from providers
    public func listenForNotifications(port: UInt16) async throws -> AsyncStream<ProviderNotification> {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        return AsyncStream { continuation in
            let handler = NotificationHandler(
                networkKey: self.networkKey,
                continuation: continuation
            )

            let bootstrap = DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }

            Task {
                do {
                    let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
                    print("Notification listener ready on port \(port)")

                    continuation.onTermination = { _ in
                        channel.close(promise: nil)
                        try? group.syncShutdownGracefully()
                    }
                } catch {
                    print("Notification listener failed: \(error)")
                    continuation.finish()
                    try? group.syncShutdownGracefully()
                }
            }
        }
    }

    // MARK: - Private Helpers

    /// Send message with retry logic
    private func sendWithRetry(
        _ message: ControlMessage,
        to endpoint: String
    ) async throws -> ControlMessage {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                return try await sendMessage(message, to: endpoint)
            } catch {
                lastError = error
                if attempt < maxRetries {
                    // Wait before retry
                    try await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
                }
            }
        }

        throw lastError ?? ConsumerError.providerTimeout
    }

    /// Send message and wait for response
    private func sendMessage(
        _ message: ControlMessage,
        to endpoint: String
    ) async throws -> ControlMessage {
        // Parse endpoint (format: "IP:port")
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2,
              let host = parts.first.map(String.init),
              let port = Int(parts.last!) else {
            throw ConsumerError.invalidResponse("Invalid endpoint format: \(endpoint)")
        }

        // Create event loop group for this request
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        // Create response handler
        let responseHandler = ResponseHandler(networkKey: networkKey)

        // Create UDP channel
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(responseHandler)
            }

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(localPort)).get()
        defer {
            try? channel.close().wait()
        }

        // Encrypt message
        let encrypted = try encryptMessage(message)

        // Create remote address
        let remoteAddress = try SocketAddress(ipAddress: host, port: port)

        // Create addressed envelope
        var buffer = channel.allocator.buffer(capacity: encrypted.count)
        buffer.writeBytes(encrypted)
        let envelope = AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)

        // Send message
        try await channel.writeAndFlush(envelope).get()

        // Wait for response with timeout
        return try await withThrowingTaskGroup(of: ControlMessage.self) { group in
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.retryTimeout * 1_000_000_000))
                throw ConsumerError.providerTimeout
            }

            // Receive task
            group.addTask {
                try await responseHandler.waitForResponse()
            }

            // Return first result (either response or timeout)
            guard let result = try await group.next() else {
                throw ConsumerError.providerTimeout
            }

            group.cancelAll()
            return result
        }
    }

    // MARK: - Encryption

    /// Encrypt control message using ChaCha20-Poly1305
    private func encryptMessage(_ message: ControlMessage) throws -> Data {
        // Encode message to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(message)

        // Encrypt with ChaCha20-Poly1305
        let key = SymmetricKey(data: networkKey)
        let nonce = ChaChaPoly.Nonce()
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

        // Return combined format: [nonce][ciphertext][tag]
        return sealedBox.combined
    }

    /// Decrypt control message
    private func decryptMessage(_ data: Data) throws -> ControlMessage {
        // Decrypt with ChaCha20-Poly1305
        let key = SymmetricKey(data: networkKey)
        let sealedBox = try ChaChaPoly.SealedBox(combined: data)
        let plaintext = try ChaChaPoly.open(sealedBox, using: key)

        // Decode from JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ControlMessage.self, from: plaintext)

        // Verify timestamp (prevent replay attacks - allow 60 second window)
        let now = UInt64(Date().timeIntervalSince1970)
        let timeDiff = abs(Int64(now) - Int64(message.timestamp))
        guard timeDiff < 60 else {
            throw ConsumerError.invalidResponse("Message timestamp too old (replay attack?)")
        }

        return message
    }
}

// MARK: - NIO Handlers

/// Handler for receiving responses
private final class ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let networkKey: Data
    private var responseContinuation: CheckedContinuation<ControlMessage, Error>?
    private let lock = NSLock()

    init(networkKey: Data) {
        self.networkKey = networkKey
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let data = Data(bytes)

        do {
            let message = try decryptMessage(data)

            lock.lock()
            let continuation = responseContinuation
            responseContinuation = nil
            lock.unlock()

            continuation?.resume(returning: message)
        } catch {
            lock.lock()
            let continuation = responseContinuation
            responseContinuation = nil
            lock.unlock()

            continuation?.resume(throwing: error)
        }
    }

    func waitForResponse() async throws -> ControlMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            responseContinuation = continuation
            lock.unlock()
        }
    }

    private func decryptMessage(_ data: Data) throws -> ControlMessage {
        let key = SymmetricKey(data: networkKey)
        let sealedBox = try ChaChaPoly.SealedBox(combined: data)
        let plaintext = try ChaChaPoly.open(sealedBox, using: key)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ControlMessage.self, from: plaintext)

        let now = UInt64(Date().timeIntervalSince1970)
        let timeDiff = abs(Int64(now) - Int64(message.timestamp))
        guard timeDiff < 60 else {
            throw ConsumerError.invalidResponse("Message timestamp too old")
        }

        return message
    }
}

/// Handler for notification listener
private final class NotificationHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let networkKey: Data
    private let continuation: AsyncStream<ProviderNotification>.Continuation

    init(networkKey: Data, continuation: AsyncStream<ProviderNotification>.Continuation) {
        self.networkKey = networkKey
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let data = Data(bytes)

        do {
            let message = try decryptMessage(data)

            if case .vmCreated(let response) = message.action {
                continuation.yield(.vmReady(vmId: response.vmId, vmIP: response.vmIP))
            }
        } catch {
            print("Error decrypting notification: \(error)")
        }
    }

    private func decryptMessage(_ data: Data) throws -> ControlMessage {
        let key = SymmetricKey(data: networkKey)
        let sealedBox = try ChaChaPoly.SealedBox(combined: data)
        let plaintext = try ChaChaPoly.open(sealedBox, using: key)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ControlMessage.self, from: plaintext)
    }
}
