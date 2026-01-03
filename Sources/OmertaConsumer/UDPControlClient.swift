import Foundation
import Network
import Crypto
import OmertaCore

/// Client for sending encrypted UDP control messages to provider daemons
public actor UDPControlClient {
    private let networkKey: Data
    private let localPort: UInt16
    private var connections: [String: NWConnection] = [:]
    private let maxRetries: Int = 3
    private let retryTimeout: TimeInterval = 2.0

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
        consumerEndpoint: String
    ) async throws -> VMCreatedResponse {
        let request = RequestVMMessage(
            vmId: vmId,
            requirements: requirements,
            vpnConfig: vpnConfig,
            consumerEndpoint: consumerEndpoint
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

    // MARK: - Notification Listener

    /// Listen for async notifications from providers
    public func listenForNotifications(port: UInt16) async throws -> AsyncStream<ProviderNotification> {
        let listener = try NWListener(using: .udp, on: NWEndpoint.Port(integerLiteral: port))

        return AsyncStream { continuation in
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())

                connection.receiveMessage { data, _, _, error in
                    if let error = error {
                        print("Error receiving notification: \(error)")
                        return
                    }

                    guard let data = data else { return }

                    do {
                        let message = try self.decryptMessageSync(data)

                        // Extract notification from message action
                        if case .vmCreated(let response) = message.action {
                            continuation.yield(.vmReady(vmId: response.vmId, vmIP: response.vmIP))
                        }
                        // Add more notification types as needed
                    } catch {
                        print("Error decrypting notification: \(error)")
                    }
                }
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("Notification listener ready on port \(port)")
                case .failed(let error):
                    print("Notification listener failed: \(error)")
                    continuation.finish()
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }

            listener.start(queue: .global())

            continuation.onTermination = { _ in
                listener.cancel()
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
        let connection = getOrCreateConnection(to: endpoint)

        // Encrypt message
        let encrypted = try encryptMessage(message)

        // Send message
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: encrypted, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        // Wait for response with timeout
        return try await withThrowingTaskGroup(of: ControlMessage.self) { group in
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.retryTimeout * 1_000_000_000))
                throw ConsumerError.providerTimeout
            }

            // Receive task
            group.addTask {
                try await self.receiveMessage(from: connection)
            }

            // Return first result (either response or timeout)
            guard let result = try await group.next() else {
                throw ConsumerError.providerTimeout
            }

            group.cancelAll()
            return result
        }
    }

    /// Receive and decrypt response
    private func receiveMessage(from connection: NWConnection) async throws -> ControlMessage {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data = data else {
                    continuation.resume(throwing: ConsumerError.invalidResponse("No data received"))
                    return
                }

                do {
                    let message = try self.decryptMessageSync(data)
                    continuation.resume(returning: message)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Get or create UDP connection to endpoint
    private func getOrCreateConnection(to endpoint: String) -> NWConnection {
        if let existing = connections[endpoint] {
            return existing
        }

        // Parse endpoint (format: "IP:port")
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2,
              let host = parts.first.map(String.init),
              let port = UInt16(parts.last!) else {
            fatalError("Invalid endpoint format: \(endpoint)")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port),
            using: .udp
        )

        connection.start(queue: .global())
        connections[endpoint] = connection

        return connection
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
    private func decryptMessageSync(_ data: Data) throws -> ControlMessage {
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

    // MARK: - Cleanup

    deinit {
        for connection in connections.values {
            connection.cancel()
        }
    }
}
