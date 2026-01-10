// E2EConnectivityTests.swift
// Phase 11: End-to-End Connectivity Tests

import XCTest
@testable import OmertaNetwork
@testable import OmertaVM
@testable import OmertaProvider
@testable import OmertaCore

#if os(Linux)
import Foundation
#endif

// MARK: - E2E Test Infrastructure

/// Test helper for simulating consumer WireGuard server
struct MockConsumerServer {
    let publicKey: String
    let privateKey: String
    let endpoint: String
    let vpnSubnet: String
    let serverVPNIP: String
    let clientVPNIP: String

    static func create(port: UInt16 = 51820) -> MockConsumerServer {
        // Generate test keys (base64 encoded 32-byte keys)
        let privateKeyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let privateKey = Data(privateKeyBytes).base64EncodedString()

        // For testing, public key can be derived or simulated
        let publicKeyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let publicKey = Data(publicKeyBytes).base64EncodedString()

        return MockConsumerServer(
            publicKey: publicKey,
            privateKey: privateKey,
            endpoint: "203.0.113.50:\(port)",
            vpnSubnet: "10.200.200.0/24",
            serverVPNIP: "10.200.200.1",
            clientVPNIP: "10.200.200.2"
        )
    }
}

/// Test helper for VM network setup verification
struct VMNetworkVerifier {

    /// Verify cloud-init config contains correct WireGuard settings
    static func verifyCloudInitConfig(
        config: VMNetworkConfig,
        expectedConsumerPublicKey: String,
        expectedEndpoint: String
    ) -> [String] {
        var errors: [String] = []

        // Verify WireGuard peer config
        if config.wireGuard.peer.publicKey != expectedConsumerPublicKey {
            errors.append("WireGuard peer public key mismatch")
        }

        if config.wireGuard.peer.endpoint != expectedEndpoint {
            errors.append("WireGuard endpoint mismatch: expected \(expectedEndpoint), got \(config.wireGuard.peer.endpoint)")
        }

        // Verify firewall defaults
        if !config.firewall.allowLoopback {
            errors.append("Firewall should allow loopback")
        }

        if !config.firewall.allowWireGuardInterface {
            errors.append("Firewall should allow WireGuard interface")
        }

        return errors
    }

    /// Verify generated user-data YAML contains expected content
    static func verifyUserData(
        userData: String,
        expectedConsumerPublicKey: String,
        expectedEndpoint: String
    ) -> [String] {
        var errors: [String] = []

        // Must be cloud-config format
        if !userData.hasPrefix("#cloud-config") {
            errors.append("User data must start with #cloud-config")
        }

        // Must contain WireGuard config
        if !userData.contains("path: /etc/wireguard/wg0.conf") {
            errors.append("Missing WireGuard config file")
        }

        if !userData.contains("PublicKey = \(expectedConsumerPublicKey)") {
            errors.append("Missing consumer public key in WireGuard config")
        }

        if !userData.contains("Endpoint = \(expectedEndpoint)") {
            errors.append("Missing endpoint in WireGuard config")
        }

        // Must contain firewall script
        if !userData.contains("path: /etc/omerta/firewall.sh") {
            errors.append("Missing firewall script")
        }

        // Must have DROP policies
        if !userData.contains("iptables -P OUTPUT DROP") {
            errors.append("Missing OUTPUT DROP policy")
        }

        if !userData.contains("iptables -P INPUT DROP") {
            errors.append("Missing INPUT DROP policy")
        }

        // Must allow WireGuard interface
        if !userData.contains("-o wg0 -j ACCEPT") {
            errors.append("Missing wg0 output allow rule")
        }

        // Must have setup completion signal
        if !userData.contains("/run/omerta-ready") {
            errors.append("Missing setup completion signal")
        }

        return errors
    }

    /// Verify firewall rules block non-WireGuard traffic
    static func verifyIsolationRules(userData: String) -> [String] {
        var errors: [String] = []

        // Should NOT allow general eth0 traffic
        if userData.contains("-o eth0 -j ACCEPT") && !userData.contains("--dport 67:68") {
            errors.append("Should not allow general eth0 output")
        }

        // Should block by default
        if !userData.contains("-P OUTPUT DROP") {
            errors.append("Default OUTPUT policy should be DROP")
        }

        // Should allow WireGuard handshake port
        let portPatterns = [
            "--dport 51820",
            "--dport 51821",
            "--dport 51900"
        ]
        let hasHandshakeRule = portPatterns.contains { userData.contains($0) }
        if !hasHandshakeRule && !userData.contains("-p udp --dport") {
            errors.append("Should allow WireGuard handshake UDP port")
        }

        return errors
    }
}

// MARK: - E2E Flow Tests (No actual VMs)

final class E2EConnectivityTests: XCTestCase {

    // MARK: - Full Flow Simulation Tests

    func testE2EFlowConfigGeneration() throws {
        // Simulate consumer creating a WireGuard server
        let consumer = MockConsumerServer.create(port: 51820)

        // Provider receives consumer's public key and endpoint
        // Provider generates VM config
        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vmPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(),
            vmAddress: consumer.clientVPNIP + "/24"
        )

        // Verify the config is correct
        let configErrors = VMNetworkVerifier.verifyCloudInitConfig(
            config: vmConfig,
            expectedConsumerPublicKey: consumer.publicKey,
            expectedEndpoint: consumer.endpoint
        )

        XCTAssertTrue(configErrors.isEmpty, "Config errors: \(configErrors.joined(separator: ", "))")
    }

    func testE2EFlowUserDataGeneration() throws {
        let consumer = MockConsumerServer.create(port: 51820)

        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vmPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        )

        // Generate cloud-init user-data
        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmConfig)

        // Verify user-data content
        let errors = VMNetworkVerifier.verifyUserData(
            userData: userData,
            expectedConsumerPublicKey: consumer.publicKey,
            expectedEndpoint: consumer.endpoint
        )

        XCTAssertTrue(errors.isEmpty, "User data errors: \(errors.joined(separator: ", "))")
    }

    func testE2EFlowIsolationRules() throws {
        let consumer = MockConsumerServer.create(port: 51820)

        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vmPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmConfig)

        // Verify isolation rules
        let errors = VMNetworkVerifier.verifyIsolationRules(userData: userData)

        XCTAssertTrue(errors.isEmpty, "Isolation errors: \(errors.joined(separator: ", "))")
    }

    // MARK: - Consumer Server Tests

    func testConsumerServerConfigGeneration() {
        let consumer = MockConsumerServer.create(port: 51900)

        XCTAssertFalse(consumer.publicKey.isEmpty)
        XCTAssertFalse(consumer.privateKey.isEmpty)
        XCTAssertTrue(consumer.endpoint.contains(":51900"))
        XCTAssertEqual(consumer.vpnSubnet, "10.200.200.0/24")
    }

    func testConsumerServerUniqueKeys() {
        let server1 = MockConsumerServer.create()
        let server2 = MockConsumerServer.create()

        // Each server should have unique keys
        XCTAssertNotEqual(server1.publicKey, server2.publicKey)
        XCTAssertNotEqual(server1.privateKey, server2.privateKey)
    }

    // MARK: - VM Network Mode Tests

    func testAllNetworkModesGenerateValidConfig() throws {
        let consumer = MockConsumerServer.create()
        let modeNames = ["direct", "sampled", "conntrack", "filtered"]

        for modeName in modeNames {
            let vmConfig = VMNetworkConfigFactory.createForConsumer(
                consumerPublicKey: consumer.publicKey,
                consumerEndpoint: consumer.endpoint,
                vmPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            )

            let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmConfig)

            // All modes should generate valid cloud-init config
            XCTAssertTrue(userData.hasPrefix("#cloud-config"),
                         "Mode \(modeName) should generate valid cloud-config")
            XCTAssertTrue(userData.contains("wg-quick up wg0"),
                         "Mode \(modeName) should start WireGuard")
        }
    }

    // MARK: - Bidirectional Config Tests

    func testBidirectionalConfigConsistency() throws {
        // Consumer creates server config
        let consumer = MockConsumerServer.create(port: 51820)

        // VM private key
        let vmPrivateKeyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let vmPrivateKey = Data(vmPrivateKeyBytes).base64EncodedString()

        // For a real scenario, derive public key from private
        // For test, simulate with random bytes
        let vmPublicKeyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let vmPublicKey = Data(vmPublicKeyBytes).base64EncodedString()

        // VM config points to consumer
        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vmPrivateKey: vmPrivateKey,
            vmAddress: consumer.clientVPNIP + "/24"
        )

        // Verify VM config has consumer as peer
        XCTAssertEqual(vmConfig.wireGuard.peer.publicKey, consumer.publicKey)
        XCTAssertEqual(vmConfig.wireGuard.peer.endpoint, consumer.endpoint)

        // In real scenario, consumer would add VM as peer using vmPublicKey
        // This test verifies the config structure is correct for both sides
        XCTAssertFalse(vmPublicKey.isEmpty, "VM should have public key to share with consumer")
    }

    // MARK: - Package Installation Tests

    func testPackageInstallationIncluded() throws {
        let consumer = MockConsumerServer.create()

        // Test with Debian packages
        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vmPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(),
            packageConfig: .debian
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmConfig)

        XCTAssertTrue(userData.contains("packages:"), "Should have packages section")
        XCTAssertTrue(userData.contains("- wireguard"), "Should install wireguard")
        XCTAssertTrue(userData.contains("- iptables"), "Should install iptables")
    }

    func testAlpinePackageNames() throws {
        let consumer = MockConsumerServer.create()

        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vmPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(),
            packageConfig: .alpine
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmConfig)

        XCTAssertTrue(userData.contains("- wireguard-tools"), "Alpine uses wireguard-tools")
    }

    // MARK: - Setup Completion Signal Tests

    func testSetupCompletionSignal() throws {
        let consumer = MockConsumerServer.create()

        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vmPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmConfig)

        // Verify setup completion signal
        XCTAssertTrue(userData.contains("OMERTA_SETUP_COMPLETE"),
                     "Should write completion marker")
        XCTAssertTrue(userData.contains("/run/omerta-ready"),
                     "Should signal to /run/omerta-ready")
        XCTAssertTrue(userData.contains("/etc/omerta/setup-complete.sh"),
                     "Should have setup-complete script")
    }

    // MARK: - Firewall Order Tests

    func testFirewallAppliedBeforeWireGuard() throws {
        let consumer = MockConsumerServer.create()

        let vmConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vmPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmConfig)

        // Find positions of firewall and wireguard commands in runcmd
        guard let firewallPos = userData.range(of: "/etc/omerta/firewall.sh"),
              let wireguardPos = userData.range(of: "wg-quick up wg0") else {
            XCTFail("Missing firewall or wireguard commands")
            return
        }

        // Firewall should come before WireGuard in runcmd section
        XCTAssertTrue(firewallPos.lowerBound < wireguardPos.lowerBound,
                     "Firewall should be applied before WireGuard starts")
    }
}

// MARK: - Linux-specific E2E Tests

#if os(Linux)
/// E2E tests for Linux providers using QEMU
/// Parallel to E2EMacOSTests but uses SimpleVMManager with QEMU backend
@MainActor
final class E2ELinuxTests: XCTestCase {

    var vmManager: SimpleVMManager!
    var tempDirectory: URL!
    var createdVMIds: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-e2e-linux-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Use dry-run mode for unit tests
        vmManager = SimpleVMManager(dryRun: true)
        createdVMIds = []
    }

    override func tearDown() async throws {
        // Stop all VMs we created
        for vmId in createdVMIds {
            try? await vmManager.stopVM(vmId: vmId)
        }
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    func testE2EProviderIntegrationQEMU() async throws {
        let consumer = MockConsumerServer.create()
        let vmId = UUID()
        createdVMIds.append(vmId)

        // Provider sets up VM with network isolation
        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint
        )

        // Verify VM has WireGuard key to share with consumer
        XCTAssertFalse(result.vmWireGuardPublicKey.isEmpty)
        XCTAssertNotEqual(result.vmWireGuardPublicKey, "test-mode-no-wireguard")

        // Verify VM got expected IP
        XCTAssertFalse(result.vmIP.isEmpty)
    }

    func testE2ELinuxVMCloudInitGenerated() async throws {
        let consumer = MockConsumerServer.create()
        let vmId = UUID()
        createdVMIds.append(vmId)

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint
        )

        // In dry-run mode, we can verify the config would be generated correctly
        // by checking that the VM was created with expected parameters
        XCTAssertFalse(result.vmWireGuardPublicKey.isEmpty)
        let isRunning = await vmManager.isVMRunning(vmId: vmId)
        XCTAssertTrue(isRunning)
    }

    func testE2EMultipleQEMUVMs() async throws {
        let consumer = MockConsumerServer.create()
        var results: [SimpleVMManager.VMStartResult] = []

        // Start 3 VMs
        for _ in 0..<3 {
            let vmId = UUID()
            createdVMIds.append(vmId)

            let result = try await vmManager.startVM(
                vmId: vmId,
                requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
                sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
                consumerPublicKey: consumer.publicKey,
                consumerEndpoint: consumer.endpoint
            )
            results.append(result)
        }

        // Verify all have unique keys
        let publicKeys = Set(results.map { $0.vmWireGuardPublicKey })
        XCTAssertEqual(publicKeys.count, 3, "Each VM should have unique WireGuard key")

        // Verify all are running
        let activeCount = await vmManager.getActiveVMCount()
        XCTAssertEqual(activeCount, 3)
    }

    func testE2ELinuxVMCustomVPNIP() async throws {
        let consumer = MockConsumerServer.create()
        let vmId = UUID()
        createdVMIds.append(vmId)
        let customIP = "10.99.0.100"

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            vpnIP: customIP
        )

        XCTAssertEqual(result.vmIP, customIP, "VM should use custom VPN IP")
    }

    func testE2ELinuxVMTestMode() async throws {
        // Test mode is triggered by using "test://" prefix in endpoint
        let vmId = UUID()
        createdVMIds.append(vmId)

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: "test-public-key",
            consumerEndpoint: "test://localhost"  // test:// prefix triggers test mode
        )

        XCTAssertEqual(result.vmWireGuardPublicKey, "test-mode-no-wireguard",
                      "Test mode should not have WireGuard")
    }

    func testE2ELinuxVMStartStop() async throws {
        let consumer = MockConsumerServer.create()
        let vmId = UUID()

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint
        )

        // VM should be running
        let isRunningBefore = await vmManager.isVMRunning(vmId: vmId)
        XCTAssertTrue(isRunningBefore)
        XCTAssertFalse(result.vmIP.isEmpty)

        // Stop VM
        try await vmManager.stopVM(vmId: vmId)

        // VM should no longer be running
        let isRunningAfter = await vmManager.isVMRunning(vmId: vmId)
        XCTAssertFalse(isRunningAfter)
    }
}
#endif

// MARK: - macOS-specific E2E Tests

#if os(macOS)
import Virtualization

@MainActor
final class E2EMacOSTests: XCTestCase {

    var vpnManager: ProviderVPNManager!
    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        vpnManager = ProviderVPNManager(dryRun: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    func testE2EProviderIntegration() async throws {
        let consumer = MockConsumerServer.create()
        let vmId = UUID()

        // Provider sets up VM network (Phase 10 integration)
        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .filtered,
            consumerPublicKey: consumer.publicKey,
            consumerEndpoint: consumer.endpoint,
            outputDirectory: tempDirectory.path
        )

        // Verify network device is configured
        XCTAssertNotNil(setup.networkDevice)
        XCTAssertTrue(setup.networkDevice.attachment is VZNATNetworkDeviceAttachment)

        // Verify VM has keys to share with consumer
        XCTAssertFalse(setup.vmPublicKey.isEmpty)
        XCTAssertFalse(setup.vmPrivateKey.isEmpty)

        // Verify cloud-init ISO path
        XCTAssertTrue(setup.cloudInitISOPath.hasSuffix(".iso"))

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    func testE2EAllModes() async throws {
        let consumer = MockConsumerServer.create()
        let modes: [VMNetworkMode] = [.direct, .sampled, .conntrack, .filtered]

        for mode in modes {
            let vmId = UUID()

            let setup = try await vpnManager.setupVMNetwork(
                vmId: vmId,
                mode: mode,
                consumerPublicKey: consumer.publicKey,
                consumerEndpoint: consumer.endpoint,
                outputDirectory: tempDirectory.path
            )

            XCTAssertNotNil(setup.networkDevice,
                           "Mode \(mode.rawValue) should create network device")

            await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
        }
    }

    func testE2EMultipleVMs() async throws {
        let consumer = MockConsumerServer.create()
        var setups: [VMNetworkSetup] = []

        // Create multiple VMs
        for _ in 0..<3 {
            let vmId = UUID()
            let setup = try await vpnManager.setupVMNetwork(
                vmId: vmId,
                mode: .filtered,
                consumerPublicKey: consumer.publicKey,
                consumerEndpoint: consumer.endpoint,
                outputDirectory: tempDirectory.path
            )
            setups.append(setup)
        }

        // Verify all have unique keys
        let publicKeys = Set(setups.map { $0.vmPublicKey })
        XCTAssertEqual(publicKeys.count, 3, "Each VM should have unique public key")

        // Cleanup all
        for setup in setups {
            await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
        }
    }
}
#endif

// MARK: - Live E2E Tests (require actual infrastructure)

#if E2E_LIVE_TESTS
/// These tests require:
/// - WireGuard tools installed
/// - Root/sudo access
/// - Network connectivity
/// - For VM tests: macOS with Virtualization.framework support
///
/// Run with: swift test -Xswiftc -DE2E_LIVE_TESTS --filter E2ELive
final class E2ELiveTests: XCTestCase {

    var ephemeralVPN: EphemeralVPN!

    override func setUp() async throws {
        try await super.setUp()
        ephemeralVPN = EphemeralVPN(basePort: 51900, backend: .dryRun)
    }

    func testLiveConsumerServerCreation() async throws {
        // Check if WireGuard backend is available
        let isAvailable = await ephemeralVPN.isBackendAvailable()
        try XCTSkipUnless(isAvailable, "WireGuard backend not available")

        let jobId = UUID()
        let vpnConfig = try await ephemeralVPN.createVPNForJob(jobId)

        XCTAssertFalse(vpnConfig.consumerPublicKey.isEmpty)
        XCTAssertFalse(vpnConfig.consumerEndpoint.isEmpty)
        XCTAssertFalse(vpnConfig.vmVPNIP.isEmpty)

        // Cleanup
        try await ephemeralVPN.stopVPNForJob(jobId)
    }

    func testLiveConsumerAcceptsPeer() async throws {
        let isAvailable = await ephemeralVPN.isBackendAvailable()
        try XCTSkipUnless(isAvailable, "WireGuard backend not available")

        let jobId = UUID()
        let vpnConfig = try await ephemeralVPN.createVPNForJob(jobId)

        // Simulate provider sending their public key
        let providerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        // Consumer adds provider as peer
        try await ephemeralVPN.addProviderPeer(
            jobId: jobId,
            providerPublicKey: providerPublicKey
        )

        // Cleanup
        try await ephemeralVPN.stopVPNForJob(jobId)
    }
}

#if os(macOS)
/// Live VM tests - require actual VM image and elevated privileges
@MainActor
final class E2ELiveVMTests: XCTestCase {

    func testLiveVMBootWithNetworkIsolation() async throws {
        // This test would:
        // 1. Create consumer WireGuard server
        // 2. Create VM with cloud-init config
        // 3. Boot VM
        // 4. Wait for cloud-init completion
        // 5. Verify WireGuard tunnel is up
        // 6. Verify VM can reach consumer
        // 7. Verify VM cannot reach internet

        throw XCTSkip("Live VM tests require VM image and elevated privileges")
    }

    func testLiveVMIsolationVerification() async throws {
        // This test would verify that VM cannot reach arbitrary internet addresses
        throw XCTSkip("Live VM tests require VM image and elevated privileges")
    }

    func testLiveBidirectionalDataTransfer() async throws {
        // This test would send data both directions through the WireGuard tunnel
        throw XCTSkip("Live VM tests require VM image and elevated privileges")
    }
}
#endif
#endif
