import XCTest
@testable import OmertaNetwork
@testable import OmertaCore
import Foundation

final class ConverterTests: XCTestCase {

    // MARK: - ComputeJob <-> ComputeRequest Conversion Tests

    func testComputeJobToRequestConversion() throws {
        let job = ComputeJob(
            requesterId: "requester-123",
            networkId: "network-abc",
            requirements: ResourceRequirements(
                type: .cpuOnly,
                cpuCores: 4,
                memoryMB: 8192,
                gpu: nil,
                maxRuntimeSeconds: 3600
            ),
            workload: .script(ScriptWorkload(
                language: "python",
                scriptContent: "print('hello')",
                dependencies: ["numpy"],
                environment: ["PATH": "/usr/bin"]
            )),
            vpnConfig: VPNConfiguration(
                wireguardConfig: "[Interface]...",
                endpoint: "192.168.1.100:51820",
                publicKey: Data([1, 2, 3]),
                vpnServerIP: "10.0.0.1"
            )
        )

        // Convert to proto
        let request = ComputeRequest.from(job, requesterId: "requester-123", networkId: "network-abc")

        // Verify conversion
        XCTAssertEqual(request.requestId, job.id.uuidString)
        XCTAssertEqual(request.metadata.peerId, "requester-123")
        XCTAssertEqual(request.metadata.networkId, "network-abc")
        XCTAssertEqual(request.requirements.cpuCores, 4)
        XCTAssertEqual(request.requirements.memoryMb, 8192)
        XCTAssertEqual(request.vpn.endpoint, "192.168.1.100:51820")
        XCTAssertEqual(request.vpn.vpnServerIp, "10.0.0.1")
    }

    func testComputeRequestToJobConversion() throws {
        let request = ComputeRequest(
            requestId: UUID().uuidString,
            metadata: RequestMetadata(
                peerId: "peer-456",
                networkId: "network-xyz",
                timestamp: UInt64(Date().timeIntervalSince1970),
                clientVersion: "0.4.0"
            ),
            requirements: Proto_ResourceRequirements(
                type: .cpuOnly,
                cpuCores: 8,
                memoryMb: 16384,
                gpu: nil,
                maxRuntimeSeconds: 7200
            ),
            workload: .script(ScriptWorkload(
                language: "bash",
                scriptContent: "echo 'test'",
                dependencies: [],
                env: [:]
            )),
            activityDescription: "Test job",
            signature: Data(),
            vpn: Proto_VPNConfiguration(
                wireguardConfig: "[Interface]...",
                endpoint: "10.0.0.1:51820",
                publicKey: Data([4, 5, 6]),
                allowedIps: "0.0.0.0/0",
                vpnServerIp: "10.0.0.1"
            )
        )

        // Convert to domain
        let job = request.toComputeJob()

        XCTAssertEqual(job.requesterId, "peer-456")
        XCTAssertEqual(job.networkId, "network-xyz")
        XCTAssertEqual(job.requirements.cpuCores, 8)
        XCTAssertEqual(job.requirements.memoryMB, 16384)
        XCTAssertEqual(job.vpnConfig.endpoint, "10.0.0.1:51820")
        XCTAssertEqual(job.vpnConfig.vpnServerIP, "10.0.0.1")

        // Check workload
        if case .script(let script) = job.workload {
            XCTAssertEqual(script.language, "bash")
            XCTAssertEqual(script.scriptContent, "echo 'test'")
        } else {
            XCTFail("Expected script workload")
        }
    }

    func testComputeJobRoundTripConversion() throws {
        let originalJob = ComputeJob(
            requesterId: "requester-999",
            networkId: "network-test",
            requirements: ResourceRequirements(
                type: .gpuRequired,
                cpuCores: 16,
                memoryMB: 32768,
                gpu: GPURequirements(
                    vramMB: 16384,
                    requiredCapabilities: ["Metal"],
                    metalOnly: true
                ),
                maxRuntimeSeconds: 1800
            ),
            workload: .binary(BinaryWorkload(
                binaryURL: "https://example.com/binary",
                binaryHash: "abc123",
                arguments: ["--flag", "value"],
                environment: ["VAR": "value"]
            )),
            vpnConfig: VPNConfiguration(
                wireguardConfig: "[Interface]...",
                endpoint: "192.168.1.1:51820",
                publicKey: Data([7, 8, 9]),
                vpnServerIP: "10.0.0.1"
            )
        )

        // Convert to proto and back
        let request = ComputeRequest.from(originalJob, requesterId: "requester-999", networkId: "network-test")
        let convertedJob = request.toComputeJob()

        // Verify fields match
        XCTAssertEqual(convertedJob.requesterId, originalJob.requesterId)
        XCTAssertEqual(convertedJob.networkId, originalJob.networkId)
        XCTAssertEqual(convertedJob.requirements.cpuCores, originalJob.requirements.cpuCores)
        XCTAssertEqual(convertedJob.requirements.memoryMB, originalJob.requirements.memoryMB)
        XCTAssertEqual(convertedJob.vpnConfig.endpoint, originalJob.vpnConfig.endpoint)

        // Check workload type
        if case .binary(let binary) = convertedJob.workload {
            XCTAssertEqual(binary.binaryURL, "https://example.com/binary")
            XCTAssertEqual(binary.binaryHash, "abc123")
            XCTAssertEqual(binary.arguments, ["--flag", "value"])
        } else {
            XCTFail("Expected binary workload")
        }
    }

    // MARK: - ResourceRequirements Conversion Tests

    func testResourceRequirementsConversion() {
        let domainRequirements = ResourceRequirements(
            type: .cpuOnly,
            cpuCores: 4,
            memoryMB: 8192,
            gpu: nil,
            maxRuntimeSeconds: 3600
        )

        let protoRequirements = Proto_ResourceRequirements.from(domainRequirements)

        XCTAssertEqual(protoRequirements.cpuCores, 4)
        XCTAssertEqual(protoRequirements.memoryMb, 8192)
        XCTAssertEqual(protoRequirements.maxRuntimeSeconds, 3600)
        XCTAssertNil(protoRequirements.gpu)
    }

    func testResourceRequirementsWithGPU() {
        let domainRequirements = ResourceRequirements(
            type: .gpuRequired,
            cpuCores: 8,
            memoryMB: 16384,
            gpu: GPURequirements(
                vramMB: 8192,
                requiredCapabilities: ["Metal", "Compute"],
                metalOnly: true
            ),
            maxRuntimeSeconds: 7200
        )

        let protoRequirements = Proto_ResourceRequirements.from(domainRequirements)

        XCTAssertEqual(protoRequirements.cpuCores, 8)
        XCTAssertEqual(protoRequirements.memoryMb, 16384)
        XCTAssertNotNil(protoRequirements.gpu)
        XCTAssertEqual(protoRequirements.gpu?.vramMb, 8192)
        XCTAssertEqual(protoRequirements.gpu?.requiredCapabilities, ["Metal", "Compute"])
        XCTAssertTrue(protoRequirements.gpu?.metalOnly ?? false)
    }

    func testResourceTypeConversion() {
        // Test all resource type conversions
        let cpuOnly = ResourceRequirements(type: .cpuOnly, cpuCores: 1, memoryMB: 1024, gpu: nil, maxRuntimeSeconds: 60)
        let gpuRequired = ResourceRequirements(type: .gpuRequired, cpuCores: 1, memoryMB: 1024, gpu: nil, maxRuntimeSeconds: 60)
        let gpuPreferred = ResourceRequirements(type: .gpuPreferred, cpuCores: 1, memoryMB: 1024, gpu: nil, maxRuntimeSeconds: 60)

        let protoCpuOnly = Proto_ResourceRequirements.from(cpuOnly)
        let protoGpuRequired = Proto_ResourceRequirements.from(gpuRequired)
        let protoGpuPreferred = Proto_ResourceRequirements.from(gpuPreferred)

        XCTAssertEqual(protoCpuOnly.type, .cpuOnly)
        XCTAssertEqual(protoGpuRequired.type, .gpuRequired)
        XCTAssertEqual(protoGpuPreferred.type, .gpuPreferred)
    }

    // MARK: - VPNConfiguration Conversion Tests

    func testVPNConfigurationConversion() {
        let domainVPN = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=...",
            endpoint: "192.168.1.100:51820",
            publicKey: Data([1, 2, 3, 4, 5]),
            vpnServerIP: "10.0.0.1"
        )

        let protoVPN = Proto_VPNConfiguration.from(domainVPN)

        XCTAssertEqual(protoVPN.wireguardConfig, "[Interface]\nPrivateKey=...")
        XCTAssertEqual(protoVPN.endpoint, "192.168.1.100:51820")
        XCTAssertEqual(protoVPN.publicKey, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(protoVPN.vpnServerIp, "10.0.0.1")
        XCTAssertEqual(protoVPN.allowedIps, "0.0.0.0/0")
    }

    func testVPNConfigurationRoundTrip() {
        let originalVPN = VPNConfiguration(
            wireguardConfig: "[Interface]\nAddress=10.0.0.2/24",
            endpoint: "10.20.30.40:51820",
            publicKey: Data([10, 20, 30, 40, 50]),
            vpnServerIP: "10.0.0.1"
        )

        let protoVPN = Proto_VPNConfiguration.from(originalVPN)
        let convertedVPN = protoVPN.toVPNConfiguration()

        XCTAssertEqual(convertedVPN.wireguardConfig, originalVPN.wireguardConfig)
        XCTAssertEqual(convertedVPN.endpoint, originalVPN.endpoint)
        XCTAssertEqual(convertedVPN.publicKey, originalVPN.publicKey)
        XCTAssertEqual(convertedVPN.vpnServerIP, originalVPN.vpnServerIP)
    }

    // MARK: - WorkloadSpec Conversion Tests

    func testScriptWorkloadConversion() {
        let domainScript = ScriptWorkload(
            language: "python",
            scriptContent: "import sys\nprint('hello')",
            dependencies: ["numpy", "pandas"],
            environment: ["PYTHONPATH": "/usr/lib/python3"]
        )

        let protoScript = ScriptWorkload(
            language: "python",
            scriptContent: "import sys\nprint('hello')",
            dependencies: ["numpy", "pandas"],
            env: ["PYTHONPATH": "/usr/lib/python3"]
        )

        let protoWorkload = WorkloadSpec.script(protoScript)
        let convertedWorkload = protoWorkload.toWorkload()

        if case .script(let converted) = convertedWorkload {
            XCTAssertEqual(converted.language, "python")
            XCTAssertEqual(converted.scriptContent, "import sys\nprint('hello')")
            XCTAssertEqual(converted.dependencies, ["numpy", "pandas"])
            XCTAssertEqual(converted.environment["PYTHONPATH"], "/usr/lib/python3")
        } else {
            XCTFail("Expected script workload")
        }
    }

    func testBinaryWorkloadConversion() {
        let domainBinary = BinaryWorkload(
            binaryURL: "https://example.com/app",
            binaryHash: "sha256:abc123",
            arguments: ["--input", "file.txt", "--output", "result.txt"],
            environment: ["HOME": "/home/user"]
        )

        let protoBinary = BinaryWorkload(
            binaryUrl: "https://example.com/app",
            binaryHash: "sha256:abc123",
            args: ["--input", "file.txt", "--output", "result.txt"],
            env: ["HOME": "/home/user"]
        )

        let protoWorkload = WorkloadSpec.binary(protoBinary)
        let convertedWorkload = protoWorkload.toWorkload()

        if case .binary(let converted) = convertedWorkload {
            XCTAssertEqual(converted.binaryURL, "https://example.com/app")
            XCTAssertEqual(converted.binaryHash, "sha256:abc123")
            XCTAssertEqual(converted.arguments, ["--input", "file.txt", "--output", "result.txt"])
            XCTAssertEqual(converted.environment["HOME"], "/home/user")
        } else {
            XCTFail("Expected binary workload")
        }
    }

    func testWorkloadSpecRoundTrip() {
        // Test script workload round trip
        let originalScript = OmertaCore.ScriptWorkload(
            language: "bash",
            scriptContent: "#!/bin/bash\necho test",
            dependencies: [],
            environment: [:]
        )

        let protoScript = WorkloadSpec.from(.script(originalScript))
        let convertedScript = protoScript.toWorkload()

        if case .script(let script) = convertedScript {
            XCTAssertEqual(script.language, "bash")
            XCTAssertEqual(script.scriptContent, "#!/bin/bash\necho test")
        } else {
            XCTFail("Expected script workload")
        }

        // Test binary workload round trip
        let originalBinary = OmertaCore.BinaryWorkload(
            binaryURL: "https://example.com/binary",
            binaryHash: "hash123",
            arguments: ["arg1", "arg2"],
            environment: ["KEY": "VALUE"]
        )

        let protoBinary = WorkloadSpec.from(.binary(originalBinary))
        let convertedBinary = protoBinary.toWorkload()

        if case .binary(let binary) = convertedBinary {
            XCTAssertEqual(binary.binaryURL, "https://example.com/binary")
            XCTAssertEqual(binary.binaryHash, "hash123")
            XCTAssertEqual(binary.arguments, ["arg1", "arg2"])
            XCTAssertEqual(binary.environment["KEY"], "VALUE")
        } else {
            XCTFail("Expected binary workload")
        }
    }

    // MARK: - ExecutionResult -> ComputeResponse Conversion Tests

    func testSuccessfulExecutionResultConversion() {
        let result = ExecutionResult(
            exitCode: 0,
            stdout: Data("Success output".utf8),
            stderr: Data(),
            metrics: ExecutionMetrics(
                executionTimeMs: 1234,
                cpuTimeMs: 1000,
                memoryPeakMB: 512,
                networkEgressBytes: 1024,
                networkIngressBytes: 2048
            )
        )

        let response = ComputeResponse.from(result, requestId: "test-request-123")

        XCTAssertEqual(response.requestId, "test-request-123")
        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(response.result?.exitCode, 0)
        XCTAssertEqual(response.result?.stdout, Data("Success output".utf8))
        XCTAssertEqual(response.metrics?.executionTimeMs, 1234)
        XCTAssertEqual(response.metrics?.cpuTimeMs, 1000)
        XCTAssertEqual(response.metrics?.memoryPeakMb, 512)
    }

    func testFailedExecutionResultConversion() {
        let result = ExecutionResult(
            exitCode: 1,
            stdout: Data(),
            stderr: Data("Error message".utf8),
            metrics: ExecutionMetrics(
                executionTimeMs: 500,
                cpuTimeMs: 400,
                memoryPeakMB: 256,
                networkEgressBytes: 0,
                networkIngressBytes: 0
            )
        )

        let response = ComputeResponse.from(result, requestId: "test-request-456")

        XCTAssertEqual(response.requestId, "test-request-456")
        XCTAssertEqual(response.status, .failure)
        XCTAssertEqual(response.result?.exitCode, 1)
        XCTAssertEqual(response.result?.stderr, Data("Error message".utf8))
    }

    func testErrorResponseCreation() {
        enum TestError: Error {
            case testFailure
        }

        let response = ComputeResponse.error(TestError.testFailure, requestId: "error-request")

        XCTAssertEqual(response.requestId, "error-request")
        XCTAssertEqual(response.status, .failure)
        // Error message should contain something (actual format varies)
        XCTAssertFalse(response.message.isEmpty)
    }

    func testRejectedResponseCreation() {
        let response = ComputeResponse.rejected("Insufficient resources", requestId: "reject-request")

        XCTAssertEqual(response.requestId, "reject-request")
        XCTAssertEqual(response.status, .rejected)
        XCTAssertEqual(response.message, "Insufficient resources")
    }

    // Note: .timeout and .rogueConnectionDetected response helpers are not yet implemented
    // They are defined as enum cases in ResponseStatus but no convenience constructors exist yet

    // MARK: - JobStatus Conversion Tests

    func testJobStatusConversion() {
        let queuedProto = Proto_JobStatus.queued
        let runningProto = Proto_JobStatus.running
        let completedProto = Proto_JobStatus.completed
        let failedProto = Proto_JobStatus.failed
        let cancelledProto = Proto_JobStatus.cancelled

        let queuedDomain = queuedProto.toJobStatus()
        let runningDomain = runningProto.toJobStatus()
        let completedDomain = completedProto.toJobStatus()
        let failedDomain = failedProto.toJobStatus()
        let cancelledDomain = cancelledProto.toJobStatus()

        XCTAssertEqual(queuedDomain, .queued)
        XCTAssertEqual(runningDomain, .running)
        XCTAssertEqual(completedDomain, .completed)
        XCTAssertEqual(failedDomain, .failed)
        XCTAssertEqual(cancelledDomain, .cancelled)
    }

    func testJobStatusReverseConversion() {
        let queuedDomain = JobStatus.queued
        let runningDomain = JobStatus.running
        let completedDomain = JobStatus.completed
        let failedDomain = JobStatus.failed
        let cancelledDomain = JobStatus.cancelled

        let queuedProto = Proto_JobStatus.from(queuedDomain)
        let runningProto = Proto_JobStatus.from(runningDomain)
        let completedProto = Proto_JobStatus.from(completedDomain)
        let failedProto = Proto_JobStatus.from(failedDomain)
        let cancelledProto = Proto_JobStatus.from(cancelledDomain)

        XCTAssertEqual(queuedProto, .queued)
        XCTAssertEqual(runningProto, .running)
        XCTAssertEqual(completedProto, .completed)
        XCTAssertEqual(failedProto, .failed)
        XCTAssertEqual(cancelledProto, .cancelled)
    }

    // MARK: - Metrics Conversion Tests

    func testExecutionMetricsConversion() {
        let domainMetrics = ExecutionMetrics(
            executionTimeMs: 5000,
            cpuTimeMs: 4500,
            memoryPeakMB: 1024,
            networkEgressBytes: 1048576,
            networkIngressBytes: 2097152
        )

        let protoMetrics = Proto_ExecutionMetrics.from(domainMetrics)

        XCTAssertEqual(protoMetrics.executionTimeMs, 5000)
        XCTAssertEqual(protoMetrics.cpuTimeMs, 4500)
        XCTAssertEqual(protoMetrics.memoryPeakMb, 1024)
        XCTAssertEqual(protoMetrics.networkEgressBytes, 1048576)
        XCTAssertEqual(protoMetrics.networkIngressBytes, 2097152)
    }

    // MARK: - Edge Cases

    func testEmptyWorkloadConversion() {
        let emptyScript = OmertaCore.ScriptWorkload(
            language: "python",
            scriptContent: "",
            dependencies: [],
            environment: [:]
        )

        let protoWorkload = WorkloadSpec.from(.script(emptyScript))
        let converted = protoWorkload.toWorkload()

        if case .script(let script) = converted {
            XCTAssertEqual(script.scriptContent, "")
            XCTAssertEqual(script.dependencies, [])
            XCTAssertEqual(script.environment, [:])
        } else {
            XCTFail("Expected script workload")
        }
    }

    func testLargeDataConversion() {
        // Test with large stdout/stderr data
        let largeData = Data(repeating: 0x42, count: 1024 * 1024) // 1MB

        let result = ExecutionResult(
            exitCode: 0,
            stdout: largeData,
            stderr: Data(),
            metrics: ExecutionMetrics(
                executionTimeMs: 1000,
                cpuTimeMs: 900,
                memoryPeakMB: 2048,
                networkEgressBytes: 0,
                networkIngressBytes: 0
            )
        )

        let response = ComputeResponse.from(result, requestId: "large-data")

        XCTAssertEqual(response.result?.stdout.count, 1024 * 1024)
    }
}
