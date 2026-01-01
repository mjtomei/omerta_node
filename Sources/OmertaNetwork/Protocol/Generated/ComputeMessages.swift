import Foundation

// MARK: - Core Compute Messages

/// A compute request submitted to a provider
public struct ComputeRequest: Sendable, Codable {
    public var requestId: String
    public var metadata: RequestMetadata
    public var requirements: Proto_ResourceRequirements
    public var workload: WorkloadSpec
    public var activityDescription: String
    public var signature: Data
    public var vpn: Proto_VPNConfiguration

    public init(
        requestId: String,
        metadata: RequestMetadata,
        requirements: Proto_ResourceRequirements,
        workload: WorkloadSpec,
        activityDescription: String,
        signature: Data,
        vpn: Proto_VPNConfiguration
    ) {
        self.requestId = requestId
        self.metadata = metadata
        self.requirements = requirements
        self.workload = workload
        self.activityDescription = activityDescription
        self.signature = signature
        self.vpn = vpn
    }
}

/// Metadata about the requester and request
public struct RequestMetadata: Sendable, Codable {
    public var peerId: String
    public var networkId: String
    public var timestamp: UInt64
    public var clientVersion: String

    public init(
        peerId: String,
        networkId: String,
        timestamp: UInt64,
        clientVersion: String
    ) {
        self.peerId = peerId
        self.networkId = networkId
        self.timestamp = timestamp
        self.clientVersion = clientVersion
    }
}

/// Resource requirements for proto compatibility
public struct Proto_ResourceRequirements: Sendable, Codable {
    public var type: ResourceType
    public var cpuCores: UInt32
    public var memoryMb: UInt64
    public var gpu: GpuRequirements?
    public var maxRuntimeSeconds: UInt64

    public init(
        type: ResourceType,
        cpuCores: UInt32,
        memoryMb: UInt64,
        gpu: GpuRequirements? = nil,
        maxRuntimeSeconds: UInt64
    ) {
        self.type = type
        self.cpuCores = cpuCores
        self.memoryMb = memoryMb
        self.gpu = gpu
        self.maxRuntimeSeconds = maxRuntimeSeconds
    }
}

/// Resource type enum
public enum ResourceType: Int, Sendable, Codable {
    case cpuOnly = 0
    case gpuRequired = 1
    case gpuPreferred = 2
}

/// GPU requirements
public struct GpuRequirements: Sendable, Codable {
    public var vramMb: UInt64
    public var requiredCapabilities: [String]
    public var metalOnly: Bool

    public init(
        vramMb: UInt64,
        requiredCapabilities: [String],
        metalOnly: Bool
    ) {
        self.vramMb = vramMb
        self.requiredCapabilities = requiredCapabilities
        self.metalOnly = metalOnly
    }
}

// MARK: - Workload Specifications

/// Workload specification
public enum WorkloadSpec: Sendable, Codable {
    case script(ScriptWorkload)
    case binary(BinaryWorkload)
}

/// Script-based workload
public struct ScriptWorkload: Sendable, Codable {
    public var language: String
    public var scriptContent: String
    public var dependencies: [String]
    public var env: [String: String]

    public init(
        language: String,
        scriptContent: String,
        dependencies: [String] = [],
        env: [String: String] = [:]
    ) {
        self.language = language
        self.scriptContent = scriptContent
        self.dependencies = dependencies
        self.env = env
    }
}

/// Binary-based workload
public struct BinaryWorkload: Sendable, Codable {
    public var binaryUrl: String
    public var binaryHash: String
    public var args: [String]
    public var env: [String: String]

    public init(
        binaryUrl: String,
        binaryHash: String,
        args: [String] = [],
        env: [String: String] = [:]
    ) {
        self.binaryUrl = binaryUrl
        self.binaryHash = binaryHash
        self.args = args
        self.env = env
    }
}

// MARK: - VPN Configuration

/// VPN configuration for proto compatibility
public struct Proto_VPNConfiguration: Sendable, Codable {
    public var wireguardConfig: String
    public var endpoint: String
    public var publicKey: Data
    public var allowedIps: String
    public var vpnServerIp: String

    public init(
        wireguardConfig: String,
        endpoint: String,
        publicKey: Data,
        allowedIps: String = "0.0.0.0/0",
        vpnServerIp: String
    ) {
        self.wireguardConfig = wireguardConfig
        self.endpoint = endpoint
        self.publicKey = publicKey
        self.allowedIps = allowedIps
        self.vpnServerIp = vpnServerIp
    }
}

// MARK: - Compute Response

/// Response to a compute request
public struct ComputeResponse: Sendable, Codable {
    public var requestId: String
    public var status: ResponseStatus
    public var result: Proto_ExecutionResult?
    public var metrics: Proto_ExecutionMetrics?
    public var logs: [LogEntry]
    public var message: String

    public init(
        requestId: String,
        status: ResponseStatus,
        result: Proto_ExecutionResult? = nil,
        metrics: Proto_ExecutionMetrics? = nil,
        logs: [LogEntry] = [],
        message: String = ""
    ) {
        self.requestId = requestId
        self.status = status
        self.result = result
        self.metrics = metrics
        self.logs = logs
        self.message = message
    }
}

/// Response status enum
public enum ResponseStatus: Int, Sendable, Codable {
    case success = 0
    case failure = 1
    case timeout = 2
    case rejected = 3
    case rogueConnectionDetected = 4
    case cancelled = 5
}

/// Execution result for proto compatibility
public struct Proto_ExecutionResult: Sendable, Codable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(
        exitCode: Int32,
        stdout: Data,
        stderr: Data
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Execution metrics for proto compatibility
public struct Proto_ExecutionMetrics: Sendable, Codable {
    public var executionTimeMs: UInt64
    public var cpuTimeMs: UInt64
    public var memoryPeakMb: UInt64
    public var networkEgressBytes: UInt64
    public var networkIngressBytes: UInt64

    public init(
        executionTimeMs: UInt64,
        cpuTimeMs: UInt64,
        memoryPeakMb: UInt64,
        networkEgressBytes: UInt64,
        networkIngressBytes: UInt64
    ) {
        self.executionTimeMs = executionTimeMs
        self.cpuTimeMs = cpuTimeMs
        self.memoryPeakMb = memoryPeakMb
        self.networkEgressBytes = networkEgressBytes
        self.networkIngressBytes = networkIngressBytes
    }
}

/// Log entry
public struct LogEntry: Sendable, Codable {
    public var timestamp: UInt64
    public var level: LogLevel
    public var message: String

    public init(
        timestamp: UInt64,
        level: LogLevel,
        message: String
    ) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

/// Log level enum
public enum LogLevel: Int, Sendable, Codable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
}

// MARK: - Job Control

/// Cancel job request
public struct CancelJobRequest: Sendable, Codable {
    public var jobId: String
    public var gracePeriodSeconds: UInt64

    public init(
        jobId: String,
        gracePeriodSeconds: UInt64 = 30
    ) {
        self.jobId = jobId
        self.gracePeriodSeconds = gracePeriodSeconds
    }
}

/// Cancel job response
public struct CancelJobResponse: Sendable, Codable {
    public var cancelled: Bool
    public var message: String

    public init(
        cancelled: Bool,
        message: String
    ) {
        self.cancelled = cancelled
        self.message = message
    }
}

/// Job status request
public struct JobStatusRequest: Sendable, Codable {
    public var jobId: String

    public init(jobId: String) {
        self.jobId = jobId
    }
}

/// Job status update
public struct JobStatusUpdate: Sendable, Codable {
    public var jobId: String
    public var status: Proto_JobStatus
    public var message: String
    public var progressPercent: UInt64

    public init(
        jobId: String,
        status: Proto_JobStatus,
        message: String,
        progressPercent: UInt64
    ) {
        self.jobId = jobId
        self.status = status
        self.message = message
        self.progressPercent = progressPercent
    }
}

/// Job status enum for proto compatibility
public enum Proto_JobStatus: Int, Sendable, Codable {
    case queued = 0
    case running = 1
    case completed = 2
    case failed = 3
    case cancelled = 4
}

// MARK: - Peer Discovery

/// Peer announcement
public struct PeerAnnouncement: Sendable, Codable {
    public var peerId: String
    public var networkId: String
    public var capabilities: [ResourceCapability]
    public var metadata: PeerMetadata
    public var timestamp: UInt64
    public var signature: Data
    public var endpoint: String

    public init(
        peerId: String,
        networkId: String,
        capabilities: [ResourceCapability],
        metadata: PeerMetadata,
        timestamp: UInt64,
        signature: Data,
        endpoint: String
    ) {
        self.peerId = peerId
        self.networkId = networkId
        self.capabilities = capabilities
        self.metadata = metadata
        self.timestamp = timestamp
        self.signature = signature
        self.endpoint = endpoint
    }
}

/// Resource capability
public struct ResourceCapability: Sendable, Codable {
    public var type: ResourceType
    public var availableCpuCores: UInt32
    public var availableMemoryMb: UInt64
    public var hasGpu: Bool
    public var gpu: GpuCapability?
    public var supportedWorkloadTypes: [String]

    public init(
        type: ResourceType,
        availableCpuCores: UInt32,
        availableMemoryMb: UInt64,
        hasGpu: Bool,
        gpu: GpuCapability? = nil,
        supportedWorkloadTypes: [String]
    ) {
        self.type = type
        self.availableCpuCores = availableCpuCores
        self.availableMemoryMb = availableMemoryMb
        self.hasGpu = hasGpu
        self.gpu = gpu
        self.supportedWorkloadTypes = supportedWorkloadTypes
    }
}

/// GPU capability
public struct GpuCapability: Sendable, Codable {
    public var gpuModel: String
    public var totalVramMb: UInt64
    public var availableVramMb: UInt64
    public var supportedApis: [String]
    public var supportsVirtualization: Bool

    public init(
        gpuModel: String,
        totalVramMb: UInt64,
        availableVramMb: UInt64,
        supportedApis: [String],
        supportsVirtualization: Bool
    ) {
        self.gpuModel = gpuModel
        self.totalVramMb = totalVramMb
        self.availableVramMb = availableVramMb
        self.supportedApis = supportedApis
        self.supportsVirtualization = supportsVirtualization
    }
}

/// Peer metadata
public struct PeerMetadata: Sendable, Codable {
    public var reputationScore: UInt32
    public var jobsCompleted: UInt64
    public var jobsRejected: UInt64
    public var averageResponseTimeMs: Double

    public init(
        reputationScore: UInt32,
        jobsCompleted: UInt64,
        jobsRejected: UInt64,
        averageResponseTimeMs: Double
    ) {
        self.reputationScore = reputationScore
        self.jobsCompleted = jobsCompleted
        self.jobsRejected = jobsRejected
        self.averageResponseTimeMs = averageResponseTimeMs
    }
}

/// Peer query
public struct PeerQuery: Sendable, Codable {
    public var networkId: String
    public var requirements: Proto_ResourceRequirements
    public var maxResults: UInt32

    public init(
        networkId: String,
        requirements: Proto_ResourceRequirements,
        maxResults: UInt32 = 10
    ) {
        self.networkId = networkId
        self.requirements = requirements
        self.maxResults = maxResults
    }
}

// MARK: - Network Management

/// Announce request
public struct AnnounceRequest: Sendable, Codable {
    public var announcement: PeerAnnouncement

    public init(announcement: PeerAnnouncement) {
        self.announcement = announcement
    }
}

/// Announce response
public struct AnnounceResponse: Sendable, Codable {
    public var success: Bool
    public var message: String
    public var dhtNodes: [String]

    public init(
        success: Bool,
        message: String,
        dhtNodes: [String] = []
    ) {
        self.success = success
        self.message = message
        self.dhtNodes = dhtNodes
    }
}

/// Find peers request
public struct FindPeersRequest: Sendable, Codable {
    public var query: PeerQuery

    public init(query: PeerQuery) {
        self.query = query
    }
}

/// Find peers response
public struct FindPeersResponse: Sendable, Codable {
    public var peers: [PeerAnnouncement]

    public init(peers: [PeerAnnouncement]) {
        self.peers = peers
    }
}
