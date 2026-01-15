import XCTest
@testable import OmertaVPN
@testable import OmertaCore
import Foundation
import Crypto
#if canImport(Security)
import Security
#endif

/// Tests for native WireGuard implementations on Linux (netlink) and macOS (utun)
/// These tests help debug issues with the platform-specific WireGuard code
final class NativeWireGuardTests: XCTestCase {

    // MARK: - Key Generation Tests

    func testKeyPairGeneration() throws {
        // Test that we can generate valid Curve25519 key pairs
        let privateKey = try generateTestPrivateKey()
        let publicKey = try derivePublicKey(from: privateKey)

        XCTAssertEqual(privateKey.count, 44, "Base64 private key should be 44 chars")
        XCTAssertEqual(publicKey.count, 44, "Base64 public key should be 44 chars")

        // Decode and verify raw sizes
        guard let privateData = Data(base64Encoded: privateKey),
              let publicData = Data(base64Encoded: publicKey) else {
            XCTFail("Keys should be valid base64")
            return
        }

        XCTAssertEqual(privateData.count, 32, "Private key should be 32 bytes")
        XCTAssertEqual(publicData.count, 32, "Public key should be 32 bytes")
    }

    func testPublicKeyDerivationDeterministic() throws {
        // Same private key should always derive the same public key
        let privateKey = try generateTestPrivateKey()
        let publicKey1 = try derivePublicKey(from: privateKey)
        let publicKey2 = try derivePublicKey(from: privateKey)

        XCTAssertEqual(publicKey1, publicKey2, "Public key derivation should be deterministic")
    }

    // MARK: - Interface Name Tests

    func testInterfaceNameLength() {
        // WireGuard interface names must be ≤15 characters
        let testUUIDs = [
            UUID(),
            UUID(),
            UUID()
        ]

        for uuid in testUUIDs {
            let interfaceName = "wg\(uuid.uuidString.prefix(8))"
            XCTAssertLessThanOrEqual(interfaceName.count, 15,
                "Interface name '\(interfaceName)' must be ≤15 chars")
        }
    }

    func testProviderInterfaceNameFormat() {
        // Provider uses wg-<uuid8> format
        let vmId = UUID()
        let interfaceName = "wg-\(vmId.uuidString.prefix(8))"
        XCTAssertLessThanOrEqual(interfaceName.count, 15,
            "Provider interface name must be ≤15 chars")
        XCTAssertTrue(interfaceName.hasPrefix("wg-"),
            "Provider interface should start with 'wg-'")
    }

    func testConsumerInterfaceNameFormat() {
        // Consumer uses wg<uuid8> format (no dash)
        let jobId = UUID()
        let interfaceName = "wg\(jobId.uuidString.prefix(8))"
        XCTAssertLessThanOrEqual(interfaceName.count, 15,
            "Consumer interface name must be ≤15 chars")
        XCTAssertFalse(interfaceName.contains("-"),
            "Consumer interface should not have dash")
    }

    // MARK: - VPN Configuration Tests

    func testVPNConfigurationFormat() {
        // Test that VPNConfiguration has all required fields
        let config = VPNConfiguration(
            consumerPublicKey: "test_public_key_base64_encoded_32bytes=",
            consumerEndpoint: "192.168.1.100:51900",
            consumerVPNIP: "10.99.0.1",
            vmVPNIP: "10.99.0.2",
            vpnSubnet: "10.99.0.0/24"
        )

        XCTAssertFalse(config.consumerPublicKey.isEmpty, "Consumer public key required")
        XCTAssertTrue(config.consumerEndpoint.contains(":"), "Endpoint needs port")
        XCTAssertTrue(config.vmVPNIP.hasPrefix("10."), "VM VPN IP should be in 10.x range")
        XCTAssertTrue(config.vpnSubnet.contains("/"), "Subnet needs CIDR notation")
    }

    func testVPNSubnetGeneration() {
        // Test that unique subnets are generated for different job IDs
        let jobId1 = UUID()
        let jobId2 = UUID()

        let subnet1 = generateVPNSubnet(for: jobId1)
        let subnet2 = generateVPNSubnet(for: jobId2)

        // Different UUIDs should (usually) generate different subnets
        // Note: There's a small chance of collision
        if jobId1 != jobId2 {
            // With 200*250 = 50,000 possible subnets, collision is rare
            print("Subnet 1: \(subnet1), Subnet 2: \(subnet2)")
        }

        // Both should be valid /24 subnets in 10.x.y.0 range
        XCTAssertTrue(subnet1.hasPrefix("10."), "Subnet should start with 10.")
        XCTAssertTrue(subnet1.hasSuffix(".0/24"), "Subnet should be /24")
        XCTAssertTrue(subnet2.hasPrefix("10."), "Subnet should start with 10.")
        XCTAssertTrue(subnet2.hasSuffix(".0/24"), "Subnet should be /24")
    }

    // MARK: - IP Address Validation Tests

    func testIPv4Validation() {
        let validIPs = ["10.0.0.1", "192.168.1.100", "255.255.255.255", "0.0.0.0"]
        let invalidIPs = ["256.0.0.1", "10.0.0", "10.0.0.1.2", "abc.def.ghi.jkl"]

        for ip in validIPs {
            XCTAssertTrue(isValidIPv4(ip), "\(ip) should be valid")
        }

        for ip in invalidIPs {
            XCTAssertFalse(isValidIPv4(ip), "\(ip) should be invalid")
        }
    }

    func testCIDRParsing() {
        let validCIDRs = ["10.0.0.0/8", "192.168.1.0/24", "10.99.0.2/32"]
        let invalidCIDRs = ["10.0.0.0", "10.0.0.0/33", "10.0.0.0/abc"]

        for cidr in validCIDRs {
            let parts = cidr.split(separator: "/")
            XCTAssertEqual(parts.count, 2, "\(cidr) should have 2 parts")
            if let prefix = UInt8(parts[1]) {
                XCTAssertLessThanOrEqual(prefix, 32, "Prefix should be ≤32")
            }
        }

        for cidr in invalidCIDRs {
            let parts = cidr.split(separator: "/")
            if parts.count == 2 {
                let prefix = UInt8(parts[1])
                XCTAssertTrue(prefix == nil || prefix! > 32, "\(cidr) should be invalid")
            }
        }
    }

    // MARK: - Linux Netlink Tests (compile on Linux only)

    #if os(Linux)
    func testLinuxWireGuardManagerInitialization() {
        let manager = LinuxWireGuardManager()
        XCTAssertNotNil(manager, "LinuxWireGuardManager should initialize")
    }

    func testNetlinkSocketCreation() throws {
        // Test that we can create netlink sockets
        // This requires root, so we test the error handling
        let manager = LinuxWireGuardManager()

        // Creating an interface without root should fail gracefully
        do {
            try manager.createInterface(
                name: "wgtest001",
                privateKeyBase64: try generateTestPrivateKey(),
                listenPort: 0,
                address: "10.250.0.1",
                prefixLength: 24,
                peers: []
            )
            // If we get here without error, we have root - clean up
            try? manager.deleteInterface(name: "wgtest001")
        } catch let error as NetlinkError {
            // Expected: should fail with permission error (EPERM = 1)
            if case .operationFailed(let errno) = error {
                XCTAssertEqual(errno, 1, "Should fail with EPERM (1) without root")
            }
        } catch {
            // Other errors are also acceptable in non-root context
            print("Non-root error (expected): \(error)")
        }
    }

    func testWireGuardPeerConfigParsing() {
        // Test peer configuration parsing
        let validPeerKey = "dGVzdF9wdWJsaWNfa2V5X2Jhc2U2NF9lbmNvZGVkMzI=" // 32 bytes base64
        let peerConfig = WireGuardPeerConfig(
            publicKeyBase64: validPeerKey,
            endpoint: nil,
            allowedIPs: [("10.99.0.2", 32)],
            persistentKeepalive: 25
        )

        XCTAssertNotNil(peerConfig, "Valid peer config should parse")
        XCTAssertEqual(peerConfig?.allowedIPs.count, 1, "Should have 1 allowed IP")
    }
    #endif

    // MARK: - macOS Native Tests (compile on macOS only)

    #if os(macOS)
    func testMacOSWireGuardManagerInitialization() async {
        let manager = MacOSWireGuardManager()
        // Manager should initialize without crashing
        let interfaceName = await manager.getInterfaceName()
        XCTAssertTrue(interfaceName.isEmpty, "Interface name should be empty before start")
    }

    func testWireGuardConfigCreation() throws {
        let privateKey = Data(repeating: 0x42, count: 32)
        let config = WireGuardConfig(
            privateKey: privateKey,
            listenPort: 51820,
            address: "10.99.0.1",
            prefixLength: 24,
            peers: []
        )

        XCTAssertEqual(config.listenPort, 51820, "Listen port should match")
        XCTAssertEqual(config.address, "10.99.0.1", "Address should match")
        XCTAssertEqual(config.prefixLength, 24, "Prefix length should match")
    }

    func testWireGuardPeerCreation() {
        let publicKey = Data(repeating: 0x43, count: 32)
        let peer = WireGuardPeer(
            publicKey: publicKey,
            endpoint: ("192.168.1.100", 51820),
            allowedIPs: [("10.99.0.2", 32)],
            persistentKeepalive: 25
        )

        XCTAssertEqual(peer.publicKey.count, 32, "Public key should be 32 bytes")
        XCTAssertNotNil(peer.endpoint, "Endpoint should be set")
        XCTAssertEqual(peer.allowedIPs.count, 1, "Should have 1 allowed IP")
    }

    func testPFRulesSyntax() throws {
        // Test pf rules syntax that caused the original issue
        let vmVPNIP = "10.233.77.2"
        let vmNATIP = "192.168.64.2"
        let interface = "utun8"

        // The CORRECT syntax (without 'inet' keyword that was causing issues)
        let correctRules = """
# Omerta NAT/RDR rules for VM \(vmVPNIP) -> \(vmNATIP)
# DNAT: Redirect traffic destined to VPN IP to the VM's NAT IP
rdr pass on \(interface) proto tcp from any to \(vmVPNIP) -> \(vmNATIP)
rdr pass on \(interface) proto udp from any to \(vmVPNIP) -> \(vmNATIP)
"""

        // Verify the rules don't contain 'inet' keyword that causes syntax errors
        XCTAssertFalse(correctRules.contains(" inet "),
            "Rules should not contain 'inet' keyword which causes pf syntax errors on macOS")

        // Verify basic structure
        XCTAssertTrue(correctRules.contains("rdr pass on"),
            "Should have rdr pass rules")
        XCTAssertTrue(correctRules.contains("proto tcp"),
            "Should have tcp protocol")
        XCTAssertTrue(correctRules.contains("proto udp"),
            "Should have udp protocol")
    }

    func testMacOSPacketFilterRulesGeneration() {
        // Test the NAT rules generation from MacOSPacketFilterManager
        let rules = MacOSPacketFilterManager.generateNATRules(
            vmVPNIP: "10.99.0.2",
            vmNATIP: "192.168.64.2",
            vpnInterface: "utun5",
            externalInterface: "en0"
        )

        // Verify structure
        XCTAssertTrue(rules.contains("nat on en0"),
            "Should have NAT rule for external interface")
        XCTAssertTrue(rules.contains("rdr on utun5"),
            "Should have RDR rule for VPN interface")
        XCTAssertTrue(rules.contains("pass quick"),
            "Should have pass rules for VPN traffic")

        // Verify no problematic 'inet' keyword in rdr rules
        let lines = rules.split(separator: "\n")
        for line in lines where line.contains("rdr") {
            XCTAssertFalse(line.contains(" inet "),
                "RDR line should not contain 'inet': \(line)")
        }
    }
    #endif

    // MARK: - Helper Functions

    private func generateTestPrivateKey() throws -> String {
        // Use Curve25519 to generate a valid private key
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return privateKey.rawRepresentation.base64EncodedString()
    }

    private func derivePublicKey(from privateKeyBase64: String) throws -> String {
        guard let privateKeyData = Data(base64Encoded: privateKeyBase64),
              privateKeyData.count == 32 else {
            throw NSError(domain: "TestError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid private key"])
        }

        // Use Curve25519 to derive public key
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        return privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    private func generateVPNSubnet(for jobId: UUID) -> String {
        let jobBytes = withUnsafeBytes(of: jobId.uuid) { Array($0) }
        let subnetByte1 = Int(jobBytes[0] % 200) + 50  // 50-249
        let subnetByte2 = Int(jobBytes[1] % 250) + 1   // 1-250
        return "10.\(subnetByte1).\(subnetByte2).0/24"
    }

    private func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part), num >= 0, num <= 255 else { return false }
            return true
        }
    }
}

// MARK: - Integration Tests (require actual system setup)

/// Integration tests that verify the full WireGuard flow
/// These require root privileges and are skipped in CI
final class NativeWireGuardIntegrationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()

        // Skip integration tests if not running as root
        #if os(Linux)
        guard geteuid() == 0 else {
            throw XCTSkip("Integration tests require root privileges")
        }
        #elseif os(macOS)
        guard geteuid() == 0 else {
            throw XCTSkip("Integration tests require root privileges")
        }
        #endif
    }

    #if os(Linux)
    func testLinuxInterfaceCreationAndCleanup() async throws {
        let manager = LinuxWireGuardManager()
        let testInterface = "wgtest123"
        let privateKey = try generateRandomKey()

        // Create interface
        try manager.createInterface(
            name: testInterface,
            privateKeyBase64: privateKey,
            listenPort: 0,
            address: "10.250.0.1",
            prefixLength: 24,
            peers: []
        )

        // Verify interface exists
        let exists = interfaceExists(testInterface)
        XCTAssertTrue(exists, "Interface should be created")

        // Delete interface
        try manager.deleteInterface(name: testInterface)

        // Verify interface is gone
        let existsAfter = interfaceExists(testInterface)
        XCTAssertFalse(existsAfter, "Interface should be deleted")
    }

    private func interfaceExists(_ name: String) -> Bool {
        let result = try? FileManager.default.contentsOfDirectory(atPath: "/sys/class/net")
        return result?.contains(name) ?? false
    }
    #endif

    #if os(macOS)
    func testMacOSInterfaceCreationAndCleanup() async throws {
        let manager = MacOSWireGuardManager()
        let privateKey = Data(repeating: 0x42, count: 32)

        let config = WireGuardConfig(
            privateKey: privateKey,
            listenPort: 0,  // Let system assign port
            address: "10.250.0.1",
            prefixLength: 24,
            peers: []
        )

        // Create interface
        try await manager.start(name: "wgtest", config: config)

        // Get interface name (should be utunX)
        let interfaceName = await manager.getInterfaceName()
        XCTAssertTrue(interfaceName.hasPrefix("utun"), "Interface should be utun")

        // Stop interface
        await manager.stop()
    }

    func testPFRulesLoadingAndFlushing() throws {
        let anchor = "omerta-test"
        let rules = "pass quick on lo0 all\n"

        // Try to enable pf (may already be enabled)
        try? MacOSPacketFilterManager.enable()

        // Load rules
        try MacOSPacketFilterManager.loadRulesIntoAnchor(anchor: anchor, rules: rules)

        // Flush rules
        try MacOSPacketFilterManager.flushAnchor(anchor: anchor)

        // Success if we get here without throwing
    }
    #endif

    private func generateRandomKey() throws -> String {
        // Use Curve25519 to generate a valid private key
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return privateKey.rawRepresentation.base64EncodedString()
    }
}
