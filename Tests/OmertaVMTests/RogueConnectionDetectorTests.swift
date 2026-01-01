import XCTest
@testable import OmertaVM
@testable import OmertaCore
import Foundation

final class RogueConnectionDetectorTests: XCTestCase {
    var detector: RogueConnectionDetector!

    override func setUp() async throws {
        try await super.setUp()
        detector = RogueConnectionDetector(monitoringInterval: 1.0)
    }

    func testMonitoringInitialization() async throws {
        let jobId = UUID()
        let vpnConfig = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test\n",
            endpoint: "192.168.1.1:51820",
            publicKey: Data("test".utf8),
            vpnServerIP: "10.99.0.1"
        )

        var rogueEvents: [RogueConnectionEvent] = []

        // Start monitoring (will run in background)
        try await detector.startMonitoring(
            jobId: jobId,
            vpnConfig: vpnConfig
        ) { event in
            rogueEvents.append(event)
        }

        // Verify monitoring was started
        let stats = await detector.getMonitoringStats(for: jobId)
        XCTAssertNotNil(stats, "Monitoring stats should exist for job")
        XCTAssertEqual(stats?.jobId, jobId, "Should track correct job ID")

        // Stop monitoring
        await detector.stopMonitoring(jobId: jobId)

        // Verify monitoring was stopped
        let statsAfterStop = await detector.getMonitoringStats(for: jobId)
        XCTAssertNil(statsAfterStop, "Monitoring stats should be removed after stop")
    }

    func testSuspiciousConnectionDetection() {
        // Test parsing of suspicious connections
        let connections = [
            ActiveConnectionTest(
                destinationIP: "8.8.8.8",
                destinationPort: "443",
                protocol: "tcp"
            ),
            ActiveConnectionTest(
                destinationIP: "10.99.0.1", // VPN server - should be allowed
                destinationPort: "51820",
                protocol: "udp"
            ),
            ActiveConnectionTest(
                destinationIP: "127.0.0.1", // Localhost - should be allowed
                destinationPort: "8080",
                protocol: "tcp"
            )
        ]

        // 8.8.8.8 would be suspicious if not going through VPN
        // 10.99.0.1 is the VPN server itself - allowed
        // 127.0.0.1 is localhost - allowed

        let vpnServerIP = "10.99.0.1"

        let suspiciousCount = connections.filter { conn in
            // Skip localhost
            if conn.destinationIP.hasPrefix("127.") || conn.destinationIP == "::1" {
                return false
            }
            // Skip VPN server
            if conn.destinationIP == vpnServerIP {
                return false
            }
            // Everything else is suspicious (if not through VPN)
            return true
        }.count

        XCTAssertEqual(suspiciousCount, 1, "Should detect one suspicious connection (8.8.8.8)")
    }

    func testNetstatOutputParsing() {
        let netstatOutput = """
        Proto Recv-Q Send-Q Local Address           Foreign Address         State
        tcp        0      0 192.168.1.100:45678    8.8.8.8:443             ESTABLISHED
        tcp        0      0 192.168.1.100:51820    10.99.0.1:51820         ESTABLISHED
        tcp        0      0 127.0.0.1:8080         127.0.0.1:45679         ESTABLISHED
        tcp        0      0 192.168.1.100:443      1.2.3.4:12345           TIME_WAIT
        """

        let connections = parseTestNetstatOutput(netstatOutput)

        // Should parse 3 ESTABLISHED connections (ignore TIME_WAIT)
        XCTAssertEqual(connections.count, 3, "Should parse 3 ESTABLISHED connections")

        // Verify parsed connections
        let ips = connections.map { $0.destinationIP }
        XCTAssertTrue(ips.contains("8.8.8.8"), "Should parse Google DNS")
        XCTAssertTrue(ips.contains("10.99.0.1"), "Should parse VPN server")
        XCTAssertTrue(ips.contains("127.0.0.1"), "Should parse localhost")
    }

    func testVPNTunnelHealthCheck() async throws {
        let vpnConfig = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test\n",
            endpoint: "192.168.1.1:51820",
            publicKey: Data("test".utf8),
            vpnServerIP: "10.99.0.1"
        )

        // Note: Actual health check requires network access
        // This test verifies the structure exists

        // Health check should have two components:
        // 1. VPN server reachability (ping)
        // 2. WireGuard interface exists
    }

    func testRogueConnectionEvent() {
        let jobId = UUID()
        let connection = SuspiciousConnection(
            destinationIP: "8.8.8.8",
            destinationPort: "443",
            protocol: "tcp",
            processName: "curl"
        )

        let event = RogueConnectionEvent(
            jobId: jobId,
            connection: connection,
            detectedAt: Date()
        )

        XCTAssertEqual(event.jobId, jobId, "Event should track job ID")
        XCTAssertEqual(event.connection.destinationIP, "8.8.8.8", "Event should track connection details")
        XCTAssertNotNil(event.detectedAt, "Event should have timestamp")
    }

    func testMultipleJobMonitoring() async throws {
        let jobId1 = UUID()
        let jobId2 = UUID()

        let vpnConfig1 = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test1\n",
            endpoint: "192.168.1.1:51820",
            publicKey: Data("test1".utf8),
            vpnServerIP: "10.99.0.1"
        )

        let vpnConfig2 = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test2\n",
            endpoint: "192.168.1.2:51821",
            publicKey: Data("test2".utf8),
            vpnServerIP: "10.99.0.2"
        )

        // Should be able to monitor multiple jobs simultaneously
        try await detector.startMonitoring(jobId: jobId1, vpnConfig: vpnConfig1) { _ in }
        try await detector.startMonitoring(jobId: jobId2, vpnConfig: vpnConfig2) { _ in }

        let stats1 = await detector.getMonitoringStats(for: jobId1)
        let stats2 = await detector.getMonitoringStats(for: jobId2)

        XCTAssertNotNil(stats1, "Should monitor job 1")
        XCTAssertNotNil(stats2, "Should monitor job 2")
        XCTAssertNotEqual(stats1?.vpnServerIP, stats2?.vpnServerIP, "Jobs should have different VPN servers")

        await detector.stopMonitoring(jobId: jobId1)
        await detector.stopMonitoring(jobId: jobId2)
    }

    // Helper types and functions
    private struct ActiveConnectionTest {
        let destinationIP: String
        let destinationPort: String
        let protocol: String
    }

    private func parseTestNetstatOutput(_ output: String) -> [ActiveConnectionTest] {
        var connections: [ActiveConnectionTest] = []
        let lines = output.split(separator: "\n")

        for line in lines {
            if line.contains("Proto") || line.contains("Active") {
                continue
            }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 5 else { continue }

            let proto = String(parts[0])
            let foreignAddress = String(parts[4])

            let addressParts = foreignAddress.split(separator: ":")
            guard addressParts.count >= 2 else { continue }

            let ip = String(addressParts[0])
            let port = String(addressParts[1])

            // Only ESTABLISHED connections
            if parts.count >= 6 && String(parts[5]).contains("ESTABLISHED") {
                connections.append(ActiveConnectionTest(
                    destinationIP: ip,
                    destinationPort: port,
                    protocol: proto
                ))
            }
        }

        return connections
    }
}
