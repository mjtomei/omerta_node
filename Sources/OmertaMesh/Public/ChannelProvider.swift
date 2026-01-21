// ChannelProvider.swift - Standardized interface for channel-based messaging

import Foundation

/// Protocol for types that can send messages on channels
/// Use this when you only need to send, not receive
public protocol ChannelSender: Sendable {
    /// Send data to a peer on a specific channel
    func sendOnChannel(_ data: Data, to peerId: PeerId, channel: String) async throws
}

/// Protocol for types that provide channel-based messaging
/// This is the standardized interface for registering handlers and sending messages on channels.
/// Both `MeshNetwork` and wrapper types like `MeshProviderDaemon` conform to this protocol.
public protocol ChannelProvider: ChannelSender {
    /// The peer ID of this node
    var peerId: PeerId { get async }

    /// Register a handler for messages on a specific channel
    /// - Parameters:
    ///   - channel: Channel name (max 64 chars, alphanumeric/-/_ only)
    ///   - handler: Async handler called when messages arrive on this channel
    /// - Throws: Error if channel name is invalid or registration fails
    func onChannel(_ channel: String, handler: @escaping @Sendable (PeerId, Data) async -> Void) async throws

    /// Unregister a handler for a channel
    /// - Parameter channel: Channel name to stop listening on
    func offChannel(_ channel: String) async
}
