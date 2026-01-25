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

    // MARK: - Handshake Protocol Tests

    func testIncomingSessionRequest() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        var handlerCalled = false
        var receivedPeerId: PeerId?

        await manager.setSessionRequestHandler { peerId in
            handlerCalled = true
            receivedPeerId = peerId
            return true
        }

        var establishedSession: TunnelSession?
        await manager.setSessionEstablishedHandler { session in
            establishedSession = session
        }

        try await manager.start()

        // Simulate incoming session request
        let handshake = SessionHandshake(type: .request)
        let data = try JSONEncoder().encode(handshake)
        await provider.simulateMessage(from: "remote-initiator", on: "tunnel-handshake", data: data)

        // Handler should have been called
        XCTAssertTrue(handlerCalled)
        XCTAssertEqual(receivedPeerId, "remote-initiator")

        // Session should be established
        XCTAssertNotNil(establishedSession)
        let remotePeer = await establishedSession?.remotePeer
        XCTAssertEqual(remotePeer, "remote-initiator")

        // Ack should have been sent
        let messages = await provider.getSentMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].to, "remote-initiator")
        XCTAssertEqual(messages[0].channel, "tunnel-handshake")

        // Verify it's an ack
        let sentHandshake = try JSONDecoder().decode(SessionHandshake.self, from: messages[0].data)
        XCTAssertEqual(sentHandshake.type, .ack)

        await manager.stop()
    }

    func testIncomingSessionRejected() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        // Handler rejects the session
        await manager.setSessionRequestHandler { _ in
            return false
        }

        try await manager.start()

        // Simulate incoming session request
        let handshake = SessionHandshake(type: .request)
        let data = try JSONEncoder().encode(handshake)
        await provider.simulateMessage(from: "unwanted-peer", on: "tunnel-handshake", data: data)

        // No session should be created
        let currentSession = await manager.currentSession()
        XCTAssertNil(currentSession)

        // Reject should have been sent
        let messages = await provider.getSentMessages()
        XCTAssertEqual(messages.count, 1)
        let sentHandshake = try JSONDecoder().decode(SessionHandshake.self, from: messages[0].data)
        XCTAssertEqual(sentHandshake.type, .reject)

        await manager.stop()
    }

    func testReceiveCloseFromRemote() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        try await manager.start()

        // Create a session
        let session = try await manager.createSession(with: "remote-peer")
        XCTAssertNotNil(session)

        // Simulate remote closing the session
        let closeHandshake = SessionHandshake(type: .close)
        let data = try JSONEncoder().encode(closeHandshake)
        await provider.simulateMessage(from: "remote-peer", on: "tunnel-handshake", data: data)

        // Session should be nil now
        let currentSession = await manager.currentSession()
        XCTAssertNil(currentSession)

        // Original session should be disconnected
        let state = await session.state
        XCTAssertEqual(state, .disconnected)

        await manager.stop()
    }

    func testDefaultAcceptsWithoutHandler() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        // No handler set - should accept by default
        try await manager.start()

        let handshake = SessionHandshake(type: .request)
        let data = try JSONEncoder().encode(handshake)
        await provider.simulateMessage(from: "any-peer", on: "tunnel-handshake", data: data)

        // Session should be created
        let currentSession = await manager.currentSession()
        XCTAssertNotNil(currentSession)

        await manager.stop()
    }

    // MARK: - Edge Cases

    func testCreateSessionBeforeStart() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        // Try to create session before starting
        do {
            _ = try await manager.createSession(with: "peer")
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TunnelError, .notConnected)
        }
    }

    func testNewSessionClosesExisting() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        try await manager.start()

        // Create first session
        let session1 = try await manager.createSession(with: "peer-1")
        let state1Before = await session1.state
        XCTAssertEqual(state1Before, .active)

        // Create second session
        let session2 = try await manager.createSession(with: "peer-2")

        // First session should be disconnected
        let state1After = await session1.state
        XCTAssertEqual(state1After, .disconnected)

        // Second session should be active
        let state2 = await session2.state
        XCTAssertEqual(state2, .active)

        // Current session should be the second one
        let current = await manager.currentSession()
        let currentPeer = await current?.remotePeer
        XCTAssertEqual(currentPeer, "peer-2")

        await manager.stop()
    }

    func testDoubleStartIsIdempotent() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        try await manager.start()
        try await manager.start() // Should not throw

        let channels = await provider.getRegisteredChannels()
        XCTAssertTrue(channels.contains("tunnel-handshake"))

        await manager.stop()
    }

    func testDoubleStopIsIdempotent() async throws {
        let provider = MockChannelProvider()
        let manager = TunnelManager(provider: provider)

        try await manager.start()
        await manager.stop()
        await manager.stop() // Should not crash

        let channels = await provider.getRegisteredChannels()
        XCTAssertFalse(channels.contains("tunnel-handshake"))
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

    // MARK: - Message Receiving Tests

    func testReceiveMessage() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()

        // Get the receive stream
        let receiveStream = await session.receive()

        // Simulate incoming message
        await provider.simulateMessage(
            from: "peer-1",
            on: "tunnel-data",
            data: Data([1, 2, 3, 4])
        )

        // Read from stream with timeout
        var receivedData: Data?
        for await data in receiveStream {
            receivedData = data
            break // Just get first message
        }

        XCTAssertEqual(receivedData, Data([1, 2, 3, 4]))
    }

    func testReceiveFiltersByPeer() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()

        // Simulate message from wrong peer
        await provider.simulateMessage(
            from: "wrong-peer",
            on: "tunnel-data",
            data: Data([9, 9, 9])
        )

        // Simulate message from correct peer
        await provider.simulateMessage(
            from: "peer-1",
            on: "tunnel-data",
            data: Data([1, 2, 3])
        )

        // Should only receive message from correct peer
        let receiveStream = await session.receive()
        var receivedData: Data?
        for await data in receiveStream {
            receivedData = data
            break
        }

        XCTAssertEqual(receivedData, Data([1, 2, 3]))
    }

    // MARK: - Traffic Routing Tests

    func testEnableTrafficRoutingAsExit() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()

        // Enable as traffic exit
        try await session.enableTrafficRouting(asExit: true)

        let role = await session.role
        XCTAssertEqual(role, .trafficExit)
    }

    func testDisableTrafficRouting() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()
        try await session.enableTrafficRouting(asExit: false)

        let roleBefore = await session.role
        XCTAssertEqual(roleBefore, .trafficSource)

        await session.disableTrafficRouting()

        let roleAfter = await session.role
        XCTAssertEqual(roleAfter, .peer)

        // Should fail to inject now
        do {
            try await session.injectPacket(Data([0x45]))
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TunnelError, .trafficRoutingNotEnabled)
        }
    }

    func testTrafficRoutingRequiresActiveState() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        // Don't activate - should fail
        do {
            try await session.enableTrafficRouting(asExit: false)
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TunnelError, .notConnected)
        }
    }

    func testInjectPacketAsExit() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()
        try await session.enableTrafficRouting(asExit: true)

        // Inject a minimal IP packet (will go to netstack)
        // This shouldn't throw - netstack handles invalid packets gracefully
        try await session.injectPacket(Data([0x45, 0x00, 0x00, 0x14]))

        // No message sent on channel - packet goes to local netstack
        let messages = await provider.getSentMessages()
        XCTAssertFalse(messages.contains { $0.channel == "tunnel-traffic" })
    }

    // MARK: - Lifecycle Edge Cases

    func testLeaveStopsTrafficRouting() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()
        try await session.enableTrafficRouting(asExit: false)

        await session.leave()

        let role = await session.role
        XCTAssertEqual(role, .peer)

        let state = await session.state
        XCTAssertEqual(state, .disconnected)
    }

    func testSendAfterLeave() async throws {
        let provider = MockChannelProvider()
        let session = TunnelSession(
            remotePeer: "peer-1",
            provider: provider
        )

        await session.activate()
        await session.leave()

        do {
            try await session.send(Data([1, 2, 3]))
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TunnelError, .notConnected)
        }
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
