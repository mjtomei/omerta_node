import XCTest
@testable import OmertaCore

final class ResourceTests: XCTestCase {

    func testResourceRequirementsMinimal() {
        // Default requirements - no specific constraints
        let requirements = ResourceRequirements()

        XCTAssertNil(requirements.cpuCores)
        XCTAssertNil(requirements.cpuArchitecture)
        XCTAssertNil(requirements.memoryMB)
        XCTAssertNil(requirements.gpu)
    }

    func testResourceRequirementsWithCPU() {
        let requirements = ResourceRequirements(
            cpuCores: 4,
            cpuArchitecture: .arm64,
            memoryMB: 8192
        )

        XCTAssertEqual(requirements.cpuCores, 4)
        XCTAssertEqual(requirements.cpuArchitecture, .arm64)
        XCTAssertEqual(requirements.memoryMB, 8192)
        XCTAssertNil(requirements.gpu)
    }

    func testGPURequirements() {
        let gpuReq = GPURequirements(
            model: "RTX 4090",
            vramMB: 16384,
            vendor: .nvidia
        )

        let requirements = ResourceRequirements(
            cpuCores: 8,
            memoryMB: 32768,
            gpu: gpuReq
        )

        XCTAssertNotNil(requirements.gpu)
        XCTAssertEqual(requirements.gpu?.vramMB, 16384)
        XCTAssertEqual(requirements.gpu?.vendor, .nvidia)
    }

    func testResourceCapability() {
        let capability = ResourceCapability(
            cpuCores: 8,
            cpuArchitecture: .arm64,
            cpuModel: "Apple M1 Max",
            totalMemoryMB: 65536,
            availableMemoryMB: 32768,
            totalStorageMB: 500000,
            availableStorageMB: 250000,
            gpu: nil,
            networkBandwidthMbps: 1000,
            availableImages: ["ubuntu-22.04", "alpine-3.18"]
        )

        XCTAssertEqual(capability.cpuCores, 8)
        XCTAssertEqual(capability.cpuArchitecture, .arm64)
        XCTAssertEqual(capability.availableMemoryMB, 32768)
        XCTAssertNil(capability.gpu)
        XCTAssertEqual(capability.availableImages.count, 2)
    }

    func testCPUArchitecture() {
        // Test architecture detection/comparison
        XCTAssertEqual(CPUArchitecture.arm64.rawValue, "arm64")
        XCTAssertEqual(CPUArchitecture.x86_64.rawValue, "x86_64")

        // Different architectures should not be equal
        XCTAssertNotEqual(CPUArchitecture.arm64, CPUArchitecture.x86_64)
    }

    func testGPUVendors() {
        XCTAssertEqual(GPUVendor.nvidia.rawValue, "nvidia")
        XCTAssertEqual(GPUVendor.amd.rawValue, "amd")
        XCTAssertEqual(GPUVendor.apple.rawValue, "apple")
        XCTAssertEqual(GPUVendor.intel.rawValue, "intel")
    }
}
