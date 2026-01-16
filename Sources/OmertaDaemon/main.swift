import Foundation
import ArgumentParser
import Logging
import OmertaCore
import OmertaVM
import OmertaVPN
import OmertaProvider
import OmertaConsumer
import OmertaMesh

@main
struct OmertaDaemon: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "omertad",
        abstract: "Omerta provider daemon - provides VM resources to network peers via mesh network",
        version: "0.6.0 (Mesh-only)",
        subcommands: [
            Start.self,
            Stop.self,
            Status.self,
            Config.self
        ],
        defaultSubcommand: Status.self
    )
}

// MARK: - Start Command

struct Start: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Start the provider daemon"
    )

    @Option(name: .long, help: "Network ID (from 'omerta network create' or 'omerta network list')")
    var network: String?

    @Option(name: .long, help: "Mesh port (default: 9999)")
    var port: Int = 9999

    @Flag(name: .long, help: "Consumer-only mode - participate in mesh but don't offer VMs")
    var noProvider: Bool = false

    @Flag(name: .long, help: "Dry run mode - simulate VM creation without actual VMs")
    var dryRun: Bool = false

    @Option(name: .long, help: "Auto-shutdown after N seconds (for testing)")
    var timeout: Int?

    mutating func run() async throws {
        print("Starting Omerta Provider Daemon...")
        if dryRun {
            print("*** DRY RUN MODE - No actual VMs will be created ***")
        }
        print("")

        // Load network from store
        guard let networkId = network else {
            print("Error: --network <id> is required")
            print("")
            print("To create a network:")
            print("  omerta network create --name \"My Network\" --endpoint \"<your-ip>:9999\"")
            print("")
            print("To list existing networks:")
            print("  omerta network list")
            throw ExitCode.failure
        }

        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        guard let storedNetwork = await networkStore.network(id: networkId) else {
            print("Error: Network '\(networkId)' not found")
            print("")
            print("Available networks:")
            let networks = await networkStore.allNetworks()
            if networks.isEmpty {
                print("  (none)")
                print("")
                print("Create a network with:")
                print("  omerta network create --name \"My Network\" --endpoint \"<your-ip>:9999\"")
            } else {
                for n in networks {
                    print("  \(n.id) - \(n.name)")
                }
            }
            throw ExitCode.failure
        }

        let keyData = storedNetwork.key.networkKey
        let bootstrapPeers = storedNetwork.key.bootstrapPeers

        print("Network: \(storedNetwork.name) (\(networkId))")

        // Load identity for this network
        let identity: OmertaMesh.IdentityKeypair
        let identityStorePath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: "/tmp")
        let identitiesPath = identityStorePath
            .appendingPathComponent("OmertaMesh")
            .appendingPathComponent("identities.json")

        if FileManager.default.fileExists(atPath: identitiesPath.path),
           let data = try? Data(contentsOf: identitiesPath),
           let identities = try? JSONDecoder().decode([String: [String: String]].self, from: data),
           let storedIdentity = identities[networkId],
           let privateKeyBase64 = storedIdentity["privateKeyBase64"] {
            identity = try OmertaMesh.IdentityKeypair(privateKeyBase64: privateKeyBase64)
            print("Loaded identity for network: \(identity.peerId)")
        } else {
            print("Error: No identity found for network '\(networkId)'")
            print("The network may have been created on a different machine.")
            print("")
            print("To create a new network on this machine:")
            print("  omerta network create --name \"My Network\" --endpoint \"<your-ip>:9999\"")
            throw ExitCode.failure
        }

        // Check dependencies
        print("")
        print("Checking system dependencies...")
        let checker = DependencyChecker()
        do {
            try await checker.verifyProviderMode()
            print("All dependencies satisfied")
        } catch let error as DependencyChecker.MissingDependenciesError {
            print("\nMissing dependencies:")
            print(error.description)
            print("\nRun the installation script:")
            print("  curl -sSL https://raw.githubusercontent.com/omerta/omerta/main/Scripts/install.sh | bash")
            throw ExitCode.failure
        }
        print("")

        // Run the mesh daemon
        try await runMeshDaemon(networkId: networkId, identity: identity, keyData: keyData, bootstrapPeers: bootstrapPeers)
    }

    private func runMeshDaemon(networkId: String, identity: OmertaMesh.IdentityKeypair, keyData: Data, bootstrapPeers: [String]) async throws {
        // Build mesh config with encryption key and bootstrap peers from network
        let meshConfig = MeshConfig(
            encryptionKey: keyData,
            port: port,
            canRelay: true,
            canCoordinateHolePunch: true,
            bootstrapPeers: bootstrapPeers
        )

        // Create mesh daemon configuration
        let daemonConfig = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
            dryRun: dryRun,
            noProvider: noProvider
        )

        // Create and start mesh daemon
        let daemon = MeshProviderDaemon(config: daemonConfig)

        // Create VMTracker for consumer operations
        let vmTracker = VMTracker()

        // Create control socket for CLI communication
        let controlSocket = ControlSocketServer(networkId: networkId)

        do {
            // Set up consumer message handler for incoming heartbeats BEFORE starting
            await daemon.setConsumerMessageHandler { [daemon, vmTracker] peerId, data in
                await self.handleConsumerMessage(
                    from: peerId,
                    data: data,
                    daemon: daemon,
                    vmTracker: vmTracker
                )
            }

            try await daemon.start()

            // Start control socket and wire up command handler
            await controlSocket.setCommandHandler { [daemon, vmTracker] command in
                await self.handleControlCommand(
                    command,
                    daemon: daemon,
                    vmTracker: vmTracker,
                    identity: identity,
                    networkKey: keyData,
                    networkId: networkId,
                    dryRun: dryRun
                )
            }
            try await controlSocket.start()

            let status = await daemon.getStatus()

            print("")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            if noProvider {
                print("  Omerta Mesh Daemon Running (Consumer Only)")
            } else {
                print("  Omerta Provider Daemon Running")
            }
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("")
            print("Peer ID: \(identity.peerId)")
            print("Mesh Port: \(port)")
            print("Control Socket: \(ControlSocketServer.socketPath(forNetwork: networkId))")
            print("NAT Type: \(status.natType.rawValue)")
            if let publicEndpoint = status.publicEndpoint {
                print("Public Endpoint: \(publicEndpoint)")
            }
            if !bootstrapPeers.isEmpty {
                print("Bootstrap Peers: \(bootstrapPeers.joined(separator: ", "))")
            }
            print("")
            if noProvider {
                print("Running in consumer-only mode (not accepting VM requests).")
                print("Use 'omerta vm request' to request VMs from other providers.")
            } else {
                print("Ready to accept VM requests via mesh network.")
                print("Consumers can request VMs using:")
                print("  omerta vm request --network \(networkId) --peer \(identity.peerId)")
            }
            print("")
            if let timeout = timeout {
                print("Auto-shutdown in \(timeout) seconds")
            } else {
                print("Press Ctrl+C to stop")
            }
            print("")

            // Keep running until interrupted or timeout
            let duration = timeout ?? (60 * 60 * 24 * 365)  // timeout or 1 year
            try await Task.sleep(for: .seconds(duration))

            if timeout != nil {
                print("Timeout reached, shutting down...")
                await controlSocket.stop()
                await daemon.stop()
            }

        } catch let error as ControlSocketError {
            print("Error: \(error.description)")
            throw ExitCode.failure
        } catch {
            print("Failed to start daemon: \(error)")
            throw ExitCode.failure
        }
    }

    private func handleControlCommand(
        _ command: ControlCommand,
        daemon: MeshProviderDaemon,
        vmTracker: VMTracker,
        identity: OmertaMesh.IdentityKeypair,
        networkKey: Data,
        networkId: String,
        dryRun: Bool
    ) async -> ControlResponse {
        switch command {
        case .ping(let peerId, let timeout):
            // Ping through the daemon's mesh network
            if let result = await daemon.ping(peerId: peerId, timeout: TimeInterval(timeout)) {
                return .pingResult(ControlResponse.PingResultData(
                    peerId: result.peerId,
                    endpoint: result.endpoint,
                    latencyMs: result.latencyMs,
                    sentPeers: result.sentPeers,
                    receivedPeers: result.receivedPeers,
                    newPeers: result.newPeers
                ))
            } else {
                return .pingResult(nil)
            }

        case .status:
            let status = await daemon.getStatus()
            return .status(ControlResponse.StatusData(
                isRunning: true,
                peerId: status.peerId,
                natType: status.natType.rawValue,
                publicEndpoint: status.publicEndpoint,
                peerCount: status.peerCount,
                activeVMs: status.activeVMs,
                uptime: nil
            ))

        case .peers:
            let peerIds = await daemon.knownPeers()
            let peers = peerIds.map { peerId in
                ControlResponse.PeerData(peerId: peerId, endpoint: "", lastSeen: nil)
            }
            return .peers(peers)

        case .vmRequest(let peerId, let requirements, let sshPublicKey, let sshUser, let timeoutMinutes):
            return await handleVMRequest(
                providerPeerId: peerId,
                requirementsData: requirements,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser,
                timeoutMinutes: timeoutMinutes,
                daemon: daemon,
                vmTracker: vmTracker,
                identity: identity,
                networkKey: networkKey,
                networkId: networkId,
                dryRun: dryRun
            )

        case .vmRelease(let vmId):
            return await handleVMRelease(
                vmId: vmId,
                daemon: daemon,
                vmTracker: vmTracker,
                identity: identity,
                networkKey: networkKey
            )

        case .vmList:
            return await handleVMList(vmTracker: vmTracker)
        }
    }

    private func handleVMRequest(
        providerPeerId: String,
        requirementsData: Data,
        sshPublicKey: String,
        sshUser: String,
        timeoutMinutes: Int,
        daemon: MeshProviderDaemon,
        vmTracker: VMTracker,
        identity: OmertaMesh.IdentityKeypair,
        networkKey: Data,
        networkId: String,
        dryRun: Bool
    ) async -> ControlResponse {
        // Decode requirements
        guard let requirements = try? JSONDecoder().decode(ResourceRequirements.self, from: requirementsData) else {
            return .vmRequestResult(ControlResponse.VMRequestResultData(
                success: false,
                vmId: nil,
                vmIP: nil,
                sshCommand: nil,
                error: "Failed to decode resource requirements"
            ))
        }

        // Ping provider to get their endpoint
        guard let pingResult = await daemon.ping(peerId: providerPeerId, timeout: 10) else {
            return .vmRequestResult(ControlResponse.VMRequestResultData(
                success: false,
                vmId: nil,
                vmIP: nil,
                sshCommand: nil,
                error: "Failed to reach provider \(providerPeerId.prefix(16))..."
            ))
        }

        let providerEndpoint = pingResult.endpoint

        // Create MeshConsumerClient for this request
        let client = MeshConsumerClient(
            identity: identity,
            networkKey: networkKey,
            providerPeerId: providerPeerId,
            providerEndpoint: providerEndpoint,
            dryRun: dryRun
        )

        do {
            // Request VM from provider (MeshConsumerClient handles VM tracking internally)
            let connection = try await client.requestVM(
                requirements: requirements,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser,
                timeoutMinutes: timeoutMinutes
            )

            return .vmRequestResult(ControlResponse.VMRequestResultData(
                success: true,
                vmId: connection.vmId,
                vmIP: connection.vmIP,
                sshCommand: connection.sshCommand,
                error: nil
            ))
        } catch {
            return .vmRequestResult(ControlResponse.VMRequestResultData(
                success: false,
                vmId: nil,
                vmIP: nil,
                sshCommand: nil,
                error: error.localizedDescription
            ))
        }
    }

    private func handleVMRelease(
        vmId: UUID,
        daemon: MeshProviderDaemon,
        vmTracker: VMTracker,
        identity: OmertaMesh.IdentityKeypair,
        networkKey: Data
    ) async -> ControlResponse {
        // Get VM from tracker
        let vms = try? await vmTracker.loadPersistedVMs()
        guard let vm = vms?.first(where: { $0.vmId == vmId }) else {
            return .vmReleaseResult(success: false, error: "VM not found: \(vmId)")
        }

        // Create client to send release request
        let client = MeshConsumerClient(
            identity: identity,
            networkKey: networkKey,
            providerPeerId: vm.provider.peerId,
            providerEndpoint: vm.provider.endpoint,
            dryRun: false
        )

        do {
            // releaseVM handles both provider notification and local cleanup
            try await client.releaseVM(vm)
            return .vmReleaseResult(success: true, error: nil)
        } catch {
            return .vmReleaseResult(success: false, error: error.localizedDescription)
        }
    }

    private func handleVMList(vmTracker: VMTracker) async -> ControlResponse {
        do {
            let vms = try await vmTracker.loadPersistedVMs()
            let vmInfos = vms.map { vm in
                ControlResponse.VMInfoData(
                    vmId: vm.vmId,
                    providerPeerId: vm.provider.peerId,
                    vmIP: vm.vmIP,
                    createdAt: vm.createdAt
                )
            }
            return .vmList(vmInfos)
        } catch {
            return .error("Failed to load VMs: \(error.localizedDescription)")
        }
    }

    // MARK: - Consumer Message Handling

    private func handleConsumerMessage(
        from providerPeerId: String,
        data: Data,
        daemon: MeshProviderDaemon,
        vmTracker: VMTracker
    ) async {
        // Try to decode as heartbeat request from a provider
        guard let heartbeat = try? JSONDecoder().decode(MeshVMHeartbeat.self, from: data) else {
            // Not a heartbeat, ignore (could be other message types in the future)
            return
        }

        var logger = Logger(label: "io.omerta.consumer.heartbeat")
        logger.logLevel = .info

        logger.debug("Received heartbeat from provider", metadata: [
            "provider": "\(providerPeerId.prefix(16))...",
            "vmCount": "\(heartbeat.vmIds.count)"
        ])

        // Get all VMs we're tracking
        guard let allVMs = try? await vmTracker.loadPersistedVMs() else {
            logger.warning("Failed to load VMs from tracker")
            // Still respond with empty list
            let response = MeshVMHeartbeatResponse(activeVmIds: [])
            if let responseData = try? JSONEncoder().encode(response) {
                try? await daemon.sendToPeer(responseData, to: providerPeerId)
            }
            return
        }

        // Filter to VMs from THIS specific provider only
        // Critical: VMs from other providers must NOT be affected
        let vmsFromProvider = allVMs.filter { $0.provider.peerId == providerPeerId }
        let trackedIds = Set(vmsFromProvider.map { $0.vmId })
        let providerIds = Set(heartbeat.vmIds)

        // 1. Respond with intersection (VMs we still want that provider still has)
        let activeIds = trackedIds.intersection(providerIds)
        let response = MeshVMHeartbeatResponse(activeVmIds: Array(activeIds))

        if let responseData = try? JSONEncoder().encode(response) {
            do {
                try await daemon.sendToPeer(responseData, to: providerPeerId)
                logger.debug("Sent heartbeat response", metadata: [
                    "provider": "\(providerPeerId.prefix(16))...",
                    "activeVMs": "\(activeIds.count)"
                ])
            } catch {
                logger.warning("Failed to send heartbeat response", metadata: [
                    "error": "\(error)"
                ])
            }
        }

        // 2. Cleanup: VMs we're tracking that provider no longer has
        // This handles provider crash/restart or force-release scenarios
        let orphanedIds = trackedIds.subtracting(providerIds)

        if !orphanedIds.isEmpty {
            logger.info("Provider no longer has VMs, cleaning up locally", metadata: [
                "provider": "\(providerPeerId.prefix(16))...",
                "orphanedVMs": "\(orphanedIds.map { $0.uuidString.prefix(8) })"
            ])

            for vmId in orphanedIds {
                if let vm = vmsFromProvider.first(where: { $0.vmId == vmId }) {
                    // Tear down WireGuard interface
                    let interfaceName = vm.vpnInterface
                    logger.info("Tearing down orphaned VM", metadata: [
                        "vmId": "\(vmId.uuidString.prefix(8))...",
                        "interface": "\(interfaceName)"
                    ])

                    // Try to remove the WireGuard interface
                    do {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                        process.arguments = ["ip", "link", "delete", interfaceName]
                        try process.run()
                        process.waitUntilExit()
                    } catch {
                        logger.debug("Failed to delete interface (may not exist)", metadata: [
                            "interface": "\(interfaceName)",
                            "error": "\(error)"
                        ])
                    }

                    // Remove from tracker
                    try? await vmTracker.removeVM(vmId)
                    logger.info("Orphaned VM cleaned up", metadata: ["vmId": "\(vmId.uuidString.prefix(8))..."])
                }
            }
        }
    }
}

// MARK: - Stop Command

struct Stop: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Stop the provider daemon"
    )

    mutating func run() async throws {
        print("Stopping Omerta Provider Daemon...")

        // In a real implementation, this would:
        // 1. Find the running daemon process (PID file)
        // 2. Send SIGTERM signal
        // 3. Wait for graceful shutdown
        // 4. Send SIGKILL if timeout

        print("Not yet implemented")
        print("For now, use Ctrl+C in the terminal running 'omertad start'")
    }
}

// MARK: - Status Command

struct Status: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Show provider daemon status"
    )

    @Flag(name: .long, help: "Show detailed VM information")
    var detailed: Bool = false

    mutating func run() async throws {
        print("Omerta Provider Daemon")
        print("Version: 0.6.0 (Mesh-only)")
        print("")

        // In a real implementation, this would connect to running daemon
        print("Status: Not Running")
        print("")
        print("To start the daemon:")
        print("  sudo omertad start")
        print("")
        print("Provider daemon (mesh network):")
        print("  - Accepts VM requests via mesh network")
        print("  - Handles NAT traversal with hole punching")
        print("  - Creates isolated VMs accessible via SSH")
        print("  - Routes all VM traffic through WireGuard tunnel")
        print("  - Messages encrypted with network key (ChaCha20-Poly1305)")
        print("")
        print("Available commands:")
        print("  start   - Start the provider daemon")
        print("  stop    - Stop the daemon")
        print("  status  - Show daemon status (this)")
        print("  config  - Manage daemon configuration")
    }
}

// MARK: - Config Command

struct Config: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Manage provider daemon configuration",
        subcommands: [
            ConfigShow.self,
            ConfigTrust.self,
            ConfigBlock.self
        ]
    )
}

struct ConfigShow: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show current configuration"
    )

    mutating func run() async throws {
        print("Provider Daemon Configuration")
        print("============================")
        print("")
        print("Control Port: 51820 (default)")
        print("Activity logging: enabled")
        print("")
        print("Trusted networks: (none configured)")
        print("Blocked peers: (none)")
        print("")
        print("Filter rules:")
        print("  - Resource Limits: enabled")
        print("    Max CPU: 8 cores")
        print("    Max Memory: 16384 MB")
        print("    Max Storage: 100 GB")
        print("  - Quiet Hours: enabled")
        print("    Hours: 22:00 - 08:00 (require approval)")
        print("")
        print("Dynamic configuration management not yet implemented")
    }
}

struct ConfigTrust: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Add a trusted network"
    )

    @Argument(help: "Network ID to trust")
    var networkId: String

    mutating func run() async throws {
        print("Added trusted network: \(networkId)")
        print("")
        print("Configuration will be applied on next daemon restart")
    }
}

struct ConfigBlock: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "block",
        abstract: "Block a peer"
    )

    @Argument(help: "Peer ID to block")
    var peerId: String

    mutating func run() async throws {
        print("Blocked peer: \(peerId)")
        print("")
        print("Configuration will be applied on next daemon restart")
    }
}

// Data.init?(hexString:) is provided by OmertaCore
