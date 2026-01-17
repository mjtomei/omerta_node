// PeerStore.swift - Peer persistence across restarts

import Foundation
import Logging
import OmertaCore

/// Persists peer announcements to disk for recovery after restart
public actor PeerStore {
    private let storePath: URL
    private let logger: Logger
    private let maxStoredPeers: Int

    /// Stored peer with metadata
    private struct StoredPeer: Codable {
        let announcement: PeerAnnouncement
        let lastSeenAt: Date
        let successfulContacts: Int
        let failedContacts: Int

        var reliability: Double {
            let total = successfulContacts + failedContacts
            guard total > 0 else { return 0.5 }
            return Double(successfulContacts) / Double(total)
        }
    }

    private var peers: [PeerId: StoredPeer] = [:]

    public init(storePath: URL, maxStoredPeers: Int = 500) {
        self.storePath = storePath
        self.maxStoredPeers = maxStoredPeers
        self.logger = Logger(label: "io.omerta.mesh.peerstore")
    }

    // MARK: - Public API

    /// Load peers from disk
    public func load() async throws {
        guard FileManager.default.fileExists(atPath: storePath.path) else {
            logger.info("No peer store found at \(storePath.path)")
            return
        }

        let data = try Data(contentsOf: storePath)
        let stored = try JSONDecoder().decode([PeerId: StoredPeer].self, from: data)
        peers = stored

        // Remove expired peers
        let validPeers = peers.filter { !$0.value.announcement.isExpired }
        peers = validPeers

        logger.info("Loaded \(peers.count) peers from store")
    }

    /// Save peers to disk
    public func save() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(peers)

        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: storePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.write(to: storePath)
        logger.debug("Saved \(peers.count) peers to store")
    }

    /// Update or insert a peer
    public func update(_ announcement: PeerAnnouncement, contactSuccessful: Bool = true) {
        let peerId = announcement.peerId

        if var existing = peers[peerId] {
            // Update existing
            if contactSuccessful {
                existing = StoredPeer(
                    announcement: announcement,
                    lastSeenAt: Date(),
                    successfulContacts: existing.successfulContacts + 1,
                    failedContacts: existing.failedContacts
                )
            } else {
                existing = StoredPeer(
                    announcement: existing.announcement,
                    lastSeenAt: existing.lastSeenAt,
                    successfulContacts: existing.successfulContacts,
                    failedContacts: existing.failedContacts + 1
                )
            }
            peers[peerId] = existing
        } else {
            // Insert new
            peers[peerId] = StoredPeer(
                announcement: announcement,
                lastSeenAt: Date(),
                successfulContacts: contactSuccessful ? 1 : 0,
                failedContacts: contactSuccessful ? 0 : 1
            )
        }

        // Evict if over capacity
        evictIfNeeded()
    }

    /// Mark a peer contact as failed
    public func markFailed(_ peerId: PeerId) {
        guard var existing = peers[peerId] else { return }
        existing = StoredPeer(
            announcement: existing.announcement,
            lastSeenAt: existing.lastSeenAt,
            successfulContacts: existing.successfulContacts,
            failedContacts: existing.failedContacts + 1
        )
        peers[peerId] = existing
    }

    /// Get all stored peers, sorted by reliability
    public func allPeers() -> [PeerAnnouncement] {
        peers.values
            .filter { !$0.announcement.isExpired }
            .sorted { $0.reliability > $1.reliability }
            .map { $0.announcement }
    }

    /// Get peers with specific capability
    public func peers(withCapability capability: String) -> [PeerAnnouncement] {
        allPeers().filter { $0.capabilities.contains(capability) }
    }

    /// Get relay-capable peers
    public var relayPeers: [PeerAnnouncement] {
        peers(withCapability: "relay")
    }

    /// Remove a peer
    public func remove(_ peerId: PeerId) {
        peers.removeValue(forKey: peerId)
    }

    /// Number of stored peers
    public var count: Int {
        peers.count
    }

    // MARK: - Private Methods

    private func evictIfNeeded() {
        guard peers.count > maxStoredPeers else { return }

        // Sort by reliability and last seen
        let sorted = peers.sorted { a, b in
            // Prioritize reliability
            if abs(a.value.reliability - b.value.reliability) > 0.1 {
                return a.value.reliability > b.value.reliability
            }
            // Then by last seen
            return a.value.lastSeenAt > b.value.lastSeenAt
        }

        // Keep only top peers
        peers = [:]
        for (key, value) in sorted.prefix(maxStoredPeers) {
            peers[key] = value
        }
    }
}

// MARK: - Convenience Factory

extension PeerStore {
    /// Create a peer store in the default location
    /// Uses getRealUserHome() to handle sudo correctly
    public static func defaultStore() -> PeerStore {
        let homeDir = OmertaConfig.getRealUserHome()
        #if os(macOS)
        let storePath = URL(fileURLWithPath: homeDir)
            .appendingPathComponent("Library/Application Support/OmertaMesh/peers.json")
        #else
        let storePath = URL(fileURLWithPath: homeDir)
            .appendingPathComponent(".local/share/OmertaMesh/peers.json")
        #endif

        return PeerStore(storePath: storePath)
    }
}

