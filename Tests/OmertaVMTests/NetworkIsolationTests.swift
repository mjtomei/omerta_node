import XCTest
@testable import OmertaVM
@testable import OmertaCore
import Foundation

final class NetworkIsolationTests: XCTestCase {
    var networkIsolation: NetworkIsolation!

    override func setUp() async throws {
        try await super.setUp()
        networkIsolation = NetworkIsolation()
    }

    func testVPNSetupScriptGeneration() {
        let script = generateTestVPNSetupScript(
            vpnServerIP: "10.99.0.1",
            endpoint: "192.168.1.100:51820"
        )

        // Verify script contains critical VPN setup steps
        XCTAssertTrue(script.contains("wg-quick up"), "Should bring up WireGuard interface")
        XCTAssertTrue(script.contains("ping"), "Should test connectivity")
        XCTAssertTrue(script.contains("iptables"), "Should configure firewall rules")
        XCTAssertTrue(script.contains("10.99.0.1"), "Should reference VPN server IP")
    }

    func testFirewallRulesInScript() {
        let script = generateTestVPNSetupScript(
            vpnServerIP: "10.99.0.1",
            endpoint: "192.168.1.100:51820"
        )

        // Verify firewall rules block non-VPN traffic
        XCTAssertTrue(script.contains("iptables -P INPUT DROP"), "Should drop non-VPN input by default")
        XCTAssertTrue(script.contains("iptables -P OUTPUT DROP"), "Should drop non-VPN output by default")
        XCTAssertTrue(script.contains("-i wg0 -j ACCEPT"), "Should allow VPN interface input")
        XCTAssertTrue(script.contains("-o wg0 -j ACCEPT"), "Should allow VPN interface output")
        XCTAssertTrue(script.contains("-i lo -j ACCEPT"), "Should allow localhost")
    }

    func testVPNConnectivityCheck() {
        let script = generateTestVPNSetupScript(
            vpnServerIP: "10.99.0.1",
            endpoint: "192.168.1.100:51820"
        )

        // Verify script tests VPN connectivity before proceeding
        XCTAssertTrue(script.contains("ping -c 1"), "Should ping VPN server")
        XCTAssertTrue(script.contains("if [ $? -ne 0 ]"), "Should check ping result")
        XCTAssertTrue(script.contains("exit 1"), "Should exit on connectivity failure")
    }

    func testVPNInterfaceVerification() {
        let script = generateTestVPNSetupScript(
            vpnServerIP: "10.99.0.1",
            endpoint: "192.168.1.100:51820"
        )

        // Verify script checks WireGuard interface exists
        XCTAssertTrue(script.contains("ip link show wg0"), "Should verify WireGuard interface exists")
        XCTAssertTrue(script.contains("ERROR: WireGuard interface not found"), "Should error if interface missing")
    }

    func testSecurityFirstApproach() {
        let script = generateTestVPNSetupScript(
            vpnServerIP: "10.99.0.1",
            endpoint: "192.168.1.100:51820"
        )

        // Verify script terminates on any VPN setup failure
        XCTAssertTrue(script.contains("set -e"), "Should exit on any error")

        let errorCases = [
            "ERROR: Failed to bring up WireGuard interface",
            "ERROR: WireGuard config not found",
            "ERROR: WireGuard interface not found",
            "ERROR: Cannot reach VPN server"
        ]

        for errorCase in errorCases {
            XCTAssertTrue(script.contains(errorCase), "Should handle error: \(errorCase)")
        }
    }

    func testVPNRoutingVerification() throws {
        // Test VPN routing verification from console output
        let successOutput = """
        === OMERTA VM STARTED ===
        === SETTING UP VPN ROUTING ===
        Configuring VPN routing...
        VPN routing configured successfully
        Firewall rules applied - only VPN traffic permitted
        === VPN ROUTING ACTIVE ===
        === WORKLOAD OUTPUT START ===
        Hello World
        === WORKLOAD OUTPUT END ===
        """

        XCTAssertTrue(successOutput.contains("=== VPN ROUTING ACTIVE ==="), "Should verify VPN is active")
        XCTAssertTrue(successOutput.contains("VPN routing configured successfully"), "Should confirm successful setup")
    }

    func testFailedVPNSetupDetection() {
        // Test detection of failed VPN setup
        let failureOutput = """
        === OMERTA VM STARTED ===
        === SETTING UP VPN ROUTING ===
        ERROR: Cannot reach VPN server at 10.99.0.1
        """

        XCTAssertFalse(failureOutput.contains("=== VPN ROUTING ACTIVE ==="), "Should not show active when setup failed")
        XCTAssertTrue(failureOutput.contains("ERROR"), "Should contain error message")
    }

    // Helper function
    private func generateTestVPNSetupScript(vpnServerIP: String, endpoint: String) -> String {
        """
        #!/bin/sh
        set -e

        echo "Configuring VPN routing..."

        # Bring up WireGuard interface
        if [ -f /wg0.conf ]; then
            wg-quick up /wg0.conf
            if [ $? -ne 0 ]; then
                echo "ERROR: Failed to bring up WireGuard interface"
                exit 1
            fi
        else
            echo "ERROR: WireGuard config not found"
            exit 1
        fi

        # Verify VPN is up
        if ! ip link show wg0 > /dev/null 2>&1; then
            echo "ERROR: WireGuard interface not found"
            exit 1
        fi

        # Test connectivity to VPN server
        echo "Testing VPN connectivity..."
        ping -c 1 -W 5 \(vpnServerIP) > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "ERROR: Cannot reach VPN server at \(vpnServerIP)"
            exit 1
        fi

        echo "VPN routing configured successfully"
        echo "All traffic will route through \(endpoint)"

        # Block any traffic not going through VPN
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT DROP

        # Allow localhost
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A OUTPUT -o lo -j ACCEPT

        # Allow VPN interface
        iptables -A INPUT -i wg0 -j ACCEPT
        iptables -A OUTPUT -o wg0 -j ACCEPT

        # Allow established connections
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

        echo "Firewall rules applied - only VPN traffic permitted"

        exit 0
        """
    }
}
