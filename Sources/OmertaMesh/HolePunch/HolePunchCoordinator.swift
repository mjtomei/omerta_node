// HolePunchCoordinator.swift - Coordinates hole punching between NAT-bound peers

import Foundation
import Logging

/// A pending hole punch coordination request
public struct HolePunchRequest: Sendable {
    /// Unique request ID
    public let requestId: String

    /// Peer requesting the hole punch
    public let initiatorPeerId: PeerId

    /// Initiator's public endpoint
    public let initiatorEndpoint: Endpoint

    /// Initiator's NAT type
    public let initiatorNATType: NATType

    /// Target peer
    public let targetPeerId: PeerId

    /// When the request was created
    public let createdAt: Date

    /// Request state
    public var state: HolePunchRequestState

    public init(
        requestId: String = UUID().uuidString,
        initiatorPeerId: PeerId,
        initiatorEndpoint: Endpoint,
        initiatorNATType: NATType,
        targetPeerId: PeerId
    ) {
        self.requestId = requestId
        self.initiatorPeerId = initiatorPeerId
        self.initiatorEndpoint = initiatorEndpoint
        self.initiatorNATType = initiatorNATType
        self.targetPeerId = targetPeerId
        self.createdAt = Date()
        self.state = .pending
    }
}

/// State of a hole punch request
public enum HolePunchRequestState: Sendable, Equatable {
    case pending
    case inviteSent
    case executing
    case completed(success: Bool)
    case expired
}

/// Coordinates hole punching between two NAT-bound peers
/// This runs on public nodes that can reach both peers
public actor HolePunchCoordinator {
    /// Configuration for the coordinator
    public struct Config: Sendable {
        /// How long to wait for target peer to respond to invite
        public let inviteTimeout: TimeInterval

        /// How long to keep pending requests
        public let requestTimeout: TimeInterval

        /// Maximum concurrent coordinations
        public let maxConcurrent: Int

        /// Cleanup interval
        public let cleanupInterval: TimeInterval

        public init(
            inviteTimeout: TimeInterval = 10.0,
            requestTimeout: TimeInterval = 30.0,
            maxConcurrent: Int = 50,
            cleanupInterval: TimeInterval = 60.0
        ) {
            self.inviteTimeout = inviteTimeout
            self.requestTimeout = requestTimeout
            self.maxConcurrent = maxConcurrent
            self.cleanupInterval = cleanupInterval
        }

        public static let `default` = Config()
    }

    private let config: Config
    private let logger: Logger

    /// Pending hole punch requests by request ID
    private var requests: [String: HolePunchRequest] = [:]

    /// Requests indexed by target peer ID
    private var requestsByTarget: [PeerId: [String]] = [:]

    /// Callback to send messages
    private var sendMessage: ((MeshMessage, PeerId) async -> Void)?

    /// Callback to get peer endpoint
    private var getPeerEndpoint: ((PeerId) async -> Endpoint?)?

    /// Callback to get peer NAT type
    private var getPeerNATType: ((PeerId) async -> NATType?)?

    /// Cleanup task
    private var cleanupTask: Task<Void, Never>?

    public init(config: Config = .default) {
        self.config = config
        self.logger = Logger(label: "io.omerta.mesh.holepunch.coordinator")
    }

    // MARK: - Lifecycle

    /// Start the coordinator
    public func start() {
        cleanupTask?.cancel()
        cleanupTask = Task {
            await runCleanupLoop()
        }
        logger.info("Hole punch coordinator started")
    }

    /// Stop the coordinator
    public func stop() {
        cleanupTask?.cancel()
        cleanupTask = nil
        requests.removeAll()
        requestsByTarget.removeAll()
        logger.info("Hole punch coordinator stopped")
    }

    /// Set callbacks for network operations
    public func setCallbacks(
        sendMessage: @escaping (MeshMessage, PeerId) async -> Void,
        getPeerEndpoint: @escaping (PeerId) async -> Endpoint?,
        getPeerNATType: @escaping (PeerId) async -> NATType?
    ) {
        self.sendMessage = sendMessage
        self.getPeerEndpoint = getPeerEndpoint
        self.getPeerNATType = getPeerNATType
    }

    // MARK: - Request Handling

    /// Handle a hole punch request from a peer
    public func handleRequest(
        from initiatorPeerId: PeerId,
        targetPeerId: PeerId,
        initiatorEndpoint: Endpoint,
        initiatorNATType: NATType
    ) async -> Bool {
        // Check capacity
        guard requests.count < config.maxConcurrent else {
            logger.warning("Coordinator at capacity, rejecting request")
            return false
        }

        // Get target's endpoint and NAT type
        guard let targetEndpoint = await getPeerEndpoint?(targetPeerId) else {
            logger.warning("Cannot find endpoint for target peer \(targetPeerId)")
            return false
        }

        let targetNATType = await getPeerNATType?(targetPeerId) ?? .unknown

        // Check if hole punching is possible
        let compatibility = HolePunchCompatibility.check(
            initiator: initiatorNATType,
            responder: targetNATType
        )

        if !compatibility.strategy.canSucceed {
            logger.info("Hole punch impossible between \(initiatorPeerId) and \(targetPeerId)")
            return false
        }

        // Create request
        let request = HolePunchRequest(
            initiatorPeerId: initiatorPeerId,
            initiatorEndpoint: initiatorEndpoint,
            initiatorNATType: initiatorNATType,
            targetPeerId: targetPeerId
        )

        requests[request.requestId] = request
        requestsByTarget[targetPeerId, default: []].append(request.requestId)

        logger.info("Coordinating hole punch", metadata: [
            "initiator": "\(initiatorPeerId)",
            "target": "\(targetPeerId)",
            "strategy": "\(compatibility.strategy.rawValue)"
        ])

        // Send invite to target peer
        let inviteMessage = MeshMessage.holePunchInvite(
            fromPeerId: initiatorPeerId,
            theirEndpoint: initiatorEndpoint,
            theirNATType: initiatorNATType
        )
        await sendMessage?(inviteMessage, targetPeerId)

        // Update state
        var updatedRequest = request
        updatedRequest.state = .inviteSent
        requests[request.requestId] = updatedRequest

        // After invite is sent, tell initiator to execute
        // The strategy determines who sends first
        let strategy = compatibility.strategy
        let executeMessage = MeshMessage.holePunchExecute(
            targetEndpoint: targetEndpoint,
            strategy: strategy
        )
        await sendMessage?(executeMessage, initiatorPeerId)

        // Update state
        updatedRequest.state = .executing
        requests[request.requestId] = updatedRequest

        return true
    }

    /// Handle a hole punch result report from a peer
    public func handleResult(
        from peerId: PeerId,
        targetPeerId: PeerId,
        success: Bool,
        establishedEndpoint: Endpoint?
    ) {
        // Find the matching request
        let requestId = requests.first { _, req in
            (req.initiatorPeerId == peerId && req.targetPeerId == targetPeerId) ||
            (req.targetPeerId == peerId && req.initiatorPeerId == targetPeerId)
        }?.key

        guard let id = requestId else {
            logger.debug("No matching request for hole punch result")
            return
        }

        // Update state
        if var request = requests[id] {
            request.state = .completed(success: success)
            requests[id] = request

            logger.info("Hole punch completed", metadata: [
                "initiator": "\(request.initiatorPeerId)",
                "target": "\(request.targetPeerId)",
                "success": "\(success)",
                "endpoint": "\(establishedEndpoint ?? "none")"
            ])
        }
    }

    /// Get pending requests for a target peer
    public func pendingRequests(for targetPeerId: PeerId) -> [HolePunchRequest] {
        let requestIds = requestsByTarget[targetPeerId] ?? []
        return requestIds.compactMap { requests[$0] }
            .filter { $0.state == .pending || $0.state == .inviteSent }
    }

    /// Get request by ID
    public func getRequest(_ requestId: String) -> HolePunchRequest? {
        requests[requestId]
    }

    /// Number of active requests
    public var activeRequestCount: Int {
        requests.values.filter { request in
            switch request.state {
            case .pending, .inviteSent, .executing:
                return true
            default:
                return false
            }
        }.count
    }

    // MARK: - Cleanup

    private func runCleanupLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(config.cleanupInterval * 1_000_000_000))
                cleanup()
            } catch {
                break
            }
        }
    }

    private func cleanup() {
        let now = Date()
        var expiredIds: [String] = []

        for (id, request) in requests {
            let age = now.timeIntervalSince(request.createdAt)

            // Expire old requests
            if age > config.requestTimeout {
                expiredIds.append(id)
                continue
            }

            // Expire invite-sent requests that haven't progressed
            if case .inviteSent = request.state, age > config.inviteTimeout {
                expiredIds.append(id)
            }
        }

        for id in expiredIds {
            if let request = requests.removeValue(forKey: id) {
                // Remove from target index
                if var targetRequests = requestsByTarget[request.targetPeerId] {
                    targetRequests.removeAll { $0 == id }
                    if targetRequests.isEmpty {
                        requestsByTarget.removeValue(forKey: request.targetPeerId)
                    } else {
                        requestsByTarget[request.targetPeerId] = targetRequests
                    }
                }

                logger.debug("Expired hole punch request \(id)")
            }
        }

        // Clean up completed requests older than cleanup interval
        let completedCutoff = now.addingTimeInterval(-config.cleanupInterval)
        for (id, request) in requests {
            if case .completed = request.state, request.createdAt < completedCutoff {
                requests.removeValue(forKey: id)
                if var targetRequests = requestsByTarget[request.targetPeerId] {
                    targetRequests.removeAll { $0 == id }
                    if targetRequests.isEmpty {
                        requestsByTarget.removeValue(forKey: request.targetPeerId)
                    } else {
                        requestsByTarget[request.targetPeerId] = targetRequests
                    }
                }
            }
        }
    }
}
