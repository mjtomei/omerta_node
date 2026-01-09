import Foundation
import NIOCore
import NIOPosix
import Crypto
import Logging
import OmertaCore
import OmertaConsumer
import OmertaNetwork
import OmertaVM

/// Server for handling encrypted UDP control messages from consumers
/// Manages VM lifecycle in response to requestVM/releaseVM commands
/// Uses SwiftNIO for cross-platform UDP support (macOS and Linux)
public actor UDPControlServer {
    private var networkKeys: [String: Data]  // networkId -> encryption key
    private let port: UInt16
    private let logger: Logger
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var isRunning: Bool = false

    // VM management
    private let vmManager: SimpleVMManager
    private let vpnHealthMonitor: VPNHealthMonitor
    private let providerVPNManager: ProviderVPNManager

    // VM tracking - includes networkId for responses
    private var activeVMs: [UUID: ActiveVM] = [:]

    private struct ActiveVM {
        let vmId: UUID
        let networkId: String     // Network this VM belongs to
        let consumerEndpoint: String
        let vpnConfig: VPNConfiguration
        let vmIP: String          // VPN IP (e.g., 10.99.0.2)
        let tapInterface: String  // TAP interface (e.g., tap-abc12345)
        let vpnInterface: String
        let providerPublicKey: String
        let createdAt: Date
    }

    public init(
        networkKeys: [String: Data],
        port: UInt16 = 51820,
        vmManager: SimpleVMManager? = nil,
        vpnHealthMonitor: VPNHealthMonitor = VPNHealthMonitor(),
        providerVPNManager: ProviderVPNManager? = nil,
        dryRun: Bool = false
    ) {
        self.networkKeys = networkKeys
        self.port = port
        self.vmManager = vmManager ?? SimpleVMManager(dryRun: dryRun)
        self.vpnHealthMonitor = vpnHealthMonitor
        self.providerVPNManager = providerVPNManager ?? ProviderVPNManager(dryRun: dryRun)

        var logger = Logger(label: "com.omerta.provider.udp-control")
        logger.logLevel = .info
        self.logger = logger

        if dryRun {
            logger.info("UDPControlServer initialized in DRY RUN mode")
        }

        logger.info("UDPControlServer initialized with \(networkKeys.count) network key(s)")
    }

    /// Add a network key for a specific network
    public func addNetworkKey(_ networkId: String, key: Data) {
        networkKeys[networkId] = key
        logger.info("Added network key", metadata: ["network_id": "\(networkId)"])
    }

    /// Remove a network key
    public func removeNetworkKey(_ networkId: String) {
        networkKeys.removeValue(forKey: networkId)
        logger.info("Removed network key", metadata: ["network_id": "\(networkId)"])
    }

    /// Get key for a network (used by message handler)
    func getNetworkKey(_ networkId: String) -> Data? {
        networkKeys[networkId]
    }

    // MARK: - Lifecycle

    /// Start UDP control server
    public func start() async throws {
        guard !isRunning else {
            logger.warning("UDP control server already running")
            return
        }

        logger.info("Starting UDP control server", metadata: ["port": "\(port)"])

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.eventLoopGroup = group

        // Create the message handler
        let handler = ServerMessageHandler(server: self, logger: logger)

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        do {
            let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
            self.channel = channel
            self.isRunning = true

            logger.info("UDP control server listening", metadata: ["port": "\(port)"])
        } catch {
            logger.error("UDP control server failed to start", metadata: ["error": "\(error)"])
            try? group.syncShutdownGracefully()
            self.eventLoopGroup = nil
            throw error
        }
    }

    /// Stop UDP control server
    public func stop() async {
        guard isRunning else {
            logger.warning("UDP control server not running")
            return
        }

        logger.info("Stopping UDP control server")

        try? channel?.close().wait()
        channel = nil

        try? eventLoopGroup?.syncShutdownGracefully()
        eventLoopGroup = nil

        isRunning = false

        logger.info("UDP control server stopped")
    }

    // MARK: - Message Handling (called by handler)

    /// Handle incoming encrypted control message and return response
    func handleIncomingMessage(_ data: Data, from remoteAddress: SocketAddress) async -> Data? {
        do {
            // Parse envelope to get networkId
            guard let envelope = MessageEnvelope.parse(data) else {
                logger.warning("Failed to parse message envelope", metadata: ["from": "\(remoteAddress)"])
                return nil
            }

            let networkId = envelope.networkId

            // Look up key for this network
            guard let networkKey = networkKeys[networkId] else {
                logger.warning("Unknown network ID", metadata: [
                    "network_id": "\(networkId)",
                    "from": "\(remoteAddress)"
                ])
                return nil
            }

            // Decrypt message
            let message = try decryptMessage(envelope.encryptedPayload, using: networkKey)

            logger.info("Received control message", metadata: [
                "action": "\(message.action)",
                "message_id": "\(message.messageId)",
                "network_id": "\(networkId)",
                "from": "\(remoteAddress)"
            ])

            // Verify timestamp (prevent replay attacks)
            let now = UInt64(Date().timeIntervalSince1970)
            let timeDiff = abs(Int64(now) - Int64(message.timestamp))
            guard timeDiff < 60 else {
                logger.warning("Message timestamp too old - possible replay attack", metadata: [
                    "time_diff": "\(timeDiff)"
                ])
                return nil
            }

            // Handle action (pass networkId for VM tracking)
            let response = try await handleAction(message.action, networkId: networkId)

            // Send response wrapped in envelope
            let responseMessage = ControlMessage(action: response)
            let encrypted = try encryptMessage(responseMessage, using: networkKey)
            let responseEnvelope = MessageEnvelope(networkId: networkId, encryptedPayload: encrypted)

            logger.info("Response prepared successfully")
            return responseEnvelope.serialize()

        } catch {
            logger.error("Error handling message", metadata: ["error": "\(error)"])
            // Can't send error response since we might not have the right key
            return nil
        }
    }

    /// Handle specific control action
    private func handleAction(_ action: ControlAction, networkId: String) async throws -> ControlAction {
        switch action {
        case .requestVM(let request):
            return try await handleRequestVM(request, networkId: networkId)

        case .releaseVM(let request):
            return try await handleReleaseVM(request)

        case .queryVMStatus(let request):
            return try await handleQueryVMStatus(request)

        case .vmCreated, .vmReleased, .vmStatus:
            throw ProviderError.unexpectedMessage("Received response message on server")
        }
    }

    /// Handle VM request
    private func handleRequestVM(_ request: RequestVMMessage, networkId: String) async throws -> ControlAction {
        logger.info("Handling VM request", metadata: [
            "vm_id": "\(request.vmId)",
            "network_id": "\(networkId)",
            "consumer_endpoint": "\(request.consumerEndpoint)",
            "ssh_user": "\(request.sshUser)"
        ])

        // 1. Verify resources available
        guard canFulfillRequirements(request.requirements) else {
            logger.warning("Insufficient resources for VM request")
            throw ProviderError.insufficientResources
        }

        // 2. Start VM with requirements and consumer's SSH key
        // With TAP networking, VM gets VPN IP directly
        // The provider acts as gateway at .254 in the VPN subnet
        let vmVPNIP = request.vpnConfig.vmVPNIP
        let providerVPNIP = deriveProviderIP(from: vmVPNIP)

        logger.info("Starting VM with TAP networking", metadata: [
            "vm_id": "\(request.vmId)",
            "vpn_ip": "\(vmVPNIP)",
            "gateway": "\(providerVPNIP)"
        ])

        let vmIP = try await vmManager.startVM(
            vmId: request.vmId,
            requirements: request.requirements,
            sshPublicKey: request.sshPublicKey,
            sshUser: request.sshUser,
            vpnIP: vmVPNIP,
            vpnGateway: providerVPNIP
        )

        logger.info("VM started successfully", metadata: [
            "vm_id": "\(request.vmId)",
            "vm_ip": "\(vmIP)",
            "vpn_ip": "\(vmVPNIP)",
            "using_nat": "\(vmIP != vmVPNIP)"
        ])

        // 3. Create VPN tunnel connecting to consumer's WireGuard server
        // - TAP networking (Linux): route directly to the TAP interface (no NAT)
        // - NAT networking (macOS/SLIRP): use DNAT to forward VPN IP to VM's NAT IP
        let vpnInterface = "wg-\(request.vmId.uuidString.prefix(8))"
        let tapInterface = "tap-\(request.vmId.uuidString.prefix(8))"
        let providerPublicKey: String

        // If VM's actual IP differs from VPN IP, we need NAT routing
        let vmNATIP: String? = (vmIP != vmVPNIP) ? vmIP : nil

        do {
            providerPublicKey = try await providerVPNManager.createTunnel(
                vmId: request.vmId,
                vpnConfig: request.vpnConfig,
                tapInterface: tapInterface,
                vmNATIP: vmNATIP
            )
            logger.info("VPN tunnel created", metadata: [
                "vm_id": "\(request.vmId)",
                "interface": "\(vpnInterface)"
            ])
        } catch {
            // VPN setup failed - clean up VM
            logger.error("VPN tunnel creation failed, cleaning up VM", metadata: [
                "vm_id": "\(request.vmId)",
                "error": "\(error)"
            ])
            try? await vmManager.stopVM(vmId: request.vmId)
            throw ProviderError.vpnSetupFailed("Failed to create VPN tunnel: \(error)")
        }

        // 4. Start VPN health monitoring
        await vpnHealthMonitor.startMonitoring(
            vmId: request.vmId,
            vpnInterface: vpnInterface,
            consumerPublicKey: request.vpnConfig.consumerPublicKey
        ) { [weak self] deadVmId in
            guard let self = self else { return }

            await self.logger.error("VPN tunnel died - killing VM", metadata: [
                "vm_id": "\(deadVmId)"
            ])

            // Clean up VPN tunnel
            try? await self.providerVPNManager.destroyTunnel(vmId: deadVmId)

            // Kill VM
            try? await self.vmManager.stopVM(vmId: deadVmId)

            // Remove from tracking
            await self.removeVM(deadVmId)
        }

        logger.info("VPN health monitoring started", metadata: ["vm_id": "\(request.vmId)"])

        // 5. Track active VM
        // Consumer accesses VM via the VPN IP
        let activeVM = ActiveVM(
            vmId: request.vmId,
            networkId: networkId,
            consumerEndpoint: request.consumerEndpoint,
            vpnConfig: request.vpnConfig,
            vmIP: vmVPNIP,
            tapInterface: tapInterface,
            vpnInterface: vpnInterface,
            providerPublicKey: providerPublicKey,
            createdAt: Date()
        )
        activeVMs[request.vmId] = activeVM

        // 6. Return response with provider's public key
        // Consumer needs this to add provider as a peer on their WireGuard server
        let response = VMCreatedResponse(
            vmId: request.vmId,
            vmIP: vmVPNIP,
            sshPort: 22,
            providerPublicKey: providerPublicKey
        )

        return .vmCreated(response)
    }

    /// Handle VM release
    private func handleReleaseVM(_ request: ReleaseVMMessage) async throws -> ControlAction {
        logger.info("Handling VM release", metadata: ["vm_id": "\(request.vmId)"])

        guard let vm = activeVMs[request.vmId] else {
            logger.warning("VM not found", metadata: ["vm_id": "\(request.vmId)"])
            throw ProviderError.vmNotFound(request.vmId)
        }

        // 1. Stop VPN health monitoring
        await vpnHealthMonitor.stopMonitoring(vmId: request.vmId)
        logger.info("VPN health monitoring stopped", metadata: ["vm_id": "\(request.vmId)"])

        // 2. Destroy VPN tunnel (includes NAT cleanup and firewall rules)
        do {
            try await providerVPNManager.destroyTunnel(vmId: request.vmId)
            logger.info("VPN tunnel destroyed", metadata: [
                "vm_id": "\(request.vmId)",
                "interface": "\(vm.vpnInterface)"
            ])
        } catch {
            logger.warning("Failed to destroy VPN tunnel", metadata: [
                "vm_id": "\(request.vmId)",
                "error": "\(error)"
            ])
            // Continue with cleanup even if VPN teardown fails
        }

        // 3. Kill the VM
        do {
            try await vmManager.stopVM(vmId: request.vmId)
            logger.info("VM stopped", metadata: ["vm_id": "\(request.vmId)"])
        } catch {
            logger.warning("Failed to stop VM", metadata: [
                "vm_id": "\(request.vmId)",
                "error": "\(error)"
            ])
            // Continue with cleanup even if VM stop fails
        }

        // 4. Remove from tracking
        removeVM(request.vmId)

        logger.info("VM released successfully", metadata: ["vm_id": "\(request.vmId)"])

        // 5. Return response
        let response = VMReleasedResponse(vmId: request.vmId)
        return .vmReleased(response)
    }

    /// Handle VM status query
    private func handleQueryVMStatus(_ request: VMStatusRequest) async throws -> ControlAction {
        logger.info("Handling VM status query", metadata: [
            "vm_id": "\(request.vmId?.uuidString ?? "all")"
        ])

        var vmInfos: [VMInfo] = []

        if let vmId = request.vmId {
            // Query specific VM
            if let activeVM = activeVMs[vmId] {
                let info = await buildVMInfo(vmId: vmId, activeVM: activeVM)
                vmInfos.append(info)
            }
        } else {
            // Query all VMs
            for (vmId, activeVM) in activeVMs {
                let info = await buildVMInfo(vmId: vmId, activeVM: activeVM)
                vmInfos.append(info)
            }
        }

        let response = VMStatusResponse(vms: vmInfos)
        return .vmStatus(response)
    }

    /// Build VMInfo for a specific VM
    private func buildVMInfo(vmId: UUID, activeVM: ActiveVM) async -> VMInfo {
        // Check if VM is actually running
        let isRunning = await vmManager.isVMRunning(vmId: vmId)
        let status: VMStatus = isRunning ? .running : .stopped

        let uptimeSeconds = Int(Date().timeIntervalSince(activeVM.createdAt))

        return VMInfo(
            vmId: vmId,
            status: status,
            vmIP: activeVM.vmIP,
            createdAt: activeVM.createdAt,
            uptimeSeconds: uptimeSeconds,
            consoleOutput: nil  // TODO: Capture console output
        )
    }

    // MARK: - Resource Management

    /// Check if provider can fulfill requirements
    private func canFulfillRequirements(_ requirements: ResourceRequirements) -> Bool {
        // TODO: Implement actual resource checking
        // For now, accept all requests
        return true
    }

    // MARK: - Encryption

    /// Encrypt control message using ChaCha20-Poly1305
    private func encryptMessage(_ message: ControlMessage, using networkKey: Data) throws -> Data {
        // Encode message to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(message)

        // Encrypt with ChaCha20-Poly1305
        let key = SymmetricKey(data: networkKey)
        let nonce = ChaChaPoly.Nonce()
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

        // Return combined format: [nonce][ciphertext][tag]
        return sealedBox.combined
    }

    /// Decrypt control message
    private func decryptMessage(_ data: Data, using networkKey: Data) throws -> ControlMessage {
        // Decrypt with ChaCha20-Poly1305
        let key = SymmetricKey(data: networkKey)
        let sealedBox = try ChaChaPoly.SealedBox(combined: data)
        let plaintext = try ChaChaPoly.open(sealedBox, using: key)

        // Decode from JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ControlMessage.self, from: plaintext)
    }

    // MARK: - VM Management

    /// Remove a VM from tracking
    private func removeVM(_ vmId: UUID) {
        activeVMs.removeValue(forKey: vmId)
        logger.info("VM removed from tracking", metadata: ["vm_id": "\(vmId)"])
    }

    // MARK: - Status

    /// Get server status
    public func getStatus() -> ServerStatus {
        ServerStatus(
            isRunning: isRunning,
            port: port,
            activeVMs: activeVMs.count
        )
    }

    public struct ServerStatus: Sendable {
        public let isRunning: Bool
        public let port: UInt16
        public let activeVMs: Int
    }

    /// Derive provider's VPN IP from VM's VPN IP
    /// Provider uses .254 to avoid conflicts with consumer (.1) and VMs (.2, .3, etc)
    private func deriveProviderIP(from vmVPNIP: String) -> String {
        let components = vmVPNIP.split(separator: ".")
        guard components.count == 4 else {
            return "10.99.0.254"
        }
        return "\(components[0]).\(components[1]).\(components[2]).254"
    }
}

// MARK: - NIO Message Handler

/// Handler for incoming UDP messages
private final class ServerMessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let server: UDPControlServer
    private let logger: Logger

    init(server: UDPControlServer, logger: Logger) {
        self.server = server
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let remoteAddress = envelope.remoteAddress

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let messageData = Data(bytes)

        // Capture allocator before async to avoid event loop issues
        let allocator = context.channel.allocator
        let eventLoop = context.eventLoop

        // Handle message asynchronously
        Task {
            if let responseData = await server.handleIncomingMessage(messageData, from: remoteAddress) {
                // Write response on event loop
                eventLoop.execute {
                    var responseBuffer = allocator.buffer(capacity: responseData.count)
                    responseBuffer.writeBytes(responseData)

                    let responseEnvelope = AddressedEnvelope(remoteAddress: remoteAddress, data: responseBuffer)
                    context.writeAndFlush(self.wrapOutboundOut(responseEnvelope), promise: nil)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Channel error", metadata: ["error": "\(error)"])
    }
}

// MARK: - Provider Errors

public enum ProviderError: Error, CustomStringConvertible {
    case insufficientResources
    case vmNotFound(UUID)
    case unexpectedMessage(String)
    case vmCreationFailed(String)
    case vpnSetupFailed(String)

    public var description: String {
        switch self {
        case .insufficientResources:
            return "Insufficient resources to fulfill request"
        case .vmNotFound(let vmId):
            return "VM not found: \(vmId)"
        case .unexpectedMessage(let msg):
            return "Unexpected message: \(msg)"
        case .vmCreationFailed(let reason):
            return "VM creation failed: \(reason)"
        case .vpnSetupFailed(let reason):
            return "VPN setup failed: \(reason)"
        }
    }
}
