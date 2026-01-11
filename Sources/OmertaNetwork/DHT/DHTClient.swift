import Foundation
import OmertaCore
import Logging

/// High-level client for peer discovery via DHT
public actor DHTClient {
    private let node: DHTNode
    private let identity: IdentityKeypair
    private let logger: Logger

    /// Current announcement (if any)
    private var currentAnnouncement: DHTPeerAnnouncement?

    /// Re-announcement interval
    private let reannounceInterval: TimeInterval

    /// Task for periodic re-announcement
    private var reannounceTask: Task<Void, Never>?

    public init(
        identity: IdentityKeypair,
        config: DHTConfig = .default,
        reannounceInterval: TimeInterval = 1800 // 30 minutes
    ) {
        self.identity = identity
        self.node = DHTNode(identity: identity, config: config)
        self.logger = Logger(label: "io.omerta.dht.client")
        self.reannounceInterval = reannounceInterval
    }

    /// Start the DHT client
    public func start() async throws {
        try await node.start()
        logger.info("DHT client started")
    }

    /// Stop the DHT client
    public func stop() async {
        reannounceTask?.cancel()
        reannounceTask = nil
        await node.stop()
        logger.info("DHT client stopped")
    }

    /// Announce as a provider
    public func announceAsProvider(
        signalingAddress: String,
        capabilities: [String] = [DHTPeerAnnouncement.capabilityProvider],
        ttl: TimeInterval = 3600
    ) async throws {
        let announcement = DHTPeerAnnouncement(
            identity: identity.identity,
            capabilities: capabilities,
            signalingAddresses: [signalingAddress],
            ttl: ttl
        )

        let signed = try announcement.signed(with: identity)
        try await node.announce(signed)

        currentAnnouncement = signed
        logger.info("Announced as provider at \(signalingAddress)")

        // Start periodic re-announcement
        startReannouncement()
    }

    /// Announce as a relay
    public func announceAsRelay(
        signalingAddress: String,
        relayAddress: String,
        ttl: TimeInterval = 3600
    ) async throws {
        let announcement = DHTPeerAnnouncement(
            identity: identity.identity,
            capabilities: [DHTPeerAnnouncement.capabilityRelay],
            signalingAddresses: [signalingAddress, relayAddress],
            ttl: ttl
        )

        let signed = try announcement.signed(with: identity)
        try await node.announce(signed)

        currentAnnouncement = signed
        logger.info("Announced as relay at \(relayAddress)")

        startReannouncement()
    }

    /// Look up a specific peer
    public func lookupPeer(_ peerId: String) async throws -> DHTPeerAnnouncement? {
        guard let announcement = try await node.findPeer(peerId) else {
            return nil
        }

        // Verify signature and peerId matches publicKey
        guard announcement.verify() else {
            throw DHTError.invalidAnnouncement
        }

        return announcement
    }

    /// Find available providers
    public func findProviders(count: Int = 10) async throws -> [DHTPeerAnnouncement] {
        // Search near our own ID to find nearby providers
        try await node.findProviders(near: identity.identity.peerId, count: count)
    }

    /// Find providers near a specific peer ID
    public func findProviders(near peerId: String, count: Int = 10) async throws -> [DHTPeerAnnouncement] {
        try await node.findProviders(near: peerId, count: count)
    }

    /// Find relay nodes
    public func findRelays(count: Int = 5) async throws -> [DHTPeerAnnouncement] {
        let providers = try await node.findProviders(near: identity.identity.peerId, count: count * 2)
        return providers.filter { $0.capabilities.contains(DHTPeerAnnouncement.capabilityRelay) }.prefix(count).map { $0 }
    }

    /// Get the number of known nodes
    public var knownNodeCount: Int {
        get async { await node.nodeCount }
    }

    /// Get the node's peer ID
    public var peerId: String {
        identity.identity.peerId
    }

    // MARK: - Private Methods

    private func startReannouncement() {
        reannounceTask?.cancel()
        reannounceTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(reannounceInterval * 1_000_000_000))

                    if let announcement = currentAnnouncement {
                        // Create a fresh announcement with updated timestamp
                        let refreshed = DHTPeerAnnouncement(
                            peerId: announcement.peerId,
                            publicKey: announcement.publicKey,
                            capabilities: announcement.capabilities,
                            signalingAddresses: announcement.signalingAddresses,
                            timestamp: Date(),
                            ttl: announcement.ttl
                        )
                        let signed = try refreshed.signed(with: identity)
                        try await node.announce(signed)
                        currentAnnouncement = signed
                        logger.debug("Re-announced peer")
                    }
                } catch {
                    if !Task.isCancelled {
                        logger.warning("Re-announcement failed: \(error)")
                    }
                }
            }
        }
    }
}

/// Convenience methods for common operations
public extension DHTClient {
    /// Check if a peer is online (has a valid, non-expired announcement)
    func isPeerOnline(_ peerId: String) async -> Bool {
        do {
            if let announcement = try await lookupPeer(peerId) {
                return !announcement.isExpired
            }
        } catch {
            // Lookup failed
        }
        return false
    }

    /// Get the signaling address for a peer
    func getSignalingAddress(for peerId: String) async throws -> String? {
        guard let announcement = try await lookupPeer(peerId) else {
            return nil
        }
        return announcement.signalingAddresses.first
    }

    /// Get all signaling addresses for a peer
    func getSignalingAddresses(for peerId: String) async throws -> [String] {
        guard let announcement = try await lookupPeer(peerId) else {
            return []
        }
        return announcement.signalingAddresses
    }
}
