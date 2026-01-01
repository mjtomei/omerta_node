import Foundation
import OmertaCore

// MARK: - Converters between Domain Models and Proto Messages

extension ComputeRequest {
    /// Convert from domain ComputeJob to proto ComputeRequest
    public static func from(_ job: ComputeJob, requesterId: String, networkId: String) -> ComputeRequest {
        ComputeRequest(
            requestId: job.id.uuidString,
            metadata: RequestMetadata(
                peerId: requesterId,
                networkId: networkId,
                timestamp: UInt64(Date().timeIntervalSince1970),
                clientVersion: "0.4.0"
            ),
            requirements: Proto_ResourceRequirements.from(job.requirements),
            workload: WorkloadSpec.from(job.workload),
            activityDescription: job.activityDescription ?? "",
            signature: Data(), // TODO: Implement signing
            vpn: Proto_VPNConfiguration.from(job.vpnConfig)
        )
    }

    /// Convert from proto ComputeRequest to domain ComputeJob
    public func toComputeJob() -> ComputeJob {
        ComputeJob(
            id: UUID(uuidString: requestId) ?? UUID(),
            requesterId: metadata.peerId,
            networkId: metadata.networkId,
            requirements: requirements.toResourceRequirements(),
            workload: workload.toWorkload(),
            activityDescription: activityDescription.isEmpty ? nil : activityDescription,
            vpnConfig: vpn.toVPNConfiguration()
        )
    }
}

extension Proto_ResourceRequirements {
    /// Convert from domain ResourceRequirements to proto
    public static func from(_ requirements: ResourceRequirements) -> Proto_ResourceRequirements {
        Proto_ResourceRequirements(
            type: ResourceType(rawValue: requirements.type.rawValue) ?? .cpuOnly,
            cpuCores: requirements.cpuCores,
            memoryMb: requirements.memoryMB,
            gpu: requirements.gpu.map { GpuRequirements.from($0) },
            maxRuntimeSeconds: requirements.maxRuntimeSeconds
        )
    }

    /// Convert from proto to domain ResourceRequirements
    public func toResourceRequirements() -> ResourceRequirements {
        ResourceRequirements(
            type: .init(rawValue: type.rawValue) ?? .cpuOnly,
            cpuCores: cpuCores,
            memoryMB: memoryMb,
            gpu: gpu.map { $0.toGPURequirements() },
            maxRuntimeSeconds: maxRuntimeSeconds
        )
    }
}

extension GpuRequirements {
    /// Convert from domain GPURequirements to proto
    public static func from(_ gpu: GPURequirements) -> GpuRequirements {
        GpuRequirements(
            vramMb: gpu.vramMB,
            requiredCapabilities: gpu.requiredCapabilities,
            metalOnly: gpu.metalOnly
        )
    }

    /// Convert from proto to domain GPURequirements
    public func toGPURequirements() -> GPURequirements {
        GPURequirements(
            vramMB: vramMb,
            requiredCapabilities: requiredCapabilities,
            metalOnly: metalOnly
        )
    }
}

extension WorkloadSpec {
    /// Convert from domain Workload to proto WorkloadSpec
    public static func from(_ workload: Workload) -> WorkloadSpec {
        switch workload {
        case .script(let script):
            return .script(ScriptWorkload(
                language: script.language,
                scriptContent: script.scriptContent,
                dependencies: script.dependencies,
                env: script.env
            ))
        case .binary(let binary):
            return .binary(BinaryWorkload(
                binaryUrl: binary.binaryURL,
                binaryHash: binary.binaryHash,
                args: binary.args,
                env: binary.env
            ))
        }
    }

    /// Convert from proto WorkloadSpec to domain Workload
    public func toWorkload() -> Workload {
        switch self {
        case .script(let script):
            return .script(OmertaCore.ScriptWorkload(
                language: script.language,
                scriptContent: script.scriptContent,
                dependencies: script.dependencies,
                env: script.env
            ))
        case .binary(let binary):
            return .binary(OmertaCore.BinaryWorkload(
                binaryURL: binary.binaryUrl,
                binaryHash: binary.binaryHash,
                args: binary.args,
                env: binary.env
            ))
        }
    }
}

extension Proto_VPNConfiguration {
    /// Convert from domain VPNConfiguration to proto
    public static func from(_ vpn: VPNConfiguration) -> Proto_VPNConfiguration {
        Proto_VPNConfiguration(
            wireguardConfig: vpn.wireguardConfig,
            endpoint: vpn.endpoint,
            publicKey: vpn.publicKey,
            allowedIps: "0.0.0.0/0",
            vpnServerIp: vpn.vpnServerIP
        )
    }

    /// Convert from proto to domain VPNConfiguration
    public func toVPNConfiguration() -> VPNConfiguration {
        VPNConfiguration(
            wireguardConfig: wireguardConfig,
            endpoint: endpoint,
            publicKey: publicKey,
            vpnServerIP: vpnServerIp
        )
    }
}

extension ComputeResponse {
    /// Convert from domain ExecutionResult to proto ComputeResponse
    public static func from(_ result: ExecutionResult, requestId: String) -> ComputeResponse {
        ComputeResponse(
            requestId: requestId,
            status: .success,
            result: Proto_ExecutionResult(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            ),
            metrics: Proto_ExecutionMetrics.from(result.metrics),
            logs: [],
            message: "Job completed successfully"
        )
    }

    /// Create error response
    public static func error(_ error: Error, requestId: String) -> ComputeResponse {
        ComputeResponse(
            requestId: requestId,
            status: .failure,
            result: nil,
            metrics: nil,
            logs: [],
            message: error.localizedDescription
        )
    }

    /// Create rejected response
    public static func rejected(_ reason: String, requestId: String) -> ComputeResponse {
        ComputeResponse(
            requestId: requestId,
            status: .rejected,
            result: nil,
            metrics: nil,
            logs: [],
            message: reason
        )
    }
}

extension Proto_ExecutionMetrics {
    /// Convert from domain ExecutionMetrics to proto
    public static func from(_ metrics: ExecutionMetrics) -> Proto_ExecutionMetrics {
        Proto_ExecutionMetrics(
            executionTimeMs: metrics.executionTimeMs,
            cpuTimeMs: metrics.cpuTimeMs,
            memoryPeakMb: metrics.memoryPeakMB,
            networkEgressBytes: metrics.networkEgressBytes,
            networkIngressBytes: metrics.networkIngressBytes
        )
    }
}

extension Proto_JobStatus {
    /// Convert from domain JobStatus to proto
    public static func from(_ status: JobStatus) -> Proto_JobStatus {
        switch status {
        case .pending: return .queued
        case .running: return .running
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }
}

extension PeerAnnouncement {
    /// Create from local peer information
    public static func local(
        peerId: String,
        networkId: String,
        endpoint: String,
        capabilities: [ResourceCapability]
    ) -> PeerAnnouncement {
        PeerAnnouncement(
            peerId: peerId,
            networkId: networkId,
            capabilities: capabilities,
            metadata: PeerMetadata(
                reputationScore: 100,
                jobsCompleted: 0,
                jobsRejected: 0,
                averageResponseTimeMs: 0.0
            ),
            timestamp: UInt64(Date().timeIntervalSince1970),
            signature: Data(), // TODO: Implement signing
            endpoint: endpoint
        )
    }
}
