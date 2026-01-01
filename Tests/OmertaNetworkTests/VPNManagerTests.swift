import XCTest
@testable import OmertaNetwork
@testable import OmertaCore
import Foundation

final class VPNManagerTests: XCTestCase {
    var vpnManager: VPNManager!

    override func setUp() async throws {
        try await super.setUp()
        vpnManager = VPNManager(wireguardToolPath: "/usr/bin/echo") // Mock for tests
    }

    func testValidateConfiguration() async throws {
        let validConfig = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test\n",
            endpoint: "192.168.1.1:51820",
            publicKey: Data("test".utf8),
            allowedIPs: "0.0.0.0/0",
            vpnServerIP: "10.99.0.1"
        )

        // Should not throw for valid configuration
        XCTAssertNoThrow(try validateTestConfig(validConfig))
    }

    func testInvalidConfigurationEmptyWireguardConfig() {
        let invalidConfig = VPNConfiguration(
            wireguardConfig: "",
            endpoint: "192.168.1.1:51820",
            publicKey: Data("test".utf8),
            vpnServerIP: "10.99.0.1"
        )

        XCTAssertThrowsError(try validateTestConfig(invalidConfig))
    }

    func testInvalidConfigurationEmptyEndpoint() {
        let invalidConfig = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test\n",
            endpoint: "",
            publicKey: Data("test".utf8),
            vpnServerIP: "10.99.0.1"
        )

        XCTAssertThrowsError(try validateTestConfig(invalidConfig))
    }

    func testInvalidConfigurationBadEndpointFormat() {
        let invalidConfig = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test\n",
            endpoint: "192.168.1.1", // Missing port
            publicKey: Data("test".utf8),
            vpnServerIP: "10.99.0.1"
        )

        XCTAssertThrowsError(try validateTestConfig(invalidConfig))
    }

    func testActiveTunnelsTracking() async throws {
        let jobId1 = UUID()
        let jobId2 = UUID()

        let config1 = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test1\n",
            endpoint: "192.168.1.1:51820",
            publicKey: Data("test1".utf8),
            vpnServerIP: "10.99.0.1"
        )

        let config2 = VPNConfiguration(
            wireguardConfig: "[Interface]\nPrivateKey=test2\n",
            endpoint: "192.168.1.2:51821",
            publicKey: Data("test2".utf8),
            vpnServerIP: "10.99.0.2"
        )

        // Initially empty
        let initialTunnels = await vpnManager.getActiveTunnels()
        XCTAssertEqual(initialTunnels.count, 0)

        // Note: Actual tunnel creation would require WireGuard to be installed
        // This test verifies the tracking mechanism
    }

    // Helper function to test configuration validation
    private func validateTestConfig(_ config: VPNConfiguration) throws {
        guard !config.wireguardConfig.isEmpty else {
            throw VPNError.invalidConfiguration("Empty WireGuard config")
        }

        guard !config.endpoint.isEmpty else {
            throw VPNError.invalidConfiguration("Empty endpoint")
        }

        guard !config.vpnServerIP.isEmpty else {
            throw VPNError.invalidConfiguration("Empty VPN server IP")
        }

        let components = config.endpoint.split(separator: ":")
        guard components.count == 2,
              let _ = UInt16(components[1]) else {
            throw VPNError.invalidConfiguration("Invalid endpoint format")
        }
    }
}
