import XCTest
@testable import OmertaVM

final class CloudInitTests: XCTestCase {

    // MARK: - Test Data

    static let testPrivateKey = "qD9x8+hW5a3j+K8L9z4xB7rN6yM2vP0wU1tG3kF5jHo="
    static let testPublicKey = "aB3c4D5e6F7g8H9i0J1k2L3m4N5o6P7q8R9s0T1u2V3="
    static let testEndpoint = "203.0.113.50:51820"

    // MARK: - VMNetworkConfig Tests

    func testVMNetworkConfigCreation() {
        let config = createTestConfig()

        XCTAssertEqual(config.wireGuard.privateKey, Self.testPrivateKey)
        XCTAssertEqual(config.wireGuard.address, "10.200.200.2/24")
        XCTAssertEqual(config.wireGuard.peer.publicKey, Self.testPublicKey)
        XCTAssertEqual(config.wireGuard.peer.endpoint, Self.testEndpoint)
        XCTAssertEqual(config.wireGuard.peer.allowedIPs, "0.0.0.0/0, ::/0")
        XCTAssertEqual(config.wireGuard.peer.persistentKeepalive, 25)
    }

    func testVMNetworkConfigDefaultFirewall() {
        let config = createTestConfig()

        XCTAssertTrue(config.firewall.allowLoopback)
        XCTAssertTrue(config.firewall.allowWireGuardInterface)
        XCTAssertTrue(config.firewall.allowDHCP)
        XCTAssertFalse(config.firewall.allowDNS)
        XCTAssertNil(config.firewall.customRules)
    }

    func testVMNetworkConfigCodable() throws {
        let original = createTestConfig()

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VMNetworkConfig.self, from: encoded)

        XCTAssertEqual(decoded.wireGuard.privateKey, original.wireGuard.privateKey)
        XCTAssertEqual(decoded.wireGuard.peer.publicKey, original.wireGuard.peer.publicKey)
        XCTAssertEqual(decoded.instanceId, original.instanceId)
        XCTAssertEqual(decoded.hostname, original.hostname)
    }

    // MARK: - User Data Generation Tests

    func testGenerateUserDataContainsCloudConfigHeader() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.hasPrefix("#cloud-config"), "Should start with #cloud-config header")
    }

    func testGenerateUserDataContainsHostname() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("hostname: \(config.hostname)"),
                     "Should contain hostname configuration")
    }

    func testGenerateUserDataContainsWireGuardConfig() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("path: /etc/wireguard/wg0.conf"),
                     "Should create WireGuard config file")
        XCTAssertTrue(userData.contains("PrivateKey = \(Self.testPrivateKey)"),
                     "Should contain WireGuard private key")
        XCTAssertTrue(userData.contains("Address = 10.200.200.2/24"),
                     "Should contain WireGuard address")
        XCTAssertTrue(userData.contains("PublicKey = \(Self.testPublicKey)"),
                     "Should contain peer public key")
        XCTAssertTrue(userData.contains("Endpoint = \(Self.testEndpoint)"),
                     "Should contain peer endpoint")
        XCTAssertTrue(userData.contains("AllowedIPs = 0.0.0.0/0, ::/0"),
                     "Should contain allowed IPs")
    }

    func testGenerateUserDataContainsOptionalPersistentKeepalive() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("PersistentKeepalive = 25"),
                     "Should contain persistent keepalive")
    }

    func testGenerateUserDataContainsFirewallScript() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("path: /etc/omerta/firewall.sh"),
                     "Should create firewall script")
        XCTAssertTrue(userData.contains("#!/bin/sh"),
                     "Firewall script should have shebang")
    }

    func testGenerateUserDataDropPolicies() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("iptables -P INPUT DROP"),
                     "Should have DROP policy for INPUT")
        XCTAssertTrue(userData.contains("iptables -P OUTPUT DROP"),
                     "Should have DROP policy for OUTPUT")
        XCTAssertTrue(userData.contains("iptables -P FORWARD DROP"),
                     "Should have DROP policy for FORWARD")
    }

    func testGenerateUserDataAllowsLoopback() {
        var config = createTestConfig()

        // With loopback allowed (default)
        var userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)
        XCTAssertTrue(userData.contains("-i lo -j ACCEPT"), "Should allow loopback input")
        XCTAssertTrue(userData.contains("-o lo -j ACCEPT"), "Should allow loopback output")
    }

    func testGenerateUserDataAllowsWireGuardInterface() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("-i wg0 -j ACCEPT"), "Should allow wg0 input")
        XCTAssertTrue(userData.contains("-o wg0 -j ACCEPT"), "Should allow wg0 output")
    }

    func testGenerateUserDataAllowsDHCP() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("--dport 67:68 -j ACCEPT"),
                     "Should allow DHCP output")
        XCTAssertTrue(userData.contains("--sport 67:68 -j ACCEPT"),
                     "Should allow DHCP input")
    }

    func testGenerateUserDataAllowsWireGuardHandshake() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        // Should allow UDP to the peer's port for initial handshake
        XCTAssertTrue(userData.contains("-p udp --dport 51820 -j ACCEPT"),
                     "Should allow WireGuard handshake UDP")
    }

    func testGenerateUserDataDoesNotAllowGeneralInternet() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        // Should NOT have general accept rules for eth0
        XCTAssertFalse(userData.contains("-o eth0 -j ACCEPT"),
                      "Should not allow general eth0 output")
        XCTAssertFalse(userData.contains("-i eth0 -j ACCEPT"),
                      "Should not allow general eth0 input")
    }

    func testGenerateUserDataContainsRunCommands() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("runcmd:"), "Should have runcmd section")
        XCTAssertTrue(userData.contains("/etc/omerta/firewall.sh"),
                     "Should run firewall script")
        XCTAssertTrue(userData.contains("wg-quick up wg0"),
                     "Should start WireGuard")
        XCTAssertTrue(userData.contains("wg show wg0"),
                     "Should verify WireGuard")
    }

    func testGenerateUserDataContainsSetupCompleteSignal() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("/run/omerta-ready"),
                     "Should signal setup complete")
        XCTAssertTrue(userData.contains("OMERTA_SETUP_COMPLETE"),
                     "Should write completion marker")
    }

    // MARK: - Package Installation Tests

    func testGenerateUserDataContainsPackages() {
        let config = createTestConfig()
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("package_update: true"),
                     "Should enable package update")
        XCTAssertTrue(userData.contains("packages:"),
                     "Should have packages section")
    }

    func testGenerateUserDataDebianPackages() {
        let config = createTestConfigWithPackages(.debian)
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("- wireguard"),
                     "Should include wireguard package for Debian")
        XCTAssertTrue(userData.contains("- iptables"),
                     "Should include iptables package")
    }

    func testGenerateUserDataAlpinePackages() {
        let config = createTestConfigWithPackages(.alpine)
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("- wireguard-tools"),
                     "Should include wireguard-tools for Alpine")
        XCTAssertTrue(userData.contains("- iptables"),
                     "Should include iptables package")
    }

    func testGenerateUserDataNoPackages() {
        let config = createTestConfigWithPackages(nil)
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertFalse(userData.contains("packages:"),
                      "Should not have packages section when nil")
    }

    // MARK: - Meta Data Tests

    func testGenerateMetaData() {
        let config = createTestConfig()
        let metaData = CloudInitGenerator.generateNetworkIsolationMetaData(config: config)

        XCTAssertTrue(metaData.contains("instance-id: \(config.instanceId)"),
                     "Should contain instance ID")
        XCTAssertTrue(metaData.contains("local-hostname: \(config.hostname)"),
                     "Should contain hostname")
    }

    // MARK: - Factory Tests

    func testVMNetworkConfigFactory() {
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: Self.testPublicKey,
            consumerEndpoint: Self.testEndpoint,
            vmPrivateKey: Self.testPrivateKey
        )

        XCTAssertEqual(config.wireGuard.privateKey, Self.testPrivateKey)
        XCTAssertEqual(config.wireGuard.peer.publicKey, Self.testPublicKey)
        XCTAssertEqual(config.wireGuard.peer.endpoint, Self.testEndpoint)
        XCTAssertEqual(config.wireGuard.address, "10.200.200.2/24")
        XCTAssertTrue(config.instanceId.hasPrefix("omerta-"))
        XCTAssertTrue(config.hostname.hasPrefix("omerta-vm-"))
    }

    func testVMNetworkConfigFactoryCustomAddress() {
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: Self.testPublicKey,
            consumerEndpoint: Self.testEndpoint,
            vmPrivateKey: Self.testPrivateKey,
            vmAddress: "192.168.100.2/24"
        )

        XCTAssertEqual(config.wireGuard.address, "192.168.100.2/24")
    }

    func testVMNetworkConfigFactoryCustomPackageConfig() {
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: Self.testPublicKey,
            consumerEndpoint: Self.testEndpoint,
            vmPrivateKey: Self.testPrivateKey,
            packageConfig: .alpine
        )

        XCTAssertEqual(config.packageConfig?.packages, ["wireguard-tools", "iptables"])
    }

    // MARK: - Custom Firewall Rules Tests

    func testGenerateUserDataCustomFirewallRules() {
        let customRules = [
            "iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT",
            "iptables -A INPUT -p tcp --sport 443 -j ACCEPT"
        ]

        let config = VMNetworkConfig(
            wireGuard: .init(
                privateKey: Self.testPrivateKey,
                address: "10.200.200.2/24",
                peer: .init(
                    publicKey: Self.testPublicKey,
                    endpoint: Self.testEndpoint
                )
            ),
            firewall: .init(customRules: customRules),
            instanceId: "test-123",
            hostname: "test-vm"
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("--dport 443 -j ACCEPT"),
                     "Should contain custom HTTPS rule")
    }

    // MARK: - Edge Cases

    func testEndpointPortExtraction() {
        // Test with non-standard port
        let config = VMNetworkConfig(
            wireGuard: .init(
                privateKey: Self.testPrivateKey,
                address: "10.200.200.2/24",
                peer: .init(
                    publicKey: Self.testPublicKey,
                    endpoint: "1.2.3.4:12345"
                )
            ),
            instanceId: "test-123",
            hostname: "test-vm"
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("--dport 12345 -j ACCEPT"),
                     "Should extract and use non-standard port")
    }

    func testOptionalListenPort() {
        let config = VMNetworkConfig(
            wireGuard: .init(
                privateKey: Self.testPrivateKey,
                address: "10.200.200.2/24",
                listenPort: 51821,
                peer: .init(
                    publicKey: Self.testPublicKey,
                    endpoint: Self.testEndpoint
                )
            ),
            instanceId: "test-123",
            hostname: "test-vm"
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertTrue(userData.contains("ListenPort = 51821"),
                     "Should include listen port when specified")
    }

    func testNoPersistentKeepalive() {
        let config = VMNetworkConfig(
            wireGuard: .init(
                privateKey: Self.testPrivateKey,
                address: "10.200.200.2/24",
                peer: .init(
                    publicKey: Self.testPublicKey,
                    endpoint: Self.testEndpoint,
                    persistentKeepalive: nil
                )
            ),
            instanceId: "test-123",
            hostname: "test-vm"
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertFalse(userData.contains("PersistentKeepalive"),
                      "Should not include PersistentKeepalive when nil")
    }

    // MARK: - Helpers

    private func createTestConfig() -> VMNetworkConfig {
        VMNetworkConfig(
            wireGuard: .init(
                privateKey: Self.testPrivateKey,
                address: "10.200.200.2/24",
                peer: .init(
                    publicKey: Self.testPublicKey,
                    endpoint: Self.testEndpoint
                )
            ),
            packageConfig: .debian,
            instanceId: "test-instance-123",
            hostname: "omerta-vm-test"
        )
    }

    private func createTestConfigWithPackages(_ packageConfig: VMNetworkConfig.PackageConfig?) -> VMNetworkConfig {
        VMNetworkConfig(
            wireGuard: .init(
                privateKey: Self.testPrivateKey,
                address: "10.200.200.2/24",
                peer: .init(
                    publicKey: Self.testPublicKey,
                    endpoint: Self.testEndpoint
                )
            ),
            packageConfig: packageConfig,
            instanceId: "test-instance-123",
            hostname: "omerta-vm-test"
        )
    }
}
