// NetworkStore.swift - Network membership persistence

import Foundation
import Logging

/// Persists network memberships to disk for recovery after restart
public actor NetworkStore {
    private let storePath: URL
    private let logger: Logger
    private var networks: [String: Network] = [:]  // networkId -> Network

    public init(storePath: URL) {
        self.storePath = storePath
        self.logger = Logger(label: "io.omerta.mesh.networkstore")
    }

    // MARK: - Network Management

    /// Join a network using a NetworkKey
    public func join(_ key: NetworkKey, name: String? = nil) throws -> Network {
        let networkId = key.deriveNetworkId()

        // Check if already joined
        if networks[networkId] != nil {
            logger.warning("Already joined network: \(networkId)")
            throw NetworkStoreError.alreadyJoined
        }

        // Create network membership
        let network = Network(key: key, name: name)
        networks[networkId] = network

        logger.info("Joined network: \(network.name) (\(networkId))")

        // Save to disk
        Task {
            try? await save()
        }

        return network
    }

    /// Leave a network
    public func leave(_ networkId: String) throws {
        guard networks.removeValue(forKey: networkId) != nil else {
            throw NetworkStoreError.notFound
        }

        logger.info("Left network: \(networkId)")

        // Save to disk
        Task {
            try? await save()
        }
    }

    /// Get all joined networks
    public func allNetworks() -> [Network] {
        Array(networks.values)
    }

    /// Get a specific network by ID
    public func network(id: String) -> Network? {
        networks[id]
    }

    /// Get active networks only
    public func activeNetworks() -> [Network] {
        networks.values.filter { $0.isActive }
    }

    /// Set network active/inactive
    public func setActive(_ networkId: String, active: Bool) throws {
        guard var network = networks[networkId] else {
            throw NetworkStoreError.notFound
        }

        network.isActive = active
        networks[networkId] = network

        logger.info("Network \(networkId) \(active ? "activated" : "deactivated")")

        Task {
            try? await save()
        }
    }

    /// Check if a network exists
    public func contains(_ networkId: String) -> Bool {
        networks[networkId] != nil
    }

    /// Number of joined networks
    public var count: Int {
        networks.count
    }

    // MARK: - Persistence

    /// Load networks from disk
    public func load() async throws {
        guard FileManager.default.fileExists(atPath: storePath.path) else {
            logger.info("No network store found at \(storePath.path)")
            return
        }

        let data = try Data(contentsOf: storePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode([String: Network].self, from: data)
        networks = stored

        logger.info("Loaded \(networks.count) networks from store")
    }

    /// Save networks to disk
    public func save() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(networks)

        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: storePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.write(to: storePath)
        logger.debug("Saved \(networks.count) networks to store")
    }
}

// MARK: - Convenience Factory

extension NetworkStore {
    /// Create a network store in the default location
    public static func defaultStore() -> NetworkStore {
        let documentsPath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: "/tmp")

        let storePath = documentsPath
            .appendingPathComponent("OmertaMesh")
            .appendingPathComponent("networks.json")

        return NetworkStore(storePath: storePath)
    }
}

// MARK: - Errors

public enum NetworkStoreError: Error, LocalizedError {
    case alreadyJoined
    case notFound
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyJoined:
            return "Already joined this network"
        case .notFound:
            return "Network not found"
        case .persistenceFailed(let details):
            return "Failed to save/load networks: \(details)"
        }
    }
}
