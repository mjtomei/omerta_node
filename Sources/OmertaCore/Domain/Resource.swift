import Foundation

/// Resource requirements for a compute job
public struct ResourceRequirements: Sendable {
    public let type: ResourceType
    public let cpuCores: UInt32
    public let memoryMB: UInt64
    public let gpu: GPURequirements?
    public let maxRuntimeSeconds: UInt64

    public init(
        type: ResourceType = .cpuOnly,
        cpuCores: UInt32,
        memoryMB: UInt64,
        gpu: GPURequirements? = nil,
        maxRuntimeSeconds: UInt64 = 3600  // 1 hour default
    ) {
        self.type = type
        self.cpuCores = cpuCores
        self.memoryMB = memoryMB
        self.gpu = gpu
        self.maxRuntimeSeconds = maxRuntimeSeconds
    }
}

/// Type of resource requirements
public enum ResourceType: String, Sendable {
    case cpuOnly = "cpu_only"
    case gpuRequired = "gpu_required"
    case gpuPreferred = "gpu_preferred"
}

/// GPU-specific requirements
public struct GPURequirements: Sendable {
    public let vramMB: UInt64
    public let requiredCapabilities: [String]  // e.g., ["metal3", "neural-engine"]
    public let metalOnly: Bool

    public init(
        vramMB: UInt64,
        requiredCapabilities: [String] = [],
        metalOnly: Bool = true  // For macOS Virtualization.framework
    ) {
        self.vramMB = vramMB
        self.requiredCapabilities = requiredCapabilities
        self.metalOnly = metalOnly
    }
}

/// Resource capabilities of a provider
public struct ResourceCapability: Sendable {
    public let type: ResourceType
    public let availableCpuCores: UInt32
    public let availableMemoryMB: UInt64
    public let hasGPU: Bool
    public let gpu: GPUCapability?
    public let supportedWorkloadTypes: [String]  // ["script", "binary"]

    public init(
        type: ResourceType,
        availableCpuCores: UInt32,
        availableMemoryMB: UInt64,
        hasGPU: Bool = false,
        gpu: GPUCapability? = nil,
        supportedWorkloadTypes: [String] = ["script"]
    ) {
        self.type = type
        self.availableCpuCores = availableCpuCores
        self.availableMemoryMB = availableMemoryMB
        self.hasGPU = hasGPU
        self.gpu = gpu
        self.supportedWorkloadTypes = supportedWorkloadTypes
    }
}

/// GPU capability information
public struct GPUCapability: Sendable {
    public let model: String  // e.g., "Apple M3 Max"
    public let totalVRAMMB: UInt64
    public let availableVRAMMB: UInt64
    public let supportedAPIs: [String]  // ["metal3", "neural-engine"]
    public let supportsVirtualization: Bool

    public init(
        model: String,
        totalVRAMMB: UInt64,
        availableVRAMMB: UInt64,
        supportedAPIs: [String] = ["metal3"],
        supportsVirtualization: Bool = true
    ) {
        self.model = model
        self.totalVRAMMB = totalVRAMMB
        self.availableVRAMMB = availableVRAMMB
        self.supportedAPIs = supportedAPIs
        self.supportsVirtualization = supportsVirtualization
    }
}

/// Resource usage tracking
public struct ResourceUsage: Sendable {
    public let cpuUsagePercent: Double
    public let memoryUsedMB: UInt64
    public let memoryTotalMB: UInt64
    public let gpuUsagePercent: Double?

    public init(
        cpuUsagePercent: Double,
        memoryUsedMB: UInt64,
        memoryTotalMB: UInt64,
        gpuUsagePercent: Double? = nil
    ) {
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsedMB = memoryUsedMB
        self.memoryTotalMB = memoryTotalMB
        self.gpuUsagePercent = gpuUsagePercent
    }
}
