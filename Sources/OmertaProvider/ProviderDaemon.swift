import Foundation
import Logging
import OmertaCore
import OmertaVM
import OmertaNetwork

/// The main provider daemon that manages VM lifecycle
/// Handles incoming VM requests via UDP control protocol
public actor ProviderDaemon {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let controlPort: UInt16
        public let networkKeys: [String: Data]  // networkId -> encryption key
        public let ownerPeerId: String?
        public let trustedNetworks: [String]
        public let enableActivityLogging: Bool
        public let dryRun: Bool

        public init(
            controlPort: UInt16 = 51820,
            networkKeys: [String: Data],
            ownerPeerId: String? = nil,
            trustedNetworks: [String] = [],
            enableActivityLogging: Bool = true,
            dryRun: Bool = false
        ) {
            self.controlPort = controlPort
            self.networkKeys = networkKeys
            self.ownerPeerId = ownerPeerId
            self.trustedNetworks = trustedNetworks
            self.enableActivityLogging = enableActivityLogging
            self.dryRun = dryRun
        }

        /// Convenience initializer for single network key (backward compatibility)
        public init(
            controlPort: UInt16 = 51820,
            networkKey: Data,
            networkId: String = "default",
            ownerPeerId: String? = nil,
            trustedNetworks: [String] = [],
            enableActivityLogging: Bool = true,
            dryRun: Bool = false
        ) {
            self.controlPort = controlPort
            self.networkKeys = [networkId: networkKey]
            self.ownerPeerId = ownerPeerId
            self.trustedNetworks = trustedNetworks
            self.enableActivityLogging = enableActivityLogging
            self.dryRun = dryRun
        }
    }

    // MARK: - State

    private let config: Configuration
    private let logger: Logger

    private let udpControlServer: UDPControlServer
    private let filterManager: FilterManager
    private let activityLogger: VMActivityLogger?

    private var isRunning: Bool = false
    private var startedAt: Date?

    // Statistics
    private var totalVMRequestsReceived: Int = 0
    private var totalVMRequestsFiltered: Int = 0

    // MARK: - Initialization

    public init(config: Configuration) {
        self.config = config

        // Set up logging
        var logger = Logger(label: "com.omerta.provider")
        logger.logLevel = .info
        self.logger = logger

        // Initialize components
        self.udpControlServer = UDPControlServer(
            networkKeys: config.networkKeys,
            port: config.controlPort,
            dryRun: config.dryRun
        )
        self.filterManager = FilterManager(
            ownerPeerId: config.ownerPeerId,
            trustedNetworks: config.trustedNetworks
        )

        // Set up activity logger if enabled
        if config.enableActivityLogging {
            self.activityLogger = VMActivityLogger(logger: logger)
        } else {
            self.activityLogger = nil
        }
    }

    // MARK: - Lifecycle

    /// Start the provider daemon
    public func start() async throws {
        guard !isRunning else {
            logger.warning("Provider daemon already running")
            return
        }

        logger.info("Starting Omerta Provider Daemon")
        logger.info("Control port: \(config.controlPort)")

        // Start UDP control server
        try await udpControlServer.start()

        // Add default filter rules
        await addDefaultFilterRules()

        isRunning = true
        startedAt = Date()

        logger.info("Provider daemon started successfully")
        logger.info("Ready to accept VM requests")
    }

    /// Stop the provider daemon
    public func stop() async throws {
        guard isRunning else {
            logger.warning("Provider daemon not running")
            return
        }

        logger.info("Stopping Omerta Provider Daemon")

        // Stop UDP control server
        await udpControlServer.stop()

        isRunning = false
        startedAt = nil

        logger.info("Provider daemon stopped")
    }

    /// Get daemon status
    public func getStatus() async -> DaemonStatus {
        let serverStatus = await udpControlServer.getStatus()
        let filterStats = await filterManager.getStatistics()

        return DaemonStatus(
            isRunning: isRunning,
            startedAt: startedAt,
            controlPort: config.controlPort,
            activeVMs: serverStatus.activeVMs,
            filterStats: filterStats,
            totalVMRequestsReceived: totalVMRequestsReceived,
            totalVMRequestsFiltered: totalVMRequestsFiltered
        )
    }

    // MARK: - Private: Filter Rules

    private func addDefaultFilterRules() async {
        // Add resource limit rule
        let resourceRule = ResourceLimitRule(
            maxCpuCores: 8,
            maxMemoryMB: 16384,
            maxStorageMB: 102400
        )
        await filterManager.addRule(resourceRule)

        // Add quiet hours rule (10 PM - 8 AM)
        let quietHoursRule = QuietHoursRule(
            startHour: 22,
            endHour: 8,
            action: .requireApproval
        )
        await filterManager.addRule(quietHoursRule)

        logger.info("Added default filter rules")
    }

    // MARK: - Configuration Management

    /// Add a network with its encryption key
    public func addNetwork(_ networkId: String, key: Data) async {
        await udpControlServer.addNetworkKey(networkId, key: key)
        await filterManager.addTrustedNetwork(networkId)
        logger.info("Added network: \(networkId)")
    }

    /// Remove a network and its key
    public func removeNetwork(_ networkId: String) async {
        await udpControlServer.removeNetworkKey(networkId)
        await filterManager.removeTrustedNetwork(networkId)
        logger.info("Removed network: \(networkId)")
    }

    /// Add a trusted network (for filtering only, must already have key)
    public func addTrustedNetwork(_ networkId: String) async {
        await filterManager.addTrustedNetwork(networkId)
        logger.info("Added trusted network: \(networkId)")
    }

    /// Remove a trusted network
    public func removeTrustedNetwork(_ networkId: String) async {
        await filterManager.removeTrustedNetwork(networkId)
        logger.info("Removed trusted network: \(networkId)")
    }

    /// Block a peer
    public func blockPeer(_ peerId: String) async {
        await filterManager.blockPeer(peerId)
        logger.info("Blocked peer: \(peerId)")
    }

    /// Unblock a peer
    public func unblockPeer(_ peerId: String) async {
        await filterManager.unblockPeer(peerId)
        logger.info("Unblocked peer: \(peerId)")
    }
}

// MARK: - Supporting Types

/// Provider daemon status
public struct DaemonStatus: Sendable {
    public let isRunning: Bool
    public let startedAt: Date?
    public let controlPort: UInt16
    public let activeVMs: Int
    public let filterStats: FilterStatistics
    public let totalVMRequestsReceived: Int
    public let totalVMRequestsFiltered: Int

    public var uptime: TimeInterval? {
        guard let startedAt = startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }
}

// MARK: - VM Activity Logger

/// Logs VM activities for audit trail
public actor VMActivityLogger {
    private let logger: Logger
    private var logEntries: [VMActivityLogEntry] = []

    init(logger: Logger) {
        self.logger = logger
    }

    func logVMRequested(vmId: UUID, requesterId: String, networkId: String) async {
        let entry = VMActivityLogEntry(
            timestamp: Date(),
            vmId: vmId,
            requesterId: requesterId,
            networkId: networkId,
            event: "requested"
        )
        logEntries.append(entry)
        logger.info("VM requested: \(vmId)")
    }

    func logVMCreated(vmId: UUID, requesterId: String, networkId: String, vmIP: String) async {
        let entry = VMActivityLogEntry(
            timestamp: Date(),
            vmId: vmId,
            requesterId: requesterId,
            networkId: networkId,
            event: "created",
            details: "vm_ip: \(vmIP)"
        )
        logEntries.append(entry)
        logger.info("VM created: \(vmId) at \(vmIP)")
    }

    func logVMReleased(vmId: UUID, requesterId: String, networkId: String) async {
        let entry = VMActivityLogEntry(
            timestamp: Date(),
            vmId: vmId,
            requesterId: requesterId,
            networkId: networkId,
            event: "released"
        )
        logEntries.append(entry)
        logger.info("VM released: \(vmId)")
    }

    func logVMKilled(vmId: UUID, reason: String) async {
        let entry = VMActivityLogEntry(
            timestamp: Date(),
            vmId: vmId,
            requesterId: nil,
            networkId: nil,
            event: "killed",
            details: reason
        )
        logEntries.append(entry)
        logger.warning("VM killed: \(vmId) - \(reason)")
    }

    func getLogEntries() -> [VMActivityLogEntry] {
        logEntries
    }
}

/// VM activity log entry
public struct VMActivityLogEntry: Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let vmId: UUID
    public let requesterId: String?
    public let networkId: String?
    public let event: String
    public let details: String?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        vmId: UUID,
        requesterId: String?,
        networkId: String?,
        event: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.vmId = vmId
        self.requesterId = requesterId
        self.networkId = networkId
        self.event = event
        self.details = details
    }
}
