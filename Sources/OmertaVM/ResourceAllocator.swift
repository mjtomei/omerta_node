import Foundation
import OmertaCore

/// Manages resource allocation for VMs
public actor ResourceAllocator {
    private var allocatedCPU: UInt32 = 0
    private var allocatedMemoryMB: UInt64 = 0

    public init() {}

    /// Check if resources can be allocated for requirements
    public func canAllocate(_ requirements: ResourceRequirements) -> Bool {
        let availableCPU = ProcessInfo.processInfo.processorCount
        let totalMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)

        // Reserve 2 CPUs and 4GB for host system
        let availableForAllocation = UInt32(max(1, availableCPU - 2))
        let memoryForAllocation = totalMemoryMB - 4096

        // Use defaults if not specified
        let requestedCPU = requirements.cpuCores ?? 2
        let requestedMemory = requirements.memoryMB ?? 2048

        // Check if we can allocate
        let canAllocateCPU = (allocatedCPU + requestedCPU) <= availableForAllocation
        let canAllocateMemory = (allocatedMemoryMB + requestedMemory) <= memoryForAllocation

        return canAllocateCPU && canAllocateMemory
    }

    /// Allocate resources (call before starting VM)
    public func allocate(_ requirements: ResourceRequirements) throws {
        guard canAllocate(requirements) else {
            throw AllocationError.insufficientResources
        }

        let requestedCPU = requirements.cpuCores ?? 2
        let requestedMemory = requirements.memoryMB ?? 2048

        allocatedCPU += requestedCPU
        allocatedMemoryMB += requestedMemory
    }

    /// Release resources (call after VM stops)
    public func release(_ requirements: ResourceRequirements) {
        let requestedCPU = requirements.cpuCores ?? 2
        let requestedMemory = requirements.memoryMB ?? 2048

        allocatedCPU = max(0, allocatedCPU - requestedCPU)
        allocatedMemoryMB = max(0, allocatedMemoryMB - requestedMemory)
    }

    /// Get current resource usage
    public func getCurrentUsage() -> ResourceUsage {
        let totalMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let cpuCount = ProcessInfo.processInfo.processorCount

        return ResourceUsage(
            cpuUsagePercent: Double(allocatedCPU) / Double(cpuCount) * 100.0,
            memoryUsedMB: allocatedMemoryMB,
            memoryTotalMB: totalMemoryMB,
            gpuUsagePercent: nil
        )
    }
}

public enum AllocationError: Error {
    case insufficientResources
}
