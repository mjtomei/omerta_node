// MeshConfig.swift - Configuration for the mesh network

import Foundation

/// Configuration for a mesh network node
public struct MeshConfig: Sendable {
    // MARK: - Network Settings

    /// Port to bind to (0 for automatic)
    public var port: Int

    /// Whether this node can act as a relay for other peers
    public var canRelay: Bool

    /// Whether this node can coordinate hole punches for other peers
    public var canCoordinateHolePunch: Bool

    // MARK: - Relay Settings

    /// Target number of relay connections to maintain
    public var targetRelayCount: Int

    /// Maximum number of relay connections
    public var maxRelayCount: Int

    /// Maximum sessions to relay for other peers (if canRelay is true)
    public var maxRelaySessions: Int

    // MARK: - Timing Settings

    /// Interval between keepalive messages (seconds)
    public var keepaliveInterval: TimeInterval

    /// Timeout for connection attempts (seconds)
    public var connectionTimeout: TimeInterval

    /// Timeout for NAT detection (seconds)
    public var natDetectionTimeout: TimeInterval

    /// Interval between peer cache cleanup (seconds)
    public var cacheCleanupInterval: TimeInterval

    // MARK: - Discovery Settings

    /// STUN servers for NAT detection
    public var stunServers: [String]

    /// Bootstrap peers for initial discovery
    public var bootstrapPeers: [String]

    /// Maximum peers to track in cache
    public var maxCachedPeers: Int

    /// Time-to-live for cached peer info (seconds)
    public var peerCacheTTL: TimeInterval

    // MARK: - Hole Punch Settings

    /// Number of probe packets to send during hole punch
    public var holePunchProbeCount: Int

    /// Interval between hole punch probes (seconds)
    public var holePunchProbeInterval: TimeInterval

    /// Timeout for hole punch attempts (seconds)
    public var holePunchTimeout: TimeInterval

    // MARK: - Freshness Settings

    /// Maximum age for "recent" contact info (seconds)
    public var recentContactMaxAge: TimeInterval

    /// Interval between freshness queries for the same peer (seconds)
    public var freshnessQueryInterval: TimeInterval

    // MARK: - Initialization

    public init(
        port: Int = 0,
        canRelay: Bool = false,
        canCoordinateHolePunch: Bool = false,
        targetRelayCount: Int = 3,
        maxRelayCount: Int = 5,
        maxRelaySessions: Int = 50,
        keepaliveInterval: TimeInterval = 15,
        connectionTimeout: TimeInterval = 10,
        natDetectionTimeout: TimeInterval = 5,
        cacheCleanupInterval: TimeInterval = 60,
        stunServers: [String]? = nil,
        bootstrapPeers: [String] = [],
        maxCachedPeers: Int = 500,
        peerCacheTTL: TimeInterval = 3600,
        holePunchProbeCount: Int = 5,
        holePunchProbeInterval: TimeInterval = 0.2,
        holePunchTimeout: TimeInterval = 10,
        recentContactMaxAge: TimeInterval = 300,
        freshnessQueryInterval: TimeInterval = 30
    ) {
        self.port = port
        self.canRelay = canRelay
        self.canCoordinateHolePunch = canCoordinateHolePunch
        self.targetRelayCount = targetRelayCount
        self.maxRelayCount = maxRelayCount
        self.maxRelaySessions = maxRelaySessions
        self.keepaliveInterval = keepaliveInterval
        self.connectionTimeout = connectionTimeout
        self.natDetectionTimeout = natDetectionTimeout
        self.cacheCleanupInterval = cacheCleanupInterval
        self.stunServers = stunServers ?? Self.defaultSTUNServers
        self.bootstrapPeers = bootstrapPeers
        self.maxCachedPeers = maxCachedPeers
        self.peerCacheTTL = peerCacheTTL
        self.holePunchProbeCount = holePunchProbeCount
        self.holePunchProbeInterval = holePunchProbeInterval
        self.holePunchTimeout = holePunchTimeout
        self.recentContactMaxAge = recentContactMaxAge
        self.freshnessQueryInterval = freshnessQueryInterval
    }

    // MARK: - Default Values

    /// Default STUN servers
    public static let defaultSTUNServers: [String] = [
        "stun.l.google.com:19302",
        "stun1.l.google.com:19302",
        "stun2.l.google.com:19302",
        "stun.cloudflare.com:3478"
    ]

    /// Default configuration
    public static let `default` = MeshConfig()

    // MARK: - Preset Configurations

    /// Configuration for a public relay node
    public static var relayNode: MeshConfig {
        MeshConfig(
            canRelay: true,
            canCoordinateHolePunch: true,
            targetRelayCount: 0,  // Relay nodes don't need relays themselves
            maxRelayCount: 0,
            maxRelaySessions: 100,
            keepaliveInterval: 10
        )
    }

    /// Configuration for a mobile/battery-constrained device
    public static var mobile: MeshConfig {
        MeshConfig(
            targetRelayCount: 2,
            maxRelayCount: 3,
            keepaliveInterval: 30,  // Less frequent keepalives
            maxCachedPeers: 100,    // Smaller cache
            peerCacheTTL: 1800      // 30 min TTL
        )
    }

    /// Configuration for a server/always-on device
    public static var server: MeshConfig {
        MeshConfig(
            canRelay: true,
            canCoordinateHolePunch: true,
            targetRelayCount: 5,
            maxRelayCount: 10,
            maxRelaySessions: 200,
            keepaliveInterval: 10,
            maxCachedPeers: 1000,
            peerCacheTTL: 7200  // 2 hour TTL
        )
    }

    // MARK: - Validation

    /// Validate the configuration
    public func validate() throws {
        if port < 0 || port > 65535 {
            throw MeshError.invalidConfiguration(reason: "Port must be 0-65535")
        }
        if targetRelayCount < 0 {
            throw MeshError.invalidConfiguration(reason: "Target relay count must be non-negative")
        }
        if maxRelayCount < targetRelayCount {
            throw MeshError.invalidConfiguration(reason: "Max relay count must be >= target relay count")
        }
        if keepaliveInterval <= 0 {
            throw MeshError.invalidConfiguration(reason: "Keepalive interval must be positive")
        }
        if connectionTimeout <= 0 {
            throw MeshError.invalidConfiguration(reason: "Connection timeout must be positive")
        }
        if stunServers.isEmpty {
            throw MeshError.invalidConfiguration(reason: "At least one STUN server required")
        }
    }
}

// MARK: - Builder Pattern

extension MeshConfig {
    /// Create a builder for customizing configuration
    public static func builder() -> MeshConfigBuilder {
        MeshConfigBuilder()
    }
}

/// Builder for MeshConfig
public class MeshConfigBuilder {
    private var config = MeshConfig()

    public init() {}

    @discardableResult
    public func port(_ port: Int) -> Self {
        config.port = port
        return self
    }

    @discardableResult
    public func canRelay(_ canRelay: Bool) -> Self {
        config.canRelay = canRelay
        return self
    }

    @discardableResult
    public func canCoordinateHolePunch(_ can: Bool) -> Self {
        config.canCoordinateHolePunch = can
        return self
    }

    @discardableResult
    public func targetRelayCount(_ count: Int) -> Self {
        config.targetRelayCount = count
        return self
    }

    @discardableResult
    public func maxRelayCount(_ count: Int) -> Self {
        config.maxRelayCount = count
        return self
    }

    @discardableResult
    public func keepaliveInterval(_ interval: TimeInterval) -> Self {
        config.keepaliveInterval = interval
        return self
    }

    @discardableResult
    public func connectionTimeout(_ timeout: TimeInterval) -> Self {
        config.connectionTimeout = timeout
        return self
    }

    @discardableResult
    public func stunServers(_ servers: [String]) -> Self {
        config.stunServers = servers
        return self
    }

    @discardableResult
    public func bootstrapPeers(_ peers: [String]) -> Self {
        config.bootstrapPeers = peers
        return self
    }

    @discardableResult
    public func addBootstrapPeer(_ peer: String) -> Self {
        config.bootstrapPeers.append(peer)
        return self
    }

    public func build() throws -> MeshConfig {
        try config.validate()
        return config
    }

    public func buildUnchecked() -> MeshConfig {
        config
    }
}
