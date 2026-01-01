import Foundation
import Logging
import OmertaCore
import OmertaVM
import OmertaNetwork
import protocol OmertaNetwork.JobSubmissionHandler

/// The main provider daemon that manages compute job execution
public actor ProviderDaemon {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let port: Int
        public let maxConcurrentJobs: Int
        public let ownerPeerId: String?
        public let trustedNetworks: [String]
        public let enableActivityLogging: Bool
        public let resultsStoragePath: String?

        public init(
            port: Int = 50051,
            maxConcurrentJobs: Int = 1,
            ownerPeerId: String? = nil,
            trustedNetworks: [String] = [],
            enableActivityLogging: Bool = true,
            resultsStoragePath: String? = nil
        ) {
            self.port = port
            self.maxConcurrentJobs = maxConcurrentJobs
            self.ownerPeerId = ownerPeerId
            self.trustedNetworks = trustedNetworks
            self.enableActivityLogging = enableActivityLogging
            self.resultsStoragePath = resultsStoragePath
        }
    }

    // MARK: - State

    private let config: Configuration
    private let logger: Logger

    private let jobQueue: JobQueue
    private let filterManager: FilterManager
    private let vmManager: VirtualizationManager
    private let vpnManager: VPNManager
    private let rogueDetector: RogueConnectionDetector
    private let activityLogger: ActivityLogger?

    private var isRunning: Bool = false
    private var startedAt: Date?

    // Statistics
    private var totalJobsReceived: Int = 0
    private var totalJobsFiltered: Int = 0

    // MARK: - Initialization

    public init(config: Configuration) {
        self.config = config

        // Set up logging
        var logger = Logger(label: "com.omerta.provider")
        logger.logLevel = .info
        self.logger = logger

        // Initialize components
        self.jobQueue = JobQueue(maxConcurrentJobs: config.maxConcurrentJobs)
        self.filterManager = FilterManager(
            ownerPeerId: config.ownerPeerId,
            trustedNetworks: config.trustedNetworks
        )
        self.vmManager = VirtualizationManager()
        self.vpnManager = VPNManager()
        self.rogueDetector = RogueConnectionDetector()

        // Set up activity logger if enabled
        if config.enableActivityLogging {
            self.activityLogger = ActivityLogger(logger: logger)
        } else {
            self.activityLogger = nil
        }
    }

    // MARK: - Lifecycle

    /// Start the provider daemon
    public func start() async throws {
        guard !isRunning else {
            logger.warning("Provider daemon already running")
            return
        }

        logger.info("Starting Omerta Provider Daemon")
        logger.info("Port: \(config.port)")
        logger.info("Max concurrent jobs: \(config.maxConcurrentJobs)")

        // Set up job queue callback
        await jobQueue.setJobReadyCallback { [weak self] queuedJob in
            guard let self = self else {
                throw ProviderError.daemonShutdown
            }
            return try await self.executeJob(queuedJob)
        }

        // Set up queue state change monitoring
        await jobQueue.setQueueStateChangedCallback { [weak self] state in
            await self?.handleQueueStateChange(state)
        }

        // Add default filter rules
        await addDefaultFilterRules()

        isRunning = true
        startedAt = Date()

        logger.info("✅ Provider daemon started successfully")
        logger.info("Ready to accept compute requests")
    }

    /// Stop the provider daemon
    public func stop() async throws {
        guard isRunning else {
            logger.warning("Provider daemon not running")
            return
        }

        logger.info("Stopping Omerta Provider Daemon")

        // Pause queue to stop accepting new jobs
        await jobQueue.pause()

        // Wait for running jobs to complete (with timeout)
        let timeout = 30.0  // seconds
        let startTime = Date()

        while true {
            let state = await jobQueue.getState()
            if state.runningCount == 0 {
                break
            }

            if Date().timeIntervalSince(startTime) > timeout {
                logger.warning("Timeout waiting for jobs to complete, forcing shutdown")
                break
            }

            try await Task.sleep(for: .seconds(1))
        }

        // Cancel any remaining pending jobs
        let cancelled = await jobQueue.cancelAllPending()
        if cancelled > 0 {
            logger.info("Cancelled \(cancelled) pending jobs")
        }

        isRunning = false
        startedAt = nil

        logger.info("✅ Provider daemon stopped")
    }

    /// Get daemon status
    public func getStatus() async -> DaemonStatus {
        let queueState = await jobQueue.getState()
        let filterStats = await filterManager.getStatistics()

        return DaemonStatus(
            isRunning: isRunning,
            startedAt: startedAt,
            port: config.port,
            queueState: queueState,
            filterStats: filterStats,
            totalJobsReceived: totalJobsReceived,
            totalJobsFiltered: totalJobsFiltered
        )
    }

    // MARK: - Job Submission

    /// Submit a new compute job (main entry point)
    public func submitJob(_ job: ComputeJob) async throws -> UUID {
        guard isRunning else {
            throw ProviderError.daemonNotRunning
        }

        totalJobsReceived += 1

        logger.info("Received job request from \(job.requesterId)")
        logger.info("Network: \(job.networkId)")
        if let description = job.activityDescription {
            logger.info("Activity: \(description)")
        }

        // Log activity if enabled
        await activityLogger?.logJobReceived(job)

        // Filter the request
        let filterRequest = FilterRequest(from: job)
        let decision = await filterManager.evaluate(filterRequest)

        switch decision {
        case .accept(let priority):
            logger.info("✅ Job accepted with priority: \(priority)")
            let queuedJobId = await jobQueue.enqueue(job, priority: priority)
            await activityLogger?.logJobAccepted(job, priority: priority)
            return queuedJobId

        case .reject(let reason):
            totalJobsFiltered += 1
            logger.warning("❌ Job rejected: \(reason)")
            await activityLogger?.logJobRejected(job, reason: reason)
            throw ProviderError.jobRejected(reason: reason)

        case .requiresApproval(let reason):
            totalJobsFiltered += 1
            logger.warning("⏸ Job requires approval: \(reason)")
            await activityLogger?.logJobPendingApproval(job, reason: reason)
            throw ProviderError.jobRequiresApproval(reason: reason)
        }
    }

    /// Cancel a job
    public func cancelJob(_ jobId: UUID) async throws {
        let success = await jobQueue.cancelJob(jobId)
        if !success {
            throw ProviderError.jobNotFound
        }
        logger.info("Cancelled job \(jobId)")
    }

    /// Get job status
    public func getJobStatus(_ jobId: UUID) async -> JobStatus? {
        await jobQueue.getJobStatus(jobId)
    }

    // MARK: - Private: Job Execution

    private func executeJob(_ queuedJob: QueuedJob) async throws -> ExecutionResult {
        let job = queuedJob.job

        logger.info("🚀 Starting job execution: \(queuedJob.id)")
        logger.info("   Requester: \(job.requesterId)")
        logger.info("   CPU: \(job.requirements.cpuCores) cores")
        logger.info("   Memory: \(job.requirements.memoryMB) MB")

        // Log job start
        await activityLogger?.logJobStarted(queuedJob)

        let startTime = Date()

        do {
            // Check dependencies before running
            let checker = DependencyChecker()
            try await checker.verifyProviderMode()

            // Execute job via VM manager
            let result = try await vmManager.executeJob(job)

            let duration = Date().timeIntervalSince(startTime)
            logger.info("✅ Job completed successfully in \(String(format: "%.2f", duration))s")
            logger.info("   Exit code: \(result.exitCode)")
            logger.info("   Execution time: \(result.metrics.executionTimeMs)ms")

            // Log job completion
            await activityLogger?.logJobCompleted(queuedJob, result: result)

            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            logger.error("❌ Job failed after \(String(format: "%.2f", duration))s: \(error)")

            // Log job failure
            await activityLogger?.logJobFailed(queuedJob, error: error)

            throw error
        }
    }

    // MARK: - Private: Filter Rules

    private func addDefaultFilterRules() async {
        // Add resource limit rule
        let resourceRule = ResourceLimitRule(
            maxCpuCores: 8,
            maxMemoryMB: 16384,
            maxRuntimeSeconds: 3600
        )
        await filterManager.addRule(resourceRule)

        // Add quiet hours rule (10 PM - 8 AM)
        let quietHoursRule = QuietHoursRule(
            startHour: 22,
            endHour: 8,
            action: .requireApproval
        )
        await filterManager.addRule(quietHoursRule)

        logger.info("Added default filter rules")
    }

    // MARK: - Private: Event Handlers

    private func handleQueueStateChange(_ state: QueueState) async {
        logger.debug("Queue state: \(state.pendingCount) pending, \(state.runningCount) running, \(state.completedCount) completed")
    }

    // MARK: - Configuration Management

    /// Add a trusted network
    public func addTrustedNetwork(_ networkId: String) async {
        await filterManager.addTrustedNetwork(networkId)
        logger.info("Added trusted network: \(networkId)")
    }

    /// Remove a trusted network
    public func removeTrustedNetwork(_ networkId: String) async {
        await filterManager.removeTrustedNetwork(networkId)
        logger.info("Removed trusted network: \(networkId)")
    }

    /// Block a peer
    public func blockPeer(_ peerId: String) async {
        await filterManager.blockPeer(peerId)
        logger.info("Blocked peer: \(peerId)")
    }

    /// Unblock a peer
    public func unblockPeer(_ peerId: String) async {
        await filterManager.unblockPeer(peerId)
        logger.info("Unblocked peer: \(peerId)")
    }

    /// Pause accepting new jobs
    public func pause() async {
        await jobQueue.pause()
        logger.info("Paused job acceptance")
    }

    /// Resume accepting new jobs
    public func resume() async {
        await jobQueue.resume()
        logger.info("Resumed job acceptance")
    }
}

// MARK: - Supporting Types

/// Provider daemon status
public struct DaemonStatus: Sendable {
    public let isRunning: Bool
    public let startedAt: Date?
    public let port: Int
    public let queueState: QueueState
    public let filterStats: FilterStatistics
    public let totalJobsReceived: Int
    public let totalJobsFiltered: Int

    public var uptime: TimeInterval? {
        guard let startedAt = startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }
}

/// Provider errors
public enum ProviderError: Error, CustomStringConvertible {
    case daemonNotRunning
    case daemonShutdown
    case jobRejected(reason: String)
    case jobRequiresApproval(reason: String)
    case jobNotFound
    case configurationError(String)

    public var description: String {
        switch self {
        case .daemonNotRunning:
            return "Provider daemon is not running"
        case .daemonShutdown:
            return "Provider daemon has shut down"
        case .jobRejected(let reason):
            return "Job rejected: \(reason)"
        case .jobRequiresApproval(let reason):
            return "Job requires manual approval: \(reason)"
        case .jobNotFound:
            return "Job not found"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        }
    }
}

// MARK: - Activity Logger

/// Logs job activities for audit trail
public actor ActivityLogger {
    private let logger: Logger
    private var logEntries: [ActivityLogEntry] = []

    init(logger: Logger) {
        self.logger = logger
    }

    func logJobReceived(_ job: ComputeJob) async {
        let entry = ActivityLogEntry(
            timestamp: Date(),
            jobId: job.id,
            requesterId: job.requesterId,
            networkId: job.networkId,
            activityDescription: job.activityDescription,
            event: "received"
        )
        logEntries.append(entry)
        logger.info("📥 Job received: \(job.id)")
    }

    func logJobAccepted(_ job: ComputeJob, priority: JobPriority) async {
        let entry = ActivityLogEntry(
            timestamp: Date(),
            jobId: job.id,
            requesterId: job.requesterId,
            networkId: job.networkId,
            activityDescription: job.activityDescription,
            event: "accepted",
            details: "priority: \(priority)"
        )
        logEntries.append(entry)
    }

    func logJobRejected(_ job: ComputeJob, reason: String) async {
        let entry = ActivityLogEntry(
            timestamp: Date(),
            jobId: job.id,
            requesterId: job.requesterId,
            networkId: job.networkId,
            activityDescription: job.activityDescription,
            event: "rejected",
            details: reason
        )
        logEntries.append(entry)
    }

    func logJobPendingApproval(_ job: ComputeJob, reason: String) async {
        let entry = ActivityLogEntry(
            timestamp: Date(),
            jobId: job.id,
            requesterId: job.requesterId,
            networkId: job.networkId,
            activityDescription: job.activityDescription,
            event: "pending_approval",
            details: reason
        )
        logEntries.append(entry)
    }

    func logJobStarted(_ queuedJob: QueuedJob) async {
        let entry = ActivityLogEntry(
            timestamp: Date(),
            jobId: queuedJob.job.id,
            requesterId: queuedJob.job.requesterId,
            networkId: queuedJob.job.networkId,
            activityDescription: queuedJob.job.activityDescription,
            event: "started"
        )
        logEntries.append(entry)
    }

    func logJobCompleted(_ queuedJob: QueuedJob, result: ExecutionResult) async {
        let entry = ActivityLogEntry(
            timestamp: Date(),
            jobId: queuedJob.job.id,
            requesterId: queuedJob.job.requesterId,
            networkId: queuedJob.job.networkId,
            activityDescription: queuedJob.job.activityDescription,
            event: "completed",
            details: "exit_code: \(result.exitCode), time: \(result.metrics.executionTimeMs)ms"
        )
        logEntries.append(entry)
    }

    func logJobFailed(_ queuedJob: QueuedJob, error: Error) async {
        let entry = ActivityLogEntry(
            timestamp: Date(),
            jobId: queuedJob.job.id,
            requesterId: queuedJob.job.requesterId,
            networkId: queuedJob.job.networkId,
            activityDescription: queuedJob.job.activityDescription,
            event: "failed",
            details: error.localizedDescription
        )
        logEntries.append(entry)
    }

    func getLogEntries() -> [ActivityLogEntry] {
        logEntries
    }
}

/// Activity log entry
public struct ActivityLogEntry: Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let jobId: UUID
    public let requesterId: String
    public let networkId: String
    public let activityDescription: String?
    public let event: String
    public let details: String?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        jobId: UUID,
        requesterId: String,
        networkId: String,
        activityDescription: String?,
        event: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.jobId = jobId
        self.requesterId = requesterId
        self.networkId = networkId
        self.activityDescription = activityDescription
        self.event = event
        self.details = details
    }
}

// MARK: - JobSubmissionHandler Protocol Conformance

extension ProviderDaemon: JobSubmissionHandler {
    /// Handle a job submission from the gRPC service
    public func handleJobSubmission(_ job: ComputeJob) async throws -> ExecutionResult {
        // Submit job and wait for execution result
        _ = try await submitJob(job)

        // Poll for completion (simplified for MVP)
        // In production, this would use async callbacks or streams
        while true {
            if let status = await getJobStatus(job.id) {
                switch status {
                case .completed:
                    // Get result from completed jobs
                    let state = await jobQueue.getState()
                    if let completed = state.completedJobs[job.id] {
                        switch completed.result {
                        case .success(let result):
                            return result
                        case .failure(let error):
                            throw error
                        }
                    }
                    throw ProviderError.jobNotFound

                case .failed:
                    throw ProviderError.jobNotFound

                case .cancelled:
                    throw ProviderError.jobNotFound

                default:
                    // Still running or pending, wait
                    try await Task.sleep(for: .milliseconds(500))
                }
            } else {
                throw ProviderError.jobNotFound
            }
        }
    }

    /// Handle a job cancellation from the gRPC service
    public func handleJobCancellation(_ jobId: UUID) async throws {
        try await cancelJob(jobId)
    }

    /// Query job status from the gRPC service
    public func handleJobStatusQuery(_ jobId: UUID) async -> JobStatus? {
        await getJobStatus(jobId)
    }
}
