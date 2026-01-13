// ConnectionKeepaliveTests.swift - Tests for connection keepalive functionality

import XCTest
@testable import OmertaMesh

final class ConnectionKeepaliveTests: XCTestCase {

    // MARK: - Basic Functionality Tests

    /// Test adding and removing connections
    func testAddRemoveConnection() async throws {
        let keepalive = ConnectionKeepalive(config: .default)

        // Add a connection
        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")

        var peer1Monitored = await keepalive.isMonitoring(peerId: "peer1")
        var peer2Monitored = await keepalive.isMonitoring(peerId: "peer2")
        XCTAssertTrue(peer1Monitored)
        XCTAssertFalse(peer2Monitored)

        // Add another
        await keepalive.addConnection(peerId: "peer2", endpoint: "192.168.1.2:9000")

        peer2Monitored = await keepalive.isMonitoring(peerId: "peer2")
        XCTAssertTrue(peer2Monitored)

        // Remove first
        await keepalive.removeConnection(peerId: "peer1")

        peer1Monitored = await keepalive.isMonitoring(peerId: "peer1")
        peer2Monitored = await keepalive.isMonitoring(peerId: "peer2")
        XCTAssertFalse(peer1Monitored)
        XCTAssertTrue(peer2Monitored)
    }

    /// Test connection state tracking
    func testConnectionState() async throws {
        let keepalive = ConnectionKeepalive(config: .default)

        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")

        let state = await keepalive.getConnectionState(peerId: "peer1")
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.peerId, "peer1")
        XCTAssertEqual(state?.endpoint, "192.168.1.1:9000")
        XCTAssertEqual(state?.missedPings, 0)
        XCTAssertTrue(state?.isHealthy ?? false)
    }

    /// Test successful communication resets missed count
    func testSuccessfulCommunicationResetsMissed() async throws {
        let config = ConnectionKeepalive.Config(
            interval: 0.1,  // 100ms for fast testing
            missedThreshold: 3,
            responseTimeout: 1.0
        )
        let keepalive = ConnectionKeepalive(config: config)

        // Set up ping sender that always fails
        var pingCount = 0
        await keepalive.setPingSender { _, _ in
            pingCount += 1
            return false
        }

        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")

        // Start keepalive
        await keepalive.start()

        // Wait for some pings to fail
        try await Task.sleep(nanoseconds: 250_000_000)  // 250ms = ~2 intervals

        // Record successful communication (simulating incoming message)
        await keepalive.recordSuccessfulCommunication(peerId: "peer1")

        // Check that missed count was reset
        let state = await keepalive.getConnectionState(peerId: "peer1")
        XCTAssertEqual(state?.missedPings, 0)
        XCTAssertTrue(state?.isHealthy ?? false)

        await keepalive.stop()
        XCTAssertGreaterThan(pingCount, 0)
    }

    /// Test connection marked as failed after threshold missed
    func testConnectionFailureAfterThreshold() async throws {
        let config = ConnectionKeepalive.Config(
            interval: 0.05,  // 50ms for fast testing
            missedThreshold: 2,
            responseTimeout: 1.0
        )
        let keepalive = ConnectionKeepalive(config: config)

        // Track failures
        var failedPeerIds: [PeerId] = []

        // Set up ping sender that always fails
        await keepalive.setPingSender { _, _ in
            return false
        }

        await keepalive.setFailureHandler { peerId, _ in
            failedPeerIds.append(peerId)
        }

        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")

        // Start keepalive
        await keepalive.start()

        // Wait for enough pings to fail (threshold = 2, so 3 intervals should trigger)
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        await keepalive.stop()

        // Check that failure was reported
        XCTAssertTrue(failedPeerIds.contains("peer1"), "Connection should have been marked as failed")

        // Check that connection was removed from monitoring
        let isRemoved = await keepalive.isMonitoring(peerId: "peer1")
        XCTAssertFalse(isRemoved)
    }

    /// Test healthy connections are maintained
    func testHealthyConnectionMaintained() async throws {
        let config = ConnectionKeepalive.Config(
            interval: 0.05,  // 50ms for fast testing
            missedThreshold: 3,
            responseTimeout: 1.0
        )
        let keepalive = ConnectionKeepalive(config: config)

        var failedPeerIds: [PeerId] = []

        // Set up ping sender that always succeeds
        await keepalive.setPingSender { _, _ in
            return true
        }

        await keepalive.setFailureHandler { peerId, _ in
            failedPeerIds.append(peerId)
        }

        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")

        // Start keepalive
        await keepalive.start()

        // Wait for several ping cycles
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        await keepalive.stop()

        // Check that no failures were reported
        XCTAssertTrue(failedPeerIds.isEmpty, "No failures should have been reported")

        // Check that connection is still being monitored
        let stillMonitored = await keepalive.isMonitoring(peerId: "peer1")
        XCTAssertTrue(stillMonitored)

        let state = await keepalive.getConnectionState(peerId: "peer1")
        XCTAssertTrue(state?.isHealthy ?? false)
    }

    /// Test statistics tracking
    func testStatistics() async throws {
        let keepalive = ConnectionKeepalive(config: .default)

        // Initially empty
        var stats = await keepalive.statistics
        XCTAssertEqual(stats.totalConnections, 0)
        XCTAssertEqual(stats.healthyConnections, 0)

        // Add connections
        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")
        await keepalive.addConnection(peerId: "peer2", endpoint: "192.168.1.2:9000")

        stats = await keepalive.statistics
        XCTAssertEqual(stats.totalConnections, 2)
        XCTAssertEqual(stats.healthyConnections, 2)
        XCTAssertEqual(stats.healthPercentage, 100.0)
    }

    /// Test endpoint update
    func testEndpointUpdate() async throws {
        let keepalive = ConnectionKeepalive(config: .default)

        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")

        var state = await keepalive.getConnectionState(peerId: "peer1")
        XCTAssertEqual(state?.endpoint, "192.168.1.1:9000")

        // Update endpoint
        await keepalive.updateEndpoint(peerId: "peer1", endpoint: "192.168.1.1:9001")

        state = await keepalive.getConnectionState(peerId: "peer1")
        XCTAssertEqual(state?.endpoint, "192.168.1.1:9001")
    }

    /// Test multiple connections with mixed health
    func testMultipleConnectionsMixedHealth() async throws {
        let config = ConnectionKeepalive.Config(
            interval: 0.05,
            missedThreshold: 2,
            responseTimeout: 1.0
        )
        let keepalive = ConnectionKeepalive(config: config)

        var failedPeerIds: [PeerId] = []

        // peer1 succeeds, peer2 fails
        await keepalive.setPingSender { peerId, _ in
            return peerId == "peer1"
        }

        await keepalive.setFailureHandler { peerId, _ in
            failedPeerIds.append(peerId)
        }

        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")
        await keepalive.addConnection(peerId: "peer2", endpoint: "192.168.1.2:9000")

        await keepalive.start()

        // Wait for peer2 to fail
        try await Task.sleep(nanoseconds: 200_000_000)

        await keepalive.stop()

        // peer1 should still be monitored, peer2 should have failed
        let peer1Monitored = await keepalive.isMonitoring(peerId: "peer1")
        let peer2Monitored = await keepalive.isMonitoring(peerId: "peer2")
        XCTAssertTrue(peer1Monitored)
        XCTAssertFalse(peer2Monitored)
        XCTAssertTrue(failedPeerIds.contains("peer2"))
        XCTAssertFalse(failedPeerIds.contains("peer1"))
    }

    // MARK: - Timing Tests

    /// Test that keepalive maintains NAT mapping simulation
    func testKeepaliveFrequency() async throws {
        // This test verifies that keepalives are sent at the configured interval
        let config = ConnectionKeepalive.Config(
            interval: 0.1,  // 100ms
            missedThreshold: 5,
            responseTimeout: 1.0
        )
        let keepalive = ConnectionKeepalive(config: config)

        var pingTimes: [Date] = []

        await keepalive.setPingSender { _, _ in
            pingTimes.append(Date())
            return true
        }

        await keepalive.addConnection(peerId: "peer1", endpoint: "192.168.1.1:9000")

        await keepalive.start()

        // Wait for multiple intervals
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms = 5 intervals

        await keepalive.stop()

        // Should have at least 4 pings (first after 100ms, then every 100ms)
        XCTAssertGreaterThanOrEqual(pingTimes.count, 4, "Should have sent at least 4 pings")

        // Verify intervals are approximately correct
        if pingTimes.count >= 2 {
            for i in 1..<pingTimes.count {
                let interval = pingTimes[i].timeIntervalSince(pingTimes[i-1])
                // Allow 50ms tolerance
                XCTAssertGreaterThan(interval, 0.05)
                XCTAssertLessThan(interval, 0.2)
            }
        }
    }
}
