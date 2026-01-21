// MockChannelProvider.swift - Mock implementation of ChannelProvider for testing

import Foundation
@testable import OmertaMesh

/// Mock implementation of ChannelProvider for testing channel-based services
public actor MockChannelProvider: ChannelProvider {
    /// The peer ID of this mock provider
    public let _peerId: PeerId

    /// Registered channel handlers
    private var handlers: [String: @Sendable (PeerId, Data) async -> Void] = [:]

    /// Messages sent via sendOnChannel for verification
    public var sentMessages: [(data: Data, peerId: PeerId, channel: String)] = []

    /// Whether to simulate send failures
    public var shouldFailSends: Bool = false

    /// Error to throw when sends fail
    public var sendError: Error = ServiceError.peerUnreachable("mock-peer")

    public init(peerId: PeerId = "mock-peer-\(UUID().uuidString.prefix(8))") {
        self._peerId = peerId
    }

    // MARK: - ChannelProvider Implementation

    public var peerId: PeerId {
        get async { _peerId }
    }

    public func onChannel(_ channel: String, handler: @escaping @Sendable (PeerId, Data) async -> Void) async throws {
        handlers[channel] = handler
    }

    public func offChannel(_ channel: String) async {
        handlers.removeValue(forKey: channel)
    }

    public func sendOnChannel(_ data: Data, to peerId: PeerId, channel: String) async throws {
        if shouldFailSends {
            throw sendError
        }
        sentMessages.append((data, peerId, channel))
    }

    // MARK: - Test Helpers

    /// Simulate receiving a message on a channel
    /// - Parameters:
    ///   - data: Message data
    ///   - fromPeerId: Peer ID of the sender
    ///   - channel: Channel the message arrived on
    public func simulateReceive(_ data: Data, from fromPeerId: PeerId, on channel: String) async {
        if let handler = handlers[channel] {
            await handler(fromPeerId, data)
        }
    }

    /// Check if a handler is registered for a channel
    public func hasHandler(for channel: String) -> Bool {
        handlers[channel] != nil
    }

    /// Get all registered channels
    public var registeredChannels: [String] {
        Array(handlers.keys)
    }

    /// Reset all recorded data
    public func reset() {
        sentMessages.removeAll()
        shouldFailSends = false
    }

    /// Clear all handlers
    public func clearHandlers() {
        handlers.removeAll()
    }

    /// Get the last sent message
    public var lastSentMessage: (data: Data, peerId: PeerId, channel: String)? {
        sentMessages.last
    }

    /// Get sent messages for a specific channel
    public func sentMessages(on channel: String) -> [(data: Data, peerId: PeerId)] {
        sentMessages.filter { $0.channel == channel }.map { ($0.data, $0.peerId) }
    }

    /// Get sent messages to a specific peer
    public func sentMessages(to peerId: PeerId) -> [(data: Data, channel: String)] {
        sentMessages.filter { $0.peerId == peerId }.map { ($0.data, $0.channel) }
    }
}

/// Extension to connect two MockChannelProviders for bidirectional testing
extension MockChannelProvider {
    /// Connect this provider to another for bidirectional message passing
    /// Messages sent from this provider to the other's peerId will be delivered
    public func connect(to other: MockChannelProvider) async -> AsyncStream<Void> {
        let otherPeerId = await other.peerId

        // Create a stream that processes messages
        return AsyncStream { continuation in
            Task {
                // Poll for messages periodically (simple approach for testing)
                while !Task.isCancelled {
                    let messages = await self.sentMessages
                    for (index, msg) in messages.enumerated() {
                        if msg.peerId == otherPeerId {
                            await other.simulateReceive(msg.data, from: self._peerId, on: msg.channel)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
                continuation.finish()
            }
        }
    }
}
