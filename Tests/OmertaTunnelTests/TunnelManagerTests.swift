// TunnelManagerTests.swift - Tests for TunnelManager and TunnelSession

import XCTest
@testable import OmertaTunnel
@testable import OmertaMesh

// Mock ChannelProvider for testing
actor MockChannelProvider: ChannelProvider {
    let peerId: PeerId = "test-peer-\(UUID().uuidString.prefix(8))"

    private var handlers: [String: @Sendable (PeerId, Data) async -> Void] = [:]
    private var sentMessages: [(to: PeerId, channel: String, data: Data)] = []

    func onChannel(_ channel: String, handler: @escaping @Sendable (PeerId, Data) async -> Void) async throws {
        handlers[channel] = handler
    }

    func offChannel(_ channel: String) async {
        handlers.removeValue(forKey: channel)
    }

    func sendOnChannel(_ data: Data, to peerId: PeerId, channel: String) async throws {
        sentMessages.append((to: peerId, channel: channel, data: data))
    }

    // Test helpers
    func getRegisteredChannels() -> [String] {
        Array(handlers.keys)
    }

    func getSentMessages() -> [(to: PeerId, channel: String, data: Data)] {
        sentMessages
    }

    func clearSentMessages() {
        sentMessages.removeAll()
    }

    func simulateMessage(from sender: PeerId, on channel: String, data: Data) async {
        if let handler = handlers[channel] {
            await handler(sender, data)
        }
    }
}

final class TunnelManagerTests: XCTestCase {

    func testManagerInitialization() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        // Manager should not be started yet
        let session = await manager.currentSession()
        XCTAssertNil(session)
    }

    func testManagerStartStop() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        // Start the manager
        try await manager.start()

        // Check handshake channel is registered
        let channels = await provider.getRegisteredChannels()
        XCTAssertTrue(channels.contains("tunnel-handshake"))

        // Stop the manager
        await manager.stop()

        // Channel should be unregistered
        let channelsAfterStop = await provider.getRegisteredChannels()
        XCTAssertFalse(channelsAfterStop.contains("tunnel-handshake"))
    }

    func testCreateSession() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        try await manager.start()

        // Create session with a peer
        let session = try await manager.createSession(with: "remote-peer-123")

        // Verify session was created
        XCTAssertNotNil(session)
        let remotePeer = await session.remotePeer
        XCTAssertEqual(remotePeer, "remote-peer-123")

        // Verify handshake was sent
        let messages = await provider.getSentMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].to, "remote-peer-123")
        XCTAssertEqual(messages[0].channel, "tunnel-handshake")

        await manager.stop()
    }

    func testSetSessionRequestHandler() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        var requestReceived = false
        await manager.setSessionRequestHandler { peerId in
            requestReceived = true
            return true
        }

        try await manager.start()
        await manager.stop()

        // Handler is set but not called yet (would need to simulate incoming handshake)
        XCTAssertFalse(requestReceived)
    }

    func testCloseSession() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        try await manager.start()

        let session = try await manager.createSession(with: "remote-peer-123")
        XCTAssertNotNil(session)

        await provider.clearSentMessages()

        // Close the session
        await manager.closeSession()

        // Verify close handshake was sent
        let messages = await provider.getSentMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].channel, "tunnel-handshake")

        // Session should be nil
        let currentSession = await manager.currentSession()
        XCTAssertNil(currentSession)

        await manager.stop()
    }
}

final class TunnelSessionTests: XCTestCase {

    func testSessionInitialization() async throws {
        let provider = MockChannelProvider()

        let session = TunnelSession(
            remotePeer: "peer-123",
            provider: provider
        )

        // Check initial state
        let state = await session.state
        XCTAssertEqual(state, .connecting)

        let role = await session.role
        XCTAssertEqual(role, .peer)

        let remotePeer = await session.remotePeer
        XCTAssertEqual(remotePeer, "peer-123")
    }

    func testSessionActivation() async throws {
        let provider = MockChannelProvider()

        let session = TunnelSession(
            remotePeer: "peer-123",
            provider: provider
        )

        // Activate the session
        await session.activate()

        // Check state is now active
        let state = await session.state
        XCTAssertEqual(state, .active)

        // Check that channel handlers were registered
        let channels = await provider.getRegisteredChannels()
        XCTAssertTrue(channels.contains("tunnel-data"))
        XCTAssertTrue(channels.contains("tunnel-traffic"))
    }

    func testSendRequiresActiveState() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        // Try to send without activating - should fail
        do {
            try await session.send(Data([1, 2, 3]))
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TunnelError, .notConnected)
        }
    }

    func testSendMessage() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()

        // Send a message
        try await session.send(Data([1, 2, 3]))

        // Check message was sent
        let messages = await provider.getSentMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].to, "peer-1")
        XCTAssertEqual(messages[0].channel, "tunnel-data")
        XCTAssertEqual(messages[0].data, Data([1, 2, 3]))
    }

    func testLeaveSession() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()

        // Leave the session
        await session.leave()

        // State should be disconnected
        let state = await session.state
        XCTAssertEqual(state, .disconnected)

        // Channel handlers should be deregistered
        let channels = await provider.getRegisteredChannels()
        XCTAssertFalse(channels.contains("tunnel-data"))
        XCTAssertFalse(channels.contains("tunnel-traffic"))
    }

    func testTrafficRoutingNotEnabledByDefault() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()

        // Try to inject packet without enabling traffic routing
        do {
            try await session.injectPacket(Data([0x45, 0x00]))
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TunnelError, .trafficRoutingNotEnabled)
        }
    }

    func testEnableTrafficRoutingAsSource() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()

        // Enable as traffic source
        try await session.enableTrafficRouting(asExit: false)

        let role = await session.role
        XCTAssertEqual(role, .trafficSource)

        // Should be able to inject packets now
        try await session.injectPacket(Data([0x45, 0x00, 0x00, 0x14]))

        // Check packet was sent
        let messages = await provider.getSentMessages()
        XCTAssertTrue(messages.contains { $0.channel == "tunnel-traffic" })
    }
}

final class TunnelConfigTests: XCTestCase {

    func testTunnelStateEquality() {
        XCTAssertEqual(TunnelState.connecting, TunnelState.connecting)
        XCTAssertEqual(TunnelState.active, TunnelState.active)
        XCTAssertEqual(TunnelState.disconnected, TunnelState.disconnected)
        XCTAssertEqual(TunnelState.failed("error"), TunnelState.failed("error"))
        XCTAssertNotEqual(TunnelState.failed("error1"), TunnelState.failed("error2"))
    }

    func testTunnelRoleEquality() {
        XCTAssertEqual(TunnelRole.peer, TunnelRole.peer)
        XCTAssertEqual(TunnelRole.trafficSource, TunnelRole.trafficSource)
        XCTAssertEqual(TunnelRole.trafficExit, TunnelRole.trafficExit)
        XCTAssertNotEqual(TunnelRole.peer, TunnelRole.trafficSource)
    }

    func testTunnelErrorDescriptions() {
        XCTAssertNotNil(TunnelError.notConnected.errorDescription)
        XCTAssertNotNil(TunnelError.alreadyConnected.errorDescription)
        XCTAssertNotNil(TunnelError.peerNotFound("peer").errorDescription)
        XCTAssertNotNil(TunnelError.trafficRoutingNotEnabled.errorDescription)
        XCTAssertNotNil(TunnelError.netstackError("msg").errorDescription)
        XCTAssertNotNil(TunnelError.timeout.errorDescription)
        XCTAssertNotNil(TunnelError.sessionRejected.errorDescription)
    }
}
