import Foundation
import Logging
import OmertaCore
import OmertaVPN
import OmertaMesh

/// Consumer client that uses the mesh network for NAT traversal and peer discovery
/// This allows connecting to providers behind NAT without manual port forwarding
public actor MeshConsumerClient {
    // MARK: - Properties

    /// The underlying mesh network
    public let mesh: MeshNetwork

    /// Ephemeral VPN manager
    private let ephemeralVPN: EphemeralVPN

    /// VM tracker for persistence
    private let vmTracker: VMTracker

    /// Network key for control message encryption
    private let networkKey: Data

    /// Logger
    private let logger: Logger

    /// Dry run mode
    private let dryRun: Bool

    /// Whether the mesh network is started
    private var isStarted: Bool = false

    // MARK: - Initialization

    /// Create a mesh consumer client
    /// - Parameters:
    ///   - config: Omerta configuration (must have mesh config)
    ///   - persistencePath: Path to persist active VM info
    ///   - dryRun: If true, don't actually create VPN tunnels
    public init(
        config: OmertaConfig,
        persistencePath: String = "~/.omerta/vms/active.json",
        dryRun: Bool = false
    ) throws {
        guard let meshOptions = config.mesh, meshOptions.enabled else {
            throw MeshConsumerError.meshNotEnabled
        }

        guard let keyData = config.localKeyData() else {
            throw MeshConsumerError.noNetworkKey
        }

        // Create MeshConfig from MeshConfigOptions with encryption key
        var meshConfig = MeshConfig(
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

        self.mesh = MeshNetwork(identity: identity, config: meshConfig)
        self.ephemeralVPN = EphemeralVPN(dryRun: dryRun)
        self.vmTracker = VMTracker(persistencePath: persistencePath)
        self.networkKey = keyData
        self.dryRun = dryRun

        var logger = Logger(label: "io.omerta.consumer.mesh")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Create a mesh consumer client with explicit mesh config
    /// - Parameters:
    ///   - identity: Our cryptographic identity (peer ID derived from public key)
    ///   - meshConfig: Mesh network configuration
    ///   - networkKey: Network key for encryption
    ///   - persistencePath: Path to persist active VM info
    ///   - dryRun: If true, don't actually create VPN tunnels
    public init(
        identity: OmertaMesh.IdentityKeypair,
        meshConfig: MeshConfig,
        networkKey: Data,
        persistencePath: String = "~/.omerta/vms/active.json",
        dryRun: Bool = false
    ) {
        self.mesh = MeshNetwork(identity: identity, config: meshConfig)
        self.ephemeralVPN = EphemeralVPN(dryRun: dryRun)
        self.vmTracker = VMTracker(persistencePath: persistencePath)
        self.networkKey = networkKey
        self.dryRun = dryRun

        var logger = Logger(label: "io.omerta.consumer.mesh")
        logger.logLevel = .info
        self.logger = logger
    }

    // MARK: - Lifecycle

    /// Start the mesh network
    public func start() async throws {
        guard !isStarted else {
            logger.warning("Mesh consumer client already started")
            return
        }

        logger.info("Starting mesh consumer client")
        try await mesh.start()
        isStarted = true
        let peerId = await mesh.peerId
        let natType = await mesh.currentNATType
        logger.info("Mesh consumer client started", metadata: [
            "peerId": "\(peerId)",
            "natType": "\(natType.rawValue)"
        ])
    }

    /// Stop the mesh network
    public func stop() async {
        guard isStarted else { return }

        logger.info("Stopping mesh consumer client")
        await mesh.stop()
        isStarted = false
        logger.info("Mesh consumer client stopped")
    }

    // MARK: - VM Operations

    /// Request a VM from a provider via mesh network
    /// - Parameters:
    ///   - providerPeerId: The provider's peer ID
    ///   - requirements: Resource requirements for the VM
    ///   - sshPublicKey: SSH public key to inject into VM
    ///   - sshKeyPath: Path to SSH private key
    ///   - sshUser: SSH username
    /// - Returns: VM connection info
    public func requestVM(
        fromProvider providerPeerId: String,
        requirements: ResourceRequirements = ResourceRequirements(),
        sshPublicKey: String,
        sshKeyPath: String = "~/.omerta/ssh/id_ed25519",
        sshUser: String = "omerta"
    ) async throws -> VMConnection {
        guard isStarted else {
            throw MeshConsumerError.notStarted
        }

        logger.info("Requesting VM from provider via mesh", metadata: [
            "provider": "\(providerPeerId.prefix(16))..."
        ])

        // 1. Connect to provider via mesh (handles NAT traversal)
        let connection: DirectConnection
        do {
            connection = try await mesh.connect(to: providerPeerId)
            logger.info("Connected to provider", metadata: [
                "method": "\(connection.method)",
                "isDirect": "\(connection.isDirect)",
                "endpoint": "\(connection.endpoint)"
            ])
        } catch {
            logger.error("Failed to connect to provider via mesh", metadata: [
                "provider": "\(providerPeerId.prefix(16))...",
                "error": "\(error)"
            ])
            throw MeshConsumerError.connectionFailed(reason: error.localizedDescription)
        }

        // 2. Create VPN tunnel
        let vmId = UUID()
        let vpnConfig = try await ephemeralVPN.createVPNForJob(vmId, providerEndpoint: connection.endpoint)
        logger.info("VPN tunnel created", metadata: ["vmId": "\(vmId)"])

        do {
            // 3. Determine consumer endpoint
            let consumerEndpoint = try await determineConsumerEndpoint()

            // 4. Send VM request over mesh
            let request = MeshVMRequest(
                vmId: vmId,
                requirements: requirements,
                consumerPublicKey: vpnConfig.consumerPublicKey,
                consumerEndpoint: consumerEndpoint,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser
            )

            let requestData = try JSONEncoder().encode(request)
            let response = try await sendAndReceive(data: requestData, to: providerPeerId, timeout: 60)

            guard let responseData = response else {
                throw MeshConsumerError.noResponse
            }

            let vmResponse = try JSONDecoder().decode(MeshVMResponse.self, from: responseData)

            if let error = vmResponse.error {
                throw MeshConsumerError.providerError(error)
            }

            guard let vmIP = vmResponse.vmIP, let providerPublicKey = vmResponse.providerPublicKey else {
                throw MeshConsumerError.invalidResponse
            }

            logger.info("Provider response received", metadata: [
                "vmId": "\(vmId)",
                "vmIP": "\(vmIP)"
            ])

            // 5. Add provider as peer on consumer's WireGuard
            try await ephemeralVPN.addProviderPeer(
                jobId: vmId,
                providerPublicKey: providerPublicKey
            )

            // 6. Build connection info
            let vmConnection = VMConnection(
                vmId: vmId,
                provider: PeerInfo(peerId: providerPeerId, endpoint: connection.endpoint),
                vmIP: vmIP,
                sshKeyPath: sshKeyPath,
                sshUser: sshUser,
                vpnInterface: "wg\(vmId.uuidString.prefix(8))",
                createdAt: Date(),
                networkId: "mesh"
            )

            // 7. Track VM
            try await vmTracker.trackVM(vmConnection)

            logger.info("VM request completed", metadata: [
                "vmId": "\(vmId)",
                "sshCommand": "\(vmConnection.sshCommand)"
            ])

            return vmConnection

        } catch {
            // Clean up VPN on failure
            logger.warning("VM request failed, cleaning up", metadata: [
                "vmId": "\(vmId)",
                "error": "\(error)"
            ])
            try? await ephemeralVPN.destroyVPN(for: vmId)
            throw error
        }
    }

    /// Release a VM
    public func releaseVM(_ vmConnection: VMConnection, forceLocalCleanup: Bool = false) async throws {
        logger.info("Releasing VM", metadata: ["vmId": "\(vmConnection.vmId)"])

        // 1. Send release request to provider
        do {
            let request = MeshVMReleaseRequest(vmId: vmConnection.vmId)
            let requestData = try JSONEncoder().encode(request)
            _ = try await sendAndReceive(data: requestData, to: vmConnection.provider.peerId, timeout: 10)
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

        // 2. Tear down VPN
        try? await ephemeralVPN.destroyVPN(for: vmConnection.vmId)

        // 3. Stop tracking
        try await vmTracker.removeVM(vmConnection.vmId)

        logger.info("VM released", metadata: ["vmId": "\(vmConnection.vmId)"])
    }

    /// List active VMs
    public func listActiveVMs() async -> [VMConnection] {
        await vmTracker.getActiveVMs()
    }

    /// Get network statistics
    public func statistics() async -> MeshStatistics {
        await mesh.statistics()
    }

    /// Get known peers
    public func knownPeers() async -> [String] {
        await mesh.knownPeers()
    }

    /// Discover peers from bootstrap nodes
    public func discoverPeers() async throws {
        try await mesh.discoverPeers()
    }

    // MARK: - Private Methods

    /// Send data and wait for response
    private func sendAndReceive(data: Data, to peerId: String, timeout: TimeInterval) async throws -> Data? {
        // Create a response continuation
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                var responseData: Data?

                // Set up temporary message handler
                await mesh.setMessageHandler { from, receivedData in
                    if from == peerId {
                        responseData = receivedData
                    }
                }

                // Send the request
                do {
                    try await mesh.send(data, to: peerId)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Wait for response with timeout
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if let response = responseData {
                        continuation.resume(returning: response)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }

                continuation.resume(returning: nil)
            }
        }
    }

    /// Determine consumer endpoint for provider to connect back
    private func determineConsumerEndpoint() async throws -> String {
        // Use mesh public endpoint if available
        if let publicEndpoint = await mesh.currentPublicEndpoint {
            return publicEndpoint
        }

        // Fall back to local IP
        var ipAddress = "127.0.0.1"

        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        process.arguments = ["getifaddr", "en0"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                ipAddress = output
            }
        }
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/hostname")
        process.arguments = ["-I"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init) {
            ipAddress = output
        }
        #endif

        return "\(ipAddress):51821"
    }
}

// MARK: - Mesh VM Protocol Messages

/// VM request sent over mesh
struct MeshVMRequest: Codable {
    let type: String = "vm_request"
    let vmId: UUID
    let requirements: ResourceRequirements
    let consumerPublicKey: String
    let consumerEndpoint: String
    let sshPublicKey: String
    let sshUser: String
}

/// VM response received over mesh
struct MeshVMResponse: Codable {
    let type: String
    let vmId: UUID
    let vmIP: String?
    let providerPublicKey: String?
    let error: String?
}

/// VM release request sent over mesh
struct MeshVMReleaseRequest: Codable {
    let type: String = "vm_release"
    let vmId: UUID
}

// MARK: - Errors

/// Errors specific to mesh consumer client
public enum MeshConsumerError: Error, CustomStringConvertible {
    case meshNotEnabled
    case noNetworkKey
    case notStarted
    case connectionFailed(reason: String)
    case noResponse
    case invalidResponse
    case providerError(String)

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
        }
    }
}
