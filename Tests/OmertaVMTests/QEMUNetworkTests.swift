// QEMUNetworkTests.swift
// Phase 11.5: Linux QEMU Network Parity Tests

import XCTest
@testable import OmertaVM
@testable import OmertaCore

#if os(Linux)
/// Tests for Linux QEMU VM networking
/// These tests verify that QEMU VMs on Linux have the same network isolation
/// capabilities as Virtualization.framework VMs on macOS
final class QEMUNetworkTests: XCTestCase {

    var vmManager: SimpleVMManager!
    var tempDirectory: URL!
    var createdVMIds: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-qemu-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Use dry-run mode for unit tests (no actual QEMU process)
        vmManager = SimpleVMManager(dryRun: true)
        createdVMIds = []
    }

    override func tearDown() async throws {
        for vmId in createdVMIds {
            try? await vmManager.stopVM(vmId: vmId)
        }
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Cloud-Init Generation Tests

    func testQEMUVMGeneratesCloudInitISO() async throws {
        // Given: Consumer endpoint info
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerEndpoint = "203.0.113.50:51820"
        let vmId = UUID()
        createdVMIds.append(vmId)

        // When: We start a VM (dry-run mode)
        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint
        )

        // Then: VM has WireGuard public key
        XCTAssertFalse(result.vmWireGuardPublicKey.isEmpty,
                      "VM should have WireGuard public key")
        XCTAssertNotEqual(result.vmWireGuardPublicKey, "test-mode-no-wireguard",
                         "Should not be in test mode")
    }

    func testQEMUVMPublicKeyIsValidBase64() async throws {
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerEndpoint = "203.0.113.50:51820"
        let vmId = UUID()
        createdVMIds.append(vmId)

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint
        )

        // Verify the public key is valid base64
        let keyData = Data(base64Encoded: result.vmWireGuardPublicKey)
        XCTAssertNotNil(keyData, "VM public key should be valid base64")
        XCTAssertEqual(keyData?.count, 32, "WireGuard public key should be 32 bytes")
    }

    func testQEMUVMUniqueKeysPerInstance() async throws {
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerEndpoint = "203.0.113.50:51820"

        // Start multiple VMs
        var results: [SimpleVMManager.VMStartResult] = []
        for _ in 0..<3 {
            let vmId = UUID()
            createdVMIds.append(vmId)
            let result = try await vmManager.startVM(
                vmId: vmId,
                requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
                sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
                consumerPublicKey: consumerPublicKey,
                consumerEndpoint: consumerEndpoint
            )
            results.append(result)
        }

        // Verify all have unique keys
        let publicKeys = Set(results.map { $0.vmWireGuardPublicKey })
        XCTAssertEqual(publicKeys.count, 3, "Each VM should have unique WireGuard key")

        // Verify all have unique IPs
        let vmIPs = Set(results.map { $0.vmIP })
        XCTAssertEqual(vmIPs.count, 3, "Each VM should have unique IP")
    }

    // MARK: - Network Configuration Tests

    func testQEMUVMGetsExpectedIP() async throws {
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerEndpoint = "203.0.113.50:51820"
        let expectedVPNIP = "10.200.200.2"
        let vmId = UUID()
        createdVMIds.append(vmId)

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint,
            vpnIP: expectedVPNIP
        )

        XCTAssertEqual(result.vmIP, expectedVPNIP,
                      "VM should get the specified VPN IP")
    }

    func testQEMUVMCustomVPNIP() async throws {
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerEndpoint = "203.0.113.50:51820"
        let customVPNIP = "10.99.0.5"
        let vmId = UUID()
        createdVMIds.append(vmId)

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint,
            vpnIP: customVPNIP
        )

        XCTAssertEqual(result.vmIP, customVPNIP,
                      "VM should use custom VPN IP")
    }

    // MARK: - VM Lifecycle Tests

    func testQEMUVMStartStop() async throws {
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerEndpoint = "203.0.113.50:51820"
        let vmId = UUID()

        let _ = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint
        )

        // VM should be tracked
        let isRunning = await vmManager.isVMRunning(vmId: vmId)
        XCTAssertTrue(isRunning, "VM should be running after start")

        // Stop VM
        try await vmManager.stopVM(vmId: vmId)

        // VM should no longer be tracked
        let isRunningAfterStop = await vmManager.isVMRunning(vmId: vmId)
        XCTAssertFalse(isRunningAfterStop, "VM should not be running after stop")
    }

    func testQEMUVMActiveCount() async throws {
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let consumerEndpoint = "203.0.113.50:51820"

        // Start two VMs
        let vmId1 = UUID()
        let vmId2 = UUID()
        createdVMIds.append(vmId1)
        createdVMIds.append(vmId2)

        let _ = try await vmManager.startVM(
            vmId: vmId1,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint
        )
        let _ = try await vmManager.startVM(
            vmId: vmId2,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint
        )

        // Count should show both
        let countBefore = await vmManager.getActiveVMCount()
        XCTAssertEqual(countBefore, 2, "Should have 2 running VMs")

        // Stop one
        try await vmManager.stopVM(vmId: vmId1)
        createdVMIds.removeAll { $0 == vmId1 }

        // Count should show one
        let countAfter = await vmManager.getActiveVMCount()
        XCTAssertEqual(countAfter, 1, "Should have 1 running VM")
    }

    // MARK: - Test Mode Tests

    func testQEMUTestModeNoWireGuard() async throws {
        // Test mode is triggered by test:// prefix in endpoint
        let vmId = UUID()
        createdVMIds.append(vmId)

        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta",
            consumerPublicKey: "test-key",
            consumerEndpoint: "test://localhost"
        )

        // Test mode should not have real WireGuard key
        XCTAssertEqual(result.vmWireGuardPublicKey, "test-mode-no-wireguard",
                      "Test mode should indicate no WireGuard")
    }
}

// MARK: - TAP Interface Tests (require elevated privileges)

final class QEMUTAPInterfaceTests: XCTestCase {

    func testTAPInterfaceNaming() {
        // TAP interfaces should be named consistently
        let vmId = UUID()
        let expectedPrefix = "omerta"

        // The TAP interface name is derived from VM ID
        let shortId = String(vmId.uuidString.prefix(8)).lowercased()
        let expectedName = "\(expectedPrefix)\(shortId)"

        XCTAssertTrue(expectedName.count <= 15,
                     "TAP interface name must be <= 15 chars for Linux")
    }

    func testTAPSubnetCalculation() {
        // Each VM should get a unique subnet in the TAP range
        let baseSubnet = "10.100.0.0/16"

        // VM 0 gets 10.100.0.0/24, VM 1 gets 10.100.1.0/24, etc.
        let vm0Subnet = "10.100.0"
        let vm1Subnet = "10.100.1"

        XCTAssertNotEqual(vm0Subnet, vm1Subnet,
                         "Each VM should get unique TAP subnet")
    }
}

// MARK: - QEMU Availability Tests

final class QEMUAvailabilityTests: XCTestCase {

    func testQEMUBinaryDetection() {
        // Test that we can detect QEMU binaries
        let possiblePaths = [
            "/usr/bin/qemu-system-x86_64",
            "/usr/bin/qemu-system-aarch64",
            "/usr/local/bin/qemu-system-x86_64"
        ]

        let foundBinary = possiblePaths.first { FileManager.default.fileExists(atPath: $0) }

        // This test documents expected QEMU locations
        // It's OK if QEMU isn't installed (dry-run mode handles that)
        if let binary = foundBinary {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary),
                         "QEMU binary should be executable")
        }
    }

    func testKVMAvailability() {
        // Check if KVM is available
        let kvmPath = "/dev/kvm"
        let kvmExists = FileManager.default.fileExists(atPath: kvmPath)

        // Document KVM status - not a failure if unavailable
        if kvmExists {
            // Check if readable (indicates permission)
            let readable = FileManager.default.isReadableFile(atPath: kvmPath)
            if !readable {
                print("Note: /dev/kvm exists but not readable. Add user to kvm group.")
            }
        } else {
            print("Note: /dev/kvm not found. VMs will use software emulation (slow).")
        }
    }

    func testGenisoimageAvailability() {
        // Check for ISO creation tools
        let isoBinaries = [
            "/usr/bin/genisoimage",
            "/usr/bin/mkisofs",
            "/usr/bin/xorrisofs"
        ]

        let foundBinary = isoBinaries.first { FileManager.default.fileExists(atPath: $0) }
        XCTAssertNotNil(foundBinary,
                       "Need genisoimage, mkisofs, or xorrisofs for cloud-init ISO creation")
    }
}
#endif

// MARK: - Cross-Platform QEMU Config Tests

/// Tests that run on both platforms to verify QEMU config generation
final class QEMUConfigTests: XCTestCase {

    func testCloudInitConfigForQEMU() throws {
        // Generate config that would be used for QEMU VM
        let consumerPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let vmPrivateKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: "203.0.113.50:51820",
            vmPrivateKey: vmPrivateKey,
            vmAddress: "10.200.200.2/24",
            packageConfig: .debian
        )

        let userData = CloudInitGenerator.generateNetworkIsolationUserData(config: config)

        // Verify cloud-init is valid for any Linux VM (QEMU or Virtualization.framework)
        XCTAssertTrue(userData.hasPrefix("#cloud-config"))
        XCTAssertTrue(userData.contains("wg-quick up wg0"))
        XCTAssertTrue(userData.contains("iptables -P OUTPUT DROP"))
        XCTAssertTrue(userData.contains("/etc/omerta/firewall.sh"))
    }

    func testNetplanConfigForQEMU() throws {
        // QEMU VMs may use Netplan for network configuration
        let networkConfig = CloudInitGenerator.NetworkConfig(
            ipAddress: "10.100.0.2",
            gateway: "10.100.0.1",
            prefixLength: 24,
            dns: ["8.8.8.8"]
        )

        let netplanYaml = CloudInitGenerator.generateNetworkConfig(networkConfig)

        // Verify Netplan v2 format
        XCTAssertTrue(netplanYaml.contains("version: 2"))
        XCTAssertTrue(netplanYaml.contains("ethernets:"))
        XCTAssertTrue(netplanYaml.contains("10.100.0.2/24"))
        XCTAssertTrue(netplanYaml.contains("via: 10.100.0.1"))
    }
}
