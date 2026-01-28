import XCTest
@testable import OmertaVM
@testable import OmertaCore

final class ResourceAllocatorTests: XCTestCase {

    // MARK: - Helpers

    /// Skip test if system doesn't have enough resources for VM allocation tests.
    /// The ResourceAllocator reserves 2 CPUs and 4GB RAM for the host system.
    private func skipIfInsufficientResources(cpuNeeded: Int = 4, memoryMBNeeded: UInt64 = 8192) throws {
        let cpuCount = ProcessInfo.processInfo.processorCount
        let memoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)

        if cpuCount < cpuNeeded {
            throw XCTSkip("System has \(cpuCount) CPUs, need at least \(cpuNeeded) for this test (allocator reserves 2 for host)")
        }
        if memoryMB < memoryMBNeeded {
            throw XCTSkip("System has \(memoryMB)MB RAM, need at least \(memoryMBNeeded)MB for this test (allocator reserves 4GB for host)")
        }
    }

    // MARK: - Tests

    func testCanAllocateWithAvailableResources() async throws {
        // This test requires enough system resources to allocate 2 CPUs + 2GB RAM
        // after reserving 2 CPUs + 4GB for host (so need at least 4 CPUs, 6GB RAM)
        try skipIfInsufficientResources(cpuNeeded: 4, memoryMBNeeded: 6144)

        let allocator = ResourceAllocator()

        let requirements = ResourceRequirements(
            cpuCores: 2,
            memoryMB: 2048
        )

        let canAllocate = await allocator.canAllocate(requirements)
        XCTAssertTrue(canAllocate, "Should be able to allocate small resources")
    }

    func testCannotAllocateExcessiveResources() async {
        let allocator = ResourceAllocator()

        // Request more CPUs than physically possible
        let cpuCount = UInt32(ProcessInfo.processInfo.processorCount)
        let requirements = ResourceRequirements(
            cpuCores: cpuCount + 10,  // More than available
            memoryMB: 2048
        )

        let canAllocate = await allocator.canAllocate(requirements)
        XCTAssertFalse(canAllocate, "Should not be able to allocate excessive CPUs")
    }

    func testAllocateAndRelease() async throws {
        // This test requires enough resources to allocate 2 CPUs + 4GB RAM
        try skipIfInsufficientResources(cpuNeeded: 4, memoryMBNeeded: 8192)

        let allocator = ResourceAllocator()

        let requirements = ResourceRequirements(
            cpuCores: 2,
            memoryMB: 4096
        )

        // Allocate
        try await allocator.allocate(requirements)

        // Check usage increased
        let usage = await allocator.getCurrentUsage()
        XCTAssertGreaterThan(usage.cpuUsagePercent, 0)
        XCTAssertGreaterThan(usage.memoryUsedMB, 0)

        // Release
        await allocator.release(requirements)

        // Check usage decreased
        let usageAfter = await allocator.getCurrentUsage()
        XCTAssertEqual(usageAfter.memoryUsedMB, 0)
    }

    func testMultipleAllocations() async throws {
        // This test requires enough resources to allocate 2 CPUs + 2GB RAM
        try skipIfInsufficientResources(cpuNeeded: 4, memoryMBNeeded: 6144)

        let allocator = ResourceAllocator()

        let req1 = ResourceRequirements(cpuCores: 1, memoryMB: 1024)
        let req2 = ResourceRequirements(cpuCores: 1, memoryMB: 1024)

        try await allocator.allocate(req1)
        try await allocator.allocate(req2)

        let usage = await allocator.getCurrentUsage()
        XCTAssertGreaterThan(usage.memoryUsedMB, 2000)

        await allocator.release(req1)
        await allocator.release(req2)

        let finalUsage = await allocator.getCurrentUsage()
        XCTAssertEqual(finalUsage.memoryUsedMB, 0)
    }

    func testInsufficientResourcesError() async {
        let allocator = ResourceAllocator()

        // Try to allocate impossible amount
        let physicalMemory = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let requirements = ResourceRequirements(
            cpuCores: 1,
            memoryMB: physicalMemory + 100000  // Way more than available
        )

        do {
            try await allocator.allocate(requirements)
            XCTFail("Should have thrown error for insufficient resources")
        } catch {
            // Expected error
            XCTAssertTrue(error is AllocationError)
        }
    }

    func testGetCurrentUsage() async {
        let allocator = ResourceAllocator()

        let usage = await allocator.getCurrentUsage()

        XCTAssertGreaterThanOrEqual(usage.cpuUsagePercent, 0)
        XCTAssertGreaterThan(usage.memoryTotalMB, 0)
        XCTAssertGreaterThanOrEqual(usage.memoryUsedMB, 0)
        XCTAssertLessThanOrEqual(usage.memoryUsedMB, usage.memoryTotalMB)
    }
}
