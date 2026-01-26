import Foundation
import Logging
import OmertaCore
import OmertaVM
// OmertaVPN removed - using mesh tunnels instead of WireGuard
import OmertaMesh
import OmertaConsumer
import OmertaTunnel

/// Channel names for VM protocol (provider-side)
/// Must match VMChannels in MeshConsumerClient
private enum ProviderChannels {
    /// Channel for VM requests (consumer -> provider)
    static let request = "vm-request"
    /// Channel for VM responses (provider -> consumer)
    /// Format: "vm-response-{consumerPeerId}"
    static func response(for peerId: PeerId) -> String {
        "vm-response-\(peerId)"
    }
    /// Channel for VM ACKs (consumer -> provider)
    static let ack = "vm-ack"
    /// Channel for VM release requests (consumer -> provider)
    static let release = "vm-release"
    /// Channel for VM heartbeats (provider -> consumer)
    static let heartbeat = "vm-heartbeat"
    /// Channel for shutdown notifications (provider -> consumer)
    static let shutdown = "vm-shutdown"
}

/// Provider daemon that uses mesh network for NAT traversal
/// Allows consumers behind NAT to connect and request VMs
public actor MeshProviderDaemon: ChannelProvider {

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

        /// Enable persistent event logging
        public let enableEventLogging: Bool

        public init(
            identity: OmertaMesh.IdentityKeypair,
            meshConfig: MeshConfig,
            dryRun: Bool = false,
            noProvider: Bool = false,
            enableEventLogging: Bool = false
        ) {
            self.identity = identity
            self.meshConfig = meshConfig
            self.dryRun = dryRun
            self.noProvider = noProvider
            self.enableEventLogging = enableEventLogging
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

    /// Event logger for persistent event storage
    private let eventLogger: ProviderEventLogger?

    /// The mesh network
    public let mesh: MeshNetwork

    /// Our peer ID (ChannelProvider requirement)
    public var peerId: PeerId {
        config.identity.peerId
    }

    /// VM manager
    private let vmManager: VMManager

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
        let createdAt: Date
        let maxHeartbeatFailures: Int  // From timeoutMinutes (1 failure per minute)
    }

    // MARK: - Tunnel State

    /// Tunnel manager for creating sessions with consumers
    private var tunnelManager: TunnelManager?

    /// Active tunnel sessions by VM ID
    private var tunnelSessions: [UUID: TunnelSession] = [:]

    /// Active packet captures by VM ID
    private var packetCaptures: [UUID: VMPacketCapture] = [:]

    // MARK: - Heartbeat State

    /// Track consecutive heartbeat failures per consumer
    private var heartbeatFailures: [String: Int] = [:]  // consumerPeerId -> failure count

    /// Heartbeat loop task
    private var heartbeatTask: Task<Void, Never>?

    /// Pending heartbeats waiting for response (consumerPeerId -> timestamp sent)
    private var pendingHeartbeats: [String: Date] = [:]

    /// Pending ACKs waiting for response (vmId -> continuation)
    private var pendingAcks: [UUID: CheckedContinuation<MeshVMAck, any Error>] = [:]

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
        self.vmManager = VMManager(dryRun: config.dryRun)

        var logger = Logger(label: "io.omerta.provider.mesh")
        logger.logLevel = .info
        self.logger = logger

        // Create event logger if enabled
        if config.enableEventLogging {
            self.eventLogger = try? ProviderEventLogger()
        } else {
            self.eventLogger = nil
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
            "peerId": "\(config.identity.peerId)"
        ])

        // Register channel handlers before starting
        try await registerChannelHandlers()

        // Start mesh network
        try await mesh.start()

        // Initialize tunnel manager for VM traffic routing
        tunnelManager = TunnelManager(provider: mesh)

        // Set up handler for incoming tunnel sessions (when we're the consumer/exit point)
        // This enables traffic routing so VM packets are routed to the internet
        await tunnelManager?.setSessionEstablishedHandler { [weak self] session in
            guard let self = self else { return }
            let remotePeer = await session.remotePeer
            do {
                // We're the exit point - enable netstack to process VM packets
                try await session.enableTrafficRouting(asExit: true)

                // Check if this consumer has an active VM - if so, bridge traffic to VM
                await self.setupConsumerVMBridging(session: session, consumerPeerId: remotePeer)

                await self.logIncomingSession(remotePeer: remotePeer, error: nil)
            } catch {
                await self.logIncomingSession(remotePeer: remotePeer, error: error)
            }
        }

        try await tunnelManager?.start()

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

        // Notify consumers before stopping VMs
        await notifyConsumersOfShutdown()

        // Stop all packet captures and tunnel sessions
        for (vmId, capture) in packetCaptures {
            await capture.stop()
            logger.info("Stopped packet capture during shutdown", metadata: ["vmId": "\(vmId)"])
        }
        packetCaptures.removeAll()

        for (vmId, session) in tunnelSessions {
            await session.leave()
            logger.info("Closed tunnel session during shutdown", metadata: ["vmId": "\(vmId)"])
        }
        tunnelSessions.removeAll()

        // Stop tunnel manager
        await tunnelManager?.stop()
        tunnelManager = nil

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

    /// Notify all consumers that their VMs are being released due to shutdown
    private func notifyConsumersOfShutdown() async {
        // Group VMs by consumer
        var vmsByConsumer: [String: [UUID]] = [:]
        for (vmId, vmInfo) in activeVMs {
            vmsByConsumer[vmInfo.consumerPeerId, default: []].append(vmId)
        }

        guard !vmsByConsumer.isEmpty else {
            logger.debug("No consumers to notify of shutdown")
            return
        }

        logger.info("Notifying \(vmsByConsumer.count) consumer(s) of shutdown")

        // Send notification to each consumer on the shutdown channel
        for (consumerPeerId, vmIds) in vmsByConsumer {
            let notification = MeshProviderShutdownNotification(vmIds: vmIds)

            guard let notificationData = try? JSONEncoder().encode(notification) else {
                logger.error("Failed to encode shutdown notification")
                continue
            }

            do {
                try await mesh.sendOnChannel(notificationData, to: consumerPeerId, channel: ProviderChannels.shutdown)
                logger.info("Sent shutdown notification", metadata: [
                    "consumer": "\(consumerPeerId.prefix(16))...",
                    "vmCount": "\(vmIds.count)"
                ])
            } catch {
                logger.warning("Failed to send shutdown notification", metadata: [
                    "consumer": "\(consumerPeerId.prefix(16))...",
                    "error": "\(error)"
                ])
            }
        }

        // Give consumers a moment to process
        try? await Task.sleep(for: .milliseconds(500))
    }

    // MARK: - Channel Registration

    /// Register handlers for all VM-related channels
    private func registerChannelHandlers() async throws {
        // Handler for VM requests (consumer -> provider)
        try await mesh.onChannel(ProviderChannels.request) { [weak self] peerId, data in
            guard let self = self else { return }
            await self.handleVMRequestChannel(from: peerId, data: data)
        }

        // Handler for VM release requests (consumer -> provider)
        try await mesh.onChannel(ProviderChannels.release) { [weak self] peerId, data in
            guard let self = self else { return }
            await self.handleVMReleaseChannel(from: peerId, data: data)
        }

        // Handler for VM ACKs (consumer -> provider)
        try await mesh.onChannel(ProviderChannels.ack) { [weak self] peerId, data in
            guard let self = self else { return }
            await self.handleVMAckChannel(from: peerId, data: data)
        }

        // Handler for heartbeat responses (consumer -> provider)
        try await mesh.onChannel(ProviderChannels.heartbeat) { [weak self] peerId, data in
            guard let self = self else { return }
            await self.handleHeartbeatChannel(from: peerId, data: data)
        }

        logger.info("Registered channel handlers", metadata: [
            "channels": "\([ProviderChannels.request, ProviderChannels.release, ProviderChannels.ack, ProviderChannels.heartbeat])"
        ])
    }

    // MARK: - Incoming Session Handling

    /// Log incoming session establishment (called from session handler)
    private func logIncomingSession(remotePeer: PeerId, error: Error?) {
        if let error = error {
            logger.error("Failed to enable traffic routing for incoming session", metadata: [
                "peer": "\(remotePeer.prefix(16))...",
                "error": "\(error)"
            ])
        } else {
            logger.info("Traffic routing enabled for incoming session (exit point)", metadata: [
                "peer": "\(remotePeer.prefix(16))..."
            ])
        }
    }

    // MARK: - Channel Handlers

    /// Handle VM request from channel
    private func handleVMRequestChannel(from peerId: PeerId, data: Data) async {
        guard let request = try? JSONDecoder().decode(MeshVMRequest.self, from: data) else {
            logger.warning("Failed to decode VM request", metadata: ["from": "\(peerId.prefix(16))..."])
            return
        }
        await handleVMRequest(request, from: peerId)
    }

    /// Handle VM release request from channel
    private func handleVMReleaseChannel(from peerId: PeerId, data: Data) async {
        guard let request = try? JSONDecoder().decode(MeshVMReleaseRequest.self, from: data) else {
            logger.warning("Failed to decode VM release request", metadata: ["from": "\(peerId.prefix(16))..."])
            return
        }
        await handleVMRelease(request, from: peerId)
    }

    /// Handle VM ACK from channel
    private func handleVMAckChannel(from peerId: PeerId, data: Data) async {
        guard let ack = try? JSONDecoder().decode(MeshVMAck.self, from: data) else {
            logger.warning("Failed to decode VM ACK", metadata: ["from": "\(peerId.prefix(16))..."])
            return
        }
        handleVMAck(ack)
    }

    /// Handle heartbeat response from channel
    private func handleHeartbeatChannel(from peerId: PeerId, data: Data) async {
        guard let response = try? JSONDecoder().decode(MeshVMHeartbeatResponse.self, from: data) else {
            logger.warning("Failed to decode heartbeat response", metadata: ["from": "\(peerId.prefix(16))..."])
            return
        }

        // Remove from pending and get the VMs we asked about
        if pendingHeartbeats.removeValue(forKey: peerId) != nil {
            let consumerVMs = activeVMs.filter { $0.value.consumerPeerId == peerId }
            let requestedVmIds = consumerVMs.map { $0.key }
            await handleHeartbeatResponse(response, from: peerId, requestedVmIds: requestedVmIds)
        }
    }

    /// Handle VM request
    private func handleVMRequest(_ request: MeshVMRequest, from consumerPeerId: String) async {
        totalVMRequests += 1

        logger.info("Handling VM request", metadata: [
            "vmId": "\(request.vmId)",
            "from": "\(consumerPeerId.prefix(16))..."
        ])

        // Reject self-requests (consumer trying to request VM from itself)
        guard consumerPeerId != config.identity.peerId else {
            logger.warning("Rejecting self-request (consumer and provider are same peer)", metadata: [
                "vmId": "\(request.vmId)",
                "peerId": "\(consumerPeerId.prefix(16))..."
            ])

            let response = MeshVMResponse(
                type: "vm_error",
                vmId: request.vmId,
                vmIP: nil,
                providerPublicKey: nil,
                error: "Cannot request VM from self"
            )
            try? await sendResponse(response, to: consumerPeerId)
            return
        }

        // Reject if running in consumer-only mode
        guard !config.noProvider else {
            logger.warning("Rejecting VM request (running in consumer-only mode)", metadata: [
                "vmId": "\(request.vmId)"
            ])

            let response = MeshVMResponse(
                type: "vm_error",
                vmId: request.vmId,
                vmIP: nil,
                providerPublicKey: nil,
                error: "This node is not accepting VM requests"
            )
            try? await sendResponse(response, to: consumerPeerId)
            return
        }

        // Log VM request
        await eventLogger?.recordVMRequest(
            vmId: request.vmId,
            consumerPeerId: consumerPeerId,
            cpuCores: Int(request.requirements.cpuCores ?? 1),
            memoryMB: Int(request.requirements.memoryMB ?? 1024),
            diskGB: Int((request.requirements.storageMB ?? 10240) / 1024) // Convert MB to GB
        )

        do {
            // Use VM IP from request (traffic routes through mesh tunnels)
            let vmVPNIP = request.vmVPNIP

            logger.info("Starting VM with mesh tunnel routing", metadata: [
                "vmVPNIP": "\(vmVPNIP)"
            ])

            // Start VM (traffic routes through mesh tunnel)
            let vmResult = try await vmManager.startVM(
                vmId: request.vmId,
                requirements: request.requirements,
                sshPublicKey: request.sshPublicKey,
                sshUser: request.sshUser,
                vpnIP: vmVPNIP,
                reverseTunnelConfig: nil
            )

            // Track VM with heartbeat timeout (default 10 minutes = 10 failures)
            let maxFailures = request.timeoutMinutes ?? 10
            let activeVM = MeshActiveVM(
                vmId: request.vmId,
                consumerPeerId: consumerPeerId,
                vmIP: vmResult.vmIP,
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

            // Set up tunnel for VM traffic routing
            await setupVMTunnel(vmId: request.vmId, consumerPeerId: consumerPeerId)

            // Log VM creation success
            await eventLogger?.recordVMCreated(
                vmId: request.vmId,
                consumerPeerId: consumerPeerId,
                success: true,
                error: nil,
                durationMs: Int(Date().timeIntervalSince(activeVM.createdAt) * 1000)
            )

            // Send success response and wait for ACK
            // No WireGuard keys needed - traffic routes through mesh tunnels
            let response = MeshVMResponse(
                type: "vm_created",
                vmId: request.vmId,
                vmIP: vmResult.vmIP,
                providerPublicKey: nil,  // Mesh tunnels don't need WireGuard keys
                error: nil
            )

            await sendVMResponseWithAck(response, to: consumerPeerId)

        } catch {
            logger.error("VM creation failed", metadata: [
                "vmId": "\(request.vmId)",
                "error": "\(error)"
            ])

            // Log VM creation failure
            await eventLogger?.recordVMCreated(
                vmId: request.vmId,
                consumerPeerId: consumerPeerId,
                success: false,
                error: error.localizedDescription,
                durationMs: nil
            )

            // Log error
            await eventLogger?.recordError(
                component: "VMManager",
                operation: "createVM",
                errorType: "vm_creation_failed",
                errorMessage: error.localizedDescription,
                vmId: request.vmId,
                consumerPeerId: consumerPeerId
            )

            // Send error response (no ACK needed for errors)
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
            let durationMs = Int(Date().timeIntervalSince(activeVM.createdAt) * 1000)

            // Clean up packet capture and tunnel session
            await cleanupVMTunnel(vmId: request.vmId)

            try await vmManager.stopVM(vmId: request.vmId)
            activeVMs.removeValue(forKey: request.vmId)
            totalVMsReleased += 1

            logger.info("VM released successfully", metadata: ["vmId": "\(request.vmId)"])

            // Log VM release
            await eventLogger?.recordVMReleased(
                vmId: request.vmId,
                consumerPeerId: consumerPeerId,
                reason: "user_requested",
                durationMs: durationMs
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

            // Log error
            await eventLogger?.recordError(
                component: "VMManager",
                operation: "releaseVM",
                errorType: "vm_release_failed",
                errorMessage: error.localizedDescription,
                vmId: request.vmId,
                consumerPeerId: consumerPeerId
            )

            let response = MeshVMReleaseResponse(
                type: "vm_error",
                vmId: request.vmId,
                error: error.localizedDescription
            )
            try? await sendResponse(response, to: consumerPeerId)
        }
    }

    /// Handle VM ACK from consumer
    private func handleVMAck(_ ack: MeshVMAck) {
        if let continuation = pendingAcks.removeValue(forKey: ack.vmId) {
            continuation.resume(returning: ack)
            logger.debug("Received VM ACK", metadata: [
                "vmId": "\(ack.vmId.uuidString.prefix(8))...",
                "success": "\(ack.success)"
            ])
        } else {
            logger.warning("Received ACK for unknown VM", metadata: [
                "vmId": "\(ack.vmId.uuidString.prefix(8))..."
            ])
        }
    }

    // MARK: - Tunnel Setup

    /// Set up tunnel for VM traffic routing
    /// Provider acts as traffic source, consumer as traffic exit (via netstack)
    private func setupVMTunnel(vmId: UUID, consumerPeerId: String) async {
        guard let tunnelManager = tunnelManager else {
            logger.warning("Tunnel manager not initialized, skipping tunnel setup", metadata: [
                "vmId": "\(vmId)"
            ])
            return
        }

        do {
            // Create tunnel session with consumer
            let session = try await tunnelManager.createSession(with: consumerPeerId)
            tunnelSessions[vmId] = session

            // Enable traffic routing - provider is source, consumer is exit
            try await session.enableTrafficRouting(asExit: false)

            logger.info("Tunnel session created for VM", metadata: [
                "vmId": "\(vmId)",
                "consumer": "\(consumerPeerId.prefix(16))..."
            ])

            // Set up VMPacketCapture to bridge VM network to tunnel
            #if os(Linux)
            // Linux: Use TAP interface
            if let tapName = await vmManager.getTAPInterface(vmId: vmId) {
                let packetSource = TAPPacketSource(tapName: tapName, vmId: vmId)
                let capture = VMPacketCapture(vmId: vmId, packetSource: packetSource, tunnelSession: session)
                try await capture.start()
                packetCaptures[vmId] = capture

                logger.info("Packet capture started for VM (TAP)", metadata: [
                    "vmId": "\(vmId)",
                    "tap": "\(tapName)"
                ])
            } else {
                logger.warning("No TAP interface available for VM", metadata: ["vmId": "\(vmId)"])
            }
            #elseif os(macOS)
            // macOS: Use file handles
            if let handles = await vmManager.getNetworkHandles(vmId: vmId) {
                let packetSource = FileHandlePacketSource(
                    hostRead: handles.hostRead,
                    hostWrite: handles.hostWrite,
                    vmId: vmId
                )
                let capture = VMPacketCapture(vmId: vmId, packetSource: packetSource, tunnelSession: session)
                try await capture.start()
                packetCaptures[vmId] = capture

                logger.info("Packet capture started for VM (file handles)", metadata: [
                    "vmId": "\(vmId)"
                ])
            } else {
                // No file handles means test mode (NAT networking)
                logger.info("No file handles available for VM (test mode)", metadata: ["vmId": "\(vmId)"])
            }
            #endif

        } catch {
            logger.error("Failed to set up tunnel for VM", metadata: [
                "vmId": "\(vmId)",
                "error": "\(error)"
            ])
        }
    }

    /// Clean up tunnel session and packet capture for a VM
    private func cleanupVMTunnel(vmId: UUID) async {
        // Stop packet capture first
        if let capture = packetCaptures.removeValue(forKey: vmId) {
            await capture.stop()
            logger.info("Stopped packet capture for VM", metadata: ["vmId": "\(vmId)"])
        }

        // Then close tunnel session
        if let session = tunnelSessions.removeValue(forKey: vmId) {
            await session.leave()
            logger.info("Closed tunnel session for VM", metadata: ["vmId": "\(vmId)"])
        }
    }

    /// Set up bridging between consumer's tunnel session and their VM.
    /// This allows consumer->VM traffic (e.g., SSH) to flow through the tunnel.
    private func setupConsumerVMBridging(session: TunnelSession, consumerPeerId: String) async {
        // Find VM owned by this consumer
        guard let (vmId, _) = activeVMs.first(where: { $0.value.consumerPeerId == consumerPeerId }) else {
            logger.debug("No active VM for consumer, skipping VM bridging", metadata: [
                "consumer": "\(consumerPeerId.prefix(16))..."
            ])
            return
        }

        // Get packet capture for this VM
        guard let capture = packetCaptures[vmId] else {
            logger.warning("No packet capture for VM, cannot set up bridging", metadata: [
                "vmId": "\(vmId)",
                "consumer": "\(consumerPeerId.prefix(16))..."
            ])
            return
        }

        logger.info("Setting up consumer->VM bridging", metadata: [
            "vmId": "\(vmId.uuidString.prefix(8))...",
            "consumer": "\(consumerPeerId.prefix(16))..."
        ])

        // Set up traffic forward callback to inject packets into VM
        await session.setTrafficForwardCallback { [capture] packet in
            try await capture.injectFromConsumer(packet)
        }

        // Set the consumer session on packet capture for return traffic
        await capture.setConsumerSession(session)
    }

    /// Send response to a consumer on their response channel
    private func sendResponse<T: Encodable>(_ response: T, to consumerPeerId: PeerId) async throws {
        let data = try JSONEncoder().encode(response)
        let responseChannel = ProviderChannels.response(for: consumerPeerId)
        try await mesh.sendOnChannel(data, to: consumerPeerId, channel: responseChannel)
    }

    /// Send VM response and wait for ACK
    /// If ACK not received within timeout, logs warning but doesn't fail
    private func sendVMResponseWithAck(
        _ response: MeshVMResponse,
        to consumerPeerId: PeerId,
        timeout: TimeInterval = 5.0
    ) async {
        do {
            let data = try JSONEncoder().encode(response)
            let responseChannel = ProviderChannels.response(for: consumerPeerId)

            // Send the response on the consumer's response channel
            try await mesh.sendOnChannel(data, to: consumerPeerId, channel: responseChannel)

            // Wait for ACK with timeout
            do {
                let ack = try await withCheckedThrowingContinuation { continuation in
                    pendingAcks[response.vmId] = continuation

                    // Create timeout task
                    Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        // If still pending, timeout
                        if let cont = self.pendingAcks.removeValue(forKey: response.vmId) {
                            cont.resume(throwing: MeshProviderError.ackTimeout)
                        }
                    }
                }

                if ack.success {
                    logger.info("VM response ACKed", metadata: ["vmId": "\(response.vmId.uuidString.prefix(8))..."])
                } else {
                    logger.warning("Consumer rejected VM response", metadata: ["vmId": "\(response.vmId.uuidString.prefix(8))..."])
                }

            } catch is MeshProviderError {
                logger.warning("No ACK received for VM response (timeout)", metadata: [
                    "vmId": "\(response.vmId.uuidString.prefix(8))...",
                    "consumer": "\(consumerPeerId.prefix(16))..."
                ])
            }

        } catch {
            logger.error("Failed to send VM response", metadata: [
                "vmId": "\(response.vmId.uuidString.prefix(8))...",
                "error": "\(error)"
            ])
            // Clean up pending ACK if send failed
            pendingAcks.removeValue(forKey: response.vmId)
        }
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

    /// Get known peers with full info (including endpoints)
    public func knownPeersWithInfo() async -> [MeshNode.CachedPeerInfo] {
        await mesh.knownPeersWithInfo()
    }

    /// Get connected relays
    public func connectedRelays() async -> [String] {
        await mesh.connectedRelays()
    }

    /// Ping a peer through the mesh network
    /// - Parameters:
    ///   - peerId: The peer to ping
    ///   - timeout: Timeout in seconds
    ///   - requestFullList: If true, request the peer's full peer list (for bootstrap/reconnection)
    public func ping(peerId: String, timeout: TimeInterval = 5, requestFullList: Bool = false) async -> MeshNode.PingResult? {
        await mesh.ping(peerId, timeout: timeout, requestFullList: requestFullList)
    }

    /// Get endpoint for a peer - uses known peers first, falls back to fresh ping
    /// This is more reliable than always requiring a fresh ping
    /// - Parameters:
    ///   - peerId: The peer to get endpoint for
    ///   - pingTimeout: Timeout for fallback ping (default 10s)
    /// - Returns: The peer's endpoint, or nil if not reachable
    public func getEndpointForPeer(_ peerId: String, pingTimeout: TimeInterval = 10) async -> String? {
        // First check known peers - faster and doesn't require network
        let knownPeers = await knownPeersWithInfo()
        if let knownPeer = knownPeers.first(where: { $0.peerId == peerId }) {
            return knownPeer.endpoint
        }

        // Fallback to fresh ping if peer not in cache
        if let pingResult = await ping(peerId: peerId, timeout: pingTimeout) {
            return pingResult.endpoint
        }

        return nil
    }

    /// Connect to a peer through the mesh network
    public func connect(to peerId: String) async throws -> DirectConnection {
        try await mesh.connect(to: peerId)
    }

    /// Send data to a peer on a specific channel (exposed for consumer operations)
    public func sendOnChannel(_ data: Data, to peerId: PeerId, channel: String) async throws {
        try await mesh.sendOnChannel(data, to: peerId, channel: channel)
    }

    /// Register a handler for a custom channel
    public func onChannel(_ channel: String, handler: @escaping @Sendable (PeerId, Data) async -> Void) async throws {
        try await mesh.onChannel(channel, handler: handler)
    }

    /// Remove a channel handler
    public func offChannel(_ channel: String) async {
        await mesh.offChannel(channel)
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
    private func sendHeartbeatToConsumer(_ consumerPeerId: PeerId, vmIds: [UUID]) async {
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

            // Send heartbeat on heartbeat channel (response will arrive on same channel)
            try await mesh.sendOnChannel(heartbeatData, to: consumerPeerId, channel: ProviderChannels.heartbeat)

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
    case ackTimeout

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
        case .ackTimeout:
            return "ACK timeout waiting for consumer response"
        }
    }
}
