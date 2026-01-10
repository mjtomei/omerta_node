// FilteringStrategy.swift
// Protocol and implementations for packet filtering strategies

import Foundation

// MARK: - FilterDecision

/// Decision from a filtering strategy
public enum FilterDecision: Equatable, Sendable {
    /// Forward the packet
    case forward
    /// Drop the packet with reason
    case drop(reason: String)
    /// Terminate the VM immediately (for sampled/conntrack violations)
    case terminate(reason: String)
}

// MARK: - FilteringStrategy Protocol

/// Protocol for packet filtering strategies
public protocol FilteringStrategy: Sendable {
    /// Check if a packet should be forwarded
    func shouldForward(packet: IPv4Packet) async -> FilterDecision

    /// Called when violation detected (for logging/metrics)
    func recordViolation(packet: IPv4Packet, reason: String) async
}

// MARK: - FullFilterStrategy

/// Full filtering - checks every packet against allowlist
public actor FullFilterStrategy: FilteringStrategy {

    private let allowlist: EndpointAllowlist
    private var stats = FullFilterStatistics()

    public struct FullFilterStatistics: Sendable {
        public var packetsChecked: UInt64 = 0
        public var packetsForwarded: UInt64 = 0
        public var packetsDropped: UInt64 = 0
    }

    public var statistics: FullFilterStatistics {
        stats
    }

    public init(allowlist: EndpointAllowlist) {
        self.allowlist = allowlist
    }

    public func shouldForward(packet: IPv4Packet) async -> FilterDecision {
        stats.packetsChecked += 1

        guard let destPort = packet.destinationPort else {
            stats.packetsDropped += 1
            return .drop(reason: "No destination port")
        }

        let isAllowed = await allowlist.isAllowed(
            address: packet.destinationAddress,
            port: destPort
        )

        if isAllowed {
            stats.packetsForwarded += 1
            return .forward
        } else {
            stats.packetsDropped += 1
            return .drop(reason: "Not in allowlist: \(packet.destinationAddress):\(destPort)")
        }
    }

    public func recordViolation(packet: IPv4Packet, reason: String) async {
        // Could log or emit metrics here
    }
}

// MARK: - ConntrackStrategy

/// Connection tracking - checks first packet per flow, fast-paths rest
public actor ConntrackStrategy: FilteringStrategy {

    /// Flow key for tracking
    private struct FlowKey: Hashable {
        let destAddress: IPv4Address
        let destPort: UInt16
    }

    /// Flow entry with timestamp
    private struct FlowEntry {
        let createdAt: ContinuousClock.Instant
    }

    private let allowlist: EndpointAllowlist
    private let flowTimeout: Duration
    private var flows: [FlowKey: FlowEntry] = [:]
    private var stats = ConntrackStatistics()

    public struct ConntrackStatistics: Sendable {
        public var packetsProcessed: UInt64 = 0
        public var allowlistChecks: UInt64 = 0
        public var fastPathHits: UInt64 = 0
        public var trackedFlows: Int = 0
        public var flowsExpired: UInt64 = 0
    }

    public var statistics: ConntrackStatistics {
        var s = stats
        s.trackedFlows = flows.count
        return s
    }

    public init(allowlist: EndpointAllowlist, flowTimeoutSeconds: Double = 300) {
        self.allowlist = allowlist
        self.flowTimeout = .seconds(flowTimeoutSeconds)
    }

    public func shouldForward(packet: IPv4Packet) async -> FilterDecision {
        stats.packetsProcessed += 1

        guard let destPort = packet.destinationPort else {
            return .terminate(reason: "Non-port-based protocol to non-allowed endpoint")
        }

        let flowKey = FlowKey(destAddress: packet.destinationAddress, destPort: destPort)
        let now = ContinuousClock.now

        // Check if flow exists and is not expired
        if let entry = flows[flowKey] {
            if now - entry.createdAt < flowTimeout {
                stats.fastPathHits += 1
                return .forward
            } else {
                // Flow expired
                flows.removeValue(forKey: flowKey)
                stats.flowsExpired += 1
            }
        }

        // Slow path: check allowlist
        stats.allowlistChecks += 1

        let isAllowed = await allowlist.isAllowed(
            address: packet.destinationAddress,
            port: destPort
        )

        if isAllowed {
            // Add to tracked flows
            flows[flowKey] = FlowEntry(createdAt: now)
            return .forward
        } else {
            // Conntrack terminates on new bad flow
            return .terminate(reason: "Connection to non-allowed endpoint: \(packet.destinationAddress):\(destPort)")
        }
    }

    public func recordViolation(packet: IPv4Packet, reason: String) async {
        // Could log or emit metrics here
    }

    /// Clear expired flows (call periodically)
    public func cleanupExpiredFlows() {
        let now = ContinuousClock.now
        flows = flows.filter { _, entry in
            now - entry.createdAt < flowTimeout
        }
    }
}

// MARK: - SampledStrategy

/// Sampled filtering - checks random subset of packets
public actor SampledStrategy: FilteringStrategy {

    private let allowlist: EndpointAllowlist
    private let sampleRate: Double
    private var stats = SampledStatistics()

    public struct SampledStatistics: Sendable {
        public var packetsProcessed: UInt64 = 0
        public var packetsChecked: UInt64 = 0
        public var packetsForwarded: UInt64 = 0
        public var violationsDetected: UInt64 = 0
    }

    public var statistics: SampledStatistics {
        stats
    }

    /// Create a sampled strategy
    /// - Parameters:
    ///   - allowlist: Endpoint allowlist
    ///   - sampleRate: Fraction of packets to check (0.0 to 1.0)
    public init(allowlist: EndpointAllowlist, sampleRate: Double) {
        self.allowlist = allowlist
        self.sampleRate = max(0, min(1, sampleRate))  // Clamp to [0, 1]
    }

    public func shouldForward(packet: IPv4Packet) async -> FilterDecision {
        stats.packetsProcessed += 1

        // Skip check based on sample rate
        guard Double.random(in: 0...1) < sampleRate else {
            stats.packetsForwarded += 1
            return .forward  // Not sampled, allow through
        }

        // Sampled - check against allowlist
        stats.packetsChecked += 1

        guard let destPort = packet.destinationPort else {
            stats.violationsDetected += 1
            return .terminate(reason: "Sampled non-port-based packet to unknown destination")
        }

        let isAllowed = await allowlist.isAllowed(
            address: packet.destinationAddress,
            port: destPort
        )

        if isAllowed {
            stats.packetsForwarded += 1
            return .forward
        } else {
            // Sampled violation - terminate VM
            stats.violationsDetected += 1
            return .terminate(reason: "Sampled packet violated allowlist: \(packet.destinationAddress):\(destPort)")
        }
    }

    public func recordViolation(packet: IPv4Packet, reason: String) async {
        stats.violationsDetected += 1
    }
}
