import Foundation
import Logging
import OmertaCore
import OmertaVPN

// MARK: - Direct Provider Connection

/// Simplified client for direct provider connections (no network discovery)
/// Used for testing and direct provider access
public actor DirectProviderClient {
    private let ephemeralVPN: EphemeralVPN
    private let networkKey: Data
    private let logger: Logger
    private let dryRun: Bool
    private var activeVMs: [UUID: VMConnection] = [:]

    public init(networkKey: Data, dryRun: Bool = false) {
        self.ephemeralVPN = EphemeralVPN(dryRun: dryRun)
        self.networkKey = networkKey
        self.dryRun = dryRun

        var logger = Logger(label: "com.omerta.direct-client")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Request a VM directly from a provider endpoint
    public func requestVM(
        fromProvider providerEndpoint: String,
        sshPublicKey: String,
        sshKeyPath: String = "~/.omerta/ssh/id_ed25519",
        sshUser: String = "omerta",
        timeout: TimeInterval = 60.0
    ) async throws -> VMConnection {
        logger.info("Requesting VM directly from provider", metadata: [
            "provider": "\(providerEndpoint)"
        ])

        // 1. Create VPN tunnel
        let vmId = UUID()
        let vpnConfig = try await ephemeralVPN.createVPNForJob(vmId, providerEndpoint: providerEndpoint)
        logger.info("VPN tunnel created", metadata: ["vm_id": "\(vmId)"])

        do {
            // 2. Determine consumer endpoint
            let consumerEndpoint = try await determineConsumerEndpoint()

            // 3. Send request to provider (no encryption for direct mode)
            let response = try await sendDirectRequest(
                to: providerEndpoint,
                vmId: vmId,
                vpnConfig: vpnConfig,
                consumerEndpoint: consumerEndpoint,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser,
                timeout: timeout
            )

            // 4. Add provider as peer
            try await ephemeralVPN.addProviderPeer(
                jobId: vmId,
                providerPublicKey: response.providerPublicKey
            )

            // 5. Build connection info
            let connection = VMConnection(
                vmId: vmId,
                provider: PeerInfo(peerId: "direct", endpoint: providerEndpoint),
                vmIP: response.vmIP,
                sshKeyPath: sshKeyPath,
                sshUser: sshUser,
                vpnInterface: "wg\(vmId.uuidString.prefix(8))",
                createdAt: Date(),
                networkId: "direct"
            )

            activeVMs[vmId] = connection
            logger.info("VM request completed", metadata: [
                "vm_id": "\(vmId)",
                "vm_ip": "\(response.vmIP)"
            ])

            return connection
        } catch {
            logger.warning("VM request failed, cleaning up VPN", metadata: [
                "vm_id": "\(vmId)",
                "error": "\(error)"
            ])
            try? await ephemeralVPN.destroyVPN(for: vmId)
            throw error
        }
    }

    /// Release a VM by ID
    public func releaseVM(vmId: UUID) async throws {
        guard let connection = activeVMs[vmId] else {
            logger.warning("VM not found for release", metadata: ["vm_id": "\(vmId)"])
            return
        }

        // Tell provider to release
        try? await sendReleaseRequest(to: connection.provider.endpoint, vmId: vmId)

        // Tear down VPN
        try await ephemeralVPN.destroyVPN(for: vmId)

        activeVMs.removeValue(forKey: vmId)
        logger.info("VM released", metadata: ["vm_id": "\(vmId)"])
    }

    // MARK: - Private

    private func determineConsumerEndpoint() async throws -> String {
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

    private func sendDirectRequest(
        to endpoint: String,
        vmId: UUID,
        vpnConfig: VPNConfiguration,
        consumerEndpoint: String,
        sshPublicKey: String,
        sshUser: String,
        timeout: TimeInterval
    ) async throws -> VMCreatedResponse {
        let udpClient = UDPControlClient(networkId: "direct", networkKey: networkKey)

        return try await udpClient.requestVM(
            providerEndpoint: endpoint,
            vmId: vmId,
            requirements: ResourceRequirements(),
            vpnConfig: vpnConfig,
            consumerEndpoint: consumerEndpoint,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser
        )
    }

    private func sendReleaseRequest(to endpoint: String, vmId: UUID) async throws {
        let udpClient = UDPControlClient(networkId: "direct", networkKey: networkKey)
        try await udpClient.releaseVM(providerEndpoint: endpoint, vmId: vmId)
    }
}
