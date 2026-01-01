import XCTest
@testable import OmertaCore

final class JobTests: XCTestCase {
    
    func testScriptWorkload() {
        let script = ScriptWorkload(
            language: "python",
            scriptContent: "print('Hello World')",
            dependencies: ["numpy", "pandas"],
            environment: ["DEBUG": "true"]
        )
        
        XCTAssertEqual(script.language, "python")
        XCTAssertTrue(script.scriptContent.contains("Hello World"))
        XCTAssertEqual(script.dependencies.count, 2)
        XCTAssertEqual(script.environment["DEBUG"], "true")
    }
    
    func testBinaryWorkload() {
        let binary = BinaryWorkload(
            binaryURL: "http://10.0.0.1:8000/app",
            binaryHash: "abc123",
            arguments: ["--verbose", "--port=8080"],
            environment: ["ENV": "prod"]
        )
        
        XCTAssertEqual(binary.binaryURL, "http://10.0.0.1:8000/app")
        XCTAssertEqual(binary.binaryHash, "abc123")
        XCTAssertEqual(binary.arguments.count, 2)
        XCTAssertEqual(binary.environment["ENV"], "prod")
    }
    
    func testComputeJob() {
        let requirements = ResourceRequirements(
            cpuCores: 2,
            memoryMB: 4096
        )
        
        let vpnConfig = VPNConfiguration(
            wireguardConfig: "[Interface]...",
            endpoint: "10.0.0.1:51820",
            publicKey: Data([1, 2, 3, 4]),
            vpnServerIP: "10.0.0.1"
        )
        
        let script = ScriptWorkload(
            language: "bash",
            scriptContent: "echo test"
        )
        
        let job = ComputeJob(
            requesterId: "peer-123",
            networkId: "network-456",
            requirements: requirements,
            workload: .script(script),
            activityDescription: "Test job",
            vpnConfig: vpnConfig
        )
        
        XCTAssertEqual(job.requesterId, "peer-123")
        XCTAssertEqual(job.networkId, "network-456")
        XCTAssertEqual(job.activityDescription, "Test job")
        XCTAssertNotNil(job.id)
        
        // Test workload type
        if case .script(let s) = job.workload {
            XCTAssertEqual(s.language, "bash")
        } else {
            XCTFail("Expected script workload")
        }
    }
    
    func testExecutionResult() {
        let metrics = ExecutionMetrics(
            executionTimeMs: 5000,
            cpuTimeMs: 4500,
            memoryPeakMB: 2048,
            networkEgressBytes: 1024,
            networkIngressBytes: 512
        )
        
        let result = ExecutionResult(
            exitCode: 0,
            stdout: "Success".data(using: .utf8)!,
            stderr: Data(),
            metrics: metrics
        )
        
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "Success")
        XCTAssertEqual(result.metrics.executionTimeMs, 5000)
        XCTAssertEqual(result.metrics.memoryPeakMB, 2048)
    }
    
    func testJobStatus() {
        XCTAssertEqual(JobStatus.queued.rawValue, "queued")
        XCTAssertEqual(JobStatus.running.rawValue, "running")
        XCTAssertEqual(JobStatus.completed.rawValue, "completed")
        XCTAssertEqual(JobStatus.failed.rawValue, "failed")
        XCTAssertEqual(JobStatus.cancelled.rawValue, "cancelled")
    }
}
