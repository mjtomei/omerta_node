import Foundation
import Logging
import OmertaCore

/// gRPC service provider for compute requests
/// Simplified implementation without full gRPC streaming for MVP
public actor ComputeServiceProvider {

    private let logger: Logger
    private weak var jobSubmissionHandler: JobSubmissionHandler?

    public init() {
        var logger = Logger(label: "com.omerta.network.compute-service")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Set the handler for job submissions
    public func setJobSubmissionHandler(_ handler: JobSubmissionHandler?) {
        self.jobSubmissionHandler = handler
    }

    // MARK: - ComputeService RPC Methods

    /// Submit a compute job
    public func submitJob(request: ComputeRequest) async -> ComputeResponse {
        logger.info("Received job submission request: \(request.requestId)")
        logger.info("  Requester: \(request.metadata.peerId)")
        logger.info("  Network: \(request.metadata.networkId)")

        guard let handler = jobSubmissionHandler else {
            logger.error("No job submission handler configured")
            return ComputeResponse.error(
                ServiceError.notConfigured,
                requestId: request.requestId
            )
        }

        do {
            // Convert proto request to domain model
            let job = request.toComputeJob()

            // Submit to handler (ProviderDaemon)
            let result = try await handler.handleJobSubmission(job)

            // Convert result to proto response
            return ComputeResponse.from(result, requestId: request.requestId)

        } catch {
            logger.warning("Job rejected or failed: \(error)")

            // Check for rejection/approval errors by description
            let errorDesc = error.localizedDescription
            if errorDesc.contains("rejected") {
                return ComputeResponse.rejected(errorDesc, requestId: request.requestId)
            } else if errorDesc.contains("approval") {
                return ComputeResponse.rejected(errorDesc, requestId: request.requestId)
            }

            // General error
            return ComputeResponse.error(error, requestId: request.requestId)
        }
    }

    /// Cancel a running job
    public func cancelJob(request: CancelJobRequest) async -> CancelJobResponse {
        logger.info("Received job cancellation request: \(request.jobId)")

        guard let handler = jobSubmissionHandler else {
            return CancelJobResponse(
                cancelled: false,
                message: "Service not configured"
            )
        }

        do {
            guard let jobId = UUID(uuidString: request.jobId) else {
                return CancelJobResponse(
                    cancelled: false,
                    message: "Invalid job ID format"
                )
            }

            try await handler.handleJobCancellation(jobId)

            return CancelJobResponse(
                cancelled: true,
                message: "Job cancelled successfully"
            )

        } catch {
            logger.error("Job cancellation failed: \(error)")
            return CancelJobResponse(
                cancelled: false,
                message: error.localizedDescription
            )
        }
    }

    /// Get job status (simplified - no streaming for MVP)
    public func getJobStatus(request: JobStatusRequest) async -> JobStatusUpdate {
        logger.debug("Received job status request: \(request.jobId)")

        guard let handler = jobSubmissionHandler else {
            return JobStatusUpdate(
                jobId: request.jobId,
                status: .failed,
                message: "Service not configured",
                progressPercent: 0
            )
        }

        guard let jobId = UUID(uuidString: request.jobId) else {
            return JobStatusUpdate(
                jobId: request.jobId,
                status: .failed,
                message: "Invalid job ID format",
                progressPercent: 0
            )
        }

        let status = await handler.handleJobStatusQuery(jobId)

        return JobStatusUpdate(
            jobId: request.jobId,
            status: Proto_JobStatus.from(status ?? .failed),
            message: status != nil ? "Job is \(status!)" : "Job not found",
            progressPercent: status == .completed ? 100 : (status == .running ? 50 : 0)
        )
    }
}

// MARK: - Job Submission Handler Protocol

/// Protocol for handling job submissions from the gRPC service
/// Implemented by ProviderDaemon
public protocol JobSubmissionHandler: Actor {
    /// Handle a job submission and return the execution result
    func handleJobSubmission(_ job: ComputeJob) async throws -> ExecutionResult

    /// Handle a job cancellation
    func handleJobCancellation(_ jobId: UUID) async throws

    /// Query job status
    func handleJobStatusQuery(_ jobId: UUID) async -> JobStatus?
}

// MARK: - Service Errors

public enum ServiceError: Error, CustomStringConvertible {
    case notConfigured
    case invalidRequest(String)
    case networkError(String)

    public var description: String {
        switch self {
        case .notConfigured:
            return "Service not properly configured"
        case .invalidRequest(let details):
            return "Invalid request: \(details)"
        case .networkError(let details):
            return "Network error: \(details)"
        }
    }
}
