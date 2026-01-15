// ConnectionKeepalive.swift - Maintains NAT mappings for direct connections

import Foundation
import Logging

/// Manages keepalive pings to maintain NAT mappings for direct connections
public actor ConnectionKeepalive {
    /// Configuration for keepalive behavior
    public struct Config: Sendable {
        /// Interval between keepalive pings (seconds)
        public let interval: TimeInterval

        /// Number of missed keepalives before marking connection as failed
        public let missedThreshold: Int

        /// Timeout for waiting for a pong response (seconds)
        public let responseTimeout: TimeInterval

        public init(
            interval: TimeInterval = 15,
            missedThreshold: Int = 3,
            responseTimeout: TimeInterval = 5
        ) {
            self.interval = interval
            self.missedThreshold = missedThreshold
            self.responseTimeout = responseTimeout
        }

        public static let `default` = Config()
    }

    /// State of a tracked connection
    public struct ConnectionState: Sendable {
        public let peerId: PeerId
        public let endpoint: String
        public var lastSuccessfulPing: Date
        public var missedPings: Int
        public var isHealthy: Bool { missedPings < 3 }

        public init(peerId: PeerId, endpoint: String) {
            self.peerId = peerId
            self.endpoint = endpoint
            self.lastSuccessfulPing = Date()
            self.missedPings = 0
        }
    }

    /// Callback type for sending pings
    public typealias PingSender = (PeerId, String) async -> Bool

    /// Callback type for reporting failed connections
    public typealias FailureHandler = (PeerId, String) async -> Void

    // MARK: - Properties

    private let config: Config
    private let logger: Logger

    /// Active connections being monitored
    private var connections: [PeerId: ConnectionState] = [:]

    /// Background task for keepalive loop
    private var keepaliveTask: Task<Void, Never>?

    /// Callback to send ping to a peer
    private var pingSender: PingSender?

    /// Callback when a connection fails
    private var failureHandler: FailureHandler?

    // MARK: - Initialization

    public init(config: Config = .default) {
        self.config = config
        self.logger = Logger(label: "io.omerta.mesh.keepalive")
    }

    // MARK: - Configuration

    /// Set the ping sender callback
    public func setPingSender(_ sender: @escaping PingSender) {
        self.pingSender = sender
    }

    /// Set the failure handler callback
    public func setFailureHandler(_ handler: @escaping FailureHandler) {
        self.failureHandler = handler
    }

    // MARK: - Lifecycle

    /// Start the keepalive manager
    public func start() {
        guard keepaliveTask == nil else { return }

        keepaliveTask = Task {
            await runKeepaliveLoop()
        }

        logger.info("Connection keepalive started with interval \(config.interval)s")
    }

    /// Stop the keepalive manager
    public func stop() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        // Note: connections are preserved so they can be resumed
        logger.info("Connection keepalive stopped")
    }

    /// Stop and clear all connections
    public func stopAndClear() {
        stop()
        connections.removeAll()
    }

    // MARK: - Connection Management

    /// Add a connection to monitor
    public func addConnection(peerId: PeerId, endpoint: String) {
        connections[peerId] = ConnectionState(peerId: peerId, endpoint: endpoint)
        logger.debug("Added connection to monitor: \(peerId) at \(endpoint)")
    }

    /// Remove a connection from monitoring
    public func removeConnection(peerId: PeerId) {
        connections.removeValue(forKey: peerId)
        logger.debug("Removed connection from monitoring: \(peerId)")
    }

    /// Record a successful communication (resets missed count)
    public func recordSuccessfulCommunication(peerId: PeerId) {
        if var state = connections[peerId] {
            state.lastSuccessfulPing = Date()
            state.missedPings = 0
            connections[peerId] = state
        }
    }

    /// Update endpoint for a connection
    public func updateEndpoint(peerId: PeerId, endpoint: String) {
        if var state = connections[peerId] {
            state = ConnectionState(peerId: peerId, endpoint: endpoint)
            connections[peerId] = state
        }
    }

    /// Check if a connection is being monitored
    public func isMonitoring(peerId: PeerId) -> Bool {
        connections[peerId] != nil
    }

    /// Get the state of a connection
    public func getConnectionState(peerId: PeerId) -> ConnectionState? {
        connections[peerId]
    }

    /// Get all monitored connections
    public var monitoredConnections: [ConnectionState] {
        Array(connections.values)
    }

    /// Get count of healthy connections
    public var healthyConnectionCount: Int {
        connections.values.filter { $0.isHealthy }.count
    }

    // MARK: - Private Methods

    private func runKeepaliveLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(config.interval * 1_000_000_000))
                await sendKeepalives()
            } catch {
                // Task cancelled
                break
            }
        }
    }

    private func sendKeepalives() async {
        guard let sender = pingSender else {
            logger.warning("No ping sender configured for keepalive")
            return
        }

        // Copy connections to avoid mutation during iteration
        let currentConnections = connections

        if !currentConnections.isEmpty {
            logger.info("Sending keepalive pings to \(currentConnections.count) peer(s)")
        }

        for (peerId, state) in currentConnections {
            // Send ping and check response
            let success = await sender(peerId, state.endpoint)

            if success {
                // Reset missed count on success
                if var updatedState = connections[peerId] {
                    updatedState.lastSuccessfulPing = Date()
                    updatedState.missedPings = 0
                    connections[peerId] = updatedState
                    logger.info("Keepalive OK", metadata: [
                        "peer": "\(peerId.prefix(8))...",
                        "endpoint": "\(state.endpoint)"
                    ])
                }
            } else {
                // Increment missed count
                if var updatedState = connections[peerId] {
                    updatedState.missedPings += 1
                    connections[peerId] = updatedState

                    logger.warning("Keepalive missed", metadata: [
                        "peer": "\(peerId.prefix(8))...",
                        "missed": "\(updatedState.missedPings)/\(config.missedThreshold)"
                    ])

                    // Check if connection should be marked as failed
                    if updatedState.missedPings >= config.missedThreshold {
                        logger.warning("Connection to \(peerId) failed after \(config.missedThreshold) missed keepalives")

                        // Remove from monitoring
                        connections.removeValue(forKey: peerId)

                        // Notify failure handler
                        if let handler = failureHandler {
                            await handler(peerId, state.endpoint)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Statistics

extension ConnectionKeepalive {
    /// Statistics about keepalive state
    public struct Statistics: Sendable {
        public let totalConnections: Int
        public let healthyConnections: Int
        public let unhealthyConnections: Int

        public var healthPercentage: Double {
            guard totalConnections > 0 else { return 100.0 }
            return Double(healthyConnections) / Double(totalConnections) * 100.0
        }
    }

    /// Get current statistics
    public var statistics: Statistics {
        let healthy = connections.values.filter { $0.isHealthy }.count
        let unhealthy = connections.count - healthy
        return Statistics(
            totalConnections: connections.count,
            healthyConnections: healthy,
            unhealthyConnections: unhealthy
        )
    }
}
