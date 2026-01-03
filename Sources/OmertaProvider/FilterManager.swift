import Foundation
import OmertaCore

/// Priority levels for VM requests
public enum RequestPriority: Int, Comparable, Sendable {
    case owner = 100        // Requests from the machine owner (highest priority)
    case network = 50       // Requests from network peers (normal priority)
    case external = 10      // Requests from outside trusted networks (lowest priority)

    public static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Filter decision for a VM request
public enum FilterDecision: Sendable {
    case accept(priority: RequestPriority)
    case reject(reason: String)
    case requiresApproval(reason: String)
}

/// A filter rule that can be applied to requests
public protocol FilterRule: Sendable {
    var id: UUID { get }
    var name: String { get }
    var isEnabled: Bool { get }
    var priority: Int { get }  // Higher priority rules are evaluated first

    func evaluate(_ request: FilterRequest) async -> FilterRuleResult
}

/// Result from evaluating a single filter rule
public enum FilterRuleResult: Sendable {
    case pass       // Rule doesn't match or allows the request
    case reject(String)  // Rule explicitly rejects
    case requiresApproval(String)  // Rule requires manual approval
}

/// Request information for filtering
public struct FilterRequest: Sendable {
    public let requesterId: String
    public let networkId: String
    public let requirements: ResourceRequirements
    public let activityDescription: String?
    public let timestamp: Date

    public init(
        requesterId: String,
        networkId: String,
        requirements: ResourceRequirements,
        activityDescription: String?,
        timestamp: Date = Date()
    ) {
        self.requesterId = requesterId
        self.networkId = networkId
        self.requirements = requirements
        self.activityDescription = activityDescription
        self.timestamp = timestamp
    }
}

/// Actor managing filter rules and request evaluation
public actor FilterManager {

    // MARK: - State

    private var rules: [UUID: any FilterRule] = [:]
    private var defaultAction: DefaultAction = .acceptAll

    // Owner peer ID (jobs from this peer ID get highest priority)
    private var ownerPeerId: String?

    // Trusted network IDs (jobs from these networks are accepted)
    private var trustedNetworks: Set<String> = []

    // Blocked peer IDs
    private var blockedPeers: Set<String> = []

    // MARK: - Statistics

    private var totalRequestsEvaluated: Int = 0
    private var totalRequestsAccepted: Int = 0
    private var totalRequestsRejected: Int = 0
    private var totalRequestsPendingApproval: Int = 0

    // MARK: - Initialization

    public init(ownerPeerId: String? = nil, trustedNetworks: [String] = []) {
        self.ownerPeerId = ownerPeerId
        self.trustedNetworks = Set(trustedNetworks)
    }

    // MARK: - Filter Evaluation

    /// Evaluate a request against all filter rules
    public func evaluate(_ request: FilterRequest) async -> FilterDecision {
        totalRequestsEvaluated += 1

        // Check if requester is owner (highest priority)
        if let ownerPeerId = ownerPeerId, request.requesterId == ownerPeerId {
            totalRequestsAccepted += 1
            return .accept(priority: .owner)
        }

        // Check if peer is blocked (immediate rejection)
        if blockedPeers.contains(request.requesterId) {
            totalRequestsRejected += 1
            return .reject(reason: "Peer is blocked")
        }

        // Evaluate all enabled rules in priority order
        let sortedRules = rules.values
            .filter { $0.isEnabled }
            .sorted { $0.priority > $1.priority }

        for rule in sortedRules {
            let result = await rule.evaluate(request)

            switch result {
            case .pass:
                continue  // Try next rule
            case .reject(let reason):
                totalRequestsRejected += 1
                return .reject(reason: "Rule '\(rule.name)': \(reason)")
            case .requiresApproval(let reason):
                totalRequestsPendingApproval += 1
                return .requiresApproval(reason: "Rule '\(rule.name)': \(reason)")
            }
        }

        // No rules matched - apply default action
        let decision = applyDefaultAction(request)

        switch decision {
        case .accept:
            totalRequestsAccepted += 1
        case .reject:
            totalRequestsRejected += 1
        case .requiresApproval:
            totalRequestsPendingApproval += 1
        }

        return decision
    }

    private func applyDefaultAction(_ request: FilterRequest) -> FilterDecision {
        switch defaultAction {
        case .acceptAll:
            // Accept from trusted networks, require approval for others
            if trustedNetworks.contains(request.networkId) {
                return .accept(priority: .network)
            } else {
                return .requiresApproval(reason: "Network not in trusted list")
            }

        case .rejectAll:
            return .reject(reason: "Default policy: reject all")

        case .requireApproval:
            return .requiresApproval(reason: "Default policy: manual approval required")

        case .acceptTrustedOnly:
            if trustedNetworks.contains(request.networkId) {
                return .accept(priority: .network)
            } else {
                return .reject(reason: "Network not trusted")
            }
        }
    }

    // MARK: - Rule Management

    /// Add a filter rule
    public func addRule(_ rule: any FilterRule) {
        rules[rule.id] = rule
    }

    /// Remove a filter rule
    public func removeRule(_ ruleId: UUID) {
        rules.removeValue(forKey: ruleId)
    }

    /// Get all rules
    public func getRules() -> [any FilterRule] {
        Array(rules.values).sorted { $0.priority > $1.priority }
    }

    /// Enable/disable a rule
    public func setRuleEnabled(_ ruleId: UUID, enabled: Bool) {
        guard var rule = rules[ruleId] else { return }

        // Note: This won't work with current protocol because FilterRule doesn't have mutable isEnabled
        // In real implementation, we'd need a mutable wrapper or different approach
        // For now, this is a design placeholder
    }

    /// Set default action when no rules match
    public func setDefaultAction(_ action: DefaultAction) {
        self.defaultAction = action
    }

    // MARK: - Network & Peer Management

    /// Set owner peer ID
    public func setOwnerPeerId(_ peerId: String) {
        self.ownerPeerId = peerId
    }

    /// Add a trusted network
    public func addTrustedNetwork(_ networkId: String) {
        trustedNetworks.insert(networkId)
    }

    /// Remove a trusted network
    public func removeTrustedNetwork(_ networkId: String) {
        trustedNetworks.remove(networkId)
    }

    /// Get all trusted networks
    public func getTrustedNetworks() -> [String] {
        Array(trustedNetworks)
    }

    /// Block a peer
    public func blockPeer(_ peerId: String) {
        blockedPeers.insert(peerId)
    }

    /// Unblock a peer
    public func unblockPeer(_ peerId: String) {
        blockedPeers.remove(peerId)
    }

    /// Get all blocked peers
    public func getBlockedPeers() -> [String] {
        Array(blockedPeers)
    }

    // MARK: - Statistics

    /// Get filter statistics
    public func getStatistics() -> FilterStatistics {
        FilterStatistics(
            totalEvaluated: totalRequestsEvaluated,
            totalAccepted: totalRequestsAccepted,
            totalRejected: totalRequestsRejected,
            totalPendingApproval: totalRequestsPendingApproval,
            activeRulesCount: rules.values.filter { $0.isEnabled }.count,
            totalRulesCount: rules.count
        )
    }

    /// Reset statistics
    public func resetStatistics() {
        totalRequestsEvaluated = 0
        totalRequestsAccepted = 0
        totalRequestsRejected = 0
        totalRequestsPendingApproval = 0
    }
}

// MARK: - Default Actions

public enum DefaultAction: String, Sendable {
    case acceptAll           // Accept all requests (unless explicitly blocked)
    case rejectAll           // Reject all requests (unless explicitly allowed)
    case requireApproval     // Require manual approval for all
    case acceptTrustedOnly   // Only accept from trusted networks
}

// MARK: - Built-in Filter Rules

/// Filter based on resource requirements
public struct ResourceLimitRule: FilterRule {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let priority: Int

    public let maxCpuCores: UInt32
    public let maxMemoryMB: UInt64
    public let maxStorageMB: UInt64

    public init(
        id: UUID = UUID(),
        name: String = "Resource Limits",
        isEnabled: Bool = true,
        priority: Int = 50,
        maxCpuCores: UInt32 = 8,
        maxMemoryMB: UInt64 = 16384,
        maxStorageMB: UInt64 = 102400  // 100GB default
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.priority = priority
        self.maxCpuCores = maxCpuCores
        self.maxMemoryMB = maxMemoryMB
        self.maxStorageMB = maxStorageMB
    }

    public func evaluate(_ request: FilterRequest) async -> FilterRuleResult {
        if let cpuCores = request.requirements.cpuCores, cpuCores > maxCpuCores {
            return .reject("Requested CPU cores (\(cpuCores)) exceeds limit (\(maxCpuCores))")
        }

        if let memoryMB = request.requirements.memoryMB, memoryMB > maxMemoryMB {
            return .reject("Requested memory (\(memoryMB)MB) exceeds limit (\(maxMemoryMB)MB)")
        }

        if let storageMB = request.requirements.storageMB, storageMB > maxStorageMB {
            return .reject("Requested storage (\(storageMB)MB) exceeds limit (\(maxStorageMB)MB)")
        }

        return .pass
    }
}

/// Filter based on activity description keywords
public struct ActivityDescriptionRule: FilterRule {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let priority: Int

    public let requiredKeywords: [String]?  // Must contain at least one
    public let forbiddenKeywords: [String]?  // Must not contain any

    public init(
        id: UUID = UUID(),
        name: String = "Activity Description Filter",
        isEnabled: Bool = true,
        priority: Int = 40,
        requiredKeywords: [String]? = nil,
        forbiddenKeywords: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.priority = priority
        self.requiredKeywords = requiredKeywords
        self.forbiddenKeywords = forbiddenKeywords
    }

    public func evaluate(_ request: FilterRequest) async -> FilterRuleResult {
        guard let description = request.activityDescription else {
            if requiredKeywords != nil {
                return .requiresApproval("No activity description provided")
            }
            return .pass
        }

        let lowercased = description.lowercased()

        // Check forbidden keywords
        if let forbidden = forbiddenKeywords {
            for keyword in forbidden {
                if lowercased.contains(keyword.lowercased()) {
                    return .reject("Activity description contains forbidden keyword: '\(keyword)'")
                }
            }
        }

        // Check required keywords
        if let required = requiredKeywords {
            let hasRequired = required.contains { keyword in
                lowercased.contains(keyword.lowercased())
            }
            if !hasRequired {
                return .requiresApproval("Activity description does not contain required keywords")
            }
        }

        return .pass
    }
}

/// Filter based on time of day (quiet hours)
public struct QuietHoursRule: FilterRule {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let priority: Int

    public let startHour: Int  // 0-23
    public let endHour: Int    // 0-23
    public let action: QuietHoursAction

    public init(
        id: UUID = UUID(),
        name: String = "Quiet Hours",
        isEnabled: Bool = true,
        priority: Int = 60,
        startHour: Int = 22,  // 10 PM
        endHour: Int = 8,     // 8 AM
        action: QuietHoursAction = .reject
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.priority = priority
        self.startHour = startHour
        self.endHour = endHour
        self.action = action
    }

    public func evaluate(_ request: FilterRequest) async -> FilterRuleResult {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: request.timestamp)

        let isQuietHours = if startHour < endHour {
            hour >= startHour && hour < endHour
        } else {
            hour >= startHour || hour < endHour
        }

        if isQuietHours {
            switch action {
            case .reject:
                return .reject("Quiet hours (\(startHour):00 - \(endHour):00)")
            case .requireApproval:
                return .requiresApproval("Request during quiet hours")
            case .acceptLowPriorityOnly:
                // Could check if request is low priority, but for now just pass
                return .pass
            }
        }

        return .pass
    }
}

public enum QuietHoursAction: Sendable {
    case reject
    case requireApproval
    case acceptLowPriorityOnly
}

// MARK: - Statistics

public struct FilterStatistics: Sendable {
    public let totalEvaluated: Int
    public let totalAccepted: Int
    public let totalRejected: Int
    public let totalPendingApproval: Int
    public let activeRulesCount: Int
    public let totalRulesCount: Int

    public var acceptanceRate: Double {
        guard totalEvaluated > 0 else { return 0 }
        return Double(totalAccepted) / Double(totalEvaluated)
    }

    public var rejectionRate: Double {
        guard totalEvaluated > 0 else { return 0 }
        return Double(totalRejected) / Double(totalEvaluated)
    }
}
