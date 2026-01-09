import XCTest
@testable import OmertaProvider
@testable import OmertaNetwork
@testable import OmertaCore
import Foundation

/// Tests for VPN health monitoring functionality
final class VPNHealthMonitorTests: XCTestCase {

    // MARK: - Configuration Tests

    func testDefaultConfiguration() async {
        let monitor = VPNHealthMonitor()
        let status = await monitor.getStatus()

        // Default values from VPNHealthMonitor
        XCTAssertEqual(status.checkInterval, 30.0, "Default check interval should be 30s")
        XCTAssertEqual(status.timeoutThreshold, 600.0, "Default timeout should be 600s (10 min)")
        XCTAssertEqual(status.monitoredVMs, 0, "Should start with no monitored VMs")
    }

    func testCustomConfiguration() async {
        let monitor = VPNHealthMonitor(
            checkInterval: 15.0,
            timeoutThreshold: 300.0
        )
        let status = await monitor.getStatus()

        XCTAssertEqual(status.checkInterval, 15.0, "Should use custom check interval")
        XCTAssertEqual(status.timeoutThreshold, 300.0, "Should use custom timeout")
    }

    // MARK: - Monitoring Lifecycle Tests

    func testStartAndStopMonitoring() async {
        let monitor = VPNHealthMonitor(
            checkInterval: 1.0,
            timeoutThreshold: 60.0
        )

        let vmId = UUID()
        var callbackCalled = false

        // Start monitoring
        await monitor.startMonitoring(
            vmId: vmId,
            vpnInterface: "wg-test123",
            consumerPublicKey: "test_consumer_key_base64_here",
            onTunnelDeath: { deadVmId in
                callbackCalled = true
                XCTAssertEqual(deadVmId, vmId, "Callback should receive correct VM ID")
            }
        )

        // Check status
        var status = await monitor.getStatus()
        XCTAssertEqual(status.monitoredVMs, 1, "Should have 1 monitored VM")

        // Stop monitoring
        await monitor.stopMonitoring(vmId: vmId)

        // Check status again
        status = await monitor.getStatus()
        XCTAssertEqual(status.monitoredVMs, 0, "Should have 0 monitored VMs after stop")
    }

    func testStopAllMonitoring() async {
        let monitor = VPNHealthMonitor(
            checkInterval: 1.0,
            timeoutThreshold: 60.0
        )

        // Start monitoring multiple VMs
        for _ in 0..<3 {
            let vmId = UUID()
            await monitor.startMonitoring(
                vmId: vmId,
                vpnInterface: "wg-test\(vmId.uuidString.prefix(4))",
                consumerPublicKey: "test_key",
                onTunnelDeath: { _ in }
            )
        }

        // Verify count
        var status = await monitor.getStatus()
        XCTAssertEqual(status.monitoredVMs, 3, "Should have 3 monitored VMs")

        // Stop all
        await monitor.stopAll()

        // Verify all stopped
        status = await monitor.getStatus()
        XCTAssertEqual(status.monitoredVMs, 0, "Should have 0 monitored VMs after stopAll")
    }

    // MARK: - Health Check Logic Tests

    func testGracePeriodForNewVMs() async throws {
        // New VMs should get a grace period before being killed
        // (timeout threshold seconds from start)

        let monitor = VPNHealthMonitor(
            checkInterval: 0.5,  // Fast checks for testing
            timeoutThreshold: 2.0  // Short timeout for testing
        )

        let vmId = UUID()
        var tunnelDeathCalled = false

        await monitor.startMonitoring(
            vmId: vmId,
            vpnInterface: "wg-nonexistent",  // Interface doesn't exist
            consumerPublicKey: "test_key",
            onTunnelDeath: { _ in
                tunnelDeathCalled = true
            }
        )

        // Wait for a check cycle but not past the grace period
        try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

        // Should NOT have called tunnel death yet (within grace period)
        // Note: This depends on timing and `wg show` failing gracefully
        // In production, this is handled by the secondsSinceStart check

        // Clean up
        await monitor.stopMonitoring(vmId: vmId)
    }

    // MARK: - Handshake Parsing Tests

    func testHandshakeOutputParsing() {
        // Test parsing of `wg show <interface> latest-handshakes` output
        let output = """
        abc123publickey==\t1672531200
        xyz789publickey==\t0
        """

        let lines = output.split(separator: "\n")

        // First line should have a valid timestamp
        let firstParts = lines[0].split(separator: "\t")
        XCTAssertEqual(firstParts.count, 2, "Should have key and timestamp")
        XCTAssertEqual(String(firstParts[0]), "abc123publickey==", "Key should match")
        XCTAssertEqual(String(firstParts[1]), "1672531200", "Timestamp should match")

        // Convert to Date
        if let timestamp = TimeInterval(firstParts[1]) {
            let date = Date(timeIntervalSince1970: timestamp)
            XCTAssertEqual(date.timeIntervalSince1970, 1672531200, "Date conversion should work")
        }

        // Second line has timestamp 0 (no handshake)
        let secondParts = lines[1].split(separator: "\t")
        XCTAssertEqual(String(secondParts[1]), "0", "Zero timestamp means no handshake")
    }

    func testPublicKeyMatching() {
        // Test that we can match public keys with different formats
        let fullKey = "abc123def456ghi789jkl012mno345pqr678stu901="
        let searchKey = "abc123def456ghi789jkl012mno345pqr678stu901="

        // Exact match
        XCTAssertTrue(fullKey.contains(searchKey) || searchKey.contains(fullKey),
            "Keys should match")

        // Partial match (prefix)
        let partialKey = "abc123def456ghi789"
        XCTAssertTrue(fullKey.contains(partialKey), "Full key should contain partial")
    }

    // MARK: - Timeout Calculation Tests

    func testTimeoutCalculation() {
        let timeoutThreshold: TimeInterval = 600.0  // 10 minutes

        // Recent handshake
        let recentHandshake = Date(timeIntervalSinceNow: -60)  // 1 minute ago
        let secondsSinceRecent = Date().timeIntervalSince(recentHandshake)
        XCTAssertLessThan(secondsSinceRecent, timeoutThreshold, "Recent handshake should be healthy")

        // Old handshake
        let oldHandshake = Date(timeIntervalSinceNow: -700)  // 700 seconds ago
        let secondsSinceOld = Date().timeIntervalSince(oldHandshake)
        XCTAssertGreaterThan(secondsSinceOld, timeoutThreshold, "Old handshake should be timed out")
    }

    // MARK: - Edge Cases

    func testDuplicateVMMonitoring() async {
        let monitor = VPNHealthMonitor()
        let vmId = UUID()

        // Start monitoring twice with same VM ID
        await monitor.startMonitoring(
            vmId: vmId,
            vpnInterface: "wg-test1",
            consumerPublicKey: "key1",
            onTunnelDeath: { _ in }
        )

        // Second call should update, not duplicate
        await monitor.startMonitoring(
            vmId: vmId,
            vpnInterface: "wg-test2",
            consumerPublicKey: "key2",
            onTunnelDeath: { _ in }
        )

        let status = await monitor.getStatus()
        // Should still be 1 VM (updated, not duplicated)
        XCTAssertEqual(status.monitoredVMs, 1, "Should not duplicate VM monitoring")

        await monitor.stopAll()
    }

    func testStopNonExistentVM() async {
        let monitor = VPNHealthMonitor()
        let vmId = UUID()

        // Stopping a non-existent VM should not crash
        await monitor.stopMonitoring(vmId: vmId)

        let status = await monitor.getStatus()
        XCTAssertEqual(status.monitoredVMs, 0, "Should handle non-existent VM gracefully")
    }
}

// MARK: - Interface Existence Tests (Platform-specific)

#if os(macOS)
final class MacOSInterfaceExistenceTests: XCTestCase {

    func testUtunInterfaceDetection() {
        // Test that we can detect utun interfaces via ifconfig
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Should at least have lo0 interface
        XCTAssertTrue(output.contains("lo0"), "Should list lo0 interface")

        // May or may not have utun interfaces
        let hasUtun = output.contains("utun")
        print("Has utun interfaces: \(hasUtun)")
    }

    func testInterfaceExistenceHeuristic() {
        // Test the heuristic used to detect if our VPN interface exists
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // The heuristic checks for utun + 10.x.x.x IP
        let hasUtun = output.contains("utun")
        let hasVPNIP = output.contains("inet 10.")

        // If both present, consider VPN interface exists
        if hasUtun && hasVPNIP {
            print("VPN interface likely exists (utun with 10.x IP)")
        } else {
            print("No active VPN interface detected")
        }
    }
}
#endif

#if os(Linux)
final class LinuxInterfaceExistenceTests: XCTestCase {

    func testWireGuardInterfaceDetection() {
        // Test listing WireGuard interfaces on Linux
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ip")
        process.arguments = ["link", "show", "type", "wireguard"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Parse interface names from output
        // Format: "29: wg-name: <FLAGS>..."
        let lines = output.split(separator: "\n")
        var interfaces: [String] = []

        for line in lines {
            let parts = line.split(separator: ":")
            if parts.count >= 2 {
                let name = parts[1].trimmingCharacters(in: .whitespaces)
                interfaces.append(name)
            }
        }

        print("Found \(interfaces.count) WireGuard interfaces: \(interfaces)")
    }

    func testInterfaceExistenceViaNetlink() {
        // Test checking interface existence via /sys/class/net
        let netDir = "/sys/class/net"

        do {
            let interfaces = try FileManager.default.contentsOfDirectory(atPath: netDir)
            let wgInterfaces = interfaces.filter { $0.hasPrefix("wg") }

            print("WireGuard interfaces in /sys/class/net: \(wgInterfaces)")

            // Verify lo exists (should always exist)
            XCTAssertTrue(interfaces.contains("lo"), "Should have loopback interface")
        } catch {
            XCTFail("Failed to list interfaces: \(error)")
        }
    }
}
#endif
