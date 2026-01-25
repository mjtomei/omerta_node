// TunnelSession.swift - Peer-to-peer session over mesh network
//
// Manages communication with a single remote peer, including
// data messaging and optional IP traffic routing via netstack.

import Foundation
import OmertaMesh
import Logging

/// A session with a remote peer over the mesh network.
/// Provides peer-to-peer messaging and optional internet traffic routing.
public actor TunnelSession {
    /// The remote peer we're connected to
    public let remotePeer: PeerId

    /// Current state
    public private(set) var state: TunnelState = .connecting

    /// Current role in traffic routing
    public private(set) var role: TunnelRole = .peer

    // Internal components
    private let provider: any ChannelProvider
    private var netstackBridge: NetstackBridge?
    private let logger: Logger

    // Message streaming
    private var messageStream: AsyncStream<Data>?
    private var messageContinuation: AsyncStream<Data>.Continuation?

    // Return packet streaming (for traffic routing)
    private var returnPacketStream: AsyncStream<Data>?
    private var returnPacketContinuation: AsyncStream<Data>.Continuation?

    // Channel names
    private var messageChannel: String {
        "tunnel-data"
    }

    private var trafficChannel: String {
        "tunnel-traffic"
    }

    private var returnChannel: String {
        "tunnel-return"
    }

    /// Initialize a new tunnel session
    init(remotePeer: PeerId, provider: any ChannelProvider) {
        self.remotePeer = remotePeer
        self.provider = provider
        self.logger = Logger(label: "io.omerta.tunnel.session")

        // Set up message stream
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.messageStream = stream
        self.messageContinuation = continuation
    }

    /// Mark the session as active
    func activate() async {
        state = .active
        logger.info("Session activated", metadata: ["peer": "\(remotePeer)"])

        // Register message handlers
        await registerHandlers()
    }

    // MARK: - Messaging

    /// Send data to the remote peer
    public func send(_ data: Data) async throws {
        guard state == .active else {
            throw TunnelError.notConnected
        }

        try await provider.sendOnChannel(data, to: remotePeer, channel: messageChannel)

        logger.debug("Sent message", metadata: ["size": "\(data.count)"])
    }

    /// Stream of incoming messages from the remote peer
    public func receive() -> AsyncStream<Data> {
        return messageStream ?? AsyncStream { _ in }
    }

    // MARK: - Traffic Routing

    /// Enable traffic routing through this session.
    /// - Parameter asExit: If true, this session becomes the exit point (runs netstack).
    ///   If false, this session forwards traffic to the remote peer for exit.
    public func enableTrafficRouting(asExit: Bool) async throws {
        guard state == .active else {
            throw TunnelError.notConnected
        }

        if asExit {
            // We are the traffic exit point - initialize netstack
            let config = NetstackBridge.Config(
                gatewayIP: "10.200.0.1",
                mtu: 1500
            )

            do {
                let bridge = try NetstackBridge(config: config)
                bridge.setReturnCallback { [weak self] packet in
                    Task {
                        await self?.handleReturnPacket(packet)
                    }
                }
                try bridge.start()
                self.netstackBridge = bridge
                self.role = .trafficExit

                // Register handler for incoming traffic from remote peer
                // This receives packets from the source and injects them into netstack
                logger.info("Registering traffic channel handler", metadata: [
                    "channel": "\(trafficChannel)",
                    "remotePeer": "\(remotePeer.prefix(16))..."
                ])
                try await provider.onChannel(trafficChannel) { [weak self] sender, data in
                    await self?.handleTrafficPacket(from: sender, data: data)
                }

                logger.info("Traffic routing enabled (exit point)", metadata: [
                    "channel": "\(trafficChannel)"
                ])
            } catch {
                throw TunnelError.netstackError(error.localizedDescription)
            }
        } else {
            // We are the traffic source - set up return packet stream
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            self.returnPacketStream = stream
            self.returnPacketContinuation = continuation
            self.role = .trafficSource

            // Register return packet handler
            do {
                try await provider.onChannel(returnChannel) { [weak self] sender, data in
                    await self?.handleReturnData(from: sender, data: data)
                }
            } catch {
                logger.warning("Failed to register return handler: \(error)")
            }

            logger.info("Traffic routing enabled (source)")
        }
    }

    /// Inject a raw IP packet for routing.
    /// When role is trafficSource, sends to remote peer.
    /// When role is trafficExit, injects into netstack.
    public func injectPacket(_ packet: Data) async throws {
        guard state == .active else {
            throw TunnelError.notConnected
        }

        switch role {
        case .trafficSource:
            // Send packet to exit peer via mesh
            try await provider.sendOnChannel(packet, to: remotePeer, channel: trafficChannel)

        case .trafficExit:
            // Inject directly into netstack
            guard let bridge = netstackBridge else {
                throw TunnelError.trafficRoutingNotEnabled
            }
            try bridge.injectPacket(packet)

        case .peer:
            throw TunnelError.trafficRoutingNotEnabled
        }
    }

    /// Stream of return packets (responses from internet).
    /// Only valid when role is trafficSource.
    public var returnPackets: AsyncStream<Data> {
        return returnPacketStream ?? AsyncStream { _ in }
    }

    /// Disable traffic routing
    public func disableTrafficRouting() async {
        if let bridge = netstackBridge {
            bridge.stop()
            netstackBridge = nil
        }

        if role == .trafficSource {
            await provider.offChannel(returnChannel)
        } else if role == .trafficExit {
            await provider.offChannel(trafficChannel)
        }

        returnPacketContinuation?.finish()
        returnPacketContinuation = nil
        returnPacketStream = nil
        role = .peer

        logger.info("Traffic routing disabled")
    }

    // MARK: - Lifecycle

    /// Leave the session and clean up resources
    public func leave() async {
        state = .disconnected

        // Stop traffic routing
        await disableTrafficRouting()

        // Finish message stream
        messageContinuation?.finish()

        // Deregister handlers
        await deregisterHandlers()

        logger.info("Left session")
    }

    // MARK: - Private

    private func registerHandlers() async {
        // Register handler for incoming messages
        do {
            try await provider.onChannel(messageChannel) { [weak self] sender, data in
                await self?.handleMessageData(from: sender, data: data)
            }
        } catch {
            logger.warning("Failed to register message handler: \(error)")
        }

        // Register handler for traffic packets (if we're exit point)
        do {
            try await provider.onChannel(trafficChannel) { [weak self] sender, data in
                await self?.handleTrafficPacket(from: sender, data: data)
            }
        } catch {
            logger.warning("Failed to register traffic handler: \(error)")
        }
    }

    private func deregisterHandlers() async {
        await provider.offChannel(messageChannel)
        await provider.offChannel(trafficChannel)
    }

    private func handleTrafficPacket(from sender: PeerId, data: Data) async {
        guard role == .trafficExit else {
            logger.debug("Ignoring traffic packet - not exit role", metadata: [
                "role": "\(role)",
                "sender": "\(sender.prefix(16))..."
            ])
            return
        }

        guard sender == remotePeer else {
            logger.debug("Ignoring traffic packet - wrong sender", metadata: [
                "expected": "\(remotePeer.prefix(16))...",
                "actual": "\(sender.prefix(16))..."
            ])
            return
        }

        logger.info("Received traffic packet", metadata: [
            "size": "\(data.count)",
            "from": "\(sender.prefix(16))..."
        ])

        // Inject into netstack
        do {
            try netstackBridge?.injectPacket(data)
            logger.debug("Injected packet into netstack", metadata: ["size": "\(data.count)"])
        } catch {
            logger.warning("Failed to inject traffic packet: \(error)")
        }
    }

    private func handleReturnPacket(_ packet: Data) async {
        // If we're exit point, send return packet back to source
        if role == .trafficExit {
            do {
                try await provider.sendOnChannel(packet, to: remotePeer, channel: returnChannel)
            } catch {
                logger.warning("Failed to send return packet: \(error)")
            }
        }
    }

    private func handleMessageData(from sender: PeerId, data: Data) {
        guard sender == remotePeer else { return }
        messageContinuation?.yield(data)
    }

    private func handleReturnData(from sender: PeerId, data: Data) {
        guard sender == remotePeer else { return }
        returnPacketContinuation?.yield(data)
    }
}
