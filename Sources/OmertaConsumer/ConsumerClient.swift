import Foundation
import Logging
import OmertaCore
import OmertaNetwork

/// Main entry point for consumer operations
/// Handles VM lifecycle: request, track, and release VMs from providers
public actor ConsumerClient {
    private let peerSelector: PeerSelector
    private let udpControl: UDPControlClient
    private let ephemeralVPN: EphemeralVPN
    private let vmTracker: VMTracker
    private let networkKey: Data
    private let logger: Logger

    public init(
        peerRegistry: PeerRegistry,
        networkKey: Data,
        persistencePath: String = "~/.omerta/vms/active.json",
        dryRun: Bool = false
    ) {
        self.peerSelector = PeerSelector(peerRegistry: peerRegistry)
        self.udpControl = UDPControlClient(networkKey: networkKey)
        self.ephemeralVPN = EphemeralVPN(dryRun: dryRun)
        self.vmTracker = VMTracker(persistencePath: persistencePath)
        self.networkKey = networkKey

        var logger = Logger(label: "com.omerta.consumer")
        logger.logLevel = .info
        self.logger = logger
    }

    // MARK: - VM Lifecycle

    /// Request a VM from a provider
    public func requestVM(
        in networkId: String,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshKeyPath: String = "~/.omerta/ssh/id_ed25519",
        sshUser: String = "omerta",
        retryOnFailure: Bool = false,
        maxRetries: Int = 3
    ) async throws -> VMConnection {
        logger.info("Requesting VM", metadata: [
            "network_id": "\(networkId)",
            "retry": "\(retryOnFailure)"
        ])

        if retryOnFailure {
            return try await requestVMWithRetry(
                networkId: networkId,
                requirements: requirements,
                sshPublicKey: sshPublicKey,
                sshKeyPath: sshKeyPath,
                sshUser: sshUser,
                maxRetries: maxRetries
            )
        } else {
            return try await requestVMOnce(
                networkId: networkId,
                requirements: requirements,
                sshPublicKey: sshPublicKey,
                sshKeyPath: sshKeyPath,
                sshUser: sshUser
            )
        }
    }

    /// Release a VM and cleanup resources
    public func releaseVM(_ connection: VMConnection) async throws {
        logger.info("Releasing VM", metadata: ["vm_id": "\(connection.vmId)"])

        do {
            // 1. Tell provider to kill VM
            try await udpControl.releaseVM(
                providerEndpoint: connection.provider.endpoint,
                vmId: connection.vmId
            )

            logger.info("Provider acknowledged VM release", metadata: ["vm_id": "\(connection.vmId)"])
        } catch {
            logger.warning("Failed to notify provider of VM release", metadata: [
                "vm_id": "\(connection.vmId)",
                "error": "\(error)"
            ])
            // Continue with cleanup even if provider notification fails
        }

        // 2. Tear down VPN
        do {
            try await ephemeralVPN.destroyVPN(for: connection.vmId)
            logger.info("VPN tunnel torn down", metadata: ["vm_id": "\(connection.vmId)"])
        } catch {
            logger.warning("Failed to tear down VPN", metadata: [
                "vm_id": "\(connection.vmId)",
                "error": "\(error)"
            ])
        }

        // 3. Stop tracking VM
        try await vmTracker.removeVM(connection.vmId)

        logger.info("VM released successfully", metadata: ["vm_id": "\(connection.vmId)"])
    }

    /// List all active VMs
    public func listActiveVMs() async -> [VMConnection] {
        await vmTracker.getActiveVMs()
    }

    /// Get specific VM by ID
    public func getVM(_ vmId: UUID) async -> VMConnection? {
        await vmTracker.getVM(vmId)
    }

    /// Resume tracking VMs after consumer crash/restart
    public func resumeTracking() async throws {
        logger.info("Resuming VM tracking from disk")

        let persistedVMs = try await vmTracker.loadPersistedVMs()

        if persistedVMs.isEmpty {
            logger.info("No persisted VMs found")
            return
        }

        logger.info("Resumed tracking \(persistedVMs.count) VMs", metadata: [
            "vm_ids": "\(persistedVMs.map { $0.vmId.uuidString }.joined(separator: ", "))"
        ])

        // Note: VPN tunnels are NOT automatically restored
        // User must manually recreate VPN or release VMs
        for vm in persistedVMs {
            logger.warning("VM \(vm.vmId) requires manual VPN setup or release")
        }
    }

    // MARK: - Private Methods

    /// Request VM without retry
    private func requestVMOnce(
        networkId: String,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshKeyPath: String,
        sshUser: String,
        excludePeers: Set<String> = []
    ) async throws -> VMConnection {
        // 1. Select provider
        logger.info("Selecting provider")
        let provider = try await peerSelector.selectProvider(
            in: networkId,
            for: requirements,
            excludePeers: excludePeers
        )

        logger.info("Selected provider", metadata: [
            "peer_id": "\(provider.peerId)",
            "endpoint": "\(provider.endpoint)"
        ])

        // 2. Create VPN tunnel
        logger.info("Creating VPN tunnel")
        let vmId = UUID()
        let vpnConfig = try await ephemeralVPN.createVPNForJob(vmId)

        logger.info("VPN tunnel created", metadata: ["vm_id": "\(vmId)"])

        // 3. Determine consumer endpoint for notifications
        let consumerEndpoint = try await determineConsumerEndpoint()

        // 4. Send request_vm command to provider
        logger.info("Sending VM request to provider")
        let response = try await udpControl.requestVM(
            providerEndpoint: provider.endpoint,
            vmId: vmId,
            requirements: requirements,
            vpnConfig: vpnConfig,
            consumerEndpoint: consumerEndpoint,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser
        )

        logger.info("Provider created VM", metadata: [
            "vm_id": "\(vmId)",
            "vm_ip": "\(response.vmIP)"
        ])

        // 5. Build connection info
        let connection = VMConnection(
            vmId: vmId,
            provider: PeerInfo(
                peerId: provider.peerId,
                endpoint: provider.endpoint
            ),
            vmIP: response.vmIP,
            sshKeyPath: sshKeyPath,
            sshUser: sshUser,
            vpnInterface: "wg\(vmId.uuidString.prefix(8))",
            createdAt: Date(),
            networkId: networkId
        )

        // 6. Track VM
        try await vmTracker.trackVM(connection)

        logger.info("VM request completed successfully", metadata: [
            "vm_id": "\(vmId)",
            "ssh_command": "\(connection.sshCommand)"
        ])

        return connection
    }

    /// Request VM with retry logic
    private func requestVMWithRetry(
        networkId: String,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshKeyPath: String,
        sshUser: String,
        maxRetries: Int
    ) async throws -> VMConnection {
        var failedPeers = Set<String>()
        var lastError: Error?

        for attempt in 1...maxRetries {
            logger.info("VM request attempt \(attempt)/\(maxRetries)")

            do {
                let connection = try await requestVMOnce(
                    networkId: networkId,
                    requirements: requirements,
                    sshPublicKey: sshPublicKey,
                    sshKeyPath: sshKeyPath,
                    sshUser: sshUser,
                    excludePeers: failedPeers
                )
                return connection
            } catch ConsumerError.noSuitableProviders {
                // No more providers available
                logger.error("No suitable providers available after excluding failed peers")
                throw ConsumerError.noSuitableProviders
            } catch {
                lastError = error
                logger.warning("VM request attempt \(attempt) failed", metadata: [
                    "error": "\(error)"
                ])

                // Track failed provider (if we can extract peer ID from error)
                // For now, just continue
                if attempt < maxRetries {
                    // Wait before retry
                    try await Task.sleep(nanoseconds: UInt64(1.0 * 1_000_000_000))
                }
            }
        }

        logger.error("VM request failed after \(maxRetries) attempts")
        throw lastError ?? ConsumerError.providerTimeout
    }

    /// Determine consumer endpoint for provider notifications
    private func determineConsumerEndpoint() async throws -> String {
        // Get local IP address - use platform-appropriate method
        var ipAddress = "127.0.0.1"

        #if os(macOS)
        // macOS: use ipconfig getifaddr for primary interface
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
        // Linux: use hostname -I
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

        // Use default notification port (TODO: make configurable)
        return "\(ipAddress):51821"
    }
}

// MARK: - Helper Extensions

extension ConsumerClient {
    /// Request VM with minimal requirements (any available provider)
    public func requestAnyVM(
        in networkId: String,
        sshPublicKey: String,
        sshKeyPath: String = "~/.omerta/ssh/id_ed25519",
        sshUser: String = "omerta"
    ) async throws -> VMConnection {
        try await requestVM(
            in: networkId,
            requirements: ResourceRequirements(),
            sshPublicKey: sshPublicKey,
            sshKeyPath: sshKeyPath,
            sshUser: sshUser
        )
    }

    /// Request VM with specific GPU
    public func requestGPUVM(
        in networkId: String,
        gpuModel: String,
        minVRAM: UInt64? = nil,
        sshPublicKey: String,
        sshKeyPath: String = "~/.omerta/ssh/id_ed25519",
        sshUser: String = "omerta"
    ) async throws -> VMConnection {
        try await requestVM(
            in: networkId,
            requirements: ResourceRequirements(
                gpu: GPURequirements(
                    model: gpuModel,
                    vramMB: minVRAM
                )
            ),
            sshPublicKey: sshPublicKey,
            sshKeyPath: sshKeyPath,
            sshUser: sshUser
        )
    }

    /// Request VM with specific architecture
    public func requestArchVM(
        in networkId: String,
        architecture: CPUArchitecture,
        minCores: UInt32? = nil,
        minMemory: UInt64? = nil,
        sshPublicKey: String,
        sshKeyPath: String = "~/.omerta/ssh/id_ed25519",
        sshUser: String = "omerta"
    ) async throws -> VMConnection {
        try await requestVM(
            in: networkId,
            requirements: ResourceRequirements(
                cpuCores: minCores,
                cpuArchitecture: architecture,
                memoryMB: minMemory
            ),
            sshPublicKey: sshPublicKey,
            sshKeyPath: sshKeyPath,
            sshUser: sshUser
        )
    }

    /// Cleanup all active VMs
    public func cleanupAllVMs() async throws {
        let activeVMs = await vmTracker.getActiveVMs()

        logger.info("Cleaning up \(activeVMs.count) active VMs")

        for vm in activeVMs {
            do {
                try await releaseVM(vm)
            } catch {
                logger.error("Failed to cleanup VM", metadata: [
                    "vm_id": "\(vm.vmId)",
                    "error": "\(error)"
                ])
            }
        }

        logger.info("VM cleanup completed")
    }
}
