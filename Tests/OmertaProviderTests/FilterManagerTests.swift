import XCTest
@testable import OmertaProvider
@testable import OmertaCore

final class FilterManagerTests: XCTestCase {

    func testOwnerPeerGetsPriority() async throws {
        let ownerPeer = "owner-123"
        let filterManager = FilterManager(ownerPeerId: ownerPeer)

        let request = FilterRequest(
            requesterId: ownerPeer,
            networkId: "some-network",
            requirements: ResourceRequirements(
                cpuCores: 2,
                memoryMB: 1024
            ),
            activityDescription: "Test task"
        )

        let decision = await filterManager.evaluate(request)

        guard case .accept(let priority) = decision else {
            XCTFail("Expected accept decision")
            return
        }

        XCTAssertEqual(priority, .owner)
    }

    func testBlockedPeerIsRejected() async throws {
        let filterManager = FilterManager()

        let peerId = "blocked-peer"
        await filterManager.blockPeer(peerId)

        let request = FilterRequest(
            requesterId: peerId,
            networkId: "network-123",
            requirements: ResourceRequirements(
                cpuCores: 1,
                memoryMB: 512
            ),
            activityDescription: nil
        )

        let decision = await filterManager.evaluate(request)

        guard case .reject(let reason) = decision else {
            XCTFail("Expected reject decision")
            return
        }

        XCTAssertTrue(reason.contains("blocked"))
    }

    func testTrustedNetworkAccepted() async throws {
        let networkId = "trusted-network-1"
        let filterManager = FilterManager(trustedNetworks: [networkId])

        await filterManager.setDefaultAction(.acceptTrustedOnly)

        let request = FilterRequest(
            requesterId: "peer-123",
            networkId: networkId,
            requirements: ResourceRequirements(
                cpuCores: 2,
                memoryMB: 1024
            ),
            activityDescription: "Test"
        )

        let decision = await filterManager.evaluate(request)

        guard case .accept(let priority) = decision else {
            XCTFail("Expected accept decision")
            return
        }

        XCTAssertEqual(priority, .network)
    }

    func testUntrustedNetworkRejected() async throws {
        let trustedNetwork = "trusted-network"
        let filterManager = FilterManager(trustedNetworks: [trustedNetwork])

        await filterManager.setDefaultAction(.acceptTrustedOnly)

        let request = FilterRequest(
            requesterId: "peer-123",
            networkId: "untrusted-network",
            requirements: ResourceRequirements(
                cpuCores: 1,
                memoryMB: 512
            ),
            activityDescription: nil
        )

        let decision = await filterManager.evaluate(request)

        guard case .reject = decision else {
            XCTFail("Expected reject decision")
            return
        }
    }

    func testResourceLimitRule() async throws {
        let filterManager = FilterManager()

        let rule = ResourceLimitRule(
            maxCpuCores: 4,
            maxMemoryMB: 8192
        )

        await filterManager.addRule(rule)

        // Request exceeds CPU limit
        let request1 = FilterRequest(
            requesterId: "peer-123",
            networkId: "network-1",
            requirements: ResourceRequirements(
                cpuCores: 8,  // Exceeds limit of 4
                memoryMB: 4096
            ),
            activityDescription: nil
        )

        let decision1 = await filterManager.evaluate(request1)

        guard case .reject(let reason) = decision1 else {
            XCTFail("Expected reject decision for CPU limit")
            return
        }

        XCTAssertTrue(reason.contains("CPU") || reason.contains("cores"))

        // Request within limits
        let request2 = FilterRequest(
            requesterId: "peer-123",
            networkId: "network-1",
            requirements: ResourceRequirements(
                cpuCores: 2,
                memoryMB: 4096
            ),
            activityDescription: nil
        )

        let decision2 = await filterManager.evaluate(request2)

        // Should not be rejected by resource limit (may be accepted or require approval based on default policy)
        if case .reject(let reason) = decision2 {
            XCTAssertFalse(reason.contains("CPU") || reason.contains("Memory"))
        }
    }

    func testActivityDescriptionRule() async throws {
        let filterManager = FilterManager()

        let rule = ActivityDescriptionRule(
            requiredKeywords: ["ML", "training"],
            forbiddenKeywords: ["crypto", "mining"]
        )

        await filterManager.addRule(rule)

        // Request with forbidden keyword
        let request1 = FilterRequest(
            requesterId: "peer-123",
            networkId: "network-1",
            requirements: ResourceRequirements(
                cpuCores: 2,
                memoryMB: 1024
            ),
            activityDescription: "Cryptocurrency mining job"
        )

        let decision1 = await filterManager.evaluate(request1)

        guard case .reject(let reason) = decision1 else {
            XCTFail("Expected reject for forbidden keyword")
            return
        }

        XCTAssertTrue(reason.lowercased().contains("forbidden") || reason.lowercased().contains("crypto"))

        // Request with required keyword
        let request2 = FilterRequest(
            requesterId: "peer-123",
            networkId: "network-1",
            requirements: ResourceRequirements(
                cpuCores: 2,
                memoryMB: 1024
            ),
            activityDescription: "ML model training"
        )

        let decision2 = await filterManager.evaluate(request2)

        // Should not be rejected by activity description rule
        if case .reject(let reason) = decision2 {
            XCTAssertFalse(reason.contains("Activity description"))
        }
    }

    func testQuietHoursRule() async throws {
        let filterManager = FilterManager()

        // Set quiet hours to current hour (should trigger)
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: Date())

        let rule = QuietHoursRule(
            startHour: currentHour,
            endHour: (currentHour + 1) % 24,
            action: .reject
        )

        await filterManager.addRule(rule)

        let request = FilterRequest(
            requesterId: "peer-123",
            networkId: "network-1",
            requirements: ResourceRequirements(
                cpuCores: 1,
                memoryMB: 512
            ),
            activityDescription: nil
        )

        let decision = await filterManager.evaluate(request)

        // Should be rejected due to quiet hours
        guard case .reject(let reason) = decision else {
            XCTFail("Expected reject during quiet hours")
            return
        }

        XCTAssertTrue(reason.lowercased().contains("quiet"))
    }

    func testFilterStatistics() async throws {
        let filterManager = FilterManager(
            ownerPeerId: "owner",
            trustedNetworks: ["network-1"]
        )

        // Accept (owner)
        _ = await filterManager.evaluate(FilterRequest(
            requesterId: "owner",
            networkId: "network-1",
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            activityDescription: nil
        ))

        // Accept (trusted network)
        _ = await filterManager.evaluate(FilterRequest(
            requesterId: "peer-123",
            networkId: "network-1",
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            activityDescription: nil
        ))

        // Reject (untrusted)
        await filterManager.setDefaultAction(.acceptTrustedOnly)
        _ = await filterManager.evaluate(FilterRequest(
            requesterId: "peer-456",
            networkId: "untrusted-network",
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            activityDescription: nil
        ))

        let stats = await filterManager.getStatistics()

        XCTAssertEqual(stats.totalEvaluated, 3)
        XCTAssertEqual(stats.totalAccepted, 2)
        XCTAssertEqual(stats.totalRejected, 1)
        XCTAssertEqual(stats.acceptanceRate, 2.0 / 3.0, accuracy: 0.01)
    }

    func testAddAndRemoveTrustedNetwork() async throws {
        let filterManager = FilterManager()

        await filterManager.addTrustedNetwork("network-1")

        let networks = await filterManager.getTrustedNetworks()
        XCTAssertTrue(networks.contains("network-1"))

        await filterManager.removeTrustedNetwork("network-1")

        let networksAfter = await filterManager.getTrustedNetworks()
        XCTAssertFalse(networksAfter.contains("network-1"))
    }

    func testBlockAndUnblockPeer() async throws {
        let filterManager = FilterManager()

        await filterManager.blockPeer("bad-peer")

        let blocked = await filterManager.getBlockedPeers()
        XCTAssertTrue(blocked.contains("bad-peer"))

        await filterManager.unblockPeer("bad-peer")

        let blockedAfter = await filterManager.getBlockedPeers()
        XCTAssertFalse(blockedAfter.contains("bad-peer"))
    }
}
