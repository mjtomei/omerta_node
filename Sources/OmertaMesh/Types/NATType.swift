// NATType.swift - NAT classification

import Foundation

/// Classification of NAT behavior based on RFC 3489
public enum NATType: String, Codable, Sendable, Equatable {
    /// No NAT - globally routable public IP
    case `public`

    /// Full Cone NAT - any external host can send to mapped port
    /// after internal host sends one packet out
    case fullCone

    /// Restricted Cone NAT - external host can send only if
    /// internal host has sent to that IP (any port)
    case restrictedCone

    /// Port Restricted Cone NAT - external host can send only if
    /// internal host has sent to that exact IP:port
    case portRestrictedCone

    /// Symmetric NAT - different external port for each destination
    /// Most restrictive, hole punching usually fails
    case symmetric

    /// Could not determine NAT type
    case unknown

    /// Whether this NAT type can potentially be hole-punched
    public var isHolePunchable: Bool {
        switch self {
        case .public, .fullCone, .restrictedCone, .portRestrictedCone:
            return true
        case .symmetric, .unknown:
            return false
        }
    }

    /// Whether this node can act as a relay for others
    public var canRelay: Bool {
        switch self {
        case .public, .fullCone:
            return true
        default:
            return false
        }
    }
}

/// Result of NAT detection
public struct NATDetectionResult: Sendable {
    /// The detected NAT type
    public let type: NATType

    /// Our public endpoint as seen by STUN server
    public let publicEndpoint: String?

    /// Local port used for detection
    public let localPort: UInt16

    public init(type: NATType, publicEndpoint: String?, localPort: UInt16) {
        self.type = type
        self.publicEndpoint = publicEndpoint
        self.localPort = localPort
    }
}
