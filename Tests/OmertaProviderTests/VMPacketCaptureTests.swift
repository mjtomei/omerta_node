import XCTest
@testable import OmertaProvider
@testable import OmertaTunnel
@testable import OmertaMesh

final class VMPacketCaptureTests: XCTestCase {

    // MARK: - Mock Packet Source

    /// Mock packet source for testing - uses a class with synchronization
    final class MockPacketSource: PacketSource, @unchecked Sendable {
        nonisolated var inbound: AsyncStream<Data> {
            inboundStream
        }

        private let inboundStream: AsyncStream<Data>
        private let inboundContinuation: AsyncStream<Data>.Continuation
        private let lock = NSLock()

        private var _isRunning = false
        private var _writtenPackets: [Data] = []
        private var _startCalled = false
        private var _stopCalled = false

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _isRunning
        }

        var writtenPackets: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return _writtenPackets
        }

        var startCalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _startCalled
        }

        var stopCalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _stopCalled
        }

        init() {
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            self.inboundStream = stream
            self.inboundContinuation = continuation
        }

        func start() async throws {
            lock.lock()
            _startCalled = true
            _isRunning = true
            lock.unlock()
        }

        func stop() async {
            lock.lock()
            _stopCalled = true
            _isRunning = false
            lock.unlock()
            inboundContinuation.finish()
        }

        func write(_ packet: Data) async throws {
            lock.lock()
            guard _isRunning else {
                lock.unlock()
                throw PacketCaptureError.notStarted
            }
            _writtenPackets.append(packet)
            lock.unlock()
        }

        // Test helper: inject a packet as if it came from the VM
        func injectPacket(_ packet: Data) {
            inboundContinuation.yield(packet)
        }
    }

    // MARK: - Mock Channel Provider

    actor MockChannelProvider: ChannelProvider {
        let peerId: PeerId = "mock-provider-\(UUID().uuidString.prefix(8))"

        private var handlers: [String: @Sendable (MachineId, Data) async -> Void] = [:]
        private(set) var sentPackets: [(Data, String, String)] = []  // (data, target, channel)

        func onChannel(_ channel: String, handler: @escaping @Sendable (MachineId, Data) async -> Void) async throws {
            handlers[channel] = handler
        }

        func offChannel(_ channel: String) async {
            handlers.removeValue(forKey: channel)
        }

        func sendOnChannel(_ data: Data, to peer: PeerId, channel: String) async throws {
            sentPackets.append((data, peer, channel))
        }

        func sendOnChannel(_ data: Data, toMachine machineId: MachineId, channel: String) async throws {
            sentPackets.append((data, machineId, channel))
        }

        // Test helper: simulate receiving a packet on a channel
        func simulateReceive(from machineId: MachineId, data: Data, channel: String) async {
            if let handler = handlers[channel] {
                await handler(machineId, data)
            }
        }
    }

    // MARK: - Tests

    func testCaptureInitialization() async throws {
        let vmId = UUID()
        let mockSource = MockPacketSource()
        let provider = MockChannelProvider()
        let session = TunnelSession(remoteMachineId: "test-peer", channel: "data", provider: provider)

        let capture = VMPacketCapture(vmId: vmId, packetSource: mockSource, tunnelSession: session)

        let isRunning = await capture.isRunning
        XCTAssertFalse(isRunning)

        let capturedVmId = await capture.vmId
        XCTAssertEqual(capturedVmId, vmId)
    }

    func testCaptureStartStop() async throws {
        let vmId = UUID()
        let mockSource = MockPacketSource()
        let provider = MockChannelProvider()
        let session = TunnelSession(remoteMachineId: "test-peer", channel: "data", provider: provider)

        // Activate session first
        await session.activate()

        let capture = VMPacketCapture(vmId: vmId, packetSource: mockSource, tunnelSession: session)

        // Start capture
        try await capture.start()

        var isRunning = await capture.isRunning
        XCTAssertTrue(isRunning)

        let startCalled = mockSource.startCalled
        XCTAssertTrue(startCalled)

        // Stop capture
        await capture.stop()

        isRunning = await capture.isRunning
        XCTAssertFalse(isRunning)

        let stopCalled = mockSource.stopCalled
        XCTAssertTrue(stopCalled)
    }

    func testCaptureDoubleStartThrows() async throws {
        let vmId = UUID()
        let mockSource = MockPacketSource()
        let provider = MockChannelProvider()
        let session = TunnelSession(remoteMachineId: "test-peer", channel: "data", provider: provider)

        await session.activate()

        let capture = VMPacketCapture(vmId: vmId, packetSource: mockSource, tunnelSession: session)

        try await capture.start()

        do {
            try await capture.start()
            XCTFail("Expected error on double start")
        } catch PacketCaptureError.alreadyStarted {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCaptureVMPacket() async throws {
        let vmId = UUID()
        let mockSource = MockPacketSource()
        let provider = MockChannelProvider()
        let session = TunnelSession(remoteMachineId: "test-peer", channel: "data", provider: provider)

        // Activate session
        await session.activate()

        let capture = VMPacketCapture(vmId: vmId, packetSource: mockSource, tunnelSession: session)
        try await capture.start()

        // Inject a packet as if from VM
        let testPacket = Data([0x45, 0x00, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00])
        mockSource.injectPacket(testPacket)

        // Give time for async forwarding
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Verify packet was sent through tunnel (wire channel is "tunnel-data")
        let sentPackets = await provider.sentPackets
        XCTAssertEqual(sentPackets.count, 1)
        XCTAssertEqual(sentPackets[0].0, testPacket)
        XCTAssertEqual(sentPackets[0].2, "tunnel-data")

        await capture.stop()
    }

    func testInjectToVM() async throws {
        let vmId = UUID()
        let mockSource = MockPacketSource()
        let provider = MockChannelProvider()
        let session = TunnelSession(remoteMachineId: "test-peer", channel: "data", provider: provider)

        // Activate session
        await session.activate()

        let capture = VMPacketCapture(vmId: vmId, packetSource: mockSource, tunnelSession: session)
        try await capture.start()

        // Deliver a packet to the session (as TunnelManager would via dispatch)
        let returnPacket = Data([0x45, 0x00, 0x00, 0x20, 0x00, 0x02, 0x00, 0x00])
        await session.deliverIncoming(returnPacket)

        // Give time for async forwarding
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Verify packet was written to VM
        let writtenPackets = mockSource.writtenPackets
        XCTAssertEqual(writtenPackets.count, 1)
        XCTAssertEqual(writtenPackets[0], returnPacket)

        await capture.stop()
    }

    func testCaptureStats() async throws {
        let vmId = UUID()
        let mockSource = MockPacketSource()
        let provider = MockChannelProvider()
        let session = TunnelSession(remoteMachineId: "test-peer", channel: "data", provider: provider)

        await session.activate()

        let capture = VMPacketCapture(vmId: vmId, packetSource: mockSource, tunnelSession: session)
        try await capture.start()

        // Send packets in both directions
        let outPacket = Data([0x45, 0x00, 0x00, 0x14])
        mockSource.injectPacket(outPacket)

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let stats = await capture.getStats()
        XCTAssertEqual(stats.packetsToTunnel, 1)
        XCTAssertEqual(stats.bytesToTunnel, UInt64(outPacket.count))

        await capture.stop()
    }

    func testBridgeCleanup() async throws {
        let vmId = UUID()
        let mockSource = MockPacketSource()
        let provider = MockChannelProvider()
        let session = TunnelSession(remoteMachineId: "test-peer", channel: "data", provider: provider)

        await session.activate()

        let capture = VMPacketCapture(vmId: vmId, packetSource: mockSource, tunnelSession: session)

        try await capture.start()
        var isRunning = await capture.isRunning
        XCTAssertTrue(isRunning)

        await capture.stop()
        isRunning = await capture.isRunning
        XCTAssertFalse(isRunning)

        // Verify source was stopped
        let stopCalled = mockSource.stopCalled
        XCTAssertTrue(stopCalled)

        let sourceRunning = mockSource.isRunning
        XCTAssertFalse(sourceRunning)
    }

    func testStopWithoutStartIsNoop() async throws {
        let vmId = UUID()
        let mockSource = MockPacketSource()
        let provider = MockChannelProvider()
        let session = TunnelSession(remoteMachineId: "test-peer", channel: "data", provider: provider)

        let capture = VMPacketCapture(vmId: vmId, packetSource: mockSource, tunnelSession: session)

        // Stop without starting should not crash
        await capture.stop()

        let stopCalled = mockSource.stopCalled
        XCTAssertFalse(stopCalled) // stop() should return early

        let isRunning = await capture.isRunning
        XCTAssertFalse(isRunning)
    }
}
