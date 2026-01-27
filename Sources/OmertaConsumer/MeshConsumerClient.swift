import Foundation
import Logging
import OmertaCore
import OmertaMesh

/// Channel names for VM protocol
public enum VMChannels {
    /// Channel for VM requests (consumer -> provider)
    public static let request = "vm-request"
    /// Channel for VM responses (provider -> consumer)
    /// Format: "vm-response-{consumerPeerId}"
    public static func response(for peerId: PeerId) -> String {
        "vm-response-\(peerId)"
    }
    /// Channel for VM ACKs (consumer -> provider)
    public static let ack = "vm-ack"
    /// Channel for VM release requests
    public static let release = "vm-release"
    /// Channel for VM heartbeats
    public static let heartbeat = "vm-heartbeat"
    /// Channel for provider shutdown notifications
    public static let shutdown = "vm-shutdown"
}

/// Lightweight consumer client for VM requests
/// Uses MeshNetwork channels for NAT-aware routing (IPv6 > direct > relay fallback)
/// Traffic to VMs is routed through the mesh tunnel (no WireGuard required)
public actor MeshConsumerClient {
    // MARK: - Properties

    /// The mesh network for communication
    private let meshNetwork: MeshNetwork

    /// Provider peer ID
    private let providerPeerId: PeerId

    /// Our peer ID for response channel
    private let myPeerId: PeerId

    /// VM tracker for persistence
    private let vmTracker: VMTracker

    /// Network ID for tracking
    private let networkId: String

    /// Logger
    private let logger: Logger

    /// Dry run mode
    private let dryRun: Bool

    /// Pending responses keyed by vmId
    private var pendingResponses: [UUID: CheckedContinuation<MeshVMResponse, Error>] = [:]

    /// Pending release responses keyed by vmId
    private var pendingReleaseResponses: [UUID: CheckedContinuation<Void, Error>] = [:]

    // MARK: - Initialization

    /// Create a mesh consumer client for a specific provider
    /// - Parameters:
    ///   - meshNetwork: The mesh network for communication (handles encryption and routing)
    ///   - providerPeerId: The provider's peer ID
    ///   - networkId: Network ID for VM tracking
    ///   - persistencePath: Path to persist active VM info
    ///   - dryRun: If true, don't actually create tunnels
    public init(
        meshNetwork: MeshNetwork,
        providerPeerId: PeerId,
        networkId: String,
        persistencePath: String = "~/.omerta/vms/active.json",
        dryRun: Bool = false
    ) async throws {
        // Reject self-request (consumer cannot request VM from itself)
        let myPeerId = await meshNetwork.peerId
        guard myPeerId != providerPeerId else {
            throw MeshConsumerError.selfRequestNotAllowed
        }

        self.meshNetwork = meshNetwork
        self.providerPeerId = providerPeerId
        self.myPeerId = myPeerId
        self.networkId = networkId
        self.vmTracker = VMTracker(persistencePath: persistencePath)
        self.dryRun = dryRun

        var logger = Logger(label: "io.omerta.consumer.mesh")
        logger.logLevel = .info
        self.logger = logger

        // Register response channel handler
        let responseChannel = VMChannels.response(for: myPeerId)
        try await meshNetwork.onChannel(responseChannel) { [weak self] fromMachine, data in
            await self?.handleResponse(from: fromMachine, data: data)
        }

        // Register shutdown notification handler
        try await meshNetwork.onChannel(VMChannels.shutdown) { [weak self] fromMachine, data in
            await self?.handleShutdownNotification(from: fromMachine, data: data)
        }

        logger.info("MeshConsumerClient initialized", metadata: [
            "provider": "\(providerPeerId.prefix(16))...",
            "responseChannel": "\(responseChannel)"
        ])
    }

    // MARK: - Response Handling

    /// Handle incoming response from provider
    private func handleResponse(from machineId: MachineId, data: Data) async {
        // Response channel is scoped to our peerId, so only our provider sends here
        // machineId identifies which provider machine responded

        // Try to decode as VM response
        if let response = try? JSONDecoder().decode(MeshVMResponse.self, from: data) {
            logger.debug("Received VM response", metadata: ["vmId": "\(response.vmId.uuidString.prefix(8))..."])
            if let continuation = pendingResponses.removeValue(forKey: response.vmId) {
                continuation.resume(returning: response)
            }
            return
        }

        // Try to decode as release response
        if let releaseResponse = try? JSONDecoder().decode(MeshVMReleaseResponse.self, from: data) {
            logger.debug("Received release response", metadata: ["vmId": "\(releaseResponse.vmId.uuidString.prefix(8))..."])
            if let continuation = pendingReleaseResponses.removeValue(forKey: releaseResponse.vmId) {
                if let error = releaseResponse.error {
                    continuation.resume(throwing: MeshConsumerError.providerError(error))
                } else {
                    continuation.resume()
                }
            }
            return
        }

        logger.warning("Unknown response type from provider")
    }

    // MARK: - Shutdown Handling

    /// Handle shutdown notification from provider
    private func handleShutdownNotification(from machineId: MachineId, data: Data) async {
        // Shutdown channel is broadcast, so we accept from any provider machine
        guard let notification = try? JSONDecoder().decode(MeshProviderShutdownNotification.self, from: data) else {
            logger.warning("Failed to decode shutdown notification")
            return
        }

        logger.warning("Provider shutting down, cleaning up VMs", metadata: [
            "vmCount": "\(notification.vmIds.count)",
            "reason": "\(notification.reason)"
        ])

        // Clean up tracked VMs for affected VMs
        for vmId in notification.vmIds {
            logger.info("Cleaning up VM due to provider shutdown", metadata: ["vmId": "\(vmId.uuidString.prefix(8))..."])
            try? await vmTracker.removeVM(vmId)
        }
    }

    // MARK: - VM Operations

    /// Request a VM from the provider
    /// - Parameters:
    ///   - requirements: Resource requirements for the VM
    ///   - sshPublicKey: SSH public key to inject into VM
    ///   - sshKeyPath: Path to SSH private key
    ///   - sshUser: SSH username
    /// - Returns: VM connection info
    public func requestVM(
        requirements: ResourceRequirements = ResourceRequirements(),
        sshPublicKey: String,
        sshKeyPath: String = "~/.omerta/ssh/id_ed25519",
        sshUser: String = "omerta",
        timeoutMinutes: Int = 10
    ) async throws -> VMConnection {
        // Get provider endpoint
        var providerEndpoint: String? = await meshNetwork.connection(to: providerPeerId)?.endpoint
        if providerEndpoint == nil {
            providerEndpoint = try? await meshNetwork.connect(to: providerPeerId).endpoint
        }
        guard let providerEndpoint else {
            throw MeshConsumerError.connectionFailed(reason: "Cannot reach provider \(providerPeerId.prefix(16))...")
        }

        logger.info("Requesting VM from provider", metadata: [
            "provider": "\(providerPeerId.prefix(16))...",
            "timeoutMinutes": "\(timeoutMinutes)"
        ])

        // Generate VM ID
        let vmId = UUID()

        // With the mesh tunnel approach, the VM gets an IP that routes through the mesh
        // The consumer and provider are already connected via the mesh network
        // No WireGuard keys needed - traffic goes through the encrypted mesh channel
        let vmTunnelIP = generateTunnelIP(for: vmId)

        do {
            // Build VM request (no WireGuard keys - using mesh tunnels)
            let request = MeshVMRequest(
                vmId: vmId,
                requirements: requirements,
                consumerPublicKey: "",  // Not needed - mesh handles encryption
                consumerEndpoint: "",   // Not needed - mesh handles routing
                consumerVPNIP: "",      // Not needed - using mesh tunnels
                vmVPNIP: vmTunnelIP,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser,
                timeoutMinutes: timeoutMinutes
            )

            let requestData = try JSONEncoder().encode(request)

            // Send request and wait for response (via channels)
            let vmResponse = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MeshVMResponse, Error>) in
                // Store continuation
                pendingResponses[vmId] = continuation

                // Set timeout
                Task {
                    try? await Task.sleep(for: .seconds(timeoutMinutes * 60))
                    if let cont = self.pendingResponses.removeValue(forKey: vmId) {
                        cont.resume(throwing: MeshConsumerError.noResponse)
                    }
                }

                // Send request on channel
                Task {
                    do {
                        try await self.meshNetwork.sendOnChannel(requestData, to: self.providerPeerId, channel: VMChannels.request)
                        self.logger.debug("Sent VM request on channel", metadata: ["vmId": "\(vmId)"])
                    } catch {
                        if let cont = self.pendingResponses.removeValue(forKey: vmId) {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }

            if let error = vmResponse.error {
                // Send negative ACK for error response
                await sendAck(vmId: vmId, success: false)
                throw MeshConsumerError.providerError(error)
            }

            // Use the mesh tunnel IP
            let sshIP = vmResponse.vmIP ?? vmTunnelIP

            logger.info("Provider response received", metadata: [
                "vmId": "\(vmId)",
                "sshIP": "\(sshIP)"
            ])

            // Send positive ACK to confirm we received the response
            await sendAck(vmId: vmId, success: true)

            // Build connection info (no VPN interface - using mesh tunnel)
            let vmConnection = VMConnection(
                vmId: vmId,
                provider: PeerInfo(peerId: providerPeerId, endpoint: providerEndpoint),
                vmIP: sshIP,
                sshKeyPath: sshKeyPath,
                sshUser: sshUser,
                vpnInterface: "mesh-\(vmId.uuidString.prefix(8))",  // Conceptual - traffic via mesh
                createdAt: Date(),
                networkId: networkId
            )

            // Track VM
            try await vmTracker.trackVM(vmConnection)

            logger.info("VM request completed", metadata: [
                "vmId": "\(vmId)",
                "sshCommand": "\(vmConnection.sshCommand)"
            ])

            return vmConnection

        } catch {
            logger.warning("VM request failed", metadata: [
                "vmId": "\(vmId)",
                "error": "\(error)"
            ])
            throw error
        }
    }

    /// Release a VM
    public func releaseVM(_ vmConnection: VMConnection, forceLocalCleanup: Bool = false) async throws {
        logger.info("Releasing VM", metadata: ["vmId": "\(vmConnection.vmId)"])

        // Send release request to provider
        do {
            let request = MeshVMReleaseRequest(vmId: vmConnection.vmId)
            let requestData = try JSONEncoder().encode(request)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Store continuation
                pendingReleaseResponses[vmConnection.vmId] = continuation

                // Set timeout
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if let cont = self.pendingReleaseResponses.removeValue(forKey: vmConnection.vmId) {
                        cont.resume(throwing: MeshConsumerError.noResponse)
                    }
                }

                // Send release on channel
                Task {
                    do {
                        try await self.meshNetwork.sendOnChannel(requestData, to: self.providerPeerId, channel: VMChannels.release)
                        self.logger.debug("Sent VM release on channel", metadata: ["vmId": "\(vmConnection.vmId)"])
                    } catch {
                        if let cont = self.pendingReleaseResponses.removeValue(forKey: vmConnection.vmId) {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }

            logger.info("Provider acknowledged release", metadata: ["vmId": "\(vmConnection.vmId)"])
        } catch {
            if !forceLocalCleanup {
                logger.error("Failed to release VM on provider", metadata: [
                    "vmId": "\(vmConnection.vmId)",
                    "error": "\(error)"
                ])
                throw error
            }
            logger.warning("Provider release failed, forcing local cleanup", metadata: [
                "vmId": "\(vmConnection.vmId)",
                "error": "\(error)"
            ])
        }

        // Stop tracking
        try await vmTracker.removeVM(vmConnection.vmId)

        logger.info("VM released", metadata: ["vmId": "\(vmConnection.vmId)"])
    }

    /// List active VMs
    public func listActiveVMs() async -> [VMConnection] {
        await vmTracker.getActiveVMs()
    }

    // MARK: - Private Methods

    /// Generate a tunnel IP for a VM based on its ID
    private func generateTunnelIP(for vmId: UUID) -> String {
        // Use job ID bytes to generate a unique IP in 10.x.y.2
        let jobBytes = withUnsafeBytes(of: vmId.uuid) { Array($0) }
        let subnetByte1 = Int(jobBytes[0] % 200) + 50  // 50-249
        let subnetByte2 = Int(jobBytes[1] % 250) + 1   // 1-250
        return "10.\(subnetByte1).\(subnetByte2).2"
    }

    /// Send ACK to provider confirming we received their response
    private func sendAck(vmId: UUID, success: Bool) async {
        let ack = MeshVMAck(vmId: vmId, success: success)

        guard let ackData = try? JSONEncoder().encode(ack) else {
            logger.warning("Failed to encode ACK")
            return
        }

        // Send ACK on channel (fire and forget)
        do {
            try await meshNetwork.sendOnChannel(ackData, to: providerPeerId, channel: VMChannels.ack)
            logger.debug("Sent ACK", metadata: [
                "vmId": "\(vmId.uuidString.prefix(8))...",
                "success": "\(success)"
            ])
        } catch {
            logger.warning("Failed to send ACK", metadata: [
                "vmId": "\(vmId.uuidString.prefix(8))...",
                "error": "\(error)"
            ])
        }
    }
}

// VM protocol messages are in VMProtocolMessages.swift

// MARK: - Errors

/// Errors specific to mesh consumer client
public enum MeshConsumerError: Error, LocalizedError, CustomStringConvertible {
    case meshNotEnabled
    case noNetworkKey
    case notStarted
    case connectionFailed(reason: String)
    case noResponse
    case invalidResponse
    case providerError(String)
    case selfRequestNotAllowed

    public var description: String {
        switch self {
        case .meshNotEnabled:
            return "Mesh networking is not enabled in config"
        case .noNetworkKey:
            return "No network key configured (run 'omerta init' first)"
        case .notStarted:
            return "Mesh consumer client not started (call start() first)"
        case .connectionFailed(let reason):
            return "Failed to connect to provider: \(reason)"
        case .noResponse:
            return "No response from provider (timeout)"
        case .invalidResponse:
            return "Invalid response from provider"
        case .providerError(let msg):
            return "Provider error: \(msg)"
        case .selfRequestNotAllowed:
            return "Cannot request VM from self (provider and consumer have same peer ID)"
        }
    }

    public var errorDescription: String? {
        return description
    }
}
