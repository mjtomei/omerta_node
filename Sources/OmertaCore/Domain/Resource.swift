import Foundation

// MARK: - CPU Architecture

public enum CPUArchitecture: String, Codable, Sendable {
    case x86_64
    case arm64
}

// MARK: - GPU Vendor

public enum GPUVendor: String, Codable, Sendable {
    case nvidia
    case amd
    case apple
    case intel
}

// MARK: - Resource Requirements (Consumer Request)

/// Resource requirements for requesting a VM
/// All fields are optional (nil = "don't care")
public struct ResourceRequirements: Codable, Sendable {
    // CPU (nil = don't care)
    public let cpuCores: UInt32?
    public let cpuArchitecture: CPUArchitecture?

    // Memory (nil = don't care)
    public let memoryMB: UInt64?

    // Storage (nil = don't care)
    public let storageMB: UInt64?

    // GPU (nil = no GPU needed)
    public let gpu: GPURequirements?

    // Network (nil = don't care)
    public let networkBandwidthMbps: UInt32?

    // OS/Image (nil = provider default)
    public let imageId: String?

    public init(
        cpuCores: UInt32? = nil,
        cpuArchitecture: CPUArchitecture? = nil,
        memoryMB: UInt64? = nil,
        storageMB: UInt64? = nil,
        gpu: GPURequirements? = nil,
        networkBandwidthMbps: UInt32? = nil,
        imageId: String? = nil
    ) {
        self.cpuCores = cpuCores
        self.cpuArchitecture = cpuArchitecture
        self.memoryMB = memoryMB
        self.storageMB = storageMB
        self.gpu = gpu
        self.networkBandwidthMbps = networkBandwidthMbps
        self.imageId = imageId
    }
}

// MARK: - GPU Requirements

/// GPU-specific requirements
public struct GPURequirements: Codable, Sendable {
    // Exact model matching (e.g., "NVIDIA RTX 4090", "Apple M1 Max")
    public let model: String?  // nil = any GPU with sufficient VRAM

    // Minimum VRAM (nil = don't care)
    public let vramMB: UInt64?

    // Required APIs (nil = don't care)
    public let requiredAPIs: [String]?  // e.g., ["CUDA 12.0"], ["Metal"]

    // Vendor filter (nil = don't care)
    public let vendor: GPUVendor?

    public init(
        model: String? = nil,
        vramMB: UInt64? = nil,
        requiredAPIs: [String]? = nil,
        vendor: GPUVendor? = nil
    ) {
        self.model = model
        self.vramMB = vramMB
        self.requiredAPIs = requiredAPIs
        self.vendor = vendor
    }
}

// MARK: - Resource Capability (Provider Advertisement)

/// Resource capabilities advertised by a provider
public struct ResourceCapability: Codable, Sendable {
    // CPU
    public let cpuCores: UInt32
    public let cpuArchitecture: CPUArchitecture
    public let cpuModel: String?  // e.g., "Apple M1 Max", "Intel Xeon E5-2680"

    // Memory
    public let totalMemoryMB: UInt64
    public let availableMemoryMB: UInt64

    // Storage
    public let totalStorageMB: UInt64
    public let availableStorageMB: UInt64

    // GPU (nil if no GPU)
    public let gpu: GPUCapability?

    // Network
    public let networkBandwidthMbps: UInt32?

    // Available images
    public let availableImages: [String]  // e.g., ["ubuntu-22.04", "alpine-3.18"]

    public init(
        cpuCores: UInt32,
        cpuArchitecture: CPUArchitecture,
        cpuModel: String? = nil,
        totalMemoryMB: UInt64,
        availableMemoryMB: UInt64,
        totalStorageMB: UInt64,
        availableStorageMB: UInt64,
        gpu: GPUCapability? = nil,
        networkBandwidthMbps: UInt32? = nil,
        availableImages: [String] = ["ubuntu-22.04"]
    ) {
        self.cpuCores = cpuCores
        self.cpuArchitecture = cpuArchitecture
        self.cpuModel = cpuModel
        self.totalMemoryMB = totalMemoryMB
        self.availableMemoryMB = availableMemoryMB
        self.totalStorageMB = totalStorageMB
        self.availableStorageMB = availableStorageMB
        self.gpu = gpu
        self.networkBandwidthMbps = networkBandwidthMbps
        self.availableImages = availableImages
    }
}

// MARK: - GPU Capability

/// GPU capability information
public struct GPUCapability: Codable, Sendable {
    // Exact model name
    public let model: String  // "NVIDIA RTX 4090", "Apple M1 Max"

    // Vendor
    public let vendor: GPUVendor

    // VRAM
    public let totalVramMB: UInt64
    public let availableVramMB: UInt64

    // Supported APIs
    public let supportedAPIs: [String]  // ["CUDA 12.0", "OpenCL 3.0"], ["Metal"]

    // Virtualization support
    public let supportsVirtualization: Bool

    public init(
        model: String,
        vendor: GPUVendor,
        totalVramMB: UInt64,
        availableVramMB: UInt64,
        supportedAPIs: [String],
        supportsVirtualization: Bool = true
    ) {
        self.model = model
        self.vendor = vendor
        self.totalVramMB = totalVramMB
        self.availableVramMB = availableVramMB
        self.supportedAPIs = supportedAPIs
        self.supportsVirtualization = supportsVirtualization
    }
}

// MARK: - Resource Usage Tracking

/// Resource usage tracking (for provider monitoring)
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

// MARK: - Reverse SSH Tunnel Configuration

/// Configuration for VM to establish a reverse SSH tunnel back to the host
/// This is used on macOS where NAT networking doesn't allow inbound connections
public struct ReverseTunnelConfig: Codable, Sendable {
    /// Host IP from VM's perspective (NAT gateway, e.g., 192.168.64.1)
    public let hostIP: String

    /// Username on host to SSH as
    public let hostUser: String

    /// SSH port on host (usually 22)
    public let hostPort: UInt16

    /// Local port on host to forward to VM's SSH (e.g., 2222)
    public let tunnelPort: UInt16

    /// SSH private key for connecting to host (PEM format)
    public let privateKey: String

    public init(
        hostIP: String = "192.168.64.1",  // Default macOS Virtualization.framework NAT gateway
        hostUser: String,
        hostPort: UInt16 = 22,
        tunnelPort: UInt16 = 2222,
        privateKey: String
    ) {
        self.hostIP = hostIP
        self.hostUser = hostUser
        self.hostPort = hostPort
        self.tunnelPort = tunnelPort
        self.privateKey = privateKey
    }
}
