// TunnelConfig.swift - Configuration and types for tunnel sessions

import Foundation

/// Current state of a tunnel session
public enum TunnelState: Sendable, Equatable {
    case connecting
    case active
    case disconnected
    case failed(String)
}

/// Role in traffic routing
public enum TunnelRole: Sendable, Equatable {
    /// Just messaging, no traffic routing
    case peer
    /// Sends traffic to remote peer for exit
    case trafficSource
    /// Receives traffic and forwards to internet via netstack
    case trafficExit
}

/// Errors from tunnel operations
public enum TunnelError: Error, LocalizedError, Sendable, Equatable {
    case notConnected
    case alreadyConnected
    case peerNotFound(String)
    case trafficRoutingNotEnabled
    case netstackError(String)
    case timeout
    case sessionRejected

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Session not connected"
        case .alreadyConnected:
            return "Session already connected"
        case .peerNotFound(let peerId):
            return "Peer not found: \(peerId)"
        case .trafficRoutingNotEnabled:
            return "Traffic routing not enabled"
        case .netstackError(let message):
            return "Netstack error: \(message)"
        case .timeout:
            return "Operation timed out"
        case .sessionRejected:
            return "Session rejected by peer"
        }
    }
}
