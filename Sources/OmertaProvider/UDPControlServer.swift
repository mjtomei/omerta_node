import Foundation
import Network
import Crypto
import Logging
import OmertaCore
import OmertaConsumer
import OmertaNetwork
import OmertaVM

/// Server for handling encrypted UDP control messages from consumers
/// Manages VM lifecycle in response to requestVM/releaseVM commands
public actor UDPControlServer {
    private let networkKey: Data
    private let port: UInt16
    private let logger: Logger
    private var listener: NWListener?
    private var isRunning: Bool = false

    // VM management
    private let vmManager: SimpleVMManager
    private let vpnHealthMonitor: VPNHealthMonitor

    // VM tracking
    private var activeVMs: [UUID: ActiveVM] = [:]

    private struct ActiveVM {
        let vmId: UUID
        let consumerEndpoint: String
        let vpnConfig: VPNConfiguration
        let vmIP: String
        let vpnInterface: String
        let createdAt: Date
    }

    public init(
        networkKey: Data,
        port: UInt16 = 51820,
        vmManager: SimpleVMManager = SimpleVMManager(),
        vpnHealthMonitor: VPNHealthMonitor = VPNHealthMonitor()
    ) {
        self.networkKey = networkKey
        self.port = port
        self.vmManager = vmManager
        self.vpnHealthMonitor = vpnHealthMonitor

        var logger = Logger(label: "com.omerta.provider.udp-control")
        logger.logLevel = .info
        self.logger = logger
    }

    // MARK: - Lifecycle

    /// Start UDP control server
    public func start() async throws {
        guard !isRunning else {
            logger.warning("UDP control server already running")
            return
        }

        logger.info("Starting UDP control server", metadata: ["port": "\(port)"])

        let listener = try NWListener(using: .udp, on: NWEndpoint.Port(integerLiteral: port))

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }

            connection.start(queue: .global())

            // Handle incoming message
            connection.receiveMessage { data, _, _, error in
                if let error = error {
                    self.logger.error("Error receiving message", metadata: ["error": "\(error)"])
                    return
                }

                guard let data = data else { return }

                Task {
                    await self.handleIncomingMessage(data, from: connection)
                }
            }
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            Task {
                switch state {
                case .ready:
                    await self.logger.info("UDP control server listening", metadata: ["port": "\(self.port)"])
                case .failed(let error):
                    await self.logger.error("UDP control server failed", metadata: ["error": "\(error)"])
                case .cancelled:
                    await self.logger.info("UDP control server cancelled")
                default:
                    break
                }
            }
        }

        listener.start(queue: .global())
        self.listener = listener
        self.isRunning = true

        logger.info("UDP control server started successfully")
    }

    /// Stop UDP control server
    public func stop() async {
        guard isRunning else {
            logger.warning("UDP control server not running")
            return
        }

        logger.info("Stopping UDP control server")

        listener?.cancel()
        listener = nil
        isRunning = false

        logger.info("UDP control server stopped")
    }

    // MARK: - Message Handling

    /// Handle incoming encrypted control message
    private func handleIncomingMessage(_ data: Data, from connection: NWConnection) async {
        do {
            // Decrypt message
            let message = try decryptMessage(data)

            logger.info("Received control message", metadata: [
                "action": "\(message.action)",
                "message_id": "\(message.messageId)"
            ])

            // Verify timestamp (prevent replay attacks)
            let now = UInt64(Date().timeIntervalSince1970)
            let timeDiff = abs(Int64(now) - Int64(message.timestamp))
            guard timeDiff < 60 else {
                logger.warning("Message timestamp too old - possible replay attack", metadata: [
                    "time_diff": "\(timeDiff)"
                ])
                return
            }

            // Handle action
            let response = try await handleAction(message.action)

            // Send response
            let responseMessage = ControlMessage(action: response)
            let encrypted = try encryptMessage(responseMessage)

            connection.send(content: encrypted, completion: .contentProcessed { error in
                if let error = error {
                    self.logger.error("Failed to send response", metadata: ["error": "\(error)"])
                } else {
                    self.logger.info("Response sent successfully")
                }
            })

        } catch {
            logger.error("Error handling message", metadata: ["error": "\(error)"])

            // Try to send error response
            do {
                let errorResponse = ControlMessage(
                    action: .vmCreated(VMCreatedResponse(
                        vmId: UUID(),
                        vmIP: "",
                        sshPort: 0
                    ))
                )
                let encrypted = try encryptMessage(errorResponse)
                connection.send(content: encrypted, completion: .contentProcessed { _ in })
            } catch {
                logger.error("Failed to send error response", metadata: ["error": "\(error)"])
            }
        }
    }

    /// Handle specific control action
    private func handleAction(_ action: ControlAction) async throws -> ControlAction {
        switch action {
        case .requestVM(let request):
            return try await handleRequestVM(request)

        case .releaseVM(let request):
            return try await handleReleaseVM(request)

        case .vmCreated, .vmReleased:
            throw ProviderError.unexpectedMessage("Received response message on server")
        }
    }

    /// Handle VM request
    private func handleRequestVM(_ request: RequestVMMessage) async throws -> ControlAction {
        logger.info("Handling VM request", metadata: [
            "vm_id": "\(request.vmId)",
            "consumer_endpoint": "\(request.consumerEndpoint)"
        ])

        // 1. Verify resources available
        guard canFulfillRequirements(request.requirements) else {
            logger.warning("Insufficient resources for VM request")
            throw ProviderError.insufficientResources
        }

        // 2. Start VM with requirements
        logger.info("Starting VM", metadata: ["vm_id": "\(request.vmId)"])
        let vmIP = try await vmManager.startVM(
            vmId: request.vmId,
            requirements: request.requirements,
            vpnConfig: request.vpnConfig
        )

        logger.info("VM started successfully", metadata: [
            "vm_id": "\(request.vmId)",
            "vm_ip": "\(vmIP)"
        ])

        // 3. Extract consumer public key from VPN config
        let consumerPublicKey = String(data: request.vpnConfig.publicKey, encoding: .utf8) ?? ""

        // 4. Start VPN health monitoring
        let vpnInterface = "wg-\(request.vmId.uuidString.prefix(8))"
        await vpnHealthMonitor.startMonitoring(
            vmId: request.vmId,
            vpnInterface: vpnInterface,
            consumerPublicKey: consumerPublicKey
        ) { [weak self] deadVmId in
            guard let self = self else { return }

            await self.logger.error("VPN tunnel died - killing VM", metadata: [
                "vm_id": "\(deadVmId)"
            ])

            // Kill VM
            try? await self.vmManager.stopVM(vmId: deadVmId)

            // Remove from tracking
            await self.removeVM(deadVmId)

            // TODO: Notify consumer of VM death
        }

        logger.info("VPN health monitoring started", metadata: ["vm_id": "\(request.vmId)"])

        // 5. Track active VM
        let activeVM = ActiveVM(
            vmId: request.vmId,
            consumerEndpoint: request.consumerEndpoint,
            vpnConfig: request.vpnConfig,
            vmIP: vmIP,
            vpnInterface: vpnInterface,
            createdAt: Date()
        )
        activeVMs[request.vmId] = activeVM

        // 6. Return response
        let response = VMCreatedResponse(
            vmId: request.vmId,
            vmIP: vmIP,
            sshPort: 22
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

        // 2. Kill the VM
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

        // 3. Tear down VPN interface
        do {
            try await tearDownVPNInterface(vm.vpnInterface)
            logger.info("VPN interface torn down", metadata: [
                "vm_id": "\(request.vmId)",
                "interface": "\(vm.vpnInterface)"
            ])
        } catch {
            logger.warning("Failed to tear down VPN interface", metadata: [
                "vm_id": "\(request.vmId)",
                "interface": "\(vm.vpnInterface)",
                "error": "\(error)"
            ])
            // Continue even if VPN teardown fails
        }

        // 4. Remove from tracking
        removeVM(request.vmId)

        logger.info("VM released successfully", metadata: ["vm_id": "\(request.vmId)"])

        // 5. Return response
        let response = VMReleasedResponse(vmId: request.vmId)
        return .vmReleased(response)
    }

    /// Tear down WireGuard VPN interface
    private func tearDownVPNInterface(_ interfaceName: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        let pathValue = WireGuardPaths.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.arguments = ["env", "PATH=\(pathValue)", WireGuardPaths.wgQuick, "down", interfaceName]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ProviderError.vpnSetupFailed("Failed to tear down \(interfaceName): \(output)")
        }
    }

    // MARK: - Resource Management

    /// Check if provider can fulfill requirements
    private func canFulfillRequirements(_ requirements: ResourceRequirements) -> Bool {
        // TODO: Implement actual resource checking
        // For now, accept all requests
        return true
    }

    /// Generate VM IP address in VPN network
    private func generateVMIP() -> String {
        // Simple IP allocation: 10.99.0.x where x = number of active VMs + 2
        let offset = activeVMs.count + 2
        return "10.99.0.\(offset)"
    }

    // MARK: - Encryption

    /// Encrypt control message using ChaCha20-Poly1305
    private func encryptMessage(_ message: ControlMessage) throws -> Data {
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
    private func decryptMessage(_ data: Data) throws -> ControlMessage {
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
