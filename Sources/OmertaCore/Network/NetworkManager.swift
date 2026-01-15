import Foundation
import Logging

/// Manages multiple network memberships and network-scoped operations
public actor NetworkManager {

    // MARK: - State

    private var networks: [String: Network] = [:]  // Network ID -> Network
    private var networkConfigs: [String: NetworkConfiguration] = [:]  // Network ID -> Config
    private let logger: Logger
    private let configPath: String

    // MARK: - Configuration

    public struct NetworkConfiguration: Sendable {
        public let network: Network
        public var isEnabled: Bool
        public var autoReconnect: Bool
        public var lastSeen: Date

        public init(
            network: Network,
            isEnabled: Bool = true,
            autoReconnect: Bool = true,
            lastSeen: Date = Date()
        ) {
            self.network = network
            self.isEnabled = isEnabled
            self.autoReconnect = autoReconnect
            self.lastSeen = lastSeen
        }
    }

    // MARK: - Initialization

    public init(configPath: String? = nil) {
        var logger = Logger(label: "com.omerta.network.manager")
        logger.logLevel = .info
        self.logger = logger

        // Default config path: ~/Library/Application Support/Omerta/networks.json
        if let path = configPath {
            self.configPath = path
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let supportDir = homeDir
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("Omerta")
            self.configPath = supportDir
                .appendingPathComponent("networks.json")
                .path
        }
    }

    // MARK: - Network Management

    /// Join a new network using a network key
    public func joinNetwork(key: NetworkKey, name: String? = nil) throws -> String {
        let networkId = key.deriveNetworkId()

        // Check if already joined
        if networks[networkId] != nil {
            logger.warning("Already joined network: \(networkId)")
            throw NetworkError.alreadyJoined
        }

        // Create network membership
        let network = Network(
            id: networkId,
            name: name ?? key.networkName,
            key: key,
            joinedAt: Date(),
            isActive: true
        )

        let config = NetworkConfiguration(
            network: network,
            isEnabled: true,
            autoReconnect: true,
            lastSeen: Date()
        )

        networks[networkId] = network
        networkConfigs[networkId] = config

        logger.info("Joined network: \(network.name) (\(networkId))")

        // Save to disk
        Task {
            await saveNetworks()
        }

        return networkId
    }

    /// Leave a network
    public func leaveNetwork(networkId: String) throws {
        guard networks.removeValue(forKey: networkId) != nil else {
            throw NetworkError.notFound
        }

        networkConfigs.removeValue(forKey: networkId)

        logger.info("Left network: \(networkId)")

        // Save to disk
        Task {
            await saveNetworks()
        }
    }

    /// Get all joined networks
    public func getNetworks() -> [Network] {
        Array(networks.values)
    }

    /// Get a specific network by ID
    public func getNetwork(id: String) -> Network? {
        networks[id]
    }

    /// Enable or disable a network
    public func setNetworkEnabled(_ networkId: String, enabled: Bool) throws {
        guard var config = networkConfigs[networkId] else {
            throw NetworkError.notFound
        }

        config.isEnabled = enabled
        networkConfigs[networkId] = config

        logger.info("Network \(networkId) \(enabled ? "enabled" : "disabled")")

        Task {
            await saveNetworks()
        }
    }

    /// Get enabled networks only
    public func getEnabledNetworks() -> [Network] {
        networks.values.filter { network in
            networkConfigs[network.id]?.isEnabled ?? false
        }
    }

    /// Check if a network is enabled
    public func isNetworkEnabled(_ networkId: String) -> Bool {
        networkConfigs[networkId]?.isEnabled ?? false
    }

    /// Update last seen timestamp for a network
    public func updateLastSeen(networkId: String) {
        guard var config = networkConfigs[networkId] else { return }
        config.lastSeen = Date()
        networkConfigs[networkId] = config
    }

    // MARK: - Network Creation

    /// Create a new network and return the shareable key
    public func createNetwork(
        name: String,
        bootstrapEndpoint: String
    ) -> NetworkKey {
        logger.info("Creating new network: \(name)")

        let key = NetworkKey.generate(
            networkName: name,
            bootstrapEndpoint: bootstrapEndpoint
        )

        // Automatically join the network we created
        let networkId = key.deriveNetworkId()
        let network = Network(
            id: networkId,
            name: name,
            key: key,
            joinedAt: Date(),
            isActive: true
        )

        let config = NetworkConfiguration(
            network: network,
            isEnabled: true,
            autoReconnect: true,
            lastSeen: Date()
        )

        networks[networkId] = network
        networkConfigs[networkId] = config

        logger.info("Created and joined network: \(name) (\(networkId))")

        Task {
            await saveNetworks()
        }

        return key
    }

    // MARK: - Persistence

    /// Load networks from disk
    public func loadNetworks() async throws {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: configPath)

        guard fileManager.fileExists(atPath: configPath) else {
            logger.info("No saved networks found")
            return
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let savedNetworks = try decoder.decode([SavedNetwork].self, from: data)

        for saved in savedNetworks {
            networks[saved.id] = saved.toNetwork()
            networkConfigs[saved.id] = NetworkConfiguration(
                network: saved.toNetwork(),
                isEnabled: saved.isEnabled,
                autoReconnect: saved.autoReconnect,
                lastSeen: saved.lastSeen
            )
        }

        logger.info("Loaded \(networks.count) networks from disk")
    }

    /// Save networks to disk
    private func saveNetworks() async {
        do {
            let savedNetworks = networks.values.map { network -> SavedNetwork in
                let config = networkConfigs[network.id]!
                return SavedNetwork(
                    id: network.id,
                    name: network.name,
                    key: network.key,
                    joinedAt: network.joinedAt,
                    isActive: network.isActive,
                    isEnabled: config.isEnabled,
                    autoReconnect: config.autoReconnect,
                    lastSeen: config.lastSeen
                )
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(savedNetworks)

            // Ensure directory exists
            let url = URL(fileURLWithPath: configPath)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            try data.write(to: url)

            logger.debug("Saved \(savedNetworks.count) networks to disk")

        } catch {
            logger.error("Failed to save networks: \(error)")
        }
    }

    // MARK: - Statistics

    /// Get statistics for all networks
    public func getNetworkStatistics() -> [String: NetworkStats] {
        var stats: [String: NetworkStats] = [:]

        for (id, network) in networks {
            // Placeholder stats - would be updated from actual network activity
            stats[id] = NetworkStats(
                networkId: id,
                peerCount: 0,  // TODO: Get from peer registry
                jobsSubmitted: 0,  // TODO: Track from submissions
                jobsCompleted: 0,  // TODO: Track from completions
                averageLatencyMs: 0.0  // TODO: Calculate from metrics
            )
        }

        return stats
    }
}

// MARK: - Persistence Types

private struct SavedNetwork: Codable {
    let id: String
    let name: String
    let key: NetworkKey
    let joinedAt: Date
    let isActive: Bool
    let isEnabled: Bool
    let autoReconnect: Bool
    let lastSeen: Date

    func toNetwork() -> Network {
        Network(
            id: id,
            name: name,
            key: key,
            joinedAt: joinedAt,
            isActive: isActive
        )
    }
}

// MARK: - Errors

public enum NetworkError: Error, CustomStringConvertible {
    case alreadyJoined
    case notFound
    case invalidKey
    case persistenceFailed(String)

    public var description: String {
        switch self {
        case .alreadyJoined:
            return "Already joined this network"
        case .notFound:
            return "Network not found"
        case .invalidKey:
            return "Invalid network key"
        case .persistenceFailed(let details):
            return "Failed to save/load networks: \(details)"
        }
    }
}
