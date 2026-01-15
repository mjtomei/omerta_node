import Foundation
import Logging
import OmertaCore
import OmertaVM
import OmertaNetwork
import OmertaMesh

/// Provider daemon that uses mesh network for NAT traversal
/// Allows consumers behind NAT to connect and request VMs
public actor MeshProviderDaemon {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Mesh peer ID for this provider
        public let peerId: String

        /// Mesh network configuration
        public let meshConfig: MeshConfig

        /// Network key for control message encryption (optional, for extra layer)
        public let networkKey: Data?

        /// Whether to enable activity logging
        public let enableActivityLogging: Bool

        /// Dry run mode (don't actually create VMs)
        public let dryRun: Bool

        public init(
            peerId: String,
            meshConfig: MeshConfig = .default,
            networkKey: Data? = nil,
            enableActivityLogging: Bool = true,
            dryRun: Bool = false
        ) {
            self.peerId = peerId
            self.meshConfig = meshConfig
            self.networkKey = networkKey
            self.enableActivityLogging = enableActivityLogging
            self.dryRun = dryRun
        }

        /// Create configuration from OmertaConfig
        public static func from(config: OmertaConfig) throws -> Configuration {
            guard let meshOptions = config.mesh, meshOptions.enabled else {
                throw MeshProviderError.meshNotEnabled
            }

            // Build MeshConfig from options
            var meshConfig = MeshConfig()
            meshConfig.port = meshOptions.port
            meshConfig.bootstrapPeers = meshOptions.bootstrapPeers
            meshConfig.stunServers = meshOptions.stunServers
            meshConfig.canRelay = meshOptions.canRelay
            meshConfig.canCoordinateHolePunch = meshOptions.canCoordinateHolePunch
            meshConfig.keepaliveInterval = meshOptions.keepaliveInterval
            meshConfig.connectionTimeout = meshOptions.connectionTimeout

            let peerId = meshOptions.peerId ?? "provider-\(UUID().uuidString.prefix(8))"

            return Configuration(
                peerId: peerId,
                meshConfig: meshConfig,
                networkKey: config.localKeyData(),
                enableActivityLogging: true,
                dryRun: false
            )
        }
    }

    // MARK: - State

    private let config: Configuration
    private let logger: Logger

    /// The mesh network
    public let mesh: MeshNetwork

    /// VM manager
    private let vmManager: SimpleVMManager

    /// Activity logger
    private let activityLogger: VMActivityLogger?

    /// Whether the daemon is running
    private var isRunning: Bool = false

    /// When the daemon started
    private var startedAt: Date?

    /// Active VMs tracked by this provider
    private var activeVMs: [UUID: MeshActiveVM] = [:]

    /// Struct to track active VMs
    private struct MeshActiveVM: Sendable {
        let vmId: UUID
        let consumerPeerId: String
        let vmIP: String
        let vmWireGuardPublicKey: String
        let createdAt: Date
    }

    // Statistics
    private var totalVMRequests: Int = 0
    private var totalVMsCreated: Int = 0
    private var totalVMsReleased: Int = 0

    // MARK: - Initialization

    public init(config: Configuration) {
        self.config = config

        // Set up mesh config for provider (can relay, coordinate hole punch)
        var meshConfig = config.meshConfig
        meshConfig.canRelay = true
        meshConfig.canCoordinateHolePunch = true

        self.mesh = MeshNetwork(peerId: config.peerId, config: meshConfig)
        self.vmManager = SimpleVMManager(dryRun: config.dryRun)

        var logger = Logger(label: "io.omerta.provider.mesh")
        logger.logLevel = .info
        self.logger = logger

        if config.enableActivityLogging {
            self.activityLogger = VMActivityLogger(logger: logger)
        } else {
            self.activityLogger = nil
        }

        if config.dryRun {
            logger.info("MeshProviderDaemon initialized in DRY RUN mode")
        }
    }

    /// Convenience initializer from OmertaConfig
    public init(config: OmertaConfig) throws {
        try self.init(config: Configuration.from(config: config))
    }

    // MARK: - Lifecycle

    /// Start the mesh provider daemon
    public func start() async throws {
        guard !isRunning else {
            logger.warning("Mesh provider daemon already running")
            return
        }

        logger.info("Starting mesh provider daemon", metadata: [
            "peerId": "\(config.peerId)"
        ])

        // Set up message handler before starting
        await mesh.setMessageHandler { [weak self] fromPeerId, data in
            guard let self = self else { return }
            await self.handleIncomingMessage(from: fromPeerId, data: data)
        }

        // Start mesh network
        try await mesh.start()

        isRunning = true
        startedAt = Date()

        let natType = await mesh.currentNATType
        let publicEndpoint = await mesh.currentPublicEndpoint

        logger.info("Mesh provider daemon started", metadata: [
            "peerId": "\(config.peerId)",
            "natType": "\(natType.rawValue)",
            "publicEndpoint": "\(publicEndpoint ?? "none")"
        ])
    }

    /// Stop the mesh provider daemon
    public func stop() async {
        guard isRunning else {
            logger.warning("Mesh provider daemon not running")
            return
        }

        logger.info("Stopping mesh provider daemon")

        // Stop all active VMs
        for (vmId, _) in activeVMs {
            do {
                try await vmManager.stopVM(vmId: vmId)
                logger.info("Stopped VM during shutdown", metadata: ["vmId": "\(vmId)"])
            } catch {
                logger.warning("Failed to stop VM during shutdown", metadata: [
                    "vmId": "\(vmId)",
                    "error": "\(error)"
                ])
            }
        }
        activeVMs.removeAll()

        // Stop mesh network
        await mesh.stop()

        isRunning = false
        startedAt = nil

        logger.info("Mesh provider daemon stopped")
    }

    // MARK: - Message Handling

    /// Handle incoming message from a peer
    private func handleIncomingMessage(from peerId: String, data: Data) async {
        logger.debug("Received message from \(peerId.prefix(16))...", metadata: [
            "size": "\(data.count)"
        ])

        // Try to decode as VM request
        if let request = try? JSONDecoder().decode(MeshVMRequest.self, from: data) {
            await handleVMRequest(request, from: peerId)
            return
        }

        // Try to decode as VM release request
        if let request = try? JSONDecoder().decode(MeshVMReleaseRequest.self, from: data) {
            await handleVMRelease(request, from: peerId)
            return
        }

        logger.warning("Unknown message type from \(peerId.prefix(16))...")
    }

    /// Handle VM request
    private func handleVMRequest(_ request: MeshVMRequest, from consumerPeerId: String) async {
        totalVMRequests += 1

        logger.info("Handling VM request", metadata: [
            "vmId": "\(request.vmId)",
            "from": "\(consumerPeerId.prefix(16))..."
        ])

        await activityLogger?.logVMRequested(
            vmId: request.vmId,
            requesterId: consumerPeerId,
            networkId: "mesh"
        )

        do {
            // Get connection info to determine consumer endpoint
            let connection = await mesh.connection(to: consumerPeerId)
            let consumerEndpoint = connection?.endpoint ?? request.consumerEndpoint

            // Derive VM VPN IP
            let vmVPNIP = "10.99.0.2"  // TODO: Allocate from pool

            // Start VM
            let vmResult = try await vmManager.startVM(
                vmId: request.vmId,
                requirements: request.requirements,
                sshPublicKey: request.sshPublicKey,
                sshUser: request.sshUser,
                consumerPublicKey: request.consumerPublicKey,
                consumerEndpoint: consumerEndpoint,
                vpnIP: vmVPNIP,
                reverseTunnelConfig: nil
            )

            // Track VM
            let activeVM = MeshActiveVM(
                vmId: request.vmId,
                consumerPeerId: consumerPeerId,
                vmIP: vmResult.vmIP,
                vmWireGuardPublicKey: vmResult.vmWireGuardPublicKey,
                createdAt: Date()
            )
            activeVMs[request.vmId] = activeVM
            totalVMsCreated += 1

            logger.info("VM created successfully", metadata: [
                "vmId": "\(request.vmId)",
                "vmIP": "\(vmResult.vmIP)"
            ])

            await activityLogger?.logVMCreated(
                vmId: request.vmId,
                requesterId: consumerPeerId,
                networkId: "mesh",
                vmIP: vmResult.vmIP
            )

            // Send success response
            let response = MeshVMResponse(
                type: "vm_created",
                vmId: request.vmId,
                vmIP: vmResult.vmIP,
                providerPublicKey: vmResult.vmWireGuardPublicKey,
                error: nil
            )

            try await sendResponse(response, to: consumerPeerId)

        } catch {
            logger.error("VM creation failed", metadata: [
                "vmId": "\(request.vmId)",
                "error": "\(error)"
            ])

            // Send error response
            let response = MeshVMResponse(
                type: "vm_error",
                vmId: request.vmId,
                vmIP: nil,
                providerPublicKey: nil,
                error: error.localizedDescription
            )

            try? await sendResponse(response, to: consumerPeerId)
        }
    }

    /// Handle VM release request
    private func handleVMRelease(_ request: MeshVMReleaseRequest, from consumerPeerId: String) async {
        logger.info("Handling VM release", metadata: [
            "vmId": "\(request.vmId)",
            "from": "\(consumerPeerId.prefix(16))..."
        ])

        // Verify the consumer owns this VM
        guard let activeVM = activeVMs[request.vmId] else {
            logger.warning("VM not found for release", metadata: ["vmId": "\(request.vmId)"])
            // Send success anyway (idempotent)
            let response = MeshVMReleaseResponse(
                type: "vm_released",
                vmId: request.vmId,
                error: nil
            )
            try? await sendResponse(response, to: consumerPeerId)
            return
        }

        guard activeVM.consumerPeerId == consumerPeerId else {
            logger.warning("Consumer does not own this VM", metadata: [
                "vmId": "\(request.vmId)",
                "owner": "\(activeVM.consumerPeerId.prefix(16))...",
                "requester": "\(consumerPeerId.prefix(16))..."
            ])
            let response = MeshVMReleaseResponse(
                type: "vm_error",
                vmId: request.vmId,
                error: "Not authorized to release this VM"
            )
            try? await sendResponse(response, to: consumerPeerId)
            return
        }

        // Stop the VM
        do {
            try await vmManager.stopVM(vmId: request.vmId)
            activeVMs.removeValue(forKey: request.vmId)
            totalVMsReleased += 1

            logger.info("VM released successfully", metadata: ["vmId": "\(request.vmId)"])

            await activityLogger?.logVMReleased(
                vmId: request.vmId,
                requesterId: consumerPeerId,
                networkId: "mesh"
            )

            let response = MeshVMReleaseResponse(
                type: "vm_released",
                vmId: request.vmId,
                error: nil
            )
            try? await sendResponse(response, to: consumerPeerId)

        } catch {
            logger.error("VM release failed", metadata: [
                "vmId": "\(request.vmId)",
                "error": "\(error)"
            ])

            let response = MeshVMReleaseResponse(
                type: "vm_error",
                vmId: request.vmId,
                error: error.localizedDescription
            )
            try? await sendResponse(response, to: consumerPeerId)
        }
    }

    /// Send response to a peer
    private func sendResponse<T: Encodable>(_ response: T, to peerId: String) async throws {
        let data = try JSONEncoder().encode(response)
        try await mesh.send(data, to: peerId)
    }

    // MARK: - Status

    /// Get daemon status
    public func getStatus() async -> MeshDaemonStatus {
        let stats = await mesh.statistics()

        return MeshDaemonStatus(
            isRunning: isRunning,
            startedAt: startedAt,
            peerId: config.peerId,
            natType: stats.natType,
            publicEndpoint: stats.publicEndpoint,
            peerCount: stats.peerCount,
            activeVMs: activeVMs.count,
            totalVMRequests: totalVMRequests,
            totalVMsCreated: totalVMsCreated,
            totalVMsReleased: totalVMsReleased
        )
    }

    /// List active VMs
    public func listActiveVMs() -> [MeshVMInfo] {
        activeVMs.values.map { vm in
            MeshVMInfo(
                vmId: vm.vmId,
                consumerPeerId: vm.consumerPeerId,
                vmIP: vm.vmIP,
                createdAt: vm.createdAt,
                uptimeSeconds: Int(Date().timeIntervalSince(vm.createdAt))
            )
        }
    }

    /// Get known peers
    public func knownPeers() async -> [String] {
        await mesh.knownPeers()
    }

    /// Get connected relays
    public func connectedRelays() async -> [String] {
        await mesh.connectedRelays()
    }
}

// MARK: - Supporting Types

/// Status of the mesh provider daemon
public struct MeshDaemonStatus: Sendable {
    public let isRunning: Bool
    public let startedAt: Date?
    public let peerId: String
    public let natType: OmertaMesh.NATType
    public let publicEndpoint: String?
    public let peerCount: Int
    public let activeVMs: Int
    public let totalVMRequests: Int
    public let totalVMsCreated: Int
    public let totalVMsReleased: Int

    public var uptime: TimeInterval? {
        guard let startedAt = startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }
}

/// Info about an active VM
public struct MeshVMInfo: Sendable {
    public let vmId: UUID
    public let consumerPeerId: String
    public let vmIP: String
    public let createdAt: Date
    public let uptimeSeconds: Int
}

// MARK: - Protocol Messages (must match MeshConsumerClient)

/// VM request message (matches MeshConsumerClient.MeshVMRequest)
struct MeshVMRequest: Codable {
    let type: String
    let vmId: UUID
    let requirements: ResourceRequirements
    let consumerPublicKey: String
    let consumerEndpoint: String
    let sshPublicKey: String
    let sshUser: String
}

/// VM response message (matches MeshConsumerClient.MeshVMResponse)
struct MeshVMResponse: Codable {
    let type: String
    let vmId: UUID
    let vmIP: String?
    let providerPublicKey: String?
    let error: String?
}

/// VM release request (matches MeshConsumerClient.MeshVMReleaseRequest)
struct MeshVMReleaseRequest: Codable {
    let type: String
    let vmId: UUID
}

/// VM release response
struct MeshVMReleaseResponse: Codable {
    let type: String
    let vmId: UUID
    let error: String?
}

// MARK: - Errors

/// Errors specific to mesh provider daemon
public enum MeshProviderError: Error, CustomStringConvertible {
    case meshNotEnabled
    case notStarted
    case vmCreationFailed(String)
    case vmNotFound(UUID)

    public var description: String {
        switch self {
        case .meshNotEnabled:
            return "Mesh networking is not enabled in config"
        case .notStarted:
            return "Mesh provider daemon not started"
        case .vmCreationFailed(let reason):
            return "VM creation failed: \(reason)"
        case .vmNotFound(let vmId):
            return "VM not found: \(vmId)"
        }
    }
}
