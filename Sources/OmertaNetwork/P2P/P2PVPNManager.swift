// P2PVPNManager.swift
// Manages WireGuard VPN with NAT traversal support

import Foundation
import Logging
import OmertaCore

/// WireGuard VPN manager with P2P/NAT traversal support
/// Extends standard VPN functionality with hole-punched and relayed connections
public actor P2PVPNManager {
    private let ephemeralVPN: EphemeralVPN
    private var p2pSession: P2PSession?
    private var activeRelayProxies: [UUID: WireGuardRelayProxy] = [:]
    private let logger: Logger

    public init(basePort: UInt16 = 51900, dryRun: Bool = false) {
        self.ephemeralVPN = EphemeralVPN(basePort: basePort, dryRun: dryRun)
        self.logger = Logger(label: "io.omerta.network.p2p-vpn")
    }

    /// Start P2P session with NAT traversal
    public func startP2PSession(
        config: P2PSessionConfig
    ) async throws -> PublicEndpoint {
        let session = P2PSession(config: config)
        self.p2pSession = session

        let endpoint = try await session.start()

        logger.info("P2P session started", metadata: [
            "endpoint": "\(endpoint.endpoint)",
            "natType": "\(endpoint.natType.rawValue)"
        ])

        return endpoint
    }

    /// Stop P2P session
    public func stopP2PSession() async {
        if let session = p2pSession {
            await session.stop()
        }
        p2pSession = nil

        // Stop all relay proxies
        for (_, proxy) in activeRelayProxies {
            await proxy.stop()
        }
        activeRelayProxies.removeAll()

        logger.info("P2P session stopped")
    }

    /// Create VPN for a job with P2P/NAT traversal support
    /// Automatically uses the appropriate connection method based on NAT traversal results
    public func createP2PVPN(
        jobId: UUID,
        targetPeerId: String,
        directEndpoint: String? = nil
    ) async throws -> P2PVPNConfiguration {
        // Get connection result from P2P session
        let connectionResult: P2PConnectionResult?

        if let session = p2pSession {
            do {
                connectionResult = try await session.connectToPeer(
                    peerId: targetPeerId,
                    directEndpoint: directEndpoint
                )
            } catch {
                logger.warning("P2P connection failed, falling back to direct", metadata: [
                    "error": "\(error)"
                ])
                connectionResult = nil
            }
        } else {
            connectionResult = nil
        }

        // Create base VPN configuration
        // Use the discovered endpoint if available
        let providerEndpoint: String?
        if let result = connectionResult {
            providerEndpoint = result.remoteEndpoint
        } else {
            providerEndpoint = directEndpoint
        }

        let vpnConfig = try await ephemeralVPN.createVPNForJob(jobId, providerEndpoint: providerEndpoint)

        // Determine actual endpoint based on connection method
        let finalEndpoint: String
        let connectionMethod: P2PConnectionMethod

        if let result = connectionResult {
            switch result.method {
            case .relayed(let relayEndpoint):
                // Set up relay proxy
                let proxy = try await setupRelayProxy(
                    jobId: jobId,
                    relayEndpoint: relayEndpoint,
                    targetPeerId: targetPeerId
                )
                finalEndpoint = await proxy.localEndpoint
                connectionMethod = .relayed(relayEndpoint: relayEndpoint)

            case .holePunched(let endpoint):
                finalEndpoint = endpoint
                connectionMethod = .holePunched(endpoint: endpoint)

            case .direct(let endpoint):
                finalEndpoint = endpoint
                connectionMethod = .direct(endpoint: endpoint)
            }
        } else if let direct = directEndpoint {
            finalEndpoint = direct
            connectionMethod = .direct(endpoint: direct)
        } else {
            finalEndpoint = vpnConfig.consumerEndpoint
            connectionMethod = .direct(endpoint: vpnConfig.consumerEndpoint)
        }

        logger.info("P2P VPN created", metadata: [
            "jobId": "\(jobId)",
            "method": "\(connectionMethod)",
            "endpoint": "\(finalEndpoint)"
        ])

        return P2PVPNConfiguration(
            baseConfig: vpnConfig,
            connectionMethod: connectionMethod,
            actualEndpoint: finalEndpoint,
            natType: connectionResult?.natType ?? .unknown
        )
    }

    /// Add provider peer to VPN
    public func addProviderPeer(
        jobId: UUID,
        providerPublicKey: String
    ) async throws {
        try await ephemeralVPN.addProviderPeer(
            jobId: jobId,
            providerPublicKey: providerPublicKey
        )
    }

    /// Destroy VPN and cleanup relay proxies
    public func destroyP2PVPN(for jobId: UUID) async throws {
        // Stop relay proxy if exists
        if let proxy = activeRelayProxies.removeValue(forKey: jobId) {
            await proxy.stop()
            logger.info("Relay proxy stopped", metadata: ["jobId": "\(jobId)"])
        }

        // Destroy base VPN
        try await ephemeralVPN.destroyVPN(for: jobId)

        logger.info("P2P VPN destroyed", metadata: ["jobId": "\(jobId)"])
    }

    /// Check if VPN client is connected
    public func isClientConnected(for jobId: UUID) async throws -> Bool {
        try await ephemeralVPN.isClientConnected(for: jobId)
    }

    /// Get P2P session endpoint
    public var publicEndpoint: PublicEndpoint? {
        get async {
            await p2pSession?.endpoint
        }
    }

    /// Get NAT type
    public var natType: NATType {
        get async {
            await p2pSession?.natType ?? .unknown
        }
    }

    // MARK: - Private

    private func setupRelayProxy(
        jobId: UUID,
        relayEndpoint: String,
        targetPeerId: String
    ) async throws -> WireGuardRelayProxy {
        // Generate session token from job ID
        let tokenData = withUnsafeBytes(of: jobId.uuid) { Data($0) }

        let proxy = WireGuardRelayProxy(
            relayEndpoint: relayEndpoint,
            sessionToken: tokenData,
            peerEndpoint: targetPeerId
        )

        _ = try await proxy.start()
        activeRelayProxies[jobId] = proxy

        logger.info("Relay proxy started", metadata: [
            "jobId": "\(jobId)",
            "relay": "\(relayEndpoint)"
        ])

        return proxy
    }
}

// MARK: - P2P VPN Configuration

/// VPN configuration with P2P connection details
public struct P2PVPNConfiguration: Sendable {
    /// Base VPN configuration
    public let baseConfig: VPNConfiguration

    /// Method used to establish connection
    public let connectionMethod: P2PConnectionMethod

    /// Actual endpoint to use (may differ from base config if relayed)
    public let actualEndpoint: String

    /// NAT type of local endpoint
    public let natType: NATType

    public init(
        baseConfig: VPNConfiguration,
        connectionMethod: P2PConnectionMethod,
        actualEndpoint: String,
        natType: NATType
    ) {
        self.baseConfig = baseConfig
        self.connectionMethod = connectionMethod
        self.actualEndpoint = actualEndpoint
        self.natType = natType
    }

    /// Consumer's public key
    public var consumerPublicKey: String {
        baseConfig.consumerPublicKey
    }

    /// Consumer's endpoint (may be hole-punched or relayed)
    public var consumerEndpoint: String {
        actualEndpoint
    }

    /// Consumer's VPN IP
    public var consumerVPNIP: String {
        baseConfig.consumerVPNIP
    }

    /// VM's VPN IP
    public var vmVPNIP: String {
        baseConfig.vmVPNIP
    }

    /// VPN subnet
    public var vpnSubnet: String {
        baseConfig.vpnSubnet
    }

    /// Whether connection is relayed
    public var isRelayed: Bool {
        connectionMethod.isRelayed
    }
}

// MARK: - P2P Consumer Extension

/// Extension for ConsumerClient-like functionality with P2P support
public extension P2PVPNManager {
    /// Quick setup for consumer with P2P support
    func setupConsumer(
        peerId: String,
        networkId: String,
        publicKey: String,
        rendezvousURL: URL?
    ) async throws -> PublicEndpoint {
        let config = P2PSessionConfig(
            peerId: peerId,
            networkId: networkId,
            publicKey: publicKey,
            rendezvousURL: rendezvousURL,
            enableNATTraversal: rendezvousURL != nil
        )
        return try await startP2PSession(config: config)
    }

    /// Quick setup for consumer with defaults
    func setupConsumerWithDefaults(
        peerId: String,
        networkId: String,
        publicKey: String,
        rendezvousHost: String = "localhost",
        rendezvousPort: Int = 8080
    ) async throws -> PublicEndpoint {
        let url = URL(string: "ws://\(rendezvousHost):\(rendezvousPort)")!
        return try await setupConsumer(
            peerId: peerId,
            networkId: networkId,
            publicKey: publicKey,
            rendezvousURL: url
        )
    }
}
