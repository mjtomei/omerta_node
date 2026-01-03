import Foundation

/// Filter rule for accepting/rejecting compute requests
public struct FilterRule: Identifiable, Sendable {
    public let id: UUID
    public let condition: FilterCondition
    public let action: FilterAction
    public let priority: UInt32  // Higher = evaluated first
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        condition: FilterCondition,
        action: FilterAction,
        priority: UInt32,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.condition = condition
        self.action = action
        self.priority = priority
        self.createdAt = createdAt
    }
}

/// Filter condition types
public enum FilterCondition: Sendable {
    case peerId(PeerIdCondition)
    case ipAddress(IPAddressCondition)
    case network(NetworkCondition)
    case reputation(ReputationCondition)
    case description(DescriptionCondition)
    case resource(ResourceCondition)
}

/// Peer ID based filtering (whitelist/blacklist)
public struct PeerIdCondition: Sendable {
    public let allowedPeerIds: Set<String>
    public let blockedPeerIds: Set<String>

    public init(
        allowedPeerIds: Set<String> = [],
        blockedPeerIds: Set<String> = []
    ) {
        self.allowedPeerIds = allowedPeerIds
        self.blockedPeerIds = blockedPeerIds
    }
}

/// IP address based filtering (CIDR ranges supported)
public struct IPAddressCondition: Sendable {
    public let allowedIPs: [String]  // IP addresses or CIDR ranges
    public let blockedIPs: [String]   // IP addresses or CIDR ranges

    public init(
        allowedIPs: [String] = [],
        blockedIPs: [String] = []
    ) {
        self.allowedIPs = allowedIPs
        self.blockedIPs = blockedIPs
    }
}

/// Network based filtering
public struct NetworkCondition: Sendable {
    public let allowedNetworkIds: Set<String>
    public let blockedNetworkIds: Set<String>

    public init(
        allowedNetworkIds: Set<String> = [],
        blockedNetworkIds: Set<String> = []
    ) {
        self.allowedNetworkIds = allowedNetworkIds
        self.blockedNetworkIds = blockedNetworkIds
    }
}

/// Reputation based filtering
public struct ReputationCondition: Sendable {
    public let minReputation: UInt32  // 0-100
    public let maxRejectionRate: Double  // 0.0-1.0

    public init(
        minReputation: UInt32 = 0,
        maxRejectionRate: Double = 1.0
    ) {
        self.minReputation = minReputation
        self.maxRejectionRate = maxRejectionRate
    }
}

/// Description based filtering (keyword matching)
public struct DescriptionCondition: Sendable {
    public let requireDescription: Bool
    public let requiredKeywords: [String]  // Must contain at least one
    public let blockedKeywords: [String]   // Must not contain any

    public init(
        requireDescription: Bool = false,
        requiredKeywords: [String] = [],
        blockedKeywords: [String] = []
    ) {
        self.requireDescription = requireDescription
        self.requiredKeywords = requiredKeywords
        self.blockedKeywords = blockedKeywords
    }
}

/// Resource based filtering (limit resource requests)
public struct ResourceCondition: Sendable {
    public let maxCpuCores: UInt32
    public let maxMemoryMB: UInt64
    public let maxStorageMB: UInt64
    public let allowGPU: Bool

    public init(
        maxCpuCores: UInt32 = UInt32.max,
        maxMemoryMB: UInt64 = UInt64.max,
        maxStorageMB: UInt64 = UInt64.max,
        allowGPU: Bool = true
    ) {
        self.maxCpuCores = maxCpuCores
        self.maxMemoryMB = maxMemoryMB
        self.maxStorageMB = maxStorageMB
        self.allowGPU = allowGPU
    }
}

/// Filter action to take when rule matches
public enum FilterAction: String, Sendable {
    case accept          // Accept the request
    case reject          // Reject the request
    case queueLowPriority // Accept but queue with low priority
    case requireApproval  // Queue for manual approval
}

/// Filter evaluation result
public struct FilterResult: Sendable {
    public let action: FilterAction
    public let reason: String
    public let matchedRuleId: UUID?

    public init(
        action: FilterAction,
        reason: String,
        matchedRuleId: UUID? = nil
    ) {
        self.action = action
        self.reason = reason
        self.matchedRuleId = matchedRuleId
    }
}
