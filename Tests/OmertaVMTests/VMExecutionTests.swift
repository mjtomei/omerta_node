import XCTest
@testable import OmertaVM
@testable import OmertaCore

final class VMExecutionTests: XCTestCase {
    
    // This test requires Linux kernel to be set up
    // Run: ./Scripts/setup-vm-kernel.sh first
    func testSimpleEchoExecution() async throws {
        let manager = VirtualizationManager()
        
        let script = ScriptWorkload(
            language: "sh",
            scriptContent: "echo 'Hello from Omerta VM'"
        )
        
        let requirements = ResourceRequirements(
            cpuCores: 1,
            memoryMB: 512,
            maxRuntimeSeconds: 30
        )
        
        let vpnConfig = VPNConfiguration(
            wireguardConfig: "[Interface]...",
            endpoint: "10.0.0.1:51820",
            publicKey: Data([1, 2, 3]),
            vpnServerIP: "10.0.0.1"
        )
        
        let job = ComputeJob(
            requesterId: "test-peer",
            networkId: "test-network",
            requirements: requirements,
            workload: .script(script),
            vpnConfig: vpnConfig
        )
        
        let result = try await manager.executeJob(job)
        
        XCTAssertEqual(result.exitCode, 0, "Job should complete successfully")
        
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("Hello from Omerta VM"), "Output should contain our message")
        
        XCTAssertGreaterThan(result.metrics.executionTimeMs, 0)
    }
    
    func testExitCode() async throws {
        let manager = VirtualizationManager()
        
        let script = ScriptWorkload(
            language: "sh",
            scriptContent: "exit 42"
        )
        
        let requirements = ResourceRequirements(
            cpuCores: 1,
            memoryMB: 512,
            maxRuntimeSeconds: 30
        )
        
        let vpnConfig = VPNConfiguration(
            wireguardConfig: "[Interface]...",
            endpoint: "10.0.0.1:51820",
            publicKey: Data([1, 2, 3]),
            vpnServerIP: "10.0.0.1"
        )
        
        let job = ComputeJob(
            requesterId: "test-peer",
            networkId: "test-network",
            requirements: requirements,
            workload: .script(script),
            vpnConfig: vpnConfig
        )
        
        let result = try await manager.executeJob(job)
        
        XCTAssertEqual(result.exitCode, 42, "Should capture correct exit code")
    }
}
