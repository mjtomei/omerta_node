// NATTraversal.swift
// Main coordinator for NAT detection and hole punching

import Foundation
import Logging

/// Our discovered public endpoint
public struct PublicEndpoint: Sendable {
    public let address: String
    public let port: UInt16
    public let natType: NATType

    public var endpoint: String {
        "\(address):\(port)"
    }
}

/// Established connection to a peer
public struct PeerConnection: Sendable {
    public let peerId: String
    public let endpoint: String
    public let connectionType: ConnectionType
    public let rtt: TimeInterval
}

/// How the connection was established
public enum ConnectionType: Sendable {
    case direct              // Hole punch succeeded
    case relayed(via: String) // Using relay server
}

/// Main NAT traversal coordinator
public actor NATTraversal {
    private let rendezvousURL: URL
    private let peerId: String
    private let networkId: String
    private let publicKey: String

    private var stunClient: STUNClient?
    private var rendezvousClient: RendezvousClient?
    private var holePuncher: HolePuncher?

    private var currentEndpoint: PublicEndpoint?
    private var pendingConnections: [String: CheckedContinuation<PeerConnection, Error>] = [:]

    private let logger: Logger

    /// Default local port for hole punching
    private let localPort: UInt16

    public init(
        rendezvousURL: URL,
        peerId: String,
        networkId: String,
        publicKey: String,
        localPort: UInt16 = 51820
    ) {
        self.rendezvousURL = rendezvousURL
        self.peerId = peerId
        self.networkId = networkId
        self.publicKey = publicKey
        self.localPort = localPort
        self.logger = Logger(label: "io.omerta.network.nat")
    }

    /// Current NAT type (discovered via STUN)
    public var natType: NATType {
        currentEndpoint?.natType ?? .unknown
    }

    /// Our public endpoint
    public var publicEndpoint: PublicEndpoint? {
        currentEndpoint
    }

    /// Connect to rendezvous and discover our public endpoint
    public func start() async throws -> PublicEndpoint {
        logger.info("Starting NAT traversal", metadata: [
            "peerId": "\(peerId)",
            "rendezvous": "\(rendezvousURL)"
        ])

        // Step 1: Discover our public endpoint via STUN
        let stun = STUNClient()
        self.stunClient = stun

        let (natType, stunResult) = try await stun.detectNATType()

        let endpoint = PublicEndpoint(
            address: stunResult.publicAddress,
            port: stunResult.publicPort,
            natType: natType
        )
        self.currentEndpoint = endpoint

        logger.info("Discovered public endpoint", metadata: [
            "endpoint": "\(endpoint.endpoint)",
            "natType": "\(natType.rawValue)"
        ])

        // Step 2: Connect to rendezvous server
        let rendezvous = RendezvousClient(
            serverURL: rendezvousURL,
            peerId: peerId,
            networkId: networkId
        )
        self.rendezvousClient = rendezvous

        // Set up message handler
        await rendezvous.setMessageHandler { [weak self] message in
            Task {
                await self?.handleServerMessage(message)
            }
        }

        try await rendezvous.connect()
        try await rendezvous.register()
        try await rendezvous.reportEndpoint(endpoint.endpoint, natType: natType)

        // Step 3: Create hole puncher
        self.holePuncher = HolePuncher()

        return endpoint
    }

    /// Stop NAT traversal and disconnect
    public func stop() async {
        if let rendezvous = rendezvousClient {
            await rendezvous.disconnect()
        }
        rendezvousClient = nil
        stunClient = nil
        holePuncher = nil
        currentEndpoint = nil
    }

    /// Establish connection to peer (hole punch or relay)
    public func connectToPeer(
        peerId targetPeerId: String,
        timeout: TimeInterval = 30.0
    ) async throws -> PeerConnection {
        guard let rendezvous = rendezvousClient else {
            throw NATTraversalError.notStarted
        }

        logger.info("Requesting connection to peer", metadata: ["targetPeerId": "\(targetPeerId)"])

        // Request connection via signaling server
        try await rendezvous.requestConnection(targetPeerId: targetPeerId, myPublicKey: publicKey)

        // Wait for connection to be established
        return try await withCheckedThrowingContinuation { continuation in
            pendingConnections[targetPeerId] = continuation

            // Set up timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = pendingConnections.removeValue(forKey: targetPeerId) {
                    cont.resume(throwing: NATTraversalError.timeout)
                }
            }
        }
    }

    /// Accept incoming connection request
    public func acceptConnection(
        fromPeerId: String,
        timeout: TimeInterval = 30.0
    ) async throws -> PeerConnection {
        // Similar to connectToPeer, but we wait for the peer to initiate
        return try await withCheckedThrowingContinuation { continuation in
            pendingConnections[fromPeerId] = continuation

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = pendingConnections.removeValue(forKey: fromPeerId) {
                    cont.resume(throwing: NATTraversalError.timeout)
                }
            }
        }
    }

    /// Refresh our public endpoint (useful if NAT rebinds)
    public func refreshEndpoint() async throws -> PublicEndpoint {
        guard let stun = stunClient else {
            throw NATTraversalError.notStarted
        }

        let (natType, stunResult) = try await stun.detectNATType()

        let endpoint = PublicEndpoint(
            address: stunResult.publicAddress,
            port: stunResult.publicPort,
            natType: natType
        )
        self.currentEndpoint = endpoint

        // Update rendezvous server
        if let rendezvous = rendezvousClient {
            try await rendezvous.reportEndpoint(endpoint.endpoint, natType: natType)
        }

        return endpoint
    }

    // MARK: - Server Message Handling

    private func handleServerMessage(_ message: ServerMessage) async {
        switch message {
        case .peerEndpoint(let peerId, let endpoint, let natType, let peerPublicKey):
            logger.info("Received peer endpoint", metadata: [
                "peerId": "\(peerId)",
                "endpoint": "\(endpoint)",
                "natType": "\(natType.rawValue)"
            ])
            // Store peer info for hole punching
            await handlePeerEndpoint(peerId: peerId, endpoint: endpoint, natType: natType, publicKey: peerPublicKey)

        case .holePunchStrategy(let strategy):
            logger.info("Received hole punch strategy", metadata: ["strategy": "\(strategy.rawValue)"])
            await handleHolePunchStrategy(strategy)

        case .holePunchNow(let targetEndpoint):
            await executeHolePunch(targetEndpoint: targetEndpoint, strategy: .simultaneous)

        case .holePunchInitiate(let targetEndpoint):
            await executeHolePunch(targetEndpoint: targetEndpoint, strategy: .youInitiate)

        case .holePunchWait:
            await waitForHolePunch()

        case .holePunchContinue(let newEndpoint):
            await executeHolePunch(targetEndpoint: newEndpoint, strategy: .simultaneous)

        case .relayAssigned(let relayEndpoint, let relayToken):
            logger.info("Relay assigned", metadata: [
                "endpoint": "\(relayEndpoint)",
                "token": "\(relayToken)"
            ])
            await handleRelayAssigned(relayEndpoint: relayEndpoint, relayToken: relayToken)

        case .error(let errorMessage):
            logger.error("Server error: \(errorMessage)")
            // Fail any pending connections
            for (_, continuation) in pendingConnections {
                continuation.resume(throwing: NATTraversalError.serverError(errorMessage))
            }
            pendingConnections.removeAll()

        default:
            break
        }
    }

    private var currentPeerInfo: (peerId: String, endpoint: String, natType: NATType, publicKey: String)?
    private var currentStrategy: HolePunchStrategy?

    private func handlePeerEndpoint(peerId: String, endpoint: String, natType: NATType, publicKey: String) async {
        currentPeerInfo = (peerId, endpoint, natType, publicKey)
    }

    private func handleHolePunchStrategy(_ strategy: HolePunchStrategy) async {
        currentStrategy = strategy
    }

    private func executeHolePunch(targetEndpoint: String, strategy: HolePunchStrategy) async {
        guard let puncher = holePuncher,
              let peerInfo = currentPeerInfo else {
            return
        }

        do {
            let result = try await puncher.execute(
                localPort: localPort,
                targetEndpoint: targetEndpoint,
                strategy: strategy
            )

            switch result {
            case .success(let actualEndpoint, let rtt):
                let connection = PeerConnection(
                    peerId: peerInfo.peerId,
                    endpoint: actualEndpoint,
                    connectionType: .direct,
                    rtt: rtt
                )

                // Report success to signaling server
                try? await rendezvousClient?.holePunchResult(
                    targetPeerId: peerInfo.peerId,
                    success: true,
                    actualEndpoint: actualEndpoint
                )

                // Complete pending connection
                if let continuation = pendingConnections.removeValue(forKey: peerInfo.peerId) {
                    continuation.resume(returning: connection)
                }

            case .failed(let reason):
                logger.warning("Hole punch failed", metadata: ["reason": "\(reason)"])

                // Report failure
                try? await rendezvousClient?.holePunchResult(
                    targetPeerId: peerInfo.peerId,
                    success: false,
                    actualEndpoint: nil
                )

                // Request relay if both symmetric
                if case .bothSymmetric = reason {
                    try? await rendezvousClient?.requestRelay(targetPeerId: peerInfo.peerId)
                } else {
                    // Fail the connection
                    if let continuation = pendingConnections.removeValue(forKey: peerInfo.peerId) {
                        continuation.resume(throwing: NATTraversalError.holePunchFailed(reason))
                    }
                }
            }
        } catch {
            logger.error("Hole punch error: \(error)")
            if let continuation = pendingConnections.removeValue(forKey: peerInfo.peerId) {
                continuation.resume(throwing: error)
            }
        }

        currentPeerInfo = nil
        currentStrategy = nil
    }

    private func waitForHolePunch() async {
        guard let puncher = holePuncher else { return }

        do {
            let sourceEndpoint = try await puncher.waitForPunch(
                localPort: localPort,
                timeout: 10.0
            )

            // After receiving probe, signal that we got it
            if let rendezvous = rendezvousClient {
                try await rendezvous.holePunchSent(newEndpoint: sourceEndpoint)
            }
        } catch {
            logger.warning("Wait for hole punch failed: \(error)")
        }
    }

    private func handleRelayAssigned(relayEndpoint: String, relayToken: String) async {
        guard let peerInfo = currentPeerInfo else { return }

        // Create relay connection
        let connection = PeerConnection(
            peerId: peerInfo.peerId,
            endpoint: relayEndpoint,
            connectionType: .relayed(via: relayEndpoint),
            rtt: 0 // Unknown for relay
        )

        // Complete pending connection
        if let continuation = pendingConnections.removeValue(forKey: peerInfo.peerId) {
            continuation.resume(returning: connection)
        }

        currentPeerInfo = nil
        currentStrategy = nil
    }
}

// MARK: - Errors

public enum NATTraversalError: Error, CustomStringConvertible {
    case notStarted
    case timeout
    case serverError(String)
    case holePunchFailed(HolePunchFailure)
    case noEndpoint

    public var description: String {
        switch self {
        case .notStarted:
            return "NAT traversal not started"
        case .timeout:
            return "Connection timed out"
        case .serverError(let message):
            return "Server error: \(message)"
        case .holePunchFailed(let failure):
            return "Hole punch failed: \(failure)"
        case .noEndpoint:
            return "No endpoint discovered"
        }
    }
}

// MARK: - Convenience Extensions

public extension NATTraversal {
    /// Create with default settings for a peer
    static func create(
        peerId: String,
        networkId: String,
        publicKey: String,
        rendezvousHost: String = "localhost",
        rendezvousPort: Int = 8080
    ) -> NATTraversal {
        let url = URL(string: "ws://\(rendezvousHost):\(rendezvousPort)")!
        return NATTraversal(
            rendezvousURL: url,
            peerId: peerId,
            networkId: networkId,
            publicKey: publicKey
        )
    }

    /// Quick STUN-only endpoint discovery (no rendezvous needed)
    static func discoverEndpoint(
        stunServer: String = "stun.l.google.com:19302"
    ) async throws -> PublicEndpoint {
        let stun = STUNClient()
        let (natType, result) = try await stun.detectNATType(servers: [
            stunServer,
            "stun1.l.google.com:19302"
        ])

        return PublicEndpoint(
            address: result.publicAddress,
            port: result.publicPort,
            natType: natType
        )
    }
}
