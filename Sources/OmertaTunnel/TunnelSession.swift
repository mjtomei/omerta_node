// TunnelSession.swift - Machine-to-machine session over mesh network
//
// Manages communication with a single remote machine, including
// data messaging and optional IP traffic routing via netstack.

import Foundation
import OmertaMesh
import Logging

/// A session with a remote machine over the mesh network.
/// Provides machine-to-machine messaging and optional internet traffic routing.
public actor TunnelSession {
    /// The remote machine we're connected to
    public let remoteMachine: MachineId

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

    // Custom packet forwarding (for VM bridging instead of netstack)
    private var trafficForwardCallback: ((Data) async throws -> Void)?

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
    init(remoteMachine: MachineId, provider: any ChannelProvider) {
        self.remoteMachine = remoteMachine
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
        logger.info("Session activated", metadata: ["machine": "\(remoteMachine)"])

        // Register message handlers
        await registerHandlers()
    }

    // MARK: - Messaging

    /// Send data to the remote peer
    public func send(_ data: Data) async throws {
        guard state == .active else {
            throw TunnelError.notConnected
        }

        try await provider.sendOnChannel(data, toMachine: remoteMachine, channel: messageChannel)

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
                    "remoteMachine": "\(remoteMachine.prefix(16))..."
                ])
                try await provider.onChannel(trafficChannel) { [weak self] senderMachine, data in
                    await self?.handleTrafficPacket(from: senderMachine, data: data)
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
                try await provider.onChannel(returnChannel) { [weak self] senderMachine, data in
                    await self?.handleReturnData(from: senderMachine, data: data)
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
            // Send packet to exit machine via mesh
            try await provider.sendOnChannel(packet, toMachine: remoteMachine, channel: trafficChannel)

        case .trafficExit:
            // Inject directly into netstack
            guard let bridge = netstackBridge else {
                throw TunnelError.trafficRoutingNotEnabled
            }
            try bridge.injectPacket(packet)

        case .trafficClient:
            // Traffic client uses dialTCP through netstack, not raw packet injection
            throw TunnelError.trafficRoutingNotEnabled

        case .peer:
            throw TunnelError.trafficRoutingNotEnabled
        }
    }

    /// Stream of return packets (responses from internet).
    /// Only valid when role is trafficSource.
    public var returnPackets: AsyncStream<Data> {
        return returnPacketStream ?? AsyncStream { _ in }
    }

    /// Enable dial support for making outbound TCP connections through the tunnel.
    /// This creates a local netstack that can be used for dialTCP calls.
    /// Outbound packets go through tunnel-traffic to the remote peer (which should be trafficExit).
    /// Return packets come back via tunnel-return.
    public func enableDialSupport() async throws {
        guard state == .active else {
            throw TunnelError.notConnected
        }

        guard role == .peer else {
            throw TunnelError.alreadyConnected
        }

        // Create local netstack for dialTCP
        let config = NetstackBridge.Config(
            gatewayIP: "10.200.0.1",
            mtu: 1500
        )

        do {
            let bridge = try NetstackBridge(config: config)

            // Wire outbound packets to tunnel-traffic channel
            bridge.setReturnCallback { [weak self] packet in
                Task {
                    await self?.sendTrafficPacket(packet)
                }
            }

            try bridge.start()
            self.netstackBridge = bridge
            self.role = .trafficClient

            // Register handler for return packets from remote
            try await provider.onChannel(returnChannel) { [weak self] senderMachine, data in
                await self?.handleClientReturnPacket(from: senderMachine, data: data)
            }

            logger.info("Dial support enabled (traffic client)", metadata: [
                "remoteMachine": "\(remoteMachine.prefix(16))..."
            ])
        } catch {
            throw TunnelError.netstackError(error.localizedDescription)
        }
    }

    /// Get the netstack bridge for dialTCP calls.
    /// Only valid when dial support is enabled.
    public var netstack: NetstackBridge? {
        return netstackBridge
    }

    /// Set a callback for forwarding incoming traffic packets.
    /// When set, traffic packets are forwarded to this callback instead of netstack.
    /// This is used by providers to forward consumer traffic to VMs.
    /// - Parameter callback: The callback to invoke with each incoming traffic packet
    public func setTrafficForwardCallback(_ callback: @escaping (Data) async throws -> Void) {
        self.trafficForwardCallback = callback
        logger.info("Traffic forward callback set for VM bridging")
    }

    /// Send a return packet back to the consumer.
    /// Used for VM bridging when VM responds to consumer-initiated traffic.
    /// - Parameter packet: The packet to send back
    public func sendReturnPacket(_ packet: Data) async throws {
        guard state == .active else {
            throw TunnelError.notConnected
        }

        try await provider.sendOnChannel(packet, toMachine: remoteMachine, channel: returnChannel)
        logger.debug("Sent return packet to consumer", metadata: ["size": "\(packet.count)"])
    }

    /// Disable traffic routing
    public func disableTrafficRouting() async {
        if let bridge = netstackBridge {
            bridge.stop()
            netstackBridge = nil
        }

        switch role {
        case .trafficSource, .trafficClient:
            await provider.offChannel(returnChannel)
        case .trafficExit:
            await provider.offChannel(trafficChannel)
        case .peer:
            break
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
            try await provider.onChannel(messageChannel) { [weak self] senderMachine, data in
                await self?.handleMessageData(from: senderMachine, data: data)
            }
        } catch {
            logger.warning("Failed to register message handler: \(error)")
        }

        // Register handler for traffic packets (if we're exit point)
        do {
            try await provider.onChannel(trafficChannel) { [weak self] senderMachine, data in
                await self?.handleTrafficPacket(from: senderMachine, data: data)
            }
        } catch {
            logger.warning("Failed to register traffic handler: \(error)")
        }
    }

    private func deregisterHandlers() async {
        await provider.offChannel(messageChannel)
        await provider.offChannel(trafficChannel)
    }

    private func handleTrafficPacket(from senderMachine: MachineId, data: Data) async {
        guard role == .trafficExit else {
            logger.debug("Ignoring traffic packet - not exit role", metadata: [
                "role": "\(role)",
                "senderMachine": "\(senderMachine.prefix(16))..."
            ])
            return
        }

        guard senderMachine == remoteMachine else {
            logger.debug("Ignoring traffic packet - wrong sender", metadata: [
                "expected": "\(remoteMachine.prefix(16))...",
                "actual": "\(senderMachine.prefix(16))..."
            ])
            return
        }

        logger.info("Received traffic packet", metadata: [
            "size": "\(data.count)",
            "from": "\(senderMachine.prefix(16))..."
        ])

        // If we have a forward callback (for VM bridging), use that instead of netstack
        if let callback = trafficForwardCallback {
            do {
                try await callback(data)
                logger.info("Forwarded traffic packet to VM", metadata: ["size": "\(data.count)"])
            } catch {
                logger.warning("Failed to forward traffic packet to VM: \(error)")
            }
        } else {
            // No VM callback - inject into netstack for internet forwarding
            do {
                try netstackBridge?.injectPacket(data)
                logger.debug("Injected packet into netstack", metadata: ["size": "\(data.count)"])
            } catch {
                logger.warning("Failed to inject traffic packet: \(error)")
            }
        }
    }

    private func handleReturnPacket(_ packet: Data) async {
        // If we're exit point, send return packet back to source
        if role == .trafficExit {
            do {
                try await provider.sendOnChannel(packet, toMachine: remoteMachine, channel: returnChannel)
            } catch {
                logger.warning("Failed to send return packet: \(error)")
            }
        }
    }

    private func handleMessageData(from senderMachine: MachineId, data: Data) {
        guard senderMachine == remoteMachine else { return }
        messageContinuation?.yield(data)
    }

    private func handleReturnData(from senderMachine: MachineId, data: Data) {
        guard senderMachine == remoteMachine else {
            logger.debug("Ignoring return packet - wrong sender", metadata: [
                "expected": "\(remoteMachine.prefix(16))...",
                "actual": "\(senderMachine.prefix(16))..."
            ])
            return
        }
        logger.info("Received return packet", metadata: [
            "size": "\(data.count)",
            "from": "\(senderMachine.prefix(16))..."
        ])
        returnPacketContinuation?.yield(data)
    }

    // MARK: - Traffic Client Mode (for dialTCP)

    /// Send traffic packet to remote machine (for trafficClient mode)
    private func sendTrafficPacket(_ packet: Data) async {
        guard role == .trafficClient else { return }

        do {
            try await provider.sendOnChannel(packet, toMachine: remoteMachine, channel: trafficChannel)
            logger.debug("Sent traffic packet", metadata: ["size": "\(packet.count)"])
        } catch {
            logger.warning("Failed to send traffic packet: \(error)")
        }
    }

    /// Handle return packet in trafficClient mode - inject into local netstack
    private func handleClientReturnPacket(from senderMachine: MachineId, data: Data) async {
        guard role == .trafficClient else {
            logger.debug("Ignoring client return packet - not client role", metadata: [
                "role": "\(role)"
            ])
            return
        }

        guard senderMachine == remoteMachine else {
            logger.debug("Ignoring client return packet - wrong sender", metadata: [
                "expected": "\(remoteMachine.prefix(16))...",
                "actual": "\(senderMachine.prefix(16))..."
            ])
            return
        }

        // Inject into local netstack
        do {
            try netstackBridge?.injectPacket(data)
            logger.debug("Injected return packet into local netstack", metadata: ["size": "\(data.count)"])
        } catch {
            logger.warning("Failed to inject return packet: \(error)")
        }
    }
}
