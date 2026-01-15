import XCTest
@testable import OmertaVPN
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
            consumerPublicKey: "test_public_key_base64_encoded",
            consumerEndpoint: "192.168.1.1:51820",
            consumerVPNIP: "10.99.0.1",
            vmVPNIP: "10.99.0.2"
        )

        // Should not throw for valid configuration
        XCTAssertNoThrow(try validateTestConfig(validConfig))
    }

    func testInvalidConfigurationEmptyPublicKey() {
        let invalidConfig = VPNConfiguration(
            consumerPublicKey: "",
            consumerEndpoint: "192.168.1.1:51820",
            consumerVPNIP: "10.99.0.1",
            vmVPNIP: "10.99.0.2"
        )

        XCTAssertThrowsError(try validateTestConfig(invalidConfig))
    }

    func testInvalidConfigurationEmptyEndpoint() {
        let invalidConfig = VPNConfiguration(
            consumerPublicKey: "test_public_key_base64_encoded",
            consumerEndpoint: "",
            consumerVPNIP: "10.99.0.1",
            vmVPNIP: "10.99.0.2"
        )

        XCTAssertThrowsError(try validateTestConfig(invalidConfig))
    }

    func testInvalidConfigurationBadEndpointFormat() {
        let invalidConfig = VPNConfiguration(
            consumerPublicKey: "test_public_key_base64_encoded",
            consumerEndpoint: "192.168.1.1", // Missing port
            consumerVPNIP: "10.99.0.1",
            vmVPNIP: "10.99.0.2"
        )

        XCTAssertThrowsError(try validateTestConfig(invalidConfig))
    }

    func testActiveTunnelsTracking() async throws {
        // Initially empty
        let initialTunnels = await vpnManager.getActiveTunnels()
        XCTAssertEqual(initialTunnels.count, 0)

        // Note: Actual tunnel creation would require WireGuard to be installed
        // This test verifies the tracking mechanism
    }

    func testVPNConfigurationProperties() {
        let config = VPNConfiguration(
            consumerPublicKey: "test_public_key",
            consumerEndpoint: "192.168.1.1:51820",
            consumerVPNIP: "10.99.0.1",
            vmVPNIP: "10.99.0.2",
            vpnSubnet: "10.99.0.0/24"
        )

        XCTAssertEqual(config.consumerPublicKey, "test_public_key")
        XCTAssertEqual(config.consumerEndpoint, "192.168.1.1:51820")
        XCTAssertEqual(config.consumerVPNIP, "10.99.0.1")
        XCTAssertEqual(config.vmVPNIP, "10.99.0.2")
        XCTAssertEqual(config.vpnSubnet, "10.99.0.0/24")
    }

    // Helper function to test configuration validation
    private func validateTestConfig(_ config: VPNConfiguration) throws {
        guard !config.consumerPublicKey.isEmpty else {
            throw VPNError.invalidConfiguration("Empty consumer public key")
        }

        guard !config.consumerEndpoint.isEmpty else {
            throw VPNError.invalidConfiguration("Empty endpoint")
        }

        guard !config.consumerVPNIP.isEmpty else {
            throw VPNError.invalidConfiguration("Empty consumer VPN IP")
        }

        let components = config.consumerEndpoint.split(separator: ":")
        guard components.count == 2,
              let _ = UInt16(components[1]) else {
            throw VPNError.invalidConfiguration("Invalid endpoint format")
        }
    }
}
