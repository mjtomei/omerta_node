import Foundation

/// Represents a compute job submitted to a provider
public struct ComputeJob: Identifiable, Sendable {
    public let id: UUID
    public let requesterId: String
    public let networkId: String
    public let requirements: ResourceRequirements
    public let workload: Workload
    public let activityDescription: String?
    public let vpnConfig: VPNConfiguration
    public let submittedAt: Date

    public init(
        id: UUID = UUID(),
        requesterId: String,
        networkId: String,
        requirements: ResourceRequirements,
        workload: Workload,
        activityDescription: String? = nil,
        vpnConfig: VPNConfiguration,
        submittedAt: Date = Date()
    ) {
        self.id = id
        self.requesterId = requesterId
        self.networkId = networkId
        self.requirements = requirements
        self.workload = workload
        self.activityDescription = activityDescription
        self.vpnConfig = vpnConfig
        self.submittedAt = submittedAt
    }
}

/// Workload specification
public enum Workload: Sendable {
    case script(ScriptWorkload)
    case binary(BinaryWorkload)
}

public struct ScriptWorkload: Sendable {
    public let language: String  // "python", "bash", "swift", etc.
    public let scriptContent: String
    public let dependencies: [String]
    public let environment: [String: String]

    public init(
        language: String,
        scriptContent: String,
        dependencies: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.language = language
        self.scriptContent = scriptContent
        self.dependencies = dependencies
        self.environment = environment
    }
}

public struct BinaryWorkload: Sendable {
    public let binaryURL: String  // URL accessible via VPN
    public let binaryHash: String  // SHA256 for verification
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        binaryURL: String,
        binaryHash: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.binaryURL = binaryURL
        self.binaryHash = binaryHash
        self.arguments = arguments
        self.environment = environment
    }
}

/// VPN configuration for routing VM traffic
public struct VPNConfiguration: Sendable {
    public let wireguardConfig: String
    public let endpoint: String  // IP:port
    public let publicKey: Data
    public let allowedIPs: String  // Usually "0.0.0.0/0"
    public let serverIP: String  // Requester's IP within VPN network

    public init(
        wireguardConfig: String,
        endpoint: String,
        publicKey: Data,
        allowedIPs: String = "0.0.0.0/0",
        serverIP: String
    ) {
        self.wireguardConfig = wireguardConfig
        self.endpoint = endpoint
        self.publicKey = publicKey
        self.allowedIPs = allowedIPs
        self.serverIP = serverIP
    }
}

/// Job execution result
public struct ExecutionResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let metrics: ExecutionMetrics

    public init(
        exitCode: Int32,
        stdout: Data,
        stderr: Data,
        metrics: ExecutionMetrics
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.metrics = metrics
    }
}

/// Metrics collected during job execution
public struct ExecutionMetrics: Sendable {
    public let executionTimeMs: UInt64
    public let cpuTimeMs: UInt64
    public let memoryPeakMB: UInt64
    public let networkEgressBytes: UInt64
    public let networkIngressBytes: UInt64

    public init(
        executionTimeMs: UInt64,
        cpuTimeMs: UInt64,
        memoryPeakMB: UInt64,
        networkEgressBytes: UInt64,
        networkIngressBytes: UInt64
    ) {
        self.executionTimeMs = executionTimeMs
        self.cpuTimeMs = cpuTimeMs
        self.memoryPeakMB = memoryPeakMB
        self.networkEgressBytes = networkEgressBytes
        self.networkIngressBytes = networkIngressBytes
    }
}

/// Job status
public enum JobStatus: String, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}
