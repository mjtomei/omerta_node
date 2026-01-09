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

// MARK: - VPN Configuration

/// VPN configuration for consumer-hosted WireGuard server
/// Consumer sends this to provider so provider can connect back
public struct VPNConfiguration: Sendable, Codable {
    /// Consumer's WireGuard public key
    public let consumerPublicKey: String

    /// Consumer's WireGuard endpoint (IP:port) - where provider connects
    public let consumerEndpoint: String

    /// Consumer's IP within VPN network (e.g., 10.99.0.1)
    public let consumerVPNIP: String

    /// Requested VM IP within VPN network (e.g., 10.99.0.2)
    public let vmVPNIP: String

    /// VPN subnet (e.g., "10.99.0.0/24")
    public let vpnSubnet: String

    /// Pre-shared key for WireGuard (base64-encoded, derived from network key)
    /// Both sides already have this from network joining
    public let presharedKey: String?

    public init(
        consumerPublicKey: String,
        consumerEndpoint: String,
        consumerVPNIP: String = "10.99.0.1",
        vmVPNIP: String = "10.99.0.2",
        vpnSubnet: String = "10.99.0.0/24",
        presharedKey: String? = nil
    ) {
        self.consumerPublicKey = consumerPublicKey
        self.consumerEndpoint = consumerEndpoint
        self.consumerVPNIP = consumerVPNIP
        self.vmVPNIP = vmVPNIP
        self.vpnSubnet = vpnSubnet
        self.presharedKey = presharedKey
    }
}
