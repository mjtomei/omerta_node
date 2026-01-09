import Foundation
@testable import OmertaCore

/// Test helpers for creating resource capabilities with default values
struct TestResourceCapability {
    static func cpuOnly(
        cpuCores: UInt32 = 8,
        availableMemoryMB: UInt64 = 16384
    ) -> ResourceCapability {
        ResourceCapability(
            cpuCores: cpuCores,
            cpuArchitecture: .arm64,
            cpuModel: nil,
            totalMemoryMB: availableMemoryMB * 2,
            availableMemoryMB: availableMemoryMB,
            totalStorageMB: 100000,
            availableStorageMB: 50000,
            gpu: nil,
            networkBandwidthMbps: 1000,
            availableImages: ["ubuntu-22.04"]
        )
    }

    static func withGPU(
        cpuCores: UInt32 = 8,
        availableMemoryMB: UInt64 = 32768,
        gpuVramMB: UInt64 = 16384,
        gpuVendor: GPUVendor = .nvidia
    ) -> ResourceCapability {
        ResourceCapability(
            cpuCores: cpuCores,
            cpuArchitecture: .x86_64,
            cpuModel: nil,
            totalMemoryMB: availableMemoryMB * 2,
            availableMemoryMB: availableMemoryMB,
            totalStorageMB: 500000,
            availableStorageMB: 250000,
            gpu: GPUCapability(
                model: "RTX 4090",
                vendor: gpuVendor,
                totalVramMB: gpuVramMB,
                availableVramMB: gpuVramMB,
                supportedAPIs: ["CUDA 12.0"],
                supportsVirtualization: true
            ),
            networkBandwidthMbps: 10000,
            availableImages: ["ubuntu-22.04", "alpine-3.18"]
        )
    }
}
