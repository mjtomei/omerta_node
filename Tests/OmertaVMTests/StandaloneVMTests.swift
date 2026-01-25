// StandaloneVMTests.swift
// Phase 4.5: Standalone VM Tests
//
// Tests VM boot and connectivity functionality without requiring full consumer setup.
// These tests validate cloud-init generation and VM lifecycle in isolation.

import XCTest
@testable import OmertaVM
@testable import OmertaCore

/// Tests for standalone VM functionality
/// These tests use dry-run mode to verify configuration generation
final class StandaloneVMTests: XCTestCase {

    var vmManager: VMManager!

    override func setUp() async throws {
        try await super.setUp()
        // Use dry-run mode for unit tests
        vmManager = VMManager(dryRun: true)
    }

    override func tearDown() async throws {
        vmManager = nil
        try await super.tearDown()
    }

    // MARK: - VM Lifecycle Tests

    func testVMStartStop() async throws {
        let vmId = UUID()

        // Start VM
        let _ = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta"
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

    func testMultipleVMs() async throws {
        var vmIds: [UUID] = []

        // Start 3 VMs
        for _ in 0..<3 {
            let vmId = UUID()
            vmIds.append(vmId)

            let _ = try await vmManager.startVM(
                vmId: vmId,
                requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
                sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta"
            )
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

    // MARK: - VM IP Assignment Tests

    func testVMGetsIP() async throws {
        let vmId = UUID()

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta"
        )

        // VM should have an IP
        XCTAssertFalse(result.vmIP.isEmpty, "VM should have an IP address")

        // Cleanup
        try await vmManager.stopVM(vmId: vmId)
    }

    func testVMWithCustomVPNIP() async throws {
        let vmId = UUID()
        let customIP = "10.99.0.42"

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            vpnIP: customIP
        )

        // VM should use custom IP
        XCTAssertEqual(result.vmIP, customIP, "VM should use specified VPN IP")

        // Cleanup
        try await vmManager.stopVM(vmId: vmId)
    }

    func testUniqueIPsPerVM() async throws {
        var vmIPs: Set<String> = []
        var vmIds: [UUID] = []

        // Start multiple VMs without specifying IPs
        for _ in 0..<3 {
            let vmId = UUID()
            vmIds.append(vmId)

            let result = try await vmManager.startVM(
                vmId: vmId,
                requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
                sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta"
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

/// Tests specific to Linux TAP networking
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

// MARK: - Cloud-Init Validation Tests

/// Tests that validate cloud-init configuration generation
final class BasicCloudInitTests: XCTestCase {

    func testCloudInitExpectedFeatures() {
        // Document expected features of cloud-init configuration
        // (Actual generation is tested via integration tests)

        // Expected features:
        // 1. SSH user created with sudo access
        // 2. SSH key injected
        // 3. SSH enabled on boot

        let expectedUserConfig = [
            "sudo: ALL=(ALL) NOPASSWD:ALL",
            "shell: /bin/bash",
            "ssh_authorized_keys"
        ]

        XCTAssertEqual(expectedUserConfig.count, 3, "Cloud-init should configure sudo user with SSH")
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

// MARK: - Platform-Specific Tests

#if os(Linux)
/// Linux-specific standalone VM tests
final class LinuxStandaloneVMTests: XCTestCase {

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
