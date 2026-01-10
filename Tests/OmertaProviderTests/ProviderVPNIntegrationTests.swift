// ProviderVPNIntegrationTests.swift
// Phase 10: Provider Integration Tests

#if os(macOS)
import XCTest
import Virtualization
@testable import OmertaProvider
@testable import OmertaNetwork
@testable import OmertaVM

@MainActor
final class ProviderVPNIntegrationTests: XCTestCase {

    // MARK: - Test Data

    static let testConsumerPublicKey = "aB3c4D5e6F7g8H9i0J1k2L3m4N5o6P7q8R9s0T1u2V3="
    static let testConsumerEndpoint = "203.0.113.50:51820"

    var vpnManager: ProviderVPNManager!
    var tempDirectory: URL!

    // MARK: - Setup/Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Create temp directory for test artifacts
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Create VPN manager in dry-run mode (no actual network changes)
        vpnManager = ProviderVPNManager(dryRun: true)
    }

    override func tearDown() async throws {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDirectory)

        try await super.tearDown()
    }

    // MARK: - setupVMNetwork Tests

    func testSetupVMNetworkDirectMode() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .direct,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        // Verify network device is configured
        XCTAssertNotNil(setup.networkDevice)
        XCTAssertTrue(setup.networkDevice.attachment is VZNATNetworkDeviceAttachment,
                     "Direct mode should use NAT attachment")

        // Verify handle is direct
        if case .direct = setup.handle {
            // Expected
        } else {
            XCTFail("Direct mode should return .direct handle")
        }

        // Verify keys are generated
        XCTAssertFalse(setup.vmPrivateKey.isEmpty, "Should generate VM private key")
        XCTAssertFalse(setup.vmPublicKey.isEmpty, "Should generate VM public key")

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    func testSetupVMNetworkFilteredMode() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .filtered,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        // Verify network device is configured
        XCTAssertNotNil(setup.networkDevice)

        // Filtered mode currently falls back to NAT (Phase 8 documented limitation)
        XCTAssertTrue(setup.networkDevice.attachment is VZNATNetworkDeviceAttachment,
                     "Filtered mode falls back to NAT until Phase 15")

        // Verify handle is filtered (even in fallback mode)
        if case .filtered = setup.handle {
            // Expected
        } else {
            XCTFail("Filtered mode should return .filtered handle")
        }

        // Verify keys are generated
        XCTAssertFalse(setup.vmPrivateKey.isEmpty)
        XCTAssertFalse(setup.vmPublicKey.isEmpty)

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    func testSetupVMNetworkSampledMode() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .sampled,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        // Verify setup succeeds
        XCTAssertNotNil(setup.networkDevice)

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    func testSetupVMNetworkConntrackMode() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .conntrack,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        // Verify setup succeeds
        XCTAssertNotNil(setup.networkDevice)

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    // MARK: - Cloud-Init ISO Tests

    func testCloudInitISOPath() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .filtered,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        // In dry-run mode, ISO is not created but path is returned
        XCTAssertTrue(setup.cloudInitISOPath.contains("cidata-"),
                     "ISO path should contain cidata prefix")
        XCTAssertTrue(setup.cloudInitISOPath.hasSuffix(".iso"),
                     "ISO path should have .iso extension")

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    // MARK: - Endpoint Validation Tests

    func testInvalidEndpointFormat() async {
        let vmId = UUID()

        do {
            _ = try await vpnManager.setupVMNetwork(
                vmId: vmId,
                mode: .direct,
                consumerPublicKey: Self.testConsumerPublicKey,
                consumerEndpoint: "invalid-endpoint",  // Missing port
                outputDirectory: tempDirectory.path
            )
            XCTFail("Should throw on invalid endpoint format")
        } catch {
            // Expected
            XCTAssertTrue(error is ProviderVPNError)
        }
    }

    func testInvalidIPInEndpoint() async {
        let vmId = UUID()

        do {
            _ = try await vpnManager.setupVMNetwork(
                vmId: vmId,
                mode: .direct,
                consumerPublicKey: Self.testConsumerPublicKey,
                consumerEndpoint: "not.an.ip:51820",  // Invalid IP
                outputDirectory: tempDirectory.path
            )
            XCTFail("Should throw on invalid IP address")
        } catch {
            // Expected
            XCTAssertTrue(error is ProviderVPNError)
        }
    }

    // MARK: - Custom Address Tests

    func testCustomVMAddress() async throws {
        let vmId = UUID()
        let customAddress = "192.168.100.5/24"

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .direct,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            vmAddress: customAddress,
            outputDirectory: tempDirectory.path
        )

        // Verify setup succeeds with custom address
        XCTAssertNotNil(setup.networkDevice)

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    // MARK: - Cleanup Tests

    func testCleanupDirectMode() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .direct,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        // Cleanup should not throw
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    func testCleanupFilteredMode() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .filtered,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        // Cleanup should not throw
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }

    // MARK: - Multiple VMs Tests

    func testMultipleVMSetup() async throws {
        let vm1 = UUID()
        let vm2 = UUID()

        let setup1 = try await vpnManager.setupVMNetwork(
            vmId: vm1,
            mode: .direct,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        let setup2 = try await vpnManager.setupVMNetwork(
            vmId: vm2,
            mode: .filtered,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        // Verify both setups are independent
        XCTAssertNotEqual(setup1.vmPublicKey, setup2.vmPublicKey,
                         "Each VM should have unique keys")
        XCTAssertNotEqual(setup1.cloudInitISOPath, setup2.cloudInitISOPath,
                         "Each VM should have unique ISO path")

        // Cleanup both
        await vpnManager.cleanupVMNetwork(handle: setup1.handle, cloudInitISOPath: setup1.cloudInitISOPath)
        await vpnManager.cleanupVMNetwork(handle: setup2.handle, cloudInitISOPath: setup2.cloudInitISOPath)
    }

    // MARK: - VMNetworkSetup Tests

    func testVMNetworkSetupContainsAllFields() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .direct,
            consumerPublicKey: Self.testConsumerPublicKey,
            consumerEndpoint: Self.testConsumerEndpoint,
            outputDirectory: tempDirectory.path
        )

        XCTAssertNotNil(setup.networkDevice, "Should have network device")
        XCTAssertFalse(setup.vmPublicKey.isEmpty, "Should have public key")
        XCTAssertFalse(setup.vmPrivateKey.isEmpty, "Should have private key")
        XCTAssertFalse(setup.cloudInitISOPath.isEmpty, "Should have ISO path")

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)
    }
}

// MARK: - Non-dry-run tests (require actual cloud-init tools)

#if INTEGRATION_TESTS
@MainActor
final class ProviderVPNRealIntegrationTests: XCTestCase {

    var vpnManager: ProviderVPNManager!
    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-integration-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Create VPN manager WITHOUT dry-run (will create actual files)
        vpnManager = ProviderVPNManager(dryRun: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    func testRealCloudInitISOCreation() async throws {
        let vmId = UUID()

        let setup = try await vpnManager.setupVMNetwork(
            vmId: vmId,
            mode: .direct,
            consumerPublicKey: "aB3c4D5e6F7g8H9i0J1k2L3m4N5o6P7q8R9s0T1u2V3=",
            consumerEndpoint: "203.0.113.50:51820",
            outputDirectory: tempDirectory.path
        )

        // Verify ISO file was actually created
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.cloudInitISOPath),
                     "Cloud-init ISO should exist at \(setup.cloudInitISOPath)")

        // Cleanup
        await vpnManager.cleanupVMNetwork(handle: setup.handle, cloudInitISOPath: setup.cloudInitISOPath)

        // Verify ISO was removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.cloudInitISOPath),
                      "Cloud-init ISO should be removed after cleanup")
    }
}
#endif

#endif
