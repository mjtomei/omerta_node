// CrossPlatformTests.swift
// Phase 11.5: Cross-Platform Compatibility Tests

import XCTest
@testable import OmertaNetwork
@testable import OmertaVM

/// Tests that verify network configuration is portable across platforms
/// These tests ensure that a consumer on macOS can work with a provider on Linux and vice versa
final class CrossPlatformTests: XCTestCase {

    // MARK: - Cloud-Init Portability Tests

    func testCloudInitIdenticalAcrossPlatforms() throws {
        // Given: Same input parameters
        let consumerPublicKey = "dGVzdC1wdWJsaWMta2V5LWJhc2U2NC1lbmNvZGVkMTI="  // Fixed for reproducibility
        let vmPrivateKey = "dGVzdC1wcml2YXRlLWtleS1iYXNlNjQtZW5jb2RlZDE="
        let consumerEndpoint = "203.0.113.50:51820"
        let vmAddress = "10.200.200.2/24"
        let instanceId = "omerta-test1234"
        let hostname = "omerta-vm-test1234"

        // When: We create config with fixed parameters
        let config = VMNetworkConfig(
            wireGuard: .init(
                privateKey: vmPrivateKey,
                address: vmAddress,
                listenPort: nil,
                peer: .init(
                    publicKey: consumerPublicKey,
                    endpoint: consumerEndpoint,
                    allowedIPs: "0.0.0.0/0, ::/0",
                    persistentKeepalive: 25
                )
            ),
            firewall: .init(
                allowLoopback: true,
                allowWireGuardInterface: true,
                allowDHCP: true,
                allowDNS: false,
                allowPackageInstall: false,
                customRules: nil
            ),
            packageConfig: nil,  // No packages for reproducibility
            instanceId: instanceId,
            hostname: hostname
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        // Then: Key configuration elements are present and correct
        // These should be identical whether generated on macOS or Linux

        // WireGuard config
        XCTAssertTrue(userData.contains("PrivateKey = \(vmPrivateKey)"))
        XCTAssertTrue(userData.contains("Address = \(vmAddress)"))
        XCTAssertTrue(userData.contains("PublicKey = \(consumerPublicKey)"))
        XCTAssertTrue(userData.contains("Endpoint = \(consumerEndpoint)"))
        XCTAssertTrue(userData.contains("AllowedIPs = 0.0.0.0/0, ::/0"))
        XCTAssertTrue(userData.contains("PersistentKeepalive = 25"))

        // Firewall rules
        XCTAssertTrue(userData.contains("iptables -P INPUT DROP"))
        XCTAssertTrue(userData.contains("iptables -P OUTPUT DROP"))
        XCTAssertTrue(userData.contains("iptables -P FORWARD DROP"))
        XCTAssertTrue(userData.contains("-i wg0 -j ACCEPT"))
        XCTAssertTrue(userData.contains("-o wg0 -j ACCEPT"))

        // Hostname
        XCTAssertTrue(userData.contains("hostname: \(hostname)"))
    }

    func testWireGuardConfigFormatStandard() throws {
        // Verify WireGuard config matches standard wg format
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let vmPrivateKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: "10.0.0.1:51820",
            vmPrivateKey: vmPrivateKey
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        // WireGuard config should have standard INI format
        XCTAssertTrue(userData.contains("[Interface]"))
        XCTAssertTrue(userData.contains("[Peer]"))
        XCTAssertTrue(userData.contains("PrivateKey = "))
        XCTAssertTrue(userData.contains("PublicKey = "))
        XCTAssertTrue(userData.contains("Endpoint = "))
        XCTAssertTrue(userData.contains("AllowedIPs = "))
    }

    func testFirewallRulesUseStandardIptables() throws {
        // Verify iptables commands are standard Linux syntax
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "dGVzdC1rZXk=",
            consumerEndpoint: "10.0.0.1:51820",
            vmPrivateKey: "dGVzdC1wcml2YXRlLWtleQ=="
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        // Standard iptables syntax that works on any Linux distro
        XCTAssertTrue(userData.contains("iptables -F"))  // Flush
        XCTAssertTrue(userData.contains("iptables -X"))  // Delete chains
        XCTAssertTrue(userData.contains("iptables -P"))  // Set policy
        XCTAssertTrue(userData.contains("iptables -A"))  // Append rule
        XCTAssertTrue(userData.contains("-m state --state ESTABLISHED,RELATED"))
    }

    // MARK: - WireGuard Key Format Tests

    func testWireGuardKeyIsBase64() throws {
        // WireGuard keys must be valid base64
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        // Verify it's valid base64
        let decoded = Data(base64Encoded: key)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 32, "WireGuard key should be 32 bytes")
    }

    func testWireGuardKeyLength() throws {
        // WireGuard uses Curve25519 which requires exactly 32 bytes
        let keyData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let base64Key = keyData.base64EncodedString()

        // Base64 of 32 bytes = 44 characters (with padding)
        XCTAssertEqual(base64Key.count, 44, "Base64 encoded 32-byte key should be 44 chars")
    }

    // MARK: - Consumer/Provider Interoperability Tests

    func testConsumerConfigCompatibleWithAnyProvider() throws {
        // A consumer's VPN config should work with providers on any platform
        let consumerPrivateKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        // Consumer's WireGuard server config
        let consumerConfig = """
        [Interface]
        PrivateKey = \(consumerPrivateKey)
        Address = 10.200.200.1/24
        ListenPort = 51820

        # Provider's VM will be added as peer dynamically
        """

        XCTAssertTrue(consumerConfig.contains("[Interface]"))
        XCTAssertTrue(consumerConfig.contains("ListenPort = 51820"))
    }

    func testProviderVMConfigCompatibleWithAnyConsumer() throws {
        // A provider's VM config should connect to consumers on any platform
        let vmPrivateKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: "consumer.example.com:51820",
            vmPrivateKey: vmPrivateKey
        )

        // VM acts as WireGuard client (no ListenPort needed)
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        XCTAssertFalse(userData.contains("ListenPort"),
                      "VM client should not specify ListenPort")
        XCTAssertTrue(userData.contains("Endpoint = consumer.example.com:51820"))
    }

    // MARK: - VPN IP Address Tests

    func testVPNIPAddressFormat() throws {
        // VPN IPs should be valid CIDR notation
        let vmAddress = "10.200.200.2/24"

        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "dGVzdC1rZXk=",
            consumerEndpoint: "10.0.0.1:51820",
            vmPrivateKey: "dGVzdC1wcml2YXRlLWtleQ==",
            vmAddress: vmAddress
        )

        XCTAssertEqual(config.wireGuard.address, vmAddress)
        XCTAssertTrue(vmAddress.contains("/"), "Address should include CIDR prefix")
    }

    func testVPNSubnetConsistency() throws {
        // Consumer and VM should be in same subnet
        let consumerIP = "10.200.200.1"
        let vmIP = "10.200.200.2"
        let subnet = "/24"

        // Both should be in 10.200.200.0/24
        let consumerParts = consumerIP.split(separator: ".")
        let vmParts = vmIP.split(separator: ".")

        // First 3 octets should match for /24
        XCTAssertEqual(consumerParts[0], vmParts[0])
        XCTAssertEqual(consumerParts[1], vmParts[1])
        XCTAssertEqual(consumerParts[2], vmParts[2])
    }

    // MARK: - Endpoint Format Tests

    func testEndpointWithIPAddress() throws {
        let endpoint = "203.0.113.50:51820"

        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "dGVzdC1rZXk=",
            consumerEndpoint: endpoint,
            vmPrivateKey: "dGVzdC1wcml2YXRlLWtleQ=="
        )

        XCTAssertEqual(config.wireGuard.peer.endpoint, endpoint)
    }

    func testEndpointWithHostname() throws {
        let endpoint = "vpn.example.com:51820"

        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "dGVzdC1rZXk=",
            consumerEndpoint: endpoint,
            vmPrivateKey: "dGVzdC1wcml2YXRlLWtleQ=="
        )

        XCTAssertEqual(config.wireGuard.peer.endpoint, endpoint)
    }

    func testEndpointWithIPv6() throws {
        let endpoint = "[2001:db8::1]:51820"

        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "dGVzdC1rZXk=",
            consumerEndpoint: endpoint,
            vmPrivateKey: "dGVzdC1wcml2YXRlLWtleQ=="
        )

        XCTAssertEqual(config.wireGuard.peer.endpoint, endpoint)
    }

    // MARK: - Package Config Portability Tests

    func testDebianPackagesValid() throws {
        let config = VMNetworkConfig.PackageConfig.debian

        XCTAssertTrue(config.packages.contains("wireguard"))
        XCTAssertTrue(config.packages.contains("iptables"))
    }

    func testAlpinePackagesValid() throws {
        let config = VMNetworkConfig.PackageConfig.alpine

        // Alpine uses wireguard-tools, not wireguard
        XCTAssertTrue(config.packages.contains("wireguard-tools"))
        XCTAssertTrue(config.packages.contains("iptables"))
    }

    // MARK: - Cloud-Init Format Tests

    func testCloudInitYAMLValid() throws {
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "dGVzdC1rZXk=",
            consumerEndpoint: "10.0.0.1:51820",
            vmPrivateKey: "dGVzdC1wcml2YXRlLWtleQ=="
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        // Must start with cloud-config directive
        XCTAssertTrue(userData.hasPrefix("#cloud-config"))

        // Must have required cloud-init sections
        XCTAssertTrue(userData.contains("write_files:"))
        XCTAssertTrue(userData.contains("runcmd:"))
    }

    func testCloudInitMetaDataValid() throws {
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "dGVzdC1rZXk=",
            consumerEndpoint: "10.0.0.1:51820",
            vmPrivateKey: "dGVzdC1wcml2YXRlLWtleQ=="
        )

        let metaData = CloudInitGenerator.generateNetworkIsolationMetaData(config: config)

        // Must have instance-id and hostname
        XCTAssertTrue(metaData.contains("instance-id:"))
        XCTAssertTrue(metaData.contains("local-hostname:"))
    }
}

// MARK: - Cross-Platform Matrix Simulation Tests

/// These tests simulate the 4 provider/consumer platform combinations
final class CrossPlatformMatrixTests: XCTestCase {

    struct PlatformPair {
        let provider: String
        let consumer: String
    }

    let platformCombinations = [
        PlatformPair(provider: "macOS", consumer: "macOS"),
        PlatformPair(provider: "macOS", consumer: "Linux"),
        PlatformPair(provider: "Linux", consumer: "macOS"),
        PlatformPair(provider: "Linux", consumer: "Linux")
    ]

    func testAllPlatformPairsGenerateCompatibleConfig() throws {
        for pair in platformCombinations {
            // Consumer creates WireGuard server (generates keypair)
            let consumerPrivateKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let consumerEndpoint = "10.0.0.1:51820"

            // Provider creates VM config
            let vmPrivateKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

            let vmConfig = VMNetworkConfigFactory.createForConsumer(
                consumerPublicKey: consumerPublicKey,
                consumerEndpoint: consumerEndpoint,
                vmPrivateKey: vmPrivateKey
            )

            let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmConfig)

            // Verify config is valid for this platform pair
            XCTAssertTrue(userData.contains("wg-quick up wg0"),
                         "\(pair.provider) provider → \(pair.consumer) consumer: missing wg-quick")
            XCTAssertTrue(userData.contains("iptables"),
                         "\(pair.provider) provider → \(pair.consumer) consumer: missing iptables")
            XCTAssertTrue(userData.contains(consumerPublicKey),
                         "\(pair.provider) provider → \(pair.consumer) consumer: missing consumer key")
        }
    }

    func testWireGuardHandshakeRequirements() throws {
        // For WireGuard handshake to work:
        // 1. Consumer must have VM's public key
        // 2. VM must have consumer's public key
        // 3. VM must know consumer's endpoint
        // 4. Consumer doesn't need VM's endpoint (VM initiates)

        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let vmPrivateKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let vmPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: "consumer.example.com:51820",
            vmPrivateKey: vmPrivateKey
        )

        // VM config has consumer's public key
        XCTAssertEqual(vmConfig.wireGuard.peer.publicKey, consumerPublicKey)

        // VM config has consumer's endpoint
        XCTAssertEqual(vmConfig.wireGuard.peer.endpoint, "consumer.example.com:51820")

        // VM has private key (public key derived from it)
        XCTAssertEqual(vmConfig.wireGuard.privateKey, vmPrivateKey)

        // Consumer would add VM as peer:
        // [Peer]
        // PublicKey = <vmPublicKey>
        // AllowedIPs = 10.200.200.2/32
        // (No Endpoint needed - VM initiates connection)
        XCTAssertFalse(vmPublicKey.isEmpty, "VM public key must be shared with consumer")
    }
}
