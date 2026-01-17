// PeerEndpointManager.swift - Multi-endpoint tracking by (peerId, machineId)

import Foundation
import Logging
import OmertaCore

/// Endpoints tracked for a specific machine
public struct MachineEndpoints: Codable, Sendable {
    public let peerId: PeerId
    public let machineId: MachineId
    public var endpoints: [String]       // Ordered list - front is best
    public var lastActivity: Date

    public init(peerId: PeerId, machineId: MachineId, endpoints: [String] = [], lastActivity: Date = Date()) {
        self.peerId = peerId
        self.machineId = machineId
        self.endpoints = endpoints
        self.lastActivity = lastActivity
    }

    public var bestEndpoint: String? { endpoints.first }

    public var isStale: Bool {
        Date().timeIntervalSince(lastActivity) > 86400  // 24 hours
    }

    /// Move endpoint to front (on receive or send success)
    public mutating func promoteEndpoint(_ endpoint: String) {
        endpoints.removeAll { $0 == endpoint }
        endpoints.insert(endpoint, at: 0)
        lastActivity = Date()
    }
}

/// Persistence format for peer endpoints
private struct PeerEndpointsFile: Codable {
    let version: Int
    let savedAt: Date
    let machines: [String: MachineEndpoints]  // key = "peerId:machineId"

    static let currentVersion = 2
}

/// Manages endpoint tracking for peers by (peerId, machineId)
public actor PeerEndpointManager {
    private var machines: [String: MachineEndpoints] = [:]  // key = "peerId:machineId"
    private var isDirty = false
    private var cleanupTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private let logger: Logger
    private let maxEndpointsPerMachine = 1000

    /// Storage path for peer endpoints
    private let storagePath: URL

    public init(storagePath: URL? = nil, logger: Logger? = nil) {
        self.storagePath = storagePath ?? URL(fileURLWithPath: OmertaConfig.getRealUserHome())
            .appendingPathComponent(".omerta/mesh/peer_endpoints.json")
        self.logger = logger ?? Logger(label: "omerta.mesh.endpoints")
    }

    /// Start background tasks for cleanup and persistence
    public func start() async {
        // Load from disk
        do {
            try await load()
        } catch {
            logger.warning("Failed to load peer endpoints: \(error)")
        }

        // Start hourly cleanup task
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                await cleanup()
            }
        }

        // Start periodic save task (every 5 minutes if dirty)
        saveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if isDirty {
                    do {
                        try await save()
                    } catch {
                        logger.warning("Failed to save peer endpoints: \(error)")
                    }
                }
            }
        }
    }

    /// Stop background tasks and save
    public func stop() async {
        cleanupTask?.cancel()
        saveTask?.cancel()

        if isDirty {
            try? await save()
        }
    }

    // MARK: - Recording

    /// Record that we received a message from this endpoint
    /// Moves the endpoint to front of the list (highest priority)
    public func recordMessageReceived(from peerId: PeerId, machineId: MachineId, endpoint: String) {
        let key = makeKey(peerId: peerId, machineId: machineId)

        if var machine = machines[key] {
            machine.promoteEndpoint(endpoint)
            // Trim to max endpoints
            if machine.endpoints.count > maxEndpointsPerMachine {
                machine.endpoints = Array(machine.endpoints.prefix(maxEndpointsPerMachine))
            }
            machines[key] = machine
        } else {
            machines[key] = MachineEndpoints(
                peerId: peerId,
                machineId: machineId,
                endpoints: [endpoint],
                lastActivity: Date()
            )
        }

        isDirty = true
    }

    /// Record that we successfully sent to this endpoint
    /// Moves the endpoint to front of the list (highest priority)
    public func recordSendSuccess(to peerId: PeerId, machineId: MachineId, endpoint: String) {
        let key = makeKey(peerId: peerId, machineId: machineId)

        if var machine = machines[key] {
            machine.promoteEndpoint(endpoint)
            machines[key] = machine
            isDirty = true
        }
    }

    // MARK: - Queries

    /// Get endpoints for a specific machine, ordered by priority (best first)
    public func getEndpoints(peerId: PeerId, machineId: MachineId) -> [String] {
        let key = makeKey(peerId: peerId, machineId: machineId)
        return machines[key]?.endpoints ?? []
    }

    /// Get the best endpoint for a specific machine
    public func getBestEndpoint(peerId: PeerId, machineId: MachineId) -> String? {
        let key = makeKey(peerId: peerId, machineId: machineId)
        return machines[key]?.bestEndpoint
    }

    /// Get all endpoints for all machines with this peerId (for broadcast)
    public func getAllEndpoints(peerId: PeerId) -> [String] {
        var endpoints: [String] = []
        for (key, machine) in machines {
            if key.hasPrefix("\(peerId):") {
                endpoints.append(contentsOf: machine.endpoints)
            }
        }
        // Deduplicate while preserving order
        var seen = Set<String>()
        return endpoints.filter { seen.insert($0).inserted }
    }

    /// Get all machines with this peerId
    public func getAllMachines(peerId: PeerId) -> [MachineEndpoints] {
        machines.values.filter { $0.peerId == peerId }
    }

    /// Get all known peer IDs
    public var allPeerIds: [PeerId] {
        Array(Set(machines.values.map { $0.peerId }))
    }

    /// Check if we have any endpoints for a peer
    public func hasEndpoints(for peerId: PeerId) -> Bool {
        machines.values.contains { $0.peerId == peerId && !$0.endpoints.isEmpty }
    }

    // MARK: - Persistence

    /// Load peer endpoints from disk
    public func load() async throws {
        guard FileManager.default.fileExists(atPath: storagePath.path) else {
            return
        }

        let data = try Data(contentsOf: storagePath)
        let file = try JSONDecoder().decode(PeerEndpointsFile.self, from: data)

        // Handle version migration if needed
        if file.version == PeerEndpointsFile.currentVersion {
            machines = file.machines
            logger.info("Loaded \(machines.count) machine endpoint records")
        } else {
            logger.warning("Unknown peer endpoints file version \(file.version), starting fresh")
        }
    }

    /// Save peer endpoints to disk
    public func save() async throws {
        let file = PeerEndpointsFile(
            version: PeerEndpointsFile.currentVersion,
            savedAt: Date(),
            machines: machines
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)

        // Ensure directory exists
        let dir = storagePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try data.write(to: storagePath)
        isDirty = false

        logger.debug("Saved \(machines.count) machine endpoint records")
    }

    // MARK: - Cleanup

    /// Remove stale endpoints (not seen in 24 hours)
    private func cleanup() {
        let staleKeys = machines.filter { $0.value.isStale }.map { $0.key }

        if !staleKeys.isEmpty {
            for key in staleKeys {
                machines.removeValue(forKey: key)
            }
            isDirty = true
            logger.info("Removed \(staleKeys.count) stale machine endpoint records")
        }
    }

    // MARK: - Helpers

    private func makeKey(peerId: PeerId, machineId: MachineId) -> String {
        "\(peerId):\(machineId)"
    }
}
