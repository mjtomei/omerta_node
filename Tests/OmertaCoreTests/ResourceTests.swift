import XCTest
@testable import OmertaCore

final class ResourceTests: XCTestCase {
    
    func testResourceRequirements() {
        let requirements = ResourceRequirements(
            type: .cpuOnly,
            cpuCores: 4,
            memoryMB: 8192,
            maxRuntimeSeconds: 3600
        )
        
        XCTAssertEqual(requirements.type, .cpuOnly)
        XCTAssertEqual(requirements.cpuCores, 4)
        XCTAssertEqual(requirements.memoryMB, 8192)
        XCTAssertNil(requirements.gpu)
    }
    
    func testGPURequirements() {
        let gpuReq = GPURequirements(
            vramMB: 16384,
            requiredCapabilities: ["metal3", "neural-engine"],
            metalOnly: true
        )
        
        let requirements = ResourceRequirements(
            type: .gpuRequired,
            cpuCores: 8,
            memoryMB: 32768,
            gpu: gpuReq
        )
        
        XCTAssertEqual(requirements.type, .gpuRequired)
        XCTAssertNotNil(requirements.gpu)
        XCTAssertEqual(requirements.gpu?.vramMB, 16384)
        XCTAssertEqual(requirements.gpu?.requiredCapabilities.count, 2)
        XCTAssertTrue(requirements.gpu?.metalOnly ?? false)
    }
    
    func testResourceCapability() {
        let capability = ResourceCapability(
            type: .cpuOnly,
            availableCpuCores: 8,
            availableMemoryMB: 32768,
            hasGPU: false,
            supportedWorkloadTypes: ["script", "binary"]
        )
        
        XCTAssertEqual(capability.availableCpuCores, 8)
        XCTAssertEqual(capability.availableMemoryMB, 32768)
        XCTAssertFalse(capability.hasGPU)
        XCTAssertEqual(capability.supportedWorkloadTypes.count, 2)
    }
    
    func testResourceUsage() {
        let usage = ResourceUsage(
            cpuUsagePercent: 75.5,
            memoryUsedMB: 16384,
            memoryTotalMB: 32768,
            gpuUsagePercent: nil
        )
        
        XCTAssertEqual(usage.cpuUsagePercent, 75.5)
        XCTAssertEqual(usage.memoryUsedMB, 16384)
        XCTAssertEqual(usage.memoryTotalMB, 32768)
        XCTAssertNil(usage.gpuUsagePercent)
    }
}
