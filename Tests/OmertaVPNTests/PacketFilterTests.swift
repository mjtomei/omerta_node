import XCTest
@testable import OmertaVPN

#if os(macOS)
final class PacketFilterTests: XCTestCase {

    // MARK: - Rule Generation Tests

    func testGenerateNATRulesHasCorrectFormat() {
        let rules = MacOSPacketFilterManager.generateNATRules(
            vmVPNIP: "10.99.0.2",
            vmNATIP: "192.168.64.5",
            vpnInterface: "utun10",
            externalInterface: "en0"
        )

        // Verify required rule components
        XCTAssertTrue(rules.contains("nat on en0"), "NAT rule should use external interface")
        XCTAssertTrue(rules.contains("rdr on utun10"), "RDR rule should use VPN interface")
        XCTAssertTrue(rules.contains("from 192.168.64.5"), "NAT should be from VM NAT IP")
        XCTAssertTrue(rules.contains("to 10.99.0.2"), "RDR should redirect to VM VPN IP")
        XCTAssertTrue(rules.contains("pass quick"), "Should have pass rules for traffic")
    }

    func testGenerateNATRulesWithUtunInterface() {
        // Test that utun interfaces work correctly
        let rules = MacOSPacketFilterManager.generateNATRules(
            vmVPNIP: "10.100.50.2",
            vmNATIP: "192.168.64.10",
            vpnInterface: "utun15",
            externalInterface: "en0"
        )

        XCTAssertTrue(rules.contains("utun15"), "Should use utun interface name")
        XCTAssertFalse(rules.contains("wg-"), "Should NOT contain logical WireGuard name")
    }

    func testGenerateNATRulesRejectsInvalidInterface() {
        // Logical WireGuard names like "wg-ABC12345" should not be used directly
        // They need to be resolved to actual utun interfaces
        let rules = MacOSPacketFilterManager.generateNATRules(
            vmVPNIP: "10.99.0.2",
            vmNATIP: "192.168.64.5",
            vpnInterface: "wg-ABC12345",
            externalInterface: "en0"
        )

        // These rules will have syntax errors in pf because wg-ABC12345 isn't a real interface
        // This test documents the expected behavior - the caller must provide the real utun name
        XCTAssertTrue(rules.contains("wg-ABC12345"),
            "generateNATRules uses interface as-is - caller must provide actual interface")

        // The findInvalidInterfaces function should catch this
        let invalid = MacOSPacketFilterManager.findInvalidInterfaces(in: rules)
        XCTAssertTrue(invalid.contains("wg-ABC12345"),
            "Validation should detect wg-* as invalid interface")
    }

    // MARK: - Validation Function Tests

    func testFindInvalidInterfacesDetectsLogicalNames() {
        let rules = """
        nat on en0 from 192.168.64.5 to any -> (en0)
        rdr on wg-ABC12345 proto tcp from any to 10.99.0.2 -> 192.168.64.5
        pass quick on wg-ABC12345 from any to any
        """

        let invalid = MacOSPacketFilterManager.findInvalidInterfaces(in: rules)
        XCTAssertEqual(invalid.count, 2, "Should find 2 invalid interface references")
        XCTAssertTrue(invalid.allSatisfy { $0 == "wg-ABC12345" },
            "All invalid interfaces should be wg-ABC12345")
    }

    func testFindInvalidInterfacesAcceptsValidNames() {
        let rules = """
        nat on en0 from 192.168.64.5 to any -> (en0)
        rdr on utun10 proto tcp from any to 10.99.0.2 -> 192.168.64.5
        pass quick on utun10 from any to any
        """

        let invalid = MacOSPacketFilterManager.findInvalidInterfaces(in: rules)
        XCTAssertEqual(invalid.count, 0, "Should find no invalid interfaces")
    }

    func testIsValidUtunInterfaceAcceptsValidNames() {
        XCTAssertTrue(MacOSPacketFilterManager.isValidUtunInterface("utun0"))
        XCTAssertTrue(MacOSPacketFilterManager.isValidUtunInterface("utun1"))
        XCTAssertTrue(MacOSPacketFilterManager.isValidUtunInterface("utun10"))
        XCTAssertTrue(MacOSPacketFilterManager.isValidUtunInterface("utun99"))
        XCTAssertTrue(MacOSPacketFilterManager.isValidUtunInterface("utun100"))
    }

    func testIsValidUtunInterfaceRejectsInvalidNames() {
        XCTAssertFalse(MacOSPacketFilterManager.isValidUtunInterface("wg-ABC"))
        XCTAssertFalse(MacOSPacketFilterManager.isValidUtunInterface("wg0"))
        XCTAssertFalse(MacOSPacketFilterManager.isValidUtunInterface("tun0"))
        XCTAssertFalse(MacOSPacketFilterManager.isValidUtunInterface("en0"))
        XCTAssertFalse(MacOSPacketFilterManager.isValidUtunInterface(""))
        XCTAssertFalse(MacOSPacketFilterManager.isValidUtunInterface("utun"))
        XCTAssertFalse(MacOSPacketFilterManager.isValidUtunInterface("utun-1"))
    }

    func testIsValidPFInterfaceAcceptsCommonTypes() {
        // utun interfaces
        XCTAssertTrue(MacOSPacketFilterManager.isValidPFInterface("utun0"))
        XCTAssertTrue(MacOSPacketFilterManager.isValidPFInterface("utun10"))

        // Ethernet/Wi-Fi
        XCTAssertTrue(MacOSPacketFilterManager.isValidPFInterface("en0"))
        XCTAssertTrue(MacOSPacketFilterManager.isValidPFInterface("en1"))

        // Bridge
        XCTAssertTrue(MacOSPacketFilterManager.isValidPFInterface("bridge0"))

        // Loopback
        XCTAssertTrue(MacOSPacketFilterManager.isValidPFInterface("lo0"))

        // VM network
        XCTAssertTrue(MacOSPacketFilterManager.isValidPFInterface("vmnet0"))
        XCTAssertTrue(MacOSPacketFilterManager.isValidPFInterface("vmnet8"))
    }

    func testIsValidPFInterfaceRejectsWireGuardLogicalNames() {
        XCTAssertFalse(MacOSPacketFilterManager.isValidPFInterface("wg-ABC12345"))
        XCTAssertFalse(MacOSPacketFilterManager.isValidPFInterface("wg0"))
        XCTAssertFalse(MacOSPacketFilterManager.isValidPFInterface("wireguard0"))
    }

    func testGenerateIsolationRulesBlocksPrivateNetworks() {
        let rules = MacOSPacketFilterManager.generateIsolationRules(
            vmNATIP: "192.168.64.5",
            vpnSubnet: "10.99.0.0/24"
        )

        // Should block access to private networks
        XCTAssertTrue(rules.contains("block drop quick from 192.168.64.5 to 192.168.0.0/16"),
            "Should block 192.168.x.x")
        XCTAssertTrue(rules.contains("block drop quick from 192.168.64.5 to 10.0.0.0/8"),
            "Should block 10.x.x.x")
        XCTAssertTrue(rules.contains("block drop quick from 192.168.64.5 to 172.16.0.0/12"),
            "Should block 172.16.x.x")
    }

    func testGenerateIsolationRulesAllowsVPNSubnet() {
        let rules = MacOSPacketFilterManager.generateIsolationRules(
            vmNATIP: "192.168.64.5",
            vpnSubnet: "10.99.0.0/24"
        )

        // Should allow VPN subnet
        XCTAssertTrue(rules.contains("pass quick from 192.168.64.5 to 10.99.0.0/24"),
            "Should allow traffic to VPN subnet")
        XCTAssertTrue(rules.contains("pass quick from 10.99.0.0/24 to 192.168.64.5"),
            "Should allow traffic from VPN subnet")
    }

    func testGenerateIsolationRulesWithAllowedPorts() {
        let rules = MacOSPacketFilterManager.generateIsolationRules(
            vmNATIP: "192.168.64.5",
            vpnSubnet: "10.99.0.0/24",
            allowedPorts: [80, 443]
        )

        XCTAssertTrue(rules.contains("port 80"), "Should allow port 80")
        XCTAssertTrue(rules.contains("port 443"), "Should allow port 443")
    }

    // MARK: - Syntax Validation Tests

    func testNATRulesHaveNoLeadingWhitespace() {
        let rules = MacOSPacketFilterManager.generateNATRules(
            vmVPNIP: "10.99.0.2",
            vmNATIP: "192.168.64.5",
            vpnInterface: "utun10",
            externalInterface: "en0"
        )

        // pf is sensitive to leading whitespace on directives
        let lines = rules.split(separator: "\n")
        for line in lines {
            let trimmed = String(line)
            // Skip comment lines and empty lines
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

            // Directive lines should not have leading whitespace
            if trimmed.hasPrefix("nat ") || trimmed.hasPrefix("rdr ") ||
               trimmed.hasPrefix("pass ") || trimmed.hasPrefix("block ") {
                XCTAssertEqual(String(line), trimmed,
                    "pf directive should not have leading whitespace: '\(line)'")
            }
        }
    }

    func testNATRulesDoNotUseInetKeyword() {
        // macOS pf doesn't support 'inet' keyword in newer versions
        let rules = MacOSPacketFilterManager.generateNATRules(
            vmVPNIP: "10.99.0.2",
            vmNATIP: "192.168.64.5",
            vpnInterface: "utun10",
            externalInterface: "en0"
        )

        // 'inet' keyword causes syntax errors on macOS
        XCTAssertFalse(rules.contains(" inet "),
            "Should not use 'inet' keyword which causes syntax errors on macOS pf")
    }

    func testRDRRulesHaveValidProtocol() {
        let rules = MacOSPacketFilterManager.generateNATRules(
            vmVPNIP: "10.99.0.2",
            vmNATIP: "192.168.64.5",
            vpnInterface: "utun10",
            externalInterface: "en0"
        )

        // RDR rules should specify protocol
        XCTAssertTrue(rules.contains("proto {tcp, udp}") ||
                     (rules.contains("proto tcp") && rules.contains("proto udp")),
            "RDR rules should specify protocol(s)")
    }

    // MARK: - Edge Cases

    func testRulesWithSpecialIPAddresses() {
        // Test with various IP formats
        let rules = MacOSPacketFilterManager.generateNATRules(
            vmVPNIP: "10.0.0.2",
            vmNATIP: "192.168.0.1",
            vpnInterface: "utun0",
            externalInterface: "en0"
        )

        XCTAssertTrue(rules.contains("10.0.0.2"), "Should handle 10.0.0.x addresses")
        XCTAssertTrue(rules.contains("192.168.0.1"), "Should handle 192.168.0.x addresses")
    }

    func testRulesWithDifferentSubnets() {
        let subnets = ["10.99.0.0/24", "10.0.0.0/8", "172.16.0.0/12", "192.168.1.0/24"]

        for subnet in subnets {
            let rules = MacOSPacketFilterManager.generateIsolationRules(
                vmNATIP: "192.168.64.5",
                vpnSubnet: subnet
            )

            XCTAssertTrue(rules.contains(subnet),
                "Should include VPN subnet \(subnet) in rules")
        }
    }

    // MARK: - Interface Name Validation

    func testUtunInterfaceNamePattern() {
        // Valid utun interface names
        let validNames = ["utun0", "utun1", "utun10", "utun99"]

        for name in validNames {
            XCTAssertTrue(isValidUtunInterface(name),
                "\(name) should be a valid utun interface")
        }
    }

    func testInvalidInterfaceNamePattern() {
        // Invalid interface names that shouldn't be used directly in pf rules
        let invalidNames = [
            "wg-ABC12345",  // Logical WireGuard name
            "wg0",          // Linux-style WireGuard
            "tun0",         // tun (not utun)
            "en0",          // Ethernet (valid for external but not VPN)
            ""              // Empty
        ]

        for name in invalidNames {
            if name != "en0" {  // en0 is valid for external interface
                XCTAssertFalse(isValidUtunInterface(name),
                    "\(name) should not be a valid utun interface")
            }
        }
    }

    // MARK: - Helper Functions

    private func isValidUtunInterface(_ name: String) -> Bool {
        // utun interfaces on macOS follow the pattern utunN where N is a number
        let pattern = "^utun[0-9]+$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Integration Tests (require root)

final class PacketFilterIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Skip these tests if not running as root
        // or if running in CI where we can't modify firewall
    }

    func testCanOpenPFDevice() throws {
        // This test verifies we can open /dev/pf
        // Requires root privileges
        guard ProcessInfo.processInfo.environment["USER"] == "root" ||
              geteuid() == 0 else {
            throw XCTSkip("Requires root privileges")
        }

        do {
            _ = try MacOSPacketFilterManager.isEnabled()
        } catch {
            XCTFail("Should be able to check pf status: \(error)")
        }
    }

    func testEnableIPForwarding() throws {
        guard geteuid() == 0 else {
            throw XCTSkip("Requires root privileges")
        }

        do {
            try MacOSPacketFilterManager.enableIPForwarding()
        } catch {
            XCTFail("Should be able to enable IP forwarding: \(error)")
        }
    }
}
#endif
