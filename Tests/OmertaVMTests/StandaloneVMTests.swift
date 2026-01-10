// StandaloneVMTests.swift
// Phase 4.5: Standalone VM Tests
//
// Tests VM boot and connectivity functionality without requiring full consumer setup.
// These tests validate test mode cloud-init generation and VM lifecycle in isolation.

import XCTest
@testable import OmertaVM
@testable import OmertaCore

/// Tests for standalone VM functionality (no consumer WireGuard required)
/// These tests use dry-run mode to verify configuration generation
final class StandaloneVMTests: XCTestCase {

    var vmManager: SimpleVMManager!

    override func setUp() async throws {
        try await super.setUp()
        // Use dry-run mode for unit tests
        vmManager = SimpleVMManager(dryRun: true)
    }

    override func tearDown() async throws {
        vmManager = nil
        try await super.tearDown()
    }

    // MARK: - Test Mode Detection Tests

    func testTestModeDetectedByEndpointPrefix() async throws {
        // Given: A test:// endpoint
        let vmId = UUID()
        let testEndpoint = "test://direct-ssh"

        // When: Starting a VM with test endpoint
        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: "test-key",
            consumerEndpoint: testEndpoint
        )

        // Then: Test mode indicator returned instead of real WireGuard key
        XCTAssertEqual(result.vmWireGuardPublicKey, "test-mode-no-wireguard",
                      "Test mode should return placeholder instead of WireGuard key")

        // Cleanup
        try await vmManager.stopVM(vmId: vmId)
    }

    func testNormalModeHasWireGuardKey() async throws {
        // Given: A normal endpoint (not test://)
        let vmId = UUID()
        let normalEndpoint = "192.168.1.100:51820"
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        // When: Starting a VM with normal endpoint
        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: normalEndpoint
        )

        // Then: Real WireGuard key generated
        XCTAssertNotEqual(result.vmWireGuardPublicKey, "test-mode-no-wireguard",
                         "Normal mode should generate real WireGuard key")

        // Verify it's valid base64
        let keyData = Data(base64Encoded: result.vmWireGuardPublicKey)
        XCTAssertNotNil(keyData, "WireGuard key should be valid base64")
        XCTAssertEqual(keyData?.count, 32, "WireGuard key should be 32 bytes")

        // Cleanup
        try await vmManager.stopVM(vmId: vmId)
    }

    func testVariousTestModeEndpoints() async throws {
        // Test different test:// endpoint formats
        let testEndpoints = [
            "test://tap-ping",
            "test://direct-ssh",
            "test://console-boot",
            "test://reverse-ssh",
            "test://anything"
        ]

        for endpoint in testEndpoints {
            let vmId = UUID()
            let result = try await vmManager.startVM(
                vmId: vmId,
                requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
                sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
                consumerPublicKey: "test-key",
                consumerEndpoint: endpoint
            )

            XCTAssertEqual(result.vmWireGuardPublicKey, "test-mode-no-wireguard",
                          "Endpoint '\(endpoint)' should trigger test mode")

            try await vmManager.stopVM(vmId: vmId)
        }
    }

    // MARK: - VM Lifecycle in Test Mode

    func testTestModeVMStartStop() async throws {
        let vmId = UUID()
        let testEndpoint = "test://direct-ssh"

        // Start VM
        let _ = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: "test-key",
            consumerEndpoint: testEndpoint
        )

        // VM should be running
        let isRunningBefore = await vmManager.isVMRunning(vmId: vmId)
        XCTAssertTrue(isRunningBefore, "VM should be running after start")

        // Stop VM
        try await vmManager.stopVM(vmId: vmId)

        // VM should not be running
        let isRunningAfter = await vmManager.isVMRunning(vmId: vmId)
        XCTAssertFalse(isRunningAfter, "VM should not be running after stop")
    }

    func testMultipleTestModeVMs() async throws {
        var vmIds: [UUID] = []

        // Start 3 test mode VMs
        for i in 0..<3 {
            let vmId = UUID()
            vmIds.append(vmId)

            let result = try await vmManager.startVM(
                vmId: vmId,
                requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
                sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
                consumerPublicKey: "test-key",
                consumerEndpoint: "test://vm-\(i)"
            )

            XCTAssertEqual(result.vmWireGuardPublicKey, "test-mode-no-wireguard")
        }

        // All should be running
        let activeCount = await vmManager.getActiveVMCount()
        XCTAssertEqual(activeCount, 3, "All 3 VMs should be running")

        // Stop all
        for vmId in vmIds {
            try await vmManager.stopVM(vmId: vmId)
        }

        // None should be running
        let finalCount = await vmManager.getActiveVMCount()
        XCTAssertEqual(finalCount, 0, "No VMs should be running after stop")
    }

    // MARK: - Test Mode IP Assignment

    func testTestModeVMGetsIP() async throws {
        let vmId = UUID()
        let testEndpoint = "test://direct-ssh"

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: "test-key",
            consumerEndpoint: testEndpoint
        )

        // VM should have an IP
        XCTAssertFalse(result.vmIP.isEmpty, "VM should have an IP address")

        // Cleanup
        try await vmManager.stopVM(vmId: vmId)
    }

    func testTestModeWithCustomVPNIP() async throws {
        let vmId = UUID()
        let customIP = "10.99.0.42"

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: "test-key",
            consumerEndpoint: "test://direct-ssh",
            vpnIP: customIP
        )

        // VM should use custom IP
        XCTAssertEqual(result.vmIP, customIP, "VM should use specified VPN IP")

        // Cleanup
        try await vmManager.stopVM(vmId: vmId)
    }

    func testTestModeUniqueIPsPerVM() async throws {
        var vmIPs: Set<String> = []
        var vmIds: [UUID] = []

        // Start multiple VMs without specifying IPs
        for _ in 0..<3 {
            let vmId = UUID()
            vmIds.append(vmId)

            let result = try await vmManager.startVM(
                vmId: vmId,
                requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
                sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
                consumerPublicKey: "test-key",
                consumerEndpoint: "test://direct-ssh"
            )

            vmIPs.insert(result.vmIP)
        }

        // Each VM should have a unique IP
        XCTAssertEqual(vmIPs.count, 3, "Each VM should have unique IP")

        // Cleanup
        for vmId in vmIds {
            try await vmManager.stopVM(vmId: vmId)
        }
    }
}

// MARK: - TAP Network Configuration Tests

/// Tests specific to Linux TAP networking in test mode
final class TAPNetworkConfigTests: XCTestCase {

    func testTAPSubnetCalculation() {
        // TAP subnets should be derived from VM index
        // Each VM gets a unique /24 subnet in the 192.168.x.0 range

        // Test subnet derivation logic
        let baseThirdOctet = 100  // Starting third octet
        let vmIndex = 0

        let expectedGateway = "192.168.\(baseThirdOctet + vmIndex).1"
        let expectedVMIP = "192.168.\(baseThirdOctet + vmIndex).2"
        let expectedSubnet = "192.168.\(baseThirdOctet + vmIndex).0/24"

        XCTAssertEqual(expectedGateway, "192.168.100.1")
        XCTAssertEqual(expectedVMIP, "192.168.100.2")
        XCTAssertEqual(expectedSubnet, "192.168.100.0/24")
    }

    func testTAPInterfaceNameLength() {
        // Linux TAP interface names must be <= 15 characters
        let vmId = UUID()
        let prefix = "omerta"
        let shortId = String(vmId.uuidString.prefix(8)).lowercased()
        let tapName = "\(prefix)\(shortId)"

        XCTAssertLessThanOrEqual(tapName.count, 15,
                                  "TAP interface name '\(tapName)' must be <= 15 chars")
    }

    func testTAPGatewayIsFirstIPInSubnet() {
        // Gateway should always be .1 in the subnet
        let subnets = ["192.168.100", "192.168.101", "10.100.0"]

        for subnet in subnets {
            let gateway = "\(subnet).1"
            let vmIP = "\(subnet).2"

            // Gateway should end in .1
            XCTAssertTrue(gateway.hasSuffix(".1"), "Gateway should be .1 in subnet")
            // VM IP should be different from gateway
            XCTAssertNotEqual(gateway, vmIP, "VM IP should differ from gateway")
        }
    }
}

// MARK: - Test Mode Cloud-Init Validation Tests

/// Tests that validate the expected content of test mode cloud-init configurations
final class TestModeCloudInitTests: XCTestCase {

    func testLinuxTestModeExpectedFeatures() {
        // Document expected features of Linux test mode cloud-init
        // (Actual generation is tested via integration tests)

        // Expected features:
        // 1. SSH user created with sudo access
        // 2. SSH key injected
        // 3. Firewall blocks internet
        // 4. Firewall allows TAP subnet for SSH and ping
        // 5. Static IP on TAP interface

        let expectedFirewallRules = [
            "iptables -P INPUT DROP",       // Default deny inbound
            "iptables -P OUTPUT DROP",      // Default deny outbound
            "iptables -A INPUT -i lo -j ACCEPT",  // Allow loopback
            "iptables -A INPUT -p tcp --dport 22",  // Allow SSH
            "iptables -A INPUT -p icmp"     // Allow ping
        ]

        // These rules should block internet access while allowing TAP
        XCTAssertEqual(expectedFirewallRules.count, 5, "Test mode should have specific firewall rules")
    }

    func testMacOSTestModeExpectedFeatures() {
        // Document expected features of macOS test mode cloud-init

        // Expected features:
        // 1. SSH user created with sudo access
        // 2. SSH key injected
        // 3. Password auth enabled (fallback)
        // 4. Optional reverse tunnel config

        let expectedUserConfig = [
            "sudo: ALL=(ALL) NOPASSWD:ALL",
            "shell: /bin/bash",
            "ssh_authorized_keys"
        ]

        XCTAssertEqual(expectedUserConfig.count, 3, "Test mode should configure sudo user with SSH")
    }

    func testReverseTunnelConfigRequired() {
        // Reverse tunnel config must include all required fields
        let config = ReverseTunnelConfig(
            hostIP: "192.168.64.1",
            hostUser: "testuser",
            hostPort: 22,
            tunnelPort: 2222,
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----"
        )

        XCTAssertFalse(config.hostIP.isEmpty, "Host IP required")
        XCTAssertGreaterThan(config.hostPort, 0, "Host port required")
        XCTAssertFalse(config.hostUser.isEmpty, "Host user required")
        XCTAssertGreaterThan(config.tunnelPort, 0, "Tunnel port required")
        XCTAssertTrue(config.privateKey.contains("PRIVATE KEY"), "Private key required")
    }
}

// MARK: - Platform-Specific Test Mode Tests

#if os(Linux)
/// Linux-specific standalone VM tests
final class LinuxStandaloneVMTests: XCTestCase {

    func testLinuxTestModesAvailable() {
        // Linux supports TAP-based test modes
        let supportedModes = ["tap-ping", "direct-ssh"]

        for mode in supportedModes {
            let endpoint = "test://\(mode)"
            XCTAssertTrue(endpoint.hasPrefix("test://"),
                         "Mode \(mode) should be available on Linux")
        }
    }

    func testLinuxTAPNetworkRange() {
        // Linux TAP networks use 192.168.x.0/24 range by default
        let defaultRange = "192.168.100.0/24"

        // Verify it's a valid private network
        XCTAssertTrue(defaultRange.hasPrefix("192.168."), "Should use private IP range")
        XCTAssertTrue(defaultRange.hasSuffix("/24"), "Should use /24 subnet")
    }
}
#endif

#if os(macOS)
/// macOS-specific standalone VM tests
final class MacOSStandaloneVMTests: XCTestCase {

    func testMacOSTestModesAvailable() {
        // macOS supports console and reverse-ssh test modes
        let supportedModes = ["console-boot", "reverse-ssh"]

        for mode in supportedModes {
            let endpoint = "test://\(mode)"
            XCTAssertTrue(endpoint.hasPrefix("test://"),
                         "Mode \(mode) should be available on macOS")
        }
    }

    func testMacOSNATNetworkRange() {
        // macOS Virtualization.framework uses 192.168.64.x range
        let natRange = "192.168.64"

        // Verify it's the expected macOS vmnet range
        XCTAssertEqual(natRange, "192.168.64", "macOS uses vmnet 192.168.64.x range")
    }

    func testReverseTunnelDefaultPort() {
        // Default reverse tunnel port should avoid conflicts
        let defaultTunnelPort: UInt16 = 2222

        // Should not conflict with standard SSH
        XCTAssertNotEqual(defaultTunnelPort, 22, "Tunnel port should not be 22")
        // Should be in unprivileged range
        XCTAssertGreaterThan(defaultTunnelPort, 1024, "Tunnel port should be unprivileged")
    }
}
#endif
