import XCTest
@testable import OmertaProvider
@testable import OmertaCore

final class JobQueueTests: XCTestCase {

    func testEnqueueAndDequeue() async throws {
        let queue = JobQueue(maxConcurrentJobs: 1)
        let job = createTestJob()

        var executedJob: QueuedJob?
        await queue.setJobReadyCallback { queuedJob in
            executedJob = queuedJob
            return ExecutionResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data(),
                metrics: ExecutionMetrics(
                    executionTimeMs: 1000,
                    cpuTimeMs: 900,
                    memoryPeakMB: 512,
                    networkEgressBytes: 0,
                    networkIngressBytes: 0
                )
            )
        }

        let jobId = await queue.enqueue(job, priority: .network)

        // Give it time to process
        try await Task.sleep(for: .milliseconds(100))

        let state = await queue.getState()
        XCTAssertEqual(state.statistics.totalQueued, 1)
        XCTAssertNotNil(executedJob)
        XCTAssertEqual(executedJob?.job.id, job.id)
    }

    func testPriorityOrdering() async throws {
        let queue = JobQueue(maxConcurrentJobs: 1)

        // Pause the queue to enqueue all jobs before any execution
        await queue.pause()

        var executionOrder: [JobPriority] = []

        await queue.setJobReadyCallback { queuedJob in
            executionOrder.append(queuedJob.priority)
            // Sleep to ensure sequential execution
            try await Task.sleep(for: .milliseconds(10))
            return ExecutionResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data(),
                metrics: ExecutionMetrics(
                    executionTimeMs: 10,
                    cpuTimeMs: 9,
                    memoryPeakMB: 256,
                    networkEgressBytes: 0,
                    networkIngressBytes: 0
                )
            )
        }

        // Enqueue jobs in reverse priority order while paused
        _ = await queue.enqueue(createTestJob(), priority: .external)
        _ = await queue.enqueue(createTestJob(), priority: .network)
        _ = await queue.enqueue(createTestJob(), priority: .owner)

        // Resume queue - jobs should now execute in priority order
        await queue.resume()

        // Wait for all jobs to complete
        try await Task.sleep(for: .milliseconds(200))

        // Should execute in priority order: owner > network > external
        XCTAssertEqual(executionOrder.count, 3)
        XCTAssertEqual(executionOrder[0], .owner)
        XCTAssertEqual(executionOrder[1], .network)
        XCTAssertEqual(executionOrder[2], .external)
    }

    func testConcurrentJobLimit() async throws {
        let queue = JobQueue(maxConcurrentJobs: 2)

        var concurrentCount = 0
        var maxConcurrent = 0

        await queue.setJobReadyCallback { queuedJob in
            concurrentCount += 1
            maxConcurrent = max(maxConcurrent, concurrentCount)

            // Simulate work
            try await Task.sleep(for: .milliseconds(100))

            concurrentCount -= 1

            return ExecutionResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data(),
                metrics: ExecutionMetrics(
                    executionTimeMs: 100,
                    cpuTimeMs: 90,
                    memoryPeakMB: 256,
                    networkEgressBytes: 0,
                    networkIngressBytes: 0
                )
            )
        }

        // Enqueue 5 jobs
        for _ in 0..<5 {
            _ = await queue.enqueue(createTestJob(), priority: .network)
        }

        // Wait for all to complete
        try await Task.sleep(for: .milliseconds(600))

        // Max concurrent should not exceed 2
        XCTAssertLessThanOrEqual(maxConcurrent, 2)
        XCTAssertGreaterThan(maxConcurrent, 0)
    }

    func testJobCancellation() async throws {
        let queue = JobQueue(maxConcurrentJobs: 1)

        await queue.setJobReadyCallback { queuedJob in
            // Long running job
            try await Task.sleep(for: .seconds(10))
            return ExecutionResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data(),
                metrics: ExecutionMetrics(
                    executionTimeMs: 10000,
                    cpuTimeMs: 9000,
                    memoryPeakMB: 512,
                    networkEgressBytes: 0,
                    networkIngressBytes: 0
                )
            )
        }

        _ = await queue.enqueue(createTestJob(), priority: .network)
        let job2 = await queue.enqueue(createTestJob(), priority: .network)

        // Cancel the second job while it's pending
        let cancelled = await queue.cancelJob(job2)
        XCTAssertTrue(cancelled)

        let status = await queue.getJobStatus(job2)
        XCTAssertEqual(status, .cancelled)
    }

    func testPauseAndResume() async throws {
        let queue = JobQueue(maxConcurrentJobs: 1)

        var executedCount = 0
        await queue.setJobReadyCallback { queuedJob in
            executedCount += 1
            return ExecutionResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data(),
                metrics: ExecutionMetrics(
                    executionTimeMs: 10,
                    cpuTimeMs: 9,
                    memoryPeakMB: 256,
                    networkEgressBytes: 0,
                    networkIngressBytes: 0
                )
            )
        }

        // Pause queue before enqueueing
        await queue.pause()

        _ = await queue.enqueue(createTestJob(), priority: .network)
        _ = await queue.enqueue(createTestJob(), priority: .network)

        // Give it time
        try await Task.sleep(for: .milliseconds(100))

        // Should not have executed any jobs
        XCTAssertEqual(executedCount, 0)

        // Resume and check
        await queue.resume()
        try await Task.sleep(for: .milliseconds(100))

        // Should now execute jobs
        XCTAssertGreaterThan(executedCount, 0)
    }

    func testQueueStatistics() async throws {
        let queue = JobQueue(maxConcurrentJobs: 2)

        await queue.setJobReadyCallback { queuedJob in
            return ExecutionResult(
                exitCode: 0,
                stdout: Data(),
                stderr: Data(),
                metrics: ExecutionMetrics(
                    executionTimeMs: 10,
                    cpuTimeMs: 9,
                    memoryPeakMB: 256,
                    networkEgressBytes: 0,
                    networkIngressBytes: 0
                )
            )
        }

        // Enqueue 3 jobs
        _ = await queue.enqueue(createTestJob(), priority: .network)
        _ = await queue.enqueue(createTestJob(), priority: .network)
        _ = await queue.enqueue(createTestJob(), priority: .network)

        // Wait for completion
        try await Task.sleep(for: .milliseconds(200))

        let state = await queue.getState()
        XCTAssertEqual(state.statistics.totalQueued, 3)
        XCTAssertEqual(state.statistics.totalCompleted, 3)
        XCTAssertEqual(state.statistics.totalFailed, 0)
        XCTAssertEqual(state.statistics.successRate, 1.0)
    }

    // MARK: - Helpers

    private func createTestJob() -> ComputeJob {
        ComputeJob(
            requesterId: "test-requester",
            networkId: "test-network",
            requirements: ResourceRequirements(
                type: .cpuOnly,
                cpuCores: 1,
                memoryMB: 512
            ),
            workload: .script(ScriptWorkload(
                language: "bash",
                scriptContent: "echo test"
            )),
            vpnConfig: VPNConfiguration(
                wireguardConfig: "[Interface]...",
                endpoint: "10.0.0.1:51820",
                publicKey: Data([1, 2, 3]),
                vpnServerIP: "10.0.0.1"
            )
        )
    }
}
