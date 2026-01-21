// ServiceChannels.swift - Channel name constants for utility services
//
// Each service uses specific channel names for request/response patterns.
// Response channels are per-peer to enable routing back to the requester.

import Foundation

/// Channel names for the Health service
public enum HealthChannels {
    /// Channel for health check requests (broadcast/targeted)
    public static let request = "health-request"

    /// Per-peer response channel
    /// - Parameter peerId: The peer ID to route the response to
    public static func response(for peerId: PeerId) -> String {
        "health-response-\(peerId)"
    }
}

/// Channel names for the Message service
public enum MessageChannels {
    /// Per-peer inbox channel for receiving messages
    /// - Parameter peerId: The peer ID whose inbox this is
    public static func inbox(for peerId: PeerId) -> String {
        "msg-inbox-\(peerId)"
    }

    /// Per-peer receipt channel for delivery confirmations
    /// - Parameter peerId: The peer ID to receive receipts
    public static func receipt(for peerId: PeerId) -> String {
        "msg-receipt-\(peerId)"
    }
}

/// Channel names for the Cloister (private network) service
public enum CloisterChannels {
    /// Channel for network key negotiation requests
    public static let negotiate = "cloister-negotiate"

    /// Per-peer negotiation response channel
    /// - Parameter peerId: The peer ID to route the response to
    public static func response(for peerId: PeerId) -> String {
        "cloister-response-\(peerId)"
    }

    /// Channel for invite sharing
    public static let share = "cloister-share"

    /// Per-peer invite share acknowledgment channel
    /// - Parameter peerId: The peer ID to receive acknowledgments
    public static func shareAck(for peerId: PeerId) -> String {
        "cloister-share-ack-\(peerId)"
    }

    /// Channel for shared secret derivation requests
    public static let derive = "cloister-derive"

    /// Per-peer secret derivation response channel
    /// - Parameter peerId: The peer ID to route the response to
    public static func deriveResponse(for peerId: PeerId) -> String {
        "cloister-derive-response-\(peerId)"
    }
}
