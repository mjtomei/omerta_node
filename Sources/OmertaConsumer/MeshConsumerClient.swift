import Foundation
import Logging
import NIOCore
import NIOPosix
import OmertaCore
import OmertaVPN
import OmertaMesh

#if canImport(Darwin)
import Darwin
private let systemSocket = Darwin.socket
private let systemBind = Darwin.bind
private let systemClose = Darwin.close
private let systemSendto = Darwin.sendto
private let systemRecvfrom = Darwin.recvfrom
private let SOCK_DGRAM_VALUE = SOCK_DGRAM
#elseif canImport(Glibc)
import Glibc
private let systemSocket = Glibc.socket
private let systemBind = Glibc.bind
private let systemClose = Glibc.close
private let systemSendto = Glibc.sendto
private let systemRecvfrom = Glibc.recvfrom
private let SOCK_DGRAM_VALUE = Int32(SOCK_DGRAM.rawValue)
#endif

/// Lightweight consumer client for VM requests
/// Uses direct encrypted UDP communication - no full mesh protocol stack
public actor MeshConsumerClient {
    // MARK: - Properties

    /// Our identity for signing messages
    private let identity: OmertaMesh.IdentityKeypair

    /// Network key for encryption
    private let networkKey: Data

    /// Provider peer ID
    private let providerPeerId: String

    /// Provider endpoint (ip:port)
    private let providerEndpoint: String

    /// Ephemeral VPN manager
    private let ephemeralVPN: EphemeralVPN

    /// VM tracker for persistence
    private let vmTracker: VMTracker

    /// Logger
    private let logger: Logger

    /// Dry run mode
    private let dryRun: Bool

    // MARK: - Initialization

    /// Create a mesh consumer client for a specific provider
    /// - Parameters:
    ///   - identity: Our cryptographic identity for signing
    ///   - networkKey: 32-byte network key for encryption
    ///   - providerPeerId: The provider's peer ID
    ///   - providerEndpoint: The provider's endpoint (ip:port)
    ///   - persistencePath: Path to persist active VM info
    ///   - dryRun: If true, don't actually create VPN tunnels
    public init(
        identity: OmertaMesh.IdentityKeypair,
        networkKey: Data,
        providerPeerId: String,
        providerEndpoint: String,
        persistencePath: String = "~/.omerta/vms/active.json",
        dryRun: Bool = false
    ) {
        self.identity = identity
        self.networkKey = networkKey
        self.providerPeerId = providerPeerId
        self.providerEndpoint = providerEndpoint
        self.ephemeralVPN = EphemeralVPN(dryRun: dryRun)
        self.vmTracker = VMTracker(persistencePath: persistencePath)
        self.dryRun = dryRun

        var logger = Logger(label: "io.omerta.consumer.mesh")
        logger.logLevel = .info
        self.logger = logger
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
        logger.info("Requesting VM from provider", metadata: [
            "provider": "\(providerPeerId.prefix(16))...",
            "endpoint": "\(providerEndpoint)",
            "timeoutMinutes": "\(timeoutMinutes)"
        ])

        // 1. Create VPN tunnel
        let vmId = UUID()
        let vpnConfig = try await ephemeralVPN.createVPNForJob(vmId, providerEndpoint: providerEndpoint)
        logger.info("VPN tunnel created", metadata: ["vmId": "\(vmId)"])

        do {
            // 2. Build VM request
            let request = MeshVMRequest(
                vmId: vmId,
                requirements: requirements,
                consumerPublicKey: vpnConfig.consumerPublicKey,
                consumerEndpoint: vpnConfig.consumerEndpoint,
                consumerVPNIP: vpnConfig.consumerVPNIP,
                vmVPNIP: vpnConfig.vmVPNIP,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser,
                timeoutMinutes: timeoutMinutes
            )

            let requestData = try JSONEncoder().encode(request)

            // 3. Send request and wait for response (direct UDP)
            guard let responseData = try await sendAndReceive(data: requestData, timeout: 60) else {
                throw MeshConsumerError.noResponse
            }

            let vmResponse = try JSONDecoder().decode(MeshVMResponse.self, from: responseData)

            if let error = vmResponse.error {
                throw MeshConsumerError.providerError(error)
            }

            guard let providerPublicKey = vmResponse.providerPublicKey else {
                throw MeshConsumerError.invalidResponse
            }

            // Use the WireGuard tunnel IP we assigned
            let sshIP = vpnConfig.vmVPNIP

            logger.info("Provider response received", metadata: [
                "vmId": "\(vmId)",
                "sshIP": "\(sshIP)",
                "providerReportedIP": "\(vmResponse.vmIP ?? "none")"
            ])

            // 4. Add provider as peer on consumer's WireGuard
            try await ephemeralVPN.addProviderPeer(
                jobId: vmId,
                providerPublicKey: providerPublicKey
            )

            // 5. Build connection info
            let vmConnection = VMConnection(
                vmId: vmId,
                provider: PeerInfo(peerId: providerPeerId, endpoint: providerEndpoint),
                vmIP: sshIP,
                sshKeyPath: sshKeyPath,
                sshUser: sshUser,
                vpnInterface: "wg\(vmId.uuidString.prefix(8))",
                createdAt: Date(),
                networkId: "mesh"
            )

            // 6. Track VM
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
            _ = try await sendAndReceive(data: requestData, timeout: 10)
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

    // MARK: - Private Methods

    /// Send encrypted data and wait for encrypted response via direct UDP
    private func sendAndReceive(data: Data, timeout: TimeInterval) async throws -> Data? {
        // Create UDP socket
        let sock = systemSocket(AF_INET, SOCK_DGRAM_VALUE, 0)
        guard sock >= 0 else {
            throw MeshConsumerError.connectionFailed(reason: "Failed to create socket")
        }
        defer { systemClose(sock) }

        // Bind to random port
        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0  // Random port
        bindAddr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                systemBind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw MeshConsumerError.connectionFailed(reason: "Failed to bind socket")
        }

        // Set receive timeout
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Parse provider endpoint
        let parts = providerEndpoint.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            throw MeshConsumerError.connectionFailed(reason: "Invalid provider endpoint format")
        }
        let host = String(parts[0])

        // Resolve host to address
        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = port.bigEndian

        if inet_pton(AF_INET, host, &destAddr.sin_addr) != 1 {
            throw MeshConsumerError.connectionFailed(reason: "Invalid provider IP address")
        }

        // Create signed envelope
        let envelope = try MeshEnvelope.signed(
            from: identity,
            to: providerPeerId,
            payload: .data(data)
        )

        // Encode to JSON then encrypt
        let jsonData = try JSONEncoder().encode(envelope)
        let encryptedData = try MessageEncryption.encrypt(jsonData, key: networkKey)

        // Send encrypted data
        let sendResult = withUnsafePointer(to: &destAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                encryptedData.withUnsafeBytes { buffer in
                    systemSendto(sock, buffer.baseAddress!, buffer.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sendResult > 0 else {
            throw MeshConsumerError.connectionFailed(reason: "Failed to send data")
        }

        logger.debug("Sent \(encryptedData.count) bytes to \(providerEndpoint)")

        // Receive response
        var recvBuffer = [UInt8](repeating: 0, count: 65536)
        var srcAddr = sockaddr_in()
        var srcAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let recvResult = withUnsafeMutablePointer(to: &srcAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                systemRecvfrom(sock, &recvBuffer, recvBuffer.count, 0, sockaddrPtr, &srcAddrLen)
            }
        }

        guard recvResult > 0 else {
            // Timeout or error
            return nil
        }

        let receivedData = Data(recvBuffer.prefix(recvResult))
        logger.debug("Received \(receivedData.count) bytes")

        // Decrypt response
        guard let decryptedData = try? MessageEncryption.decrypt(receivedData, key: networkKey) else {
            throw MeshConsumerError.invalidResponse
        }

        // Decode envelope
        guard let responseEnvelope = try? JSONDecoder().decode(MeshEnvelope.self, from: decryptedData) else {
            throw MeshConsumerError.invalidResponse
        }

        // Verify signature
        guard responseEnvelope.verifySignature() else {
            throw MeshConsumerError.invalidResponse
        }

        // Extract data payload
        if case .data(let responsePayload) = responseEnvelope.payload {
            return responsePayload
        }

        throw MeshConsumerError.invalidResponse
    }
}

// VM protocol messages are now in VMProtocolMessages.swift

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
