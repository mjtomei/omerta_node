import Foundation
import OmertaCore

/// Priority levels for jobs in the queue
public enum JobPriority: Int, Comparable, Sendable {
    case owner = 100        // Jobs from the machine owner (highest priority)
    case network = 50       // Jobs from network peers (normal priority)
    case external = 10      // Jobs from outside trusted networks (lowest priority)

    public static func < (lhs: JobPriority, rhs: JobPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Represents a queued job with metadata
public struct QueuedJob: Sendable, Identifiable {
    public let id: UUID
    public let job: ComputeJob
    public let priority: JobPriority
    public let queuedAt: Date
    public let estimatedDurationSeconds: UInt64?

    public init(
        id: UUID = UUID(),
        job: ComputeJob,
        priority: JobPriority,
        queuedAt: Date = Date(),
        estimatedDurationSeconds: UInt64? = nil
    ) {
        self.id = id
        self.job = job
        self.priority = priority
        self.queuedAt = queuedAt
        self.estimatedDurationSeconds = estimatedDurationSeconds
    }
}

/// Actor managing the job queue with priority scheduling
public actor JobQueue {

    // MARK: - State

    private var pendingJobs: [QueuedJob] = []
    private var runningJobs: [UUID: QueuedJob] = [:]
    private var completedJobs: [UUID: (job: QueuedJob, result: Result<ExecutionResult, Error>)] = [:]

    private var maxConcurrentJobs: Int
    private var isPaused: Bool = false

    // MARK: - Statistics

    private var totalJobsQueued: Int = 0
    private var totalJobsCompleted: Int = 0
    private var totalJobsFailed: Int = 0
    private var totalJobsCancelled: Int = 0

    // MARK: - Callbacks

    /// Called when a job should start executing
    public var onJobReady: ((QueuedJob) async throws -> ExecutionResult)?

    /// Called when queue state changes
    public var onQueueStateChanged: ((QueueState) async -> Void)?

    // MARK: - Initialization

    public init(maxConcurrentJobs: Int = 1) {
        self.maxConcurrentJobs = maxConcurrentJobs
    }

    // MARK: - Callback Configuration

    /// Set the job ready callback
    public func setJobReadyCallback(_ callback: @escaping (QueuedJob) async throws -> ExecutionResult) {
        self.onJobReady = callback
    }

    /// Set the queue state changed callback
    public func setQueueStateChangedCallback(_ callback: @escaping (QueueState) async -> Void) {
        self.onQueueStateChanged = callback
    }

    // MARK: - Queue Management

    /// Enqueue a new job
    public func enqueue(_ job: ComputeJob, priority: JobPriority) async -> UUID {
        let queuedJob = QueuedJob(
            job: job,
            priority: priority,
            estimatedDurationSeconds: job.requirements.maxRuntimeSeconds
        )

        pendingJobs.append(queuedJob)
        sortQueue()

        totalJobsQueued += 1

        await notifyStateChanged()

        // Try to process queue immediately
        await processQueue()

        return queuedJob.id
    }

    /// Start processing the queue (if not paused and capacity available)
    public func processQueue() async {
        guard !isPaused else { return }

        while runningJobs.count < maxConcurrentJobs, let nextJob = dequeueNext() {
            await startJob(nextJob)
        }
    }

    /// Dequeue the highest priority job
    private func dequeueNext() -> QueuedJob? {
        guard !pendingJobs.isEmpty else { return nil }
        return pendingJobs.removeFirst()
    }

    /// Sort the queue by priority (highest first) then by queue time (oldest first)
    private func sortQueue() {
        pendingJobs.sort { job1, job2 in
            if job1.priority != job2.priority {
                return job1.priority > job2.priority  // Higher priority first
            }
            return job1.queuedAt < job2.queuedAt  // Older first
        }
    }

    // MARK: - Job Execution

    /// Start executing a job
    private func startJob(_ queuedJob: QueuedJob) async {
        runningJobs[queuedJob.id] = queuedJob
        await notifyStateChanged()

        // Execute the job asynchronously
        Task {
            do {
                guard let onJobReady = self.onJobReady else {
                    throw JobQueueError.noExecutorConfigured
                }

                let result = try await onJobReady(queuedJob)
                await self.completeJob(queuedJob.id, result: .success(result))
            } catch {
                await self.completeJob(queuedJob.id, result: .failure(error))
            }
        }
    }

    /// Mark a job as completed
    private func completeJob(_ jobId: UUID, result: Result<ExecutionResult, Error>) async {
        guard let queuedJob = runningJobs.removeValue(forKey: jobId) else {
            return
        }

        completedJobs[jobId] = (job: queuedJob, result: result)

        switch result {
        case .success:
            totalJobsCompleted += 1
        case .failure:
            totalJobsFailed += 1
        }

        await notifyStateChanged()

        // Process next job if available
        await processQueue()
    }

    /// Cancel a job (remove from queue or terminate if running)
    public func cancelJob(_ jobId: UUID) async -> Bool {
        // Check if job is pending
        if let index = pendingJobs.firstIndex(where: { $0.id == jobId }) {
            let cancelledJob = pendingJobs.remove(at: index)
            completedJobs[jobId] = (
                job: cancelledJob,
                result: .failure(JobQueueError.cancelled)
            )
            totalJobsCancelled += 1
            await notifyStateChanged()
            return true
        }

        // Check if job is running
        if runningJobs[jobId] != nil {
            // Mark for cancellation - actual termination handled by executor
            // The executor will call completeJob with cancellation error
            return true
        }

        return false
    }

    /// Cancel all pending jobs
    public func cancelAllPending() async -> Int {
        let count = pendingJobs.count

        for job in pendingJobs {
            completedJobs[job.id] = (
                job: job,
                result: .failure(JobQueueError.cancelled)
            )
        }

        pendingJobs.removeAll()
        totalJobsCancelled += count

        await notifyStateChanged()

        return count
    }

    // MARK: - Queue Control

    /// Pause the queue (stop accepting new jobs to execution)
    public func pause() async {
        isPaused = true
        await notifyStateChanged()
    }

    /// Resume the queue
    public func resume() async {
        isPaused = false
        await notifyStateChanged()
        await processQueue()
    }

    /// Set maximum concurrent jobs
    public func setMaxConcurrentJobs(_ max: Int) async {
        maxConcurrentJobs = max
        await processQueue()  // May allow more jobs to start
    }

    // MARK: - Query

    /// Get current queue state
    public func getState() -> QueueState {
        QueueState(
            pendingCount: pendingJobs.count,
            runningCount: runningJobs.count,
            completedCount: completedJobs.count,
            isPaused: isPaused,
            maxConcurrentJobs: maxConcurrentJobs,
            pendingJobs: pendingJobs,
            runningJobs: Array(runningJobs.values),
            statistics: QueueStatistics(
                totalQueued: totalJobsQueued,
                totalCompleted: totalJobsCompleted,
                totalFailed: totalJobsFailed,
                totalCancelled: totalJobsCancelled
            )
        )
    }

    /// Get job status
    public func getJobStatus(_ jobId: UUID) -> JobStatus? {
        if pendingJobs.contains(where: { $0.id == jobId }) {
            return .queued
        }
        if runningJobs[jobId] != nil {
            return .running
        }
        if let completion = completedJobs[jobId] {
            switch completion.result {
            case .success(let result):
                return result.exitCode == 0 ? .completed : .failed
            case .failure(let error):
                if error is JobQueueError, case .cancelled = error as! JobQueueError {
                    return .cancelled
                }
                return .failed
            }
        }
        return nil
    }

    /// Get detailed job information
    public func getJobInfo(_ jobId: UUID) -> (job: QueuedJob, result: Result<ExecutionResult, Error>?)? {
        if let pending = pendingJobs.first(where: { $0.id == jobId }) {
            return (job: pending, result: nil)
        }
        if let running = runningJobs[jobId] {
            return (job: running, result: nil)
        }
        if let completed = completedJobs[jobId] {
            return (job: completed.job, result: completed.result)
        }
        return nil
    }

    /// Get pending jobs ordered by priority
    public func getPendingJobs() -> [QueuedJob] {
        pendingJobs
    }

    /// Get running jobs
    public func getRunningJobs() -> [QueuedJob] {
        Array(runningJobs.values)
    }

    /// Clear completed job history
    public func clearCompleted() async {
        completedJobs.removeAll()
        await notifyStateChanged()
    }

    // MARK: - Notifications

    private func notifyStateChanged() async {
        let state = getState()
        await onQueueStateChanged?(state)
    }
}

// MARK: - Supporting Types

/// Snapshot of queue state
public struct QueueState: Sendable {
    public let pendingCount: Int
    public let runningCount: Int
    public let completedCount: Int
    public let isPaused: Bool
    public let maxConcurrentJobs: Int
    public let pendingJobs: [QueuedJob]
    public let runningJobs: [QueuedJob]
    public let statistics: QueueStatistics
}

/// Queue statistics
public struct QueueStatistics: Sendable {
    public let totalQueued: Int
    public let totalCompleted: Int
    public let totalFailed: Int
    public let totalCancelled: Int

    public var successRate: Double {
        let total = totalCompleted + totalFailed
        guard total > 0 else { return 0 }
        return Double(totalCompleted) / Double(total)
    }
}

/// Job queue errors
public enum JobQueueError: Error, CustomStringConvertible {
    case noExecutorConfigured
    case cancelled
    case queueFull
    case jobNotFound

    public var description: String {
        switch self {
        case .noExecutorConfigured:
            return "No job executor configured"
        case .cancelled:
            return "Job was cancelled"
        case .queueFull:
            return "Job queue is full"
        case .jobNotFound:
            return "Job not found in queue"
        }
    }
}
