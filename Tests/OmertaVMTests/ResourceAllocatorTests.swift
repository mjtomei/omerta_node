import XCTest
@testable import OmertaVM
@testable import OmertaCore

final class ResourceAllocatorTests: XCTestCase {
    
    func testCanAllocateWithAvailableResources() async {
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
