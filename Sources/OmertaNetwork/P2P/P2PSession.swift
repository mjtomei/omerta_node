// P2PSession.swift
// Coordinates NAT traversal with WireGuard VPN setup

import Foundation
import Logging
import OmertaCore

/// Connection method used for the P2P session
public enum P2PConnectionMethod: Sendable, CustomStringConvertible {
    case direct(endpoint: String)           // Direct IP (no NAT traversal needed)
    case holePunched(endpoint: String)      // NAT hole punch succeeded
    case relayed(relayEndpoint: String)     // Using relay server

    public var description: String {
        switch self {
        case .direct(let endpoint):
            return "direct(\(endpoint))"
        case .holePunched(let endpoint):
            return "hole-punched(\(endpoint))"
        case .relayed(let relay):
            return "relayed(\(relay))"
        }
    }

    public var endpoint: String {
        switch self {
        case .direct(let endpoint), .holePunched(let endpoint), .relayed(let endpoint):
            return endpoint
        }
    }

    public var isRelayed: Bool {
        if case .relayed = self { return true }
        return false
    }
}

/// Result of P2P connection establishment
public struct P2PConnectionResult: Sendable {
    public let method: P2PConnectionMethod
    public let localEndpoint: String
    public let remoteEndpoint: String
    public let rtt: TimeInterval?
    public let natType: NATType

    public init(
        method: P2PConnectionMethod,
        localEndpoint: String,
        remoteEndpoint: String,
        rtt: TimeInterval? = nil,
        natType: NATType = .unknown
    ) {
        self.method = method
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.rtt = rtt
        self.natType = natType
    }
}

/// Configuration for P2P session
public struct P2PSessionConfig: Sendable {
    public let peerId: String
    public let networkId: String
    public let publicKey: String
    public let rendezvousURL: URL?
    public let localPort: UInt16
    public let enableNATTraversal: Bool
    public let holePunchTimeout: TimeInterval
    public let fallbackToRelay: Bool

    public init(
        peerId: String,
        networkId: String,
        publicKey: String,
        rendezvousURL: URL? = nil,
        localPort: UInt16 = 51820,
        enableNATTraversal: Bool = true,
        holePunchTimeout: TimeInterval = 30.0,
        fallbackToRelay: Bool = true
    ) {
        self.peerId = peerId
        self.networkId = networkId
        self.publicKey = publicKey
        self.rendezvousURL = rendezvousURL
        self.localPort = localPort
        self.enableNATTraversal = enableNATTraversal
        self.holePunchTimeout = holePunchTimeout
        self.fallbackToRelay = fallbackToRelay
    }
}

/// Coordinates NAT traversal and WireGuard setup for P2P connections
public actor P2PSession {
    private let config: P2PSessionConfig
    private var natTraversal: NATTraversal?
    private var publicEndpoint: PublicEndpoint?
    private var activeConnections: [String: P2PConnectionResult] = [:]
    private let logger: Logger

    public init(config: P2PSessionConfig) {
        self.config = config
        self.logger = Logger(label: "io.omerta.network.p2p")
    }

    /// Start the P2P session (discover public endpoint)
    public func start() async throws -> PublicEndpoint {
        guard config.enableNATTraversal, let rendezvousURL = config.rendezvousURL else {
            // No NAT traversal - return placeholder endpoint
            logger.info("NAT traversal disabled, using direct mode")
            let endpoint = PublicEndpoint(
                address: "0.0.0.0",
                port: config.localPort,
                natType: .unknown
            )
            self.publicEndpoint = endpoint
            return endpoint
        }

        logger.info("Starting P2P session", metadata: [
            "peerId": "\(config.peerId)",
            "rendezvous": "\(rendezvousURL)"
        ])

        // Create and start NAT traversal
        let nat = NATTraversal(
            rendezvousURL: rendezvousURL,
            peerId: config.peerId,
            networkId: config.networkId,
            publicKey: config.publicKey,
            localPort: config.localPort
        )
        self.natTraversal = nat

        let endpoint = try await nat.start()
        self.publicEndpoint = endpoint

        logger.info("P2P session started", metadata: [
            "endpoint": "\(endpoint.endpoint)",
            "natType": "\(endpoint.natType.rawValue)"
        ])

        return endpoint
    }

    /// Stop the P2P session
    public func stop() async {
        if let nat = natTraversal {
            await nat.stop()
        }
        natTraversal = nil
        publicEndpoint = nil
        activeConnections.removeAll()
        logger.info("P2P session stopped")
    }

    /// Our discovered public endpoint
    public var endpoint: PublicEndpoint? {
        publicEndpoint
    }

    /// Our NAT type
    public var natType: NATType {
        publicEndpoint?.natType ?? .unknown
    }

    /// Connect to a peer (consumer connecting to provider)
    /// Returns the connection result with the method used and endpoint
    public func connectToPeer(
        peerId targetPeerId: String,
        directEndpoint: String? = nil
    ) async throws -> P2PConnectionResult {
        // Check if we already have a connection
        if let existing = activeConnections[targetPeerId] {
            logger.info("Reusing existing connection to peer", metadata: ["peerId": "\(targetPeerId)"])
            return existing
        }

        // If direct endpoint provided and NAT traversal disabled, use direct
        if let direct = directEndpoint, !config.enableNATTraversal {
            logger.info("Using direct endpoint (NAT traversal disabled)", metadata: [
                "peerId": "\(targetPeerId)",
                "endpoint": "\(direct)"
            ])

            let result = P2PConnectionResult(
                method: .direct(endpoint: direct),
                localEndpoint: "0.0.0.0:\(config.localPort)",
                remoteEndpoint: direct,
                natType: .unknown
            )
            activeConnections[targetPeerId] = result
            return result
        }

        // Try NAT traversal if available
        guard let nat = natTraversal else {
            // No NAT traversal, use direct endpoint if available
            if let direct = directEndpoint {
                let result = P2PConnectionResult(
                    method: .direct(endpoint: direct),
                    localEndpoint: "0.0.0.0:\(config.localPort)",
                    remoteEndpoint: direct,
                    natType: .unknown
                )
                activeConnections[targetPeerId] = result
                return result
            }
            throw P2PSessionError.notStarted
        }

        logger.info("Attempting NAT traversal to peer", metadata: ["peerId": "\(targetPeerId)"])

        do {
            // Attempt hole punch via signaling server
            let peerConnection = try await nat.connectToPeer(
                peerId: targetPeerId,
                timeout: config.holePunchTimeout
            )

            let method: P2PConnectionMethod
            switch peerConnection.connectionType {
            case .direct:
                method = .holePunched(endpoint: peerConnection.endpoint)
            case .relayed(let via):
                method = .relayed(relayEndpoint: via)
            }

            let result = P2PConnectionResult(
                method: method,
                localEndpoint: publicEndpoint?.endpoint ?? "unknown",
                remoteEndpoint: peerConnection.endpoint,
                rtt: peerConnection.rtt,
                natType: natType
            )

            activeConnections[targetPeerId] = result

            logger.info("Connected to peer", metadata: [
                "peerId": "\(targetPeerId)",
                "method": "\(method)",
                "rtt": "\(String(format: "%.2f", (peerConnection.rtt * 1000)))ms"
            ])

            return result

        } catch {
            logger.warning("NAT traversal failed", metadata: [
                "peerId": "\(targetPeerId)",
                "error": "\(error)"
            ])

            // Fall back to direct endpoint if available
            if let direct = directEndpoint {
                logger.info("Falling back to direct endpoint", metadata: ["endpoint": "\(direct)"])
                let result = P2PConnectionResult(
                    method: .direct(endpoint: direct),
                    localEndpoint: publicEndpoint?.endpoint ?? "unknown",
                    remoteEndpoint: direct,
                    natType: natType
                )
                activeConnections[targetPeerId] = result
                return result
            }

            throw error
        }
    }

    /// Accept incoming connection from peer (provider accepting from consumer)
    public func acceptConnection(
        fromPeerId: String
    ) async throws -> P2PConnectionResult {
        guard let nat = natTraversal else {
            throw P2PSessionError.notStarted
        }

        logger.info("Waiting for connection from peer", metadata: ["peerId": "\(fromPeerId)"])

        let peerConnection = try await nat.acceptConnection(
            fromPeerId: fromPeerId,
            timeout: config.holePunchTimeout
        )

        let method: P2PConnectionMethod
        switch peerConnection.connectionType {
        case .direct:
            method = .holePunched(endpoint: peerConnection.endpoint)
        case .relayed(let via):
            method = .relayed(relayEndpoint: via)
        }

        let result = P2PConnectionResult(
            method: method,
            localEndpoint: publicEndpoint?.endpoint ?? "unknown",
            remoteEndpoint: peerConnection.endpoint,
            rtt: peerConnection.rtt,
            natType: natType
        )

        activeConnections[fromPeerId] = result

        logger.info("Accepted connection from peer", metadata: [
            "peerId": "\(fromPeerId)",
            "method": "\(method)"
        ])

        return result
    }

    /// Get connection info for a peer
    public func getConnection(peerId: String) -> P2PConnectionResult? {
        activeConnections[peerId]
    }

    /// Disconnect from a peer
    public func disconnect(peerId: String) {
        activeConnections.removeValue(forKey: peerId)
        logger.info("Disconnected from peer", metadata: ["peerId": "\(peerId)"])
    }

    /// Refresh our public endpoint (useful if NAT rebinds)
    public func refreshEndpoint() async throws -> PublicEndpoint {
        guard let nat = natTraversal else {
            throw P2PSessionError.notStarted
        }

        let endpoint = try await nat.refreshEndpoint()
        self.publicEndpoint = endpoint

        logger.info("Endpoint refreshed", metadata: [
            "endpoint": "\(endpoint.endpoint)",
            "natType": "\(endpoint.natType.rawValue)"
        ])

        return endpoint
    }
}

// MARK: - Errors

public enum P2PSessionError: Error, CustomStringConvertible {
    case notStarted
    case peerNotFound(String)
    case connectionFailed(String)
    case relayRequired

    public var description: String {
        switch self {
        case .notStarted:
            return "P2P session not started"
        case .peerNotFound(let peerId):
            return "Peer not found: \(peerId)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .relayRequired:
            return "Relay required but not available"
        }
    }
}

// MARK: - Convenience Extensions

public extension P2PSession {
    /// Create a P2P session with default configuration
    static func create(
        peerId: String,
        networkId: String,
        publicKey: String,
        rendezvousHost: String = "localhost",
        rendezvousPort: Int = 8080
    ) -> P2PSession {
        let url = URL(string: "ws://\(rendezvousHost):\(rendezvousPort)")!
        let config = P2PSessionConfig(
            peerId: peerId,
            networkId: networkId,
            publicKey: publicKey,
            rendezvousURL: url
        )
        return P2PSession(config: config)
    }

    /// Quick STUN-only endpoint discovery (no rendezvous/signaling)
    static func discoverEndpoint() async throws -> PublicEndpoint {
        try await NATTraversal.discoverEndpoint()
    }
}
