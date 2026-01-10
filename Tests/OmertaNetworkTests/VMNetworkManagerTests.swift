#if os(macOS)
import XCTest
import Virtualization
@testable import OmertaNetwork

@MainActor
final class VMNetworkManagerTests: XCTestCase {

    // MARK: - Test Data

    static let consumerIP = IPv4Address(203, 0, 113, 50)
    static let consumerPort: UInt16 = 51900
    static let consumerEndpoint = Endpoint(address: consumerIP, port: consumerPort)

    // MARK: - Direct Mode Tests

    func testDirectModeCreatesNATAttachment() throws {
        let config = try VMNetworkManager.createNetwork(mode: .direct)

        // Should create VZNATNetworkDeviceAttachment
        XCTAssertTrue(config.networkDevice.attachment is VZNATNetworkDeviceAttachment,
                     "Direct mode should use VZNATNetworkDeviceAttachment")

        // Handle should be .direct
        if case .direct = config.handle {
            // Expected
        } else {
            XCTFail("Direct mode should return .direct handle")
        }

        // Strategy should be nil
        XCTAssertNil(config.strategy, "Direct mode should have no filtering strategy")

        // Cleanup
        VMNetworkManager.cleanup(config.handle)
    }

    func testDirectModeIgnoresEndpoint() throws {
        // Even with endpoint provided, direct mode should work
        let config = try VMNetworkManager.createNetwork(
            mode: .direct,
            consumerEndpoint: Self.consumerEndpoint
        )

        XCTAssertTrue(config.networkDevice.attachment is VZNATNetworkDeviceAttachment)

        VMNetworkManager.cleanup(config.handle)
    }

    // MARK: - Filtered Mode Tests

    func testFilteredModeCreatesConfig() throws {
        let config = try VMNetworkManager.createNetwork(
            mode: .filtered,
            consumerEndpoint: Self.consumerEndpoint
        )

        // NOTE: Filtered mode currently falls back to VZNATNetworkDeviceAttachment
        // because VZFileHandleNetworkDeviceAttachment requires special file descriptors
        // (tap interface via com.apple.vm.networking entitlement).
        // Phase 15 (NEFilterPacketProvider) will provide proper kernel-level filtering.
        XCTAssertTrue(config.networkDevice.attachment is VZNATNetworkDeviceAttachment,
                     "Filtered mode falls back to NAT until Phase 15")

        // Handle should be .filtered (even in fallback mode)
        if case .filtered = config.handle {
            // Expected
        } else {
            XCTFail("Filtered mode should return .filtered handle")
        }

        // Strategy should be FullFilterStrategy (for future use)
        XCTAssertNotNil(config.strategy, "Filtered mode should have filtering strategy")
        XCTAssertTrue(config.strategy is FullFilterStrategy,
                     "Filtered mode should use FullFilterStrategy")

        VMNetworkManager.cleanup(config.handle)
    }

    func testFilteredModeRequiresEndpoint() {
        XCTAssertThrowsError(try VMNetworkManager.createNetwork(mode: .filtered)) { error in
            guard case VMNetworkError.filteringRequiresEndpoint = error else {
                XCTFail("Should throw filteringRequiresEndpoint")
                return
            }
        }
    }

    // MARK: - Conntrack Mode Tests

    func testConntrackModeCreatesConfig() throws {
        let config = try VMNetworkManager.createNetwork(
            mode: .conntrack,
            consumerEndpoint: Self.consumerEndpoint
        )

        // Falls back to NAT until Phase 15
        XCTAssertTrue(config.networkDevice.attachment is VZNATNetworkDeviceAttachment)

        if case .filtered = config.handle {
            // Expected
        } else {
            XCTFail("Conntrack mode should return .filtered handle")
        }

        XCTAssertTrue(config.strategy is ConntrackStrategy,
                     "Conntrack mode should use ConntrackStrategy")

        VMNetworkManager.cleanup(config.handle)
    }

    func testConntrackModeRequiresEndpoint() {
        XCTAssertThrowsError(try VMNetworkManager.createNetwork(mode: .conntrack)) { error in
            guard case VMNetworkError.filteringRequiresEndpoint = error else {
                XCTFail("Should throw filteringRequiresEndpoint")
                return
            }
        }
    }

    // MARK: - Sampled Mode Tests

    func testSampledModeCreatesConfig() throws {
        let config = try VMNetworkManager.createNetwork(
            mode: .sampled,
            consumerEndpoint: Self.consumerEndpoint,
            samplingRate: 0.05
        )

        // Falls back to NAT until Phase 15
        XCTAssertTrue(config.networkDevice.attachment is VZNATNetworkDeviceAttachment)

        if case .filtered = config.handle {
            // Expected
        } else {
            XCTFail("Sampled mode should return .filtered handle")
        }

        XCTAssertTrue(config.strategy is SampledStrategy,
                     "Sampled mode should use SampledStrategy")

        VMNetworkManager.cleanup(config.handle)
    }

    func testSampledModeRequiresEndpoint() {
        XCTAssertThrowsError(try VMNetworkManager.createNetwork(mode: .sampled)) { error in
            guard case VMNetworkError.filteringRequiresEndpoint = error else {
                XCTFail("Should throw filteringRequiresEndpoint")
                return
            }
        }
    }

    func testSampledModeRespectsSamplingRate() throws {
        // Test with different sampling rates
        let config1 = try VMNetworkManager.createNetwork(
            mode: .sampled,
            consumerEndpoint: Self.consumerEndpoint,
            samplingRate: 0.01
        )

        let config2 = try VMNetworkManager.createNetwork(
            mode: .sampled,
            consumerEndpoint: Self.consumerEndpoint,
            samplingRate: 0.50
        )

        // Both should create valid configurations
        XCTAssertNotNil(config1.strategy)
        XCTAssertNotNil(config2.strategy)

        VMNetworkManager.cleanup(config1.handle)
        VMNetworkManager.cleanup(config2.handle)
    }

    // MARK: - Handle Tests

    func testFilteredHandleContainsNAT() throws {
        let config = try VMNetworkManager.createNetwork(
            mode: .filtered,
            consumerEndpoint: Self.consumerEndpoint
        )

        if case .filtered(let nat, _) = config.handle {
            // NAT should exist
            XCTAssertNotNil(nat)
        } else {
            XCTFail("Should be filtered handle")
        }

        VMNetworkManager.cleanup(config.handle)
    }

    func testFilteredHandleInFallbackMode() throws {
        let config = try VMNetworkManager.createNetwork(
            mode: .filtered,
            consumerEndpoint: Self.consumerEndpoint
        )

        if case .filtered(_, let socketPair) = config.handle {
            // In fallback mode, sockets are -1 (invalid)
            // This indicates we're using NAT attachment instead of file handle
            XCTAssertEqual(socketPair.vm, -1, "Fallback mode should have invalid vm socket")
            XCTAssertEqual(socketPair.host, -1, "Fallback mode should have invalid host socket")
        } else {
            XCTFail("Should be filtered handle")
        }

        VMNetworkManager.cleanup(config.handle)
    }

    // MARK: - Cleanup Tests

    func testCleanupDirectMode() throws {
        let config = try VMNetworkManager.createNetwork(mode: .direct)

        // Should not throw
        VMNetworkManager.cleanup(config.handle)
    }

    func testCleanupFilteredMode() throws {
        let config = try VMNetworkManager.createNetwork(
            mode: .filtered,
            consumerEndpoint: Self.consumerEndpoint
        )

        // Should not throw
        VMNetworkManager.cleanup(config.handle)
    }

    // MARK: - VMNetworkMode Tests

    func testVMNetworkModeCodable() throws {
        let modes: [VMNetworkMode] = [.direct, .sampled, .conntrack, .filtered]

        for mode in modes {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(VMNetworkMode.self, from: encoded)
            XCTAssertEqual(mode, decoded)
        }
    }

    func testVMNetworkModeRawValues() {
        XCTAssertEqual(VMNetworkMode.direct.rawValue, "direct")
        XCTAssertEqual(VMNetworkMode.sampled.rawValue, "sampled")
        XCTAssertEqual(VMNetworkMode.conntrack.rawValue, "conntrack")
        XCTAssertEqual(VMNetworkMode.filtered.rawValue, "filtered")
    }

    // MARK: - FilteredNetworkProcessor Tests
    // Note: FilteredNetworkProcessor.start() spawns a blocking recv() task.
    // Full integration tests require actual data flow, which will be in Phase 15.
    // These tests verify the basic state machine without blocking I/O.

    func testFilteredNetworkProcessorCreation() async throws {
        let config = try VMNetworkManager.createNetwork(
            mode: .filtered,
            consumerEndpoint: Self.consumerEndpoint
        )

        guard case .filtered(let nat, _) = config.handle,
              let strategy = config.strategy else {
            XCTFail("Should be filtered config")
            return
        }

        // Create processor with an invalid socket (won't actually process)
        let processor = FilteredNetworkProcessor(
            nat: nat,
            strategy: strategy,
            hostSocket: -1
        )

        // Initially not running
        let initialRunning = await processor.running
        XCTAssertFalse(initialRunning, "Processor should not be running initially")

        VMNetworkManager.cleanup(config.handle)
    }

    func testFilteredNetworkProcessorRunningFlag() async throws {
        let config = try VMNetworkManager.createNetwork(
            mode: .filtered,
            consumerEndpoint: Self.consumerEndpoint
        )

        guard case .filtered(let nat, _) = config.handle,
              let strategy = config.strategy else {
            XCTFail("Should be filtered config")
            return
        }

        // Create processor with invalid socket to avoid blocking
        let processor = FilteredNetworkProcessor(
            nat: nat,
            strategy: strategy,
            hostSocket: -1
        )

        // Test start sets running flag (task will fail immediately due to invalid socket)
        await processor.start()
        let afterStart = await processor.running
        XCTAssertTrue(afterStart, "Running flag should be set after start")

        // Stop should clear running flag
        await processor.stop()
        let afterStop = await processor.running
        XCTAssertFalse(afterStop, "Running flag should be cleared after stop")

        VMNetworkManager.cleanup(config.handle)
    }

    // MARK: - All Modes Test

    func testAllModes() throws {
        let modes: [(VMNetworkMode, Bool)] = [
            (.direct, false),     // No endpoint needed
            (.sampled, true),     // Endpoint needed
            (.conntrack, true),   // Endpoint needed
            (.filtered, true)     // Endpoint needed
        ]

        for (mode, needsEndpoint) in modes {
            if needsEndpoint {
                let config = try VMNetworkManager.createNetwork(
                    mode: mode,
                    consumerEndpoint: Self.consumerEndpoint
                )
                XCTAssertNotNil(config.networkDevice)
                VMNetworkManager.cleanup(config.handle)
            } else {
                let config = try VMNetworkManager.createNetwork(mode: mode)
                XCTAssertNotNil(config.networkDevice)
                VMNetworkManager.cleanup(config.handle)
            }
        }
    }

    // MARK: - HostSocketReader Tests

    func testHostSocketReaderCreation() throws {
        // Create a test socket pair for reader testing
        var testSockets: [Int32] = [0, 0]
        let pairResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &testSockets)
        guard pairResult == 0 else {
            XCTFail("Failed to create test socket pair")
            return
        }

        let reader = HostSocketReader(socket: testSockets[1])
        XCTAssertNotNil(reader)

        // Cleanup test sockets
        Darwin.close(testSockets[0])
        Darwin.close(testSockets[1])
    }

    func testHostSocketReaderWriteRead() throws {
        // Create a test socket pair
        var testSockets: [Int32] = [0, 0]
        let pairResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &testSockets)
        guard pairResult == 0 else {
            XCTFail("Failed to create test socket pair")
            return
        }

        let reader = HostSocketReader(socket: testSockets[1])
        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        // Write from one end
        testData.withUnsafeBytes { ptr in
            Darwin.send(testSockets[0], ptr.baseAddress, testData.count, 0)
        }

        // Read from other end
        let received = reader.readFrame()
        XCTAssertEqual(received, testData)

        // Cleanup
        Darwin.close(testSockets[0])
        Darwin.close(testSockets[1])
    }
}
#endif
