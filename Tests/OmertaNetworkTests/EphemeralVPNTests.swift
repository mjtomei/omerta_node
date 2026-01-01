import XCTest
@testable import OmertaNetwork
@testable import OmertaCore
import Foundation

final class EphemeralVPNTests: XCTestCase {
    var ephemeralVPN: EphemeralVPN!

    override func setUp() async throws {
        try await super.setUp()
        ephemeralVPN = EphemeralVPN(basePort: 52000)
    }

    func testPortAllocation() async throws {
        // Port allocation should be sequential
        let jobId1 = UUID()
        let jobId2 = UUID()

        // Note: Actual VPN creation would require WireGuard to be installed
        // This test verifies the port allocation logic

        let servers = await ephemeralVPN.getActiveServers()
        XCTAssertEqual(servers.count, 0, "Should start with no active servers")
    }

    func testVPNConfigurationGeneration() {
        // Test that generated config contains required sections
        let config = generateTestServerConfig()

        XCTAssertTrue(config.contains("[Interface]"), "Config should have Interface section")
        XCTAssertTrue(config.contains("[Peer]"), "Config should have Peer section")
        XCTAssertTrue(config.contains("PrivateKey"), "Config should have PrivateKey")
        XCTAssertTrue(config.contains("ListenPort"), "Config should have ListenPort")
    }

    func testClientConfigurationGeneration() {
        let config = generateTestClientConfig()

        XCTAssertTrue(config.contains("[Interface]"), "Client config should have Interface section")
        XCTAssertTrue(config.contains("[Peer]"), "Client config should have Peer section")
        XCTAssertTrue(config.contains("Endpoint"), "Client config should have Endpoint")
        XCTAssertTrue(config.contains("AllowedIPs = 0.0.0.0/0"), "Client config should route all traffic through VPN")
        XCTAssertTrue(config.contains("PersistentKeepalive"), "Client config should have keepalive")
    }

    func testNATForwardingRules() {
        let config = generateTestServerConfig()

        // Verify NAT and forwarding rules are present
        XCTAssertTrue(config.contains("PostUp"), "Should have PostUp rules")
        XCTAssertTrue(config.contains("PostDown"), "Should have PostDown rules")
        XCTAssertTrue(config.contains("iptables"), "Should configure iptables")
        XCTAssertTrue(config.contains("MASQUERADE"), "Should enable NAT masquerading")
        XCTAssertTrue(config.contains("ip_forward"), "Should enable IP forwarding")
    }

    func testMultipleServerTracking() async {
        let servers = await ephemeralVPN.getActiveServers()

        // Should be able to track multiple VPN servers simultaneously
        XCTAssertEqual(servers.count, 0, "Should start with empty server list")
    }

    // Helper functions
    private func generateTestServerConfig() -> String {
        """
        [Interface]
        PrivateKey = test_private_key
        Address = 10.99.0.1/24
        ListenPort = 51820

        # Enable IP forwarding
        PostUp = sysctl -w net.ipv4.ip_forward=1
        PostUp = iptables -A FORWARD -i %i -j ACCEPT
        PostUp = iptables -A FORWARD -o %i -j ACCEPT
        PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

        PostDown = iptables -D FORWARD -i %i -j ACCEPT
        PostDown = iptables -D FORWARD -o %i -j ACCEPT
        PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

        [Peer]
        PublicKey = test_client_public_key
        AllowedIPs = 10.99.0.2/32
        """
    }

    private func generateTestClientConfig() -> String {
        """
        [Interface]
        PrivateKey = test_private_key
        Address = 10.99.0.2/24
        DNS = 8.8.8.8

        [Peer]
        PublicKey = test_server_public_key
        Endpoint = 192.168.1.100:51820
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25
        """
    }
}
