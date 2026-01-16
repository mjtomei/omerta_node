// HolePunchManager.swift - Manages hole punching operations

import Foundation
import Logging

/// Manages hole punching operations for a mesh node
public actor HolePunchManager {
    /// Configuration for hole punch management
    public struct Config: Sendable {
        public let holePunchConfig: HolePunchConfig
        public let coordinatorConfig: HolePunchCoordinator.Config

        /// Whether this node can act as a coordinator (public nodes only)
        public let canCoordinate: Bool

        public init(
            holePunchConfig: HolePunchConfig = .default,
            coordinatorConfig: HolePunchCoordinator.Config = .default,
            canCoordinate: Bool = false
        ) {
            self.holePunchConfig = holePunchConfig
            self.coordinatorConfig = coordinatorConfig
            self.canCoordinate = canCoordinate
        }

        public static let `default` = Config()
    }

    private let peerId: String
    private let config: Config
    private let logger: Logger

    /// Event logger for persistent logging (optional)
    private var eventLogger: MeshEventLogger?

    /// The hole puncher for executing hole punches
    public let holePuncher: HolePuncher

    /// The coordinator (only active on public nodes)
    public let coordinator: HolePunchCoordinator?

    /// Our NAT type
    private var natType: NATType = .unknown

    /// Local port for hole punching
    private var localPort: UInt16 = 0

    /// Callback to send messages
    private var sendMessage: ((MeshMessage, PeerId) async -> Void)?

    /// Callback to get peer endpoint
    private var getPeerEndpoint: ((PeerId) async -> Endpoint?)?

    /// Callback to get peer NAT type
    private var getPeerNATType: ((PeerId) async -> NATType?)?

    /// Callback to get coordinator peer ID
    private var getCoordinatorPeerId: (() async -> PeerId?)?

    /// Pending hole punch results
    private var pendingResults: [PeerId: CheckedContinuation<HolePunchResult, Never>] = [:]

    public init(peerId: String, config: Config = .default) {
        self.peerId = peerId
        self.config = config
        self.holePuncher = HolePuncher(peerId: peerId, config: config.holePunchConfig)
        self.coordinator = config.canCoordinate ? HolePunchCoordinator(config: config.coordinatorConfig) : nil
        self.logger = Logger(label: "io.omerta.mesh.holepunch.manager")
    }

    // MARK: - Lifecycle

    /// Start the hole punch manager
    public func start(natType: NATType, localPort: UInt16) async {
        self.natType = natType
        self.localPort = localPort

        if let coordinator = coordinator {
            await coordinator.start()
        }

        logger.info("Hole punch manager started", metadata: [
            "natType": "\(natType.rawValue)",
            "canCoordinate": "\(config.canCoordinate)"
        ])
    }

    /// Stop the hole punch manager
    public func stop() async {
        if let coordinator = coordinator {
            await coordinator.stop()
        }

        // Cancel pending results
        for (_, continuation) in pendingResults {
            continuation.resume(returning: .failed(reason: .cancelled))
        }
        pendingResults.removeAll()

        logger.info("Hole punch manager stopped")
    }

    /// Set callbacks for network operations
    public func setCallbacks(
        sendMessage: @escaping (MeshMessage, PeerId) async -> Void,
        getPeerEndpoint: @escaping (PeerId) async -> Endpoint?,
        getPeerNATType: @escaping (PeerId) async -> NATType?,
        getCoordinatorPeerId: @escaping () async -> PeerId?
    ) {
        self.sendMessage = sendMessage
        self.getPeerEndpoint = getPeerEndpoint
        self.getPeerNATType = getPeerNATType
        self.getCoordinatorPeerId = getCoordinatorPeerId

        // Also set coordinator callbacks if available
        if let coordinator = coordinator {
            Task {
                await coordinator.setCallbacks(
                    sendMessage: sendMessage,
                    getPeerEndpoint: getPeerEndpoint,
                    getPeerNATType: getPeerNATType
                )
            }
        }
    }

    /// Update NAT type
    public func updateNATType(_ natType: NATType) {
        self.natType = natType
    }

    /// Set the event logger for persistent logging
    public func setEventLogger(_ logger: MeshEventLogger?) {
        self.eventLogger = logger
    }

    // MARK: - Initiating Hole Punch

    /// Establish a direct connection to a peer via hole punching
    public func establishDirectConnection(to targetPeerId: PeerId) async -> HolePunchResult {
        let startTime = Date()

        // Get target's NAT type
        let targetNATType = await getPeerNATType?(targetPeerId) ?? .unknown

        // Log hole punch started
        await eventLogger?.recordHolePunchEvent(
            peerId: targetPeerId,
            eventType: .started,
            ourNATType: natType.rawValue,
            peerNATType: targetNATType.rawValue,
            strategy: nil
        )

        // Check compatibility
        let compatibility = HolePunchCompatibility.check(
            initiator: natType,
            responder: targetNATType
        )

        if !compatibility.strategy.canSucceed {
            logger.info("Hole punch impossible to \(targetPeerId): \(compatibility.recommendation)")

            // Log failure
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await eventLogger?.recordHolePunchEvent(
                peerId: targetPeerId,
                eventType: .failed,
                ourNATType: natType.rawValue,
                peerNATType: targetNATType.rawValue,
                strategy: nil,
                durationMs: durationMs,
                error: "Both peers have symmetric NAT"
            )

            return .failed(reason: .bothSymmetric)
        }

        // If we're public and target is public, we can connect directly
        if natType.isDirectlyReachable && targetNATType.isDirectlyReachable {
            if let endpoint = await getPeerEndpoint?(targetPeerId) {
                return .success(endpoint: endpoint, rtt: 0)
            }
        }

        // Need coordination - find a coordinator
        guard let coordinatorId = await getCoordinatorPeerId?() else {
            logger.warning("No coordinator available for hole punch")
            return .failed(reason: .timeout)
        }

        // Get our public endpoint (from STUN or announcement)
        let myEndpoint = await getPeerEndpoint?(peerId) ?? "unknown:0"

        // Send hole punch request to coordinator
        let requestMessage = MeshMessage.holePunchRequest(
            targetPeerId: targetPeerId,
            myEndpoint: myEndpoint,
            myNATType: natType
        )
        await sendMessage?(requestMessage, coordinatorId)

        logger.info("Sent hole punch request via coordinator \(coordinatorId)")

        // Wait for execute message from coordinator, then execute
        return await withCheckedContinuation { continuation in
            pendingResults[targetPeerId] = continuation

            // Set timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(config.holePunchConfig.timeout * 2 * 1_000_000_000))
                if let cont = self.pendingResults.removeValue(forKey: targetPeerId) {
                    cont.resume(returning: .failed(reason: .timeout))
                }
            }
        }
    }

    // MARK: - Message Handling

    /// Handle incoming hole punch messages
    public func handleMessage(
        _ message: MeshMessage,
        from peerId: PeerId
    ) async -> MeshMessage? {
        switch message {
        case .holePunchRequest(let targetPeerId, let myEndpoint, let myNATType):
            // We're being asked to coordinate
            if let coordinator = coordinator {
                let success = await coordinator.handleRequest(
                    from: peerId,
                    targetPeerId: targetPeerId,
                    initiatorEndpoint: myEndpoint,
                    initiatorNATType: myNATType
                )
                if !success {
                    logger.debug("Failed to coordinate hole punch request")
                }
            }
            return nil

        case .holePunchInvite(let fromPeerId, let theirEndpoint, let theirNATType):
            // Someone wants to hole punch with us
            await handleInvite(
                fromPeerId: fromPeerId,
                theirEndpoint: theirEndpoint,
                theirNATType: theirNATType
            )
            return nil

        case .holePunchExecute(let targetEndpoint, let strategy):
            // Coordinator tells us to execute
            await handleExecute(
                targetEndpoint: targetEndpoint,
                strategy: strategy,
                from: peerId
            )
            return nil

        case .holePunchResult(let targetPeerId, let success, let establishedEndpoint):
            // Result from peer or coordinator
            handleResult(
                targetPeerId: targetPeerId,
                success: success,
                establishedEndpoint: establishedEndpoint
            )

            // Also update coordinator if we have one
            if let coordinator = coordinator {
                await coordinator.handleResult(
                    from: peerId,
                    targetPeerId: targetPeerId,
                    success: success,
                    establishedEndpoint: establishedEndpoint
                )
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Private Handlers

    private func handleInvite(
        fromPeerId: PeerId,
        theirEndpoint: Endpoint,
        theirNATType: NATType
    ) async {
        // Determine strategy
        let compatibility = HolePunchCompatibility.check(
            initiator: theirNATType,
            responder: natType
        )

        if !compatibility.strategy.canSucceed {
            logger.info("Rejecting hole punch invite - strategy impossible")
            return
        }

        logger.info("Received hole punch invite from \(fromPeerId)")

        // Execute hole punch
        // Note: the strategy is from the initiator's perspective, so we need to flip it
        let ourStrategy: HolePunchStrategy
        switch compatibility.strategy {
        case .initiatorFirst:
            ourStrategy = .responderFirst
        case .responderFirst:
            ourStrategy = .initiatorFirst
        default:
            ourStrategy = compatibility.strategy
        }

        let startTime = Date()
        let result = await holePuncher.execute(
            targetPeerId: fromPeerId,
            targetEndpoint: theirEndpoint,
            strategy: ourStrategy,
            localPort: localPort
        )
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Log result
        await eventLogger?.recordHolePunchEvent(
            peerId: fromPeerId,
            eventType: result.succeeded ? .succeeded : .failed,
            ourNATType: natType.rawValue,
            peerNATType: theirNATType.rawValue,
            strategy: ourStrategy.rawValue,
            durationMs: durationMs,
            error: result.succeeded ? nil : result.failureReason?.description
        )

        // Report result
        let resultMessage = MeshMessage.holePunchResult(
            targetPeerId: fromPeerId,
            success: result.succeeded,
            establishedEndpoint: result.endpoint
        )
        await sendMessage?(resultMessage, fromPeerId)
    }

    private func handleExecute(
        targetEndpoint: Endpoint,
        strategy: HolePunchStrategy,
        from coordinatorId: PeerId
    ) async {
        // Extract target peer ID from pending results
        guard let (targetPeerId, _) = pendingResults.first else {
            logger.warning("Received execute but no pending hole punch")
            return
        }

        logger.info("Executing hole punch to \(targetEndpoint) with strategy \(strategy.rawValue)")

        // Execute hole punch
        let startTime = Date()
        let result = await holePuncher.execute(
            targetPeerId: targetPeerId,
            targetEndpoint: targetEndpoint,
            strategy: strategy,
            localPort: localPort
        )
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Log result
        await eventLogger?.recordHolePunchEvent(
            peerId: targetPeerId,
            eventType: result.succeeded ? .succeeded : .failed,
            ourNATType: natType.rawValue,
            peerNATType: nil,
            strategy: strategy.rawValue,
            durationMs: durationMs,
            error: result.succeeded ? nil : result.failureReason?.description
        )

        // Resume pending result
        if let continuation = pendingResults.removeValue(forKey: targetPeerId) {
            continuation.resume(returning: result)
        }

        // Report result to coordinator
        let resultMessage = MeshMessage.holePunchResult(
            targetPeerId: targetPeerId,
            success: result.succeeded,
            establishedEndpoint: result.endpoint
        )
        await sendMessage?(resultMessage, coordinatorId)
    }

    private func handleResult(
        targetPeerId: PeerId,
        success: Bool,
        establishedEndpoint: Endpoint?
    ) {
        // Resume pending continuation if any
        if let continuation = pendingResults.removeValue(forKey: targetPeerId) {
            if success, let endpoint = establishedEndpoint {
                continuation.resume(returning: .success(endpoint: endpoint, rtt: 0))
            } else {
                continuation.resume(returning: .failed(reason: .timeout))
            }
        }
    }

    // MARK: - Status

    /// Get active hole punch count
    public var activeHolePunchCount: Int {
        get async {
            await holePuncher.activeSessionCount
        }
    }

    /// Get coordinator request count (if coordinator)
    public var coordinatorRequestCount: Int {
        get async {
            await coordinator?.activeRequestCount ?? 0
        }
    }
}
