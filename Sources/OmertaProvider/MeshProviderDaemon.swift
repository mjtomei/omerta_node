import Foundation
import Logging
import OmertaCore
import OmertaVM
import OmertaVPN
import OmertaMesh
import OmertaConsumer

/// Provider daemon that uses mesh network for NAT traversal
/// Allows consumers behind NAT to connect and request VMs
public actor MeshProviderDaemon {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Cryptographic identity for this provider (peer ID derived from public key)
        public let identity: OmertaMesh.IdentityKeypair

        /// Mesh network configuration (includes encryption key)
        public let meshConfig: MeshConfig

        /// Dry run mode (don't actually create VMs)
        public let dryRun: Bool

        /// Consumer-only mode (don't accept VM requests)
        public let noProvider: Bool

        public init(
            identity: OmertaMesh.IdentityKeypair,
            meshConfig: MeshConfig,
            dryRun: Bool = false,
            noProvider: Bool = false
        ) {
            self.identity = identity
            self.meshConfig = meshConfig
            self.dryRun = dryRun
            self.noProvider = noProvider
        }

        /// Create configuration from OmertaConfig
        public static func from(config: OmertaConfig) throws -> Configuration {
            guard let meshOptions = config.mesh, meshOptions.enabled else {
                throw MeshProviderError.meshNotEnabled
            }

            guard let keyData = config.localKeyData() else {
                throw MeshProviderError.noNetworkKey
            }

            // Build MeshConfig from options with encryption key
            let meshConfig = MeshConfig(
                encryptionKey: keyData,
                port: meshOptions.port,
                canRelay: meshOptions.canRelay,
                canCoordinateHolePunch: meshOptions.canCoordinateHolePunch,
                keepaliveInterval: meshOptions.keepaliveInterval,
                connectionTimeout: meshOptions.connectionTimeout,
                stunServers: meshOptions.stunServers,
                bootstrapPeers: meshOptions.bootstrapPeers
            )

            // Generate identity (peer ID is derived from public key)
            let identity = OmertaMesh.IdentityKeypair()

            return Configuration(
                identity: identity,
                meshConfig: meshConfig,
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
        let maxHeartbeatFailures: Int  // From timeoutMinutes (1 failure per minute)
    }

    // MARK: - Heartbeat State

    /// Track consecutive heartbeat failures per consumer
    private var heartbeatFailures: [String: Int] = [:]  // consumerPeerId -> failure count

    /// Heartbeat loop task
    private var heartbeatTask: Task<Void, Never>?

    /// Pending heartbeats waiting for response (consumerPeerId -> timestamp sent)
    private var pendingHeartbeats: [String: Date] = [:]

    /// Consumer message handler (for heartbeat requests, etc.)
    private var consumerMessageHandler: ((String, Data) async -> Void)?

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

        self.mesh = MeshNetwork(identity: config.identity, config: meshConfig)
        self.vmManager = SimpleVMManager(dryRun: config.dryRun)

        var logger = Logger(label: "io.omerta.provider.mesh")
        logger.logLevel = .info
        self.logger = logger

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
            "peerId": "\(config.identity.peerId)"
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

        // Start heartbeat loop for VM liveness checks
        startHeartbeatLoop()

        let natType = await mesh.currentNATType
        let publicEndpoint = await mesh.currentPublicEndpoint

        logger.info("Mesh provider daemon started", metadata: [
            "peerId": "\(config.identity.peerId)",
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

        // Cancel heartbeat loop
        heartbeatTask?.cancel()
        heartbeatTask = nil

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

        // Try to decode as heartbeat response
        if let response = try? JSONDecoder().decode(MeshVMHeartbeatResponse.self, from: data) {
            // Remove from pending and get the VMs we asked about
            if pendingHeartbeats.removeValue(forKey: peerId) != nil {
                let consumerVMs = activeVMs.filter { $0.value.consumerPeerId == peerId }
                let requestedVmIds = consumerVMs.map { $0.key }
                await handleHeartbeatResponse(response, from: peerId, requestedVmIds: requestedVmIds)
            }
            return
        }

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

        // Pass to consumer message handler if set (for heartbeat requests, etc.)
        if let handler = consumerMessageHandler {
            await handler(peerId, data)
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

        do {
            // Get connection info to determine consumer endpoint
            let connection = await mesh.connection(to: consumerPeerId)
            let consumerEndpoint = connection?.endpoint ?? request.consumerEndpoint

            // Use VM VPN IP from request (consumer assigns this when creating WireGuard tunnel)
            let vmVPNIP = request.vmVPNIP

            logger.info("Using VPN IPs from consumer", metadata: [
                "vmVPNIP": "\(vmVPNIP)",
                "consumerVPNIP": "\(request.consumerVPNIP)"
            ])

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

            // Track VM with heartbeat timeout (default 10 minutes = 10 failures)
            let maxFailures = request.timeoutMinutes ?? 10
            let activeVM = MeshActiveVM(
                vmId: request.vmId,
                consumerPeerId: consumerPeerId,
                vmIP: vmResult.vmIP,
                vmWireGuardPublicKey: vmResult.vmWireGuardPublicKey,
                createdAt: Date(),
                maxHeartbeatFailures: maxFailures
            )
            activeVMs[request.vmId] = activeVM
            totalVMsCreated += 1

            logger.info("VM created with heartbeat timeout", metadata: [
                "vmId": "\(request.vmId)",
                "maxHeartbeatFailures": "\(maxFailures)"
            ])

            logger.info("VM created successfully", metadata: [
                "vmId": "\(request.vmId)",
                "vmIP": "\(vmResult.vmIP)"
            ])

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
            peerId: config.identity.peerId,
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

    /// Ping a peer through the mesh network
    public func ping(peerId: String, timeout: TimeInterval = 5) async -> MeshNode.PingResult? {
        await mesh.ping(peerId, timeout: timeout)
    }

    /// Set a handler for consumer-side messages (e.g., incoming heartbeat requests)
    /// This handler is called for messages the provider daemon doesn't handle
    public func setConsumerMessageHandler(_ handler: @escaping (String, Data) async -> Void) {
        self.consumerMessageHandler = handler
    }

    /// Send data to a peer (exposed for consumer operations)
    public func sendToPeer(_ data: Data, to peerId: String) async throws {
        try await mesh.send(data, to: peerId)
    }

    // MARK: - Heartbeat Loop

    /// Start the background heartbeat loop
    private func startHeartbeatLoop() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                // Wait 60 seconds between heartbeats
                try? await Task.sleep(for: .seconds(60))

                guard !Task.isCancelled else { break }
                guard let self = self else { break }

                await self.sendHeartbeats()
            }
        }
        logger.info("Heartbeat loop started (60 second interval)")
    }

    /// Send heartbeats to all consumers with active VMs
    private func sendHeartbeats() async {
        guard !activeVMs.isEmpty else { return }

        // First, check for timed-out pending heartbeats (>30 seconds without response)
        let now = Date()
        for (consumerPeerId, sentAt) in pendingHeartbeats {
            if now.timeIntervalSince(sentAt) > 30 {
                logger.warning("Heartbeat timeout (no response)", metadata: [
                    "consumer": "\(consumerPeerId.prefix(16))..."
                ])
                pendingHeartbeats.removeValue(forKey: consumerPeerId)
                await handleHeartbeatFailure(consumerPeerId)
            }
        }

        // Group VMs by consumer
        var vmsByConsumer: [String: [UUID]] = [:]
        for (vmId, vm) in activeVMs {
            vmsByConsumer[vm.consumerPeerId, default: []].append(vmId)
        }

        logger.debug("Sending heartbeats to \(vmsByConsumer.count) consumer(s)")

        // Send heartbeat to each consumer (skip if already pending)
        for (consumerPeerId, vmIds) in vmsByConsumer {
            if pendingHeartbeats[consumerPeerId] == nil {
                await sendHeartbeatToConsumer(consumerPeerId, vmIds: vmIds)
            }
        }
    }

    /// Send heartbeat to a specific consumer
    private func sendHeartbeatToConsumer(_ consumerPeerId: String, vmIds: [UUID]) async {
        let heartbeat = MeshVMHeartbeat(vmIds: vmIds)

        guard let heartbeatData = try? JSONEncoder().encode(heartbeat) else {
            logger.error("Failed to encode heartbeat")
            return
        }

        logger.debug("Sending heartbeat to consumer", metadata: [
            "consumer": "\(consumerPeerId.prefix(16))...",
            "vmCount": "\(vmIds.count)"
        ])

        do {
            // Track as pending before sending
            pendingHeartbeats[consumerPeerId] = Date()

            // Send heartbeat (response will be handled in handleIncomingMessage)
            try await mesh.send(heartbeatData, to: consumerPeerId)

        } catch {
            logger.warning("Heartbeat send failed", metadata: [
                "consumer": "\(consumerPeerId.prefix(16))...",
                "error": "\(error)"
            ])
            pendingHeartbeats.removeValue(forKey: consumerPeerId)
            await handleHeartbeatFailure(consumerPeerId)
        }
    }

    /// Handle successful heartbeat response
    private func handleHeartbeatResponse(_ response: MeshVMHeartbeatResponse, from consumerPeerId: String, requestedVmIds: [UUID]) async {
        // Reset failure count for this consumer
        heartbeatFailures[consumerPeerId] = 0

        let activeSet = Set(response.activeVmIds)
        let requestedSet = Set(requestedVmIds)

        // Find VMs that consumer no longer acknowledges
        let abandonedIds = requestedSet.subtracting(activeSet)

        if !abandonedIds.isEmpty {
            logger.info("Consumer no longer tracking VMs", metadata: [
                "consumer": "\(consumerPeerId.prefix(16))...",
                "abandonedVMs": "\(abandonedIds.map { $0.uuidString.prefix(8) })"
            ])

            for vmId in abandonedIds {
                await cleanupVM(vmId, reason: "consumer no longer tracking")
            }
        }
    }

    /// Handle heartbeat failure (timeout or invalid response)
    private func handleHeartbeatFailure(_ consumerPeerId: String) async {
        heartbeatFailures[consumerPeerId, default: 0] += 1
        let failures = heartbeatFailures[consumerPeerId]!

        logger.warning("Heartbeat failure", metadata: [
            "consumer": "\(consumerPeerId.prefix(16))...",
            "consecutiveFailures": "\(failures)"
        ])

        // Check each VM's timeout threshold
        let consumerVMs = activeVMs.filter { $0.value.consumerPeerId == consumerPeerId }
        for (vmId, vm) in consumerVMs {
            if failures >= vm.maxHeartbeatFailures {
                logger.warning("VM heartbeat timeout exceeded", metadata: [
                    "vmId": "\(vmId.uuidString.prefix(8))...",
                    "failures": "\(failures)",
                    "maxFailures": "\(vm.maxHeartbeatFailures)"
                ])
                await cleanupVM(vmId, reason: "heartbeat timeout (\(failures) consecutive failures)")
            }
        }
    }

    /// Clean up a VM that is no longer needed
    private func cleanupVM(_ vmId: UUID, reason: String) async {
        guard let vm = activeVMs[vmId] else { return }

        logger.info("Cleaning up VM", metadata: [
            "vmId": "\(vmId.uuidString.prefix(8))...",
            "reason": "\(reason)"
        ])

        do {
            try await vmManager.stopVM(vmId: vmId)
            activeVMs.removeValue(forKey: vmId)
            totalVMsReleased += 1
            logger.info("VM cleaned up successfully", metadata: ["vmId": "\(vmId.uuidString.prefix(8))..."])
        } catch {
            logger.error("Failed to cleanup VM", metadata: [
                "vmId": "\(vmId.uuidString.prefix(8))...",
                "error": "\(error)"
            ])
            // Still remove from tracking even if stop failed
            activeVMs.removeValue(forKey: vmId)
        }

        // Clean up failure tracking if no more VMs from this consumer
        let remainingVMs = activeVMs.filter { $0.value.consumerPeerId == vm.consumerPeerId }
        if remainingVMs.isEmpty {
            heartbeatFailures.removeValue(forKey: vm.consumerPeerId)
        }
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

// VM protocol messages are now in OmertaConsumer/VMProtocolMessages.swift

// MARK: - Errors

/// Errors specific to mesh provider daemon
public enum MeshProviderError: Error, CustomStringConvertible {
    case meshNotEnabled
    case noNetworkKey
    case notStarted
    case vmCreationFailed(String)
    case vmNotFound(UUID)

    public var description: String {
        switch self {
        case .meshNotEnabled:
            return "Mesh networking is not enabled in config"
        case .noNetworkKey:
            return "No network key configured (required for encryption)"
        case .notStarted:
            return "Mesh provider daemon not started"
        case .vmCreationFailed(let reason):
            return "VM creation failed: \(reason)"
        case .vmNotFound(let vmId):
            return "VM not found: \(vmId)"
        }
    }
}
