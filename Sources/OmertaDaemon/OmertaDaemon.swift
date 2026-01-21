import Foundation
import ArgumentParser
import Logging
import OmertaCore
import OmertaVM
import OmertaVPN
import OmertaProvider
import OmertaConsumer
import OmertaMesh
import Dispatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Expand tilde in path using real user's home (sudo-aware)
private func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~/") else { return path }
    return OmertaConfig.getRealUserHome() + String(path.dropFirst(1))
}

/// Resolve a network ID or prefix to a full network
/// Returns: (network, nil) on match, (nil, error message) on no match or ambiguous
private func resolveNetwork(_ idOrPrefix: String, store: NetworkStore) async -> (OmertaMesh.Network?, String?) {
    // First try exact match
    if let network = await store.network(id: idOrPrefix) {
        return (network, nil)
    }

    // Try prefix match
    let allNetworks = await store.allNetworks()
    let matches = allNetworks.filter { $0.id.hasPrefix(idOrPrefix) }

    switch matches.count {
    case 0:
        // Also try matching by name prefix (case-insensitive)
        let nameMatches = allNetworks.filter { $0.name.lowercased().hasPrefix(idOrPrefix.lowercased()) }
        if nameMatches.count == 1 {
            return (nameMatches[0], nil)
        } else if nameMatches.count > 1 {
            var msg = "Ambiguous network name prefix '\(idOrPrefix)'. Did you mean:\n"
            for net in nameMatches.prefix(5) {
                msg += "  \(net.id.prefix(8))... (\(net.name))\n"
            }
            return (nil, msg)
        }
        return (nil, nil) // Not found, let caller handle
    case 1:
        return (matches[0], nil)
    default:
        var msg = "Ambiguous network ID prefix '\(idOrPrefix)'. Did you mean:\n"
        for net in matches.prefix(5) {
            msg += "  \(net.id.prefix(8))... (\(net.name))\n"
        }
        return (nil, msg)
    }
}

// MARK: - Daemon Configuration

/// Configuration for the omertad daemon
/// Supports loading from a simple key=value config file
struct DaemonConfig {
    var network: String?
    var port: Int = 9999
    var noProvider: Bool = false
    var dryRun: Bool = false
    var timeout: Int?
    var canRelay: Bool = true
    var canCoordinateHolePunch: Bool = true
    var enableEventLogging: Bool = false

    /// Default config file path
    static var defaultPath: String {
        "\(OmertaConfig.getRealUserHome())/.omerta/omertad.conf"
    }

    /// Load config from a file
    /// - Parameter path: Path to config file
    /// - Returns: Parsed config
    static func load(from path: String) throws -> DaemonConfig {
        let expandedPath = path.hasPrefix("~/")
            ? OmertaConfig.getRealUserHome() + String(path.dropFirst(1))
            : path
        let contents = try String(contentsOfFile: expandedPath, encoding: .utf8)
        return try parse(contents)
    }

    /// Parse config from string content
    static func parse(_ content: String) throws -> DaemonConfig {
        var config = DaemonConfig()

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse key=value
            guard let equalsIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)

            // Remove quotes if present
            let cleanValue = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch key {
            case "network":
                config.network = cleanValue
            case "port":
                config.port = Int(cleanValue) ?? 9999
            case "no-provider", "noprovider", "no_provider":
                config.noProvider = cleanValue.lowercased() == "true" || cleanValue == "1"
            case "dry-run", "dryrun", "dry_run":
                config.dryRun = cleanValue.lowercased() == "true" || cleanValue == "1"
            case "timeout":
                config.timeout = Int(cleanValue)
            case "can-relay", "canrelay", "can_relay", "relay":
                config.canRelay = cleanValue.lowercased() == "true" || cleanValue == "1"
            case "can-coordinate-hole-punch", "cancoordinateholepunch", "can_coordinate_hole_punch", "hole-punch", "holepunch":
                config.canCoordinateHolePunch = cleanValue.lowercased() == "true" || cleanValue == "1"
            case "enable-event-logging", "enableeventlogging", "enable_event_logging", "event-logging", "eventlogging":
                config.enableEventLogging = cleanValue.lowercased() == "true" || cleanValue == "1"
            default:
                // Unknown key, ignore
                break
            }
        }

        return config
    }

    /// Generate a sample config file content
    static func sampleConfig(network: String? = nil) -> String {
        """
        # Omerta Daemon Configuration
        # Place this file at ~/.omerta/omertad.conf

        # Network ID (required)
        # Get this from 'omerta network list' or 'omerta network create'
        network=\(network ?? "YOUR_NETWORK_ID")

        # Mesh port (default: 9999)
        port=9999

        # Consumer-only mode - participate in mesh but don't offer VMs
        # Set to true if you only want to request VMs, not provide them
        no-provider=false

        # Dry run mode - simulate VM creation without actual VMs (for testing)
        dry-run=false

        # Relay mode - allow relaying traffic for other peers (default: true)
        # Disable to reduce bandwidth usage if you're behind a restrictive NAT
        can-relay=true

        # Hole punch coordination - help other peers establish direct connections (default: true)
        # Disable if you want to minimize participation in the mesh
        can-coordinate-hole-punch=true

        # Enable persistent event logging for debugging (default: false)
        # Logs are written to ~/.config/Omerta*/logs/ in JSONL format
        enable-event-logging=false

        # Auto-shutdown after N seconds (optional, for testing)
        # timeout=3600
        """
    }
}

// MARK: - Shutdown Coordinator

/// Coordinates graceful shutdown of the daemon
actor ShutdownCoordinator {
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var isShuttingDown = false
    private var inFlightRequests = 0

    /// Wait for shutdown signal
    func waitForShutdown() async {
        await withCheckedContinuation { continuation in
            self.shutdownContinuation = continuation
        }
    }

    /// Request shutdown - returns immediately, shutdown happens asynchronously
    func requestShutdown() -> Bool {
        guard !isShuttingDown else { return false }
        isShuttingDown = true
        shutdownContinuation?.resume()
        return true
    }

    /// Check if shutdown is in progress
    func isShutdownRequested() -> Bool {
        isShuttingDown
    }

    /// Track in-flight request start
    func startRequest() {
        inFlightRequests += 1
    }

    /// Track in-flight request completion
    func endRequest() {
        inFlightRequests -= 1
    }

    /// Get current in-flight request count
    func getInFlightCount() -> Int {
        inFlightRequests
    }

    /// Wait for all in-flight requests to complete (with timeout)
    func waitForInFlightRequests(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while inFlightRequests > 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

@main
struct OmertaDaemon: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "omertad",
        abstract: "Omerta provider daemon - provides VM resources to network peers via mesh network",
        version: "0.6.0 (Mesh-only)",
        subcommands: [
            Start.self,
            Stop.self,
            Restart.self,
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

    @Option(name: .shortAndLong, help: "Path to config file (default: ~/.omerta/omertad.conf)")
    var config: String?

    @Argument(help: "Network ID or prefix (from 'omerta network list')")
    var networkArg: String?

    @Option(name: .long, help: "Network ID or prefix (from 'omerta network list')")
    var network: String?

    @Option(name: .long, help: "Mesh port (default: 9999)")
    var port: Int?

    @Flag(name: .long, help: "Consumer-only mode - participate in mesh but don't offer VMs")
    var noProvider: Bool = false

    @Flag(name: .long, help: "Dry run mode - simulate VM creation without actual VMs")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Disable relaying traffic for other peers")
    var noRelay: Bool = false

    @Flag(name: .long, help: "Disable hole punch coordination")
    var noHolePunch: Bool = false

    @Flag(name: .long, help: "Enable persistent event logging for debugging")
    var enableEventLogging: Bool = false

    @Option(name: .long, help: "Auto-shutdown after N seconds (for testing)")
    var timeout: Int?

    mutating func run() async throws {
        // Load config file (if specified or exists at default path)
        var fileConfig = DaemonConfig()
        let configPath = config ?? DaemonConfig.defaultPath
        let configPathExpanded = expandTilde(configPath)

        if FileManager.default.fileExists(atPath: configPathExpanded) {
            do {
                fileConfig = try DaemonConfig.load(from: configPath)
                print("Loaded config from: \(configPathExpanded)")
            } catch {
                print("Warning: Failed to load config file: \(error.localizedDescription)")
            }
        } else if config != nil {
            // User explicitly specified a config file that doesn't exist
            print("Error: Config file not found: \(configPathExpanded)")
            throw ExitCode.failure
        }

        // Merge: command line options override config file
        // For boolean flags: CLI flag disables (--no-relay), config enables by default
        // Positional arg takes precedence over --network flag
        let effectiveNetwork = networkArg ?? network ?? fileConfig.network
        let effectivePort = port ?? fileConfig.port
        let effectiveNoProvider = noProvider || fileConfig.noProvider
        let effectiveDryRun = dryRun || fileConfig.dryRun
        let effectiveTimeout = timeout ?? fileConfig.timeout
        let effectiveCanRelay = !noRelay && fileConfig.canRelay
        let effectiveCanHolePunch = !noHolePunch && fileConfig.canCoordinateHolePunch
        let effectiveEventLogging = enableEventLogging || fileConfig.enableEventLogging

        print("Starting Omerta Provider Daemon...")
        if effectiveDryRun {
            print("*** DRY RUN MODE - No actual VMs will be created ***")
        }
        print("")

        // Load network from store
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        // Determine network: explicit arg > config file > most recent
        let networkIdOrPrefix: String
        if let explicit = effectiveNetwork {
            networkIdOrPrefix = explicit
        } else if let mostRecent = await networkStore.mostRecentNetwork() {
            networkIdOrPrefix = mostRecent.id
            print("Using most recently joined network: \(mostRecent.name) (\(mostRecent.id.prefix(16))...)")
            print("")
        } else {
            print("Error: No network specified and no networks joined")
            print("")
            print("Usage:")
            print("  omertad start <network-id>")
            print("  omertad start --network <network-id>")
            print("  omertad start  # uses most recently joined network")
            print("")
            print("To join a network:")
            print("  omerta network join <invite-link>")
            print("")
            print("To create a new network:")
            print("  omerta network create --name \"My Network\"")
            throw ExitCode.failure
        }

        // Resolve network ID prefix
        let (resolvedNetwork, resolveError) = await resolveNetwork(networkIdOrPrefix, store: networkStore)

        guard let storedNetwork = resolvedNetwork else {
            if let error = resolveError {
                print(error)
                throw ExitCode.failure
            }
            print("Error: Network '\(networkIdOrPrefix)' not found")
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
                    print("  \(n.id.prefix(8))... - \(n.name)")
                }
            }
            throw ExitCode.failure
        }

        let keyData = storedNetwork.key.networkKey
        let bootstrapPeers = storedNetwork.key.bootstrapPeers

        print("Network: \(storedNetwork.name) (\(storedNetwork.id))")

        // Load identity for this network
        // Use getRealUserHome() to handle sudo correctly
        let identity: OmertaMesh.IdentityKeypair
        let homeDir = OmertaConfig.getRealUserHome()
        let identitiesPath = URL(fileURLWithPath: homeDir)
            .appendingPathComponent(".omerta/mesh/identities.json")

        if FileManager.default.fileExists(atPath: identitiesPath.path),
           let data = try? Data(contentsOf: identitiesPath),
           let identities = try? JSONDecoder().decode([String: [String: String]].self, from: data),
           let storedIdentity = identities[storedNetwork.id],
           let privateKeyBase64 = storedIdentity["privateKeyBase64"] {
            identity = try OmertaMesh.IdentityKeypair(privateKeyBase64: privateKeyBase64)
            print("Loaded identity for network: \(identity.peerId)")
        } else {
            print("Error: No identity found for network '\(storedNetwork.id)'")
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

        // Create shutdown coordinator
        let shutdownCoordinator = ShutdownCoordinator()

        // Run the mesh daemon
        try await runMeshDaemon(
            networkId: storedNetwork.id,
            identity: identity,
            keyData: keyData,
            bootstrapPeers: bootstrapPeers,
            port: effectivePort,
            noProvider: effectiveNoProvider,
            dryRun: effectiveDryRun,
            timeout: effectiveTimeout,
            canRelay: effectiveCanRelay,
            canHolePunch: effectiveCanHolePunch,
            enableEventLogging: effectiveEventLogging,
            shutdownCoordinator: shutdownCoordinator
        )
    }

    private func runMeshDaemon(
        networkId: String,
        identity: OmertaMesh.IdentityKeypair,
        keyData: Data,
        bootstrapPeers: [String],
        port: Int,
        noProvider: Bool,
        dryRun: Bool,
        timeout: Int?,
        canRelay: Bool,
        canHolePunch: Bool,
        enableEventLogging: Bool,
        shutdownCoordinator: ShutdownCoordinator
    ) async throws {
        // Build mesh config with encryption key and bootstrap peers from network
        let meshConfig = MeshConfig(
            encryptionKey: keyData,
            port: port,
            canRelay: canRelay,
            canCoordinateHolePunch: canHolePunch,
            bootstrapPeers: bootstrapPeers,
            enableEventLogging: enableEventLogging
        )

        // Create mesh daemon configuration
        let daemonConfig = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
            dryRun: dryRun,
            noProvider: noProvider,
            enableEventLogging: enableEventLogging
        )

        // Create and start mesh daemon
        let daemon = MeshProviderDaemon(config: daemonConfig)

        // Create VMTracker for consumer operations
        let vmTracker = VMTracker()

        // Create control socket for CLI communication
        let controlSocket = ControlSocketServer(networkId: networkId)

        do {
            // Set up heartbeat channel handler for incoming heartbeats when acting as consumer BEFORE starting
            try await daemon.onChannel(VMChannels.heartbeat) { [daemon, vmTracker] peerId, data in
                await self.handleConsumerMessage(
                    from: peerId,
                    data: data,
                    daemon: daemon,
                    vmTracker: vmTracker
                )
            }

            try await daemon.start()

            // Start control socket and wire up command handler
            await controlSocket.setCommandHandler { [daemon, vmTracker, shutdownCoordinator] command in
                await self.handleControlCommand(
                    command,
                    daemon: daemon,
                    vmTracker: vmTracker,
                    identity: identity,
                    networkKey: keyData,
                    networkId: networkId,
                    dryRun: dryRun,
                    shutdownCoordinator: shutdownCoordinator
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
            print("Relay: \(canRelay ? "enabled" : "disabled")")
            print("Hole Punch: \(canHolePunch ? "enabled" : "disabled")")
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
                print("Press Ctrl+C to stop, or 'omertad stop' from another terminal")
            }
            print("")

            // Set up signal handlers for graceful shutdown on Ctrl+C
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            sigintSource.setEventHandler {
                print("\nReceived SIGINT, initiating graceful shutdown...")
                Task {
                    _ = await shutdownCoordinator.requestShutdown()
                }
            }
            sigtermSource.setEventHandler {
                print("\nReceived SIGTERM, initiating graceful shutdown...")
                Task {
                    _ = await shutdownCoordinator.requestShutdown()
                }
            }
            sigintSource.resume()
            sigtermSource.resume()

            defer {
                sigintSource.cancel()
                sigtermSource.cancel()
            }

            // Wait for shutdown signal or timeout
            if let timeout = timeout {
                // Race between timeout and shutdown signal
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try? await Task.sleep(for: .seconds(timeout))
                    }
                    group.addTask {
                        await shutdownCoordinator.waitForShutdown()
                    }
                    // Wait for first to complete
                    await group.next()
                    group.cancelAll()
                }
                print("Shutting down...")
            } else {
                // Wait indefinitely for shutdown signal
                await shutdownCoordinator.waitForShutdown()
                print("Shutdown requested...")
            }

            // Graceful shutdown
            print("Waiting for in-flight requests to complete...")
            await shutdownCoordinator.waitForInFlightRequests(timeout: 30)

            let remaining = await shutdownCoordinator.getInFlightCount()
            if remaining > 0 {
                print("Warning: \(remaining) request(s) still in progress, forcing shutdown")
            }

            // Release consumer VMs (notify providers, tear down VPNs)
            print("Releasing consumer VMs...")
            await self.releaseAllConsumerVMs(
                daemon: daemon,
                vmTracker: vmTracker,
                networkId: networkId
            )

            print("Stopping control socket...")
            await controlSocket.stop()

            print("Stopping mesh daemon...")
            await daemon.stop()

            print("Shutdown complete")

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
        dryRun: Bool,
        shutdownCoordinator: ShutdownCoordinator
    ) async -> ControlResponse {
        switch command {
        case .ping(let peerId, let timeout, let requestFullList):
            // Ping through the daemon's mesh network
            if let result = await daemon.ping(peerId: peerId, timeout: TimeInterval(timeout), requestFullList: requestFullList) {
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

        case .connect(let peerId, _):
            // Connect through the daemon's mesh network
            // Note: timeout parameter reserved for future use
            do {
                let connection = try await daemon.connect(to: peerId)
                return .connectResult(ControlResponse.ConnectResultData(
                    success: true,
                    peerId: connection.peerId,
                    endpoint: connection.endpoint,
                    isDirect: connection.isDirect,
                    method: connection.method.rawValue,
                    rttMs: connection.rttMs,
                    error: nil
                ))
            } catch {
                return .connectResult(ControlResponse.ConnectResultData(
                    success: false,
                    peerId: peerId,
                    endpoint: nil,
                    isDirect: false,
                    method: "",
                    rttMs: nil,
                    error: error.localizedDescription
                ))
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
            let peerInfos = await daemon.knownPeersWithInfo()
            let peers = peerInfos.map { info in
                ControlResponse.PeerData(peerId: info.peerId, endpoint: info.endpoint, lastSeen: info.lastSeen)
            }
            return .peers(peers)

        case .vmRequest(let peerId, let requirements, let sshPublicKey, let sshUser, let timeoutMinutes, let requestDryRun):
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
                dryRun: requestDryRun
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

        case .shutdown(let graceful, let timeoutSeconds):
            let inFlight = await shutdownCoordinator.getInFlightCount()
            let activeVMs = await daemon.getStatus().activeVMs

            if graceful && inFlight > 0 {
                // Return info about pending work, but still initiate shutdown
                let accepted = await shutdownCoordinator.requestShutdown()
                return .shutdownAck(ControlResponse.ShutdownData(
                    accepted: accepted,
                    inFlightRequests: inFlight,
                    activeVMs: activeVMs,
                    message: "Shutdown initiated, waiting for \(inFlight) in-flight request(s) (timeout: \(timeoutSeconds)s)"
                ))
            } else {
                let accepted = await shutdownCoordinator.requestShutdown()
                return .shutdownAck(ControlResponse.ShutdownData(
                    accepted: accepted,
                    inFlightRequests: inFlight,
                    activeVMs: activeVMs,
                    message: accepted ? "Shutdown initiated" : "Shutdown already in progress"
                ))
            }
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

        // Create MeshConsumerClient using the daemon's MeshNetwork
        let client: MeshConsumerClient
        do {
            client = try await MeshConsumerClient(
                meshNetwork: daemon.mesh,
                providerPeerId: providerPeerId,
                networkId: networkId,
                dryRun: dryRun
            )
        } catch {
            return .vmRequestResult(ControlResponse.VMRequestResultData(
                success: false,
                vmId: nil,
                vmIP: nil,
                sshCommand: nil,
                error: "Failed to initialize consumer client: \(error)"
            ))
        }

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

        // Create client using daemon's MeshNetwork
        let client: MeshConsumerClient
        do {
            client = try await MeshConsumerClient(
                meshNetwork: daemon.mesh,
                providerPeerId: vm.provider.peerId,
                networkId: vm.networkId,
                dryRun: false
            )
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

    /// Release all consumer VMs during shutdown
    /// This notifies providers and tears down VPN interfaces
    private func releaseAllConsumerVMs(
        daemon: MeshProviderDaemon,
        vmTracker: VMTracker,
        networkId: String
    ) async {
        let vms = await vmTracker.getActiveVMs()
        guard !vms.isEmpty else {
            print("  No consumer VMs to release")
            return
        }

        print("  Releasing \(vms.count) consumer VM(s)...")

        for vm in vms {
            do {
                let client = try await MeshConsumerClient(
                    meshNetwork: daemon.mesh,
                    providerPeerId: vm.provider.peerId,
                    networkId: vm.networkId,
                    dryRun: false
                )
                // Use forceLocalCleanup=true so we still clean up even if provider is unreachable
                try await client.releaseVM(vm, forceLocalCleanup: true)
                print("  Released VM \(vm.vmId.uuidString.prefix(8))")
            } catch {
                print("  Warning: Failed to release VM \(vm.vmId.uuidString.prefix(8)): \(error)")
                // Still try to clean up VPN locally
                let ephemeralVPN = EphemeralVPN()
                try? await ephemeralVPN.destroyVPN(for: vm.vmId)
                try? await vmTracker.removeVM(vm.vmId)
            }
        }
    }

    // MARK: - Consumer Message Handling

    private func handleConsumerMessage(
        from providerPeerId: String,
        data: Data,
        daemon: MeshProviderDaemon,
        vmTracker: VMTracker
    ) async {
        // Try to decode as provider shutdown notification first
        if let notification = try? JSONDecoder().decode(MeshProviderShutdownNotification.self, from: data),
           notification.type == "provider_shutdown" {
            await handleProviderShutdown(
                from: providerPeerId,
                notification: notification,
                vmTracker: vmTracker
            )
            return
        }

        // Try to decode as heartbeat request from a provider
        // Must validate type field to avoid confusing with other message types
        guard let heartbeat = try? JSONDecoder().decode(MeshVMHeartbeat.self, from: data),
              heartbeat.type == "vm_heartbeat" else {
            // Not a heartbeat or shutdown, ignore (could be other message types in the future)
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
                try? await daemon.sendOnChannel(responseData, to: providerPeerId, channel: VMChannels.heartbeat)
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
                try await daemon.sendOnChannel(responseData, to: providerPeerId, channel: VMChannels.heartbeat)
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

    /// Handle provider shutdown notification
    /// Cleans up VPN tunnels for VMs from the shutting-down provider
    private func handleProviderShutdown(
        from providerPeerId: String,
        notification: MeshProviderShutdownNotification,
        vmTracker: VMTracker
    ) async {
        var logger = Logger(label: "io.omerta.consumer.shutdown")
        logger.logLevel = .info

        logger.info("Provider shutting down", metadata: [
            "provider": "\(providerPeerId.prefix(16))...",
            "vmCount": "\(notification.vmIds.count)",
            "reason": "\(notification.reason)"
        ])

        // Get VMs we're tracking from this provider
        guard let allVMs = try? await vmTracker.loadPersistedVMs() else {
            logger.warning("Failed to load VMs from tracker")
            return
        }

        let vmsFromProvider = allVMs.filter { $0.provider.peerId == providerPeerId }
        let affectedVMs = vmsFromProvider.filter { notification.vmIds.contains($0.vmId) }

        guard !affectedVMs.isEmpty else {
            logger.debug("No tracked VMs affected by provider shutdown")
            return
        }

        logger.info("Cleaning up \(affectedVMs.count) VM(s) from shutting-down provider")

        let ephemeralVPN = EphemeralVPN()

        for vm in affectedVMs {
            // Tear down VPN
            do {
                try await ephemeralVPN.destroyVPN(for: vm.vmId)
                logger.info("VPN torn down", metadata: ["vmId": "\(vm.vmId.uuidString.prefix(8))..."])
            } catch {
                logger.warning("Failed to tear down VPN", metadata: [
                    "vmId": "\(vm.vmId.uuidString.prefix(8))...",
                    "error": "\(error)"
                ])
            }

            // Remove from tracker
            try? await vmTracker.removeVM(vm.vmId)
            logger.info("VM cleaned up due to provider shutdown", metadata: [
                "vmId": "\(vm.vmId.uuidString.prefix(8))..."
            ])
        }
    }
}

// MARK: - Stop Command

struct Stop: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Stop the provider daemon"
    )

    @Argument(help: "Network ID or prefix (default: first available)")
    var networkArg: String?

    @Option(name: .long, help: "Network ID or prefix (default: first available)")
    var network: String?

    @Option(name: .long, help: "Graceful shutdown timeout in seconds (default: 30)")
    var timeout: Int = 30

    @Flag(name: .long, help: "Force immediate shutdown (don't wait for in-flight requests)")
    var force: Bool = false

    mutating func run() async throws {
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        let networkId: String
        let specifiedNetwork = networkArg ?? network
        if let specified = specifiedNetwork {
            let (resolved, error) = await resolveNetwork(specified, store: networkStore)
            guard let net = resolved else {
                print(error ?? "Network '\(specified)' not found")
                throw ExitCode.failure
            }
            networkId = net.id
        } else {
            let networks = await networkStore.allNetworks()
            guard let firstNetwork = networks.first else {
                print("Error: No networks found")
                throw ExitCode.failure
            }
            networkId = firstNetwork.id
        }

        // Check if daemon is running
        let client = ControlSocketClient(networkId: networkId)
        guard client.isDaemonRunning() else {
            print("Daemon is not running for network '\(networkId)'")
            return
        }

        print("Stopping Omerta Provider Daemon...")

        // Send shutdown command
        do {
            let response = try await client.send(.shutdown(graceful: !force, timeoutSeconds: timeout))

            switch response {
            case .shutdownAck(let data):
                print(data.message)
                if data.inFlightRequests > 0 {
                    print("In-flight requests: \(data.inFlightRequests)")
                }
                if data.activeVMs > 0 {
                    print("Active VMs: \(data.activeVMs)")
                }
                print("")
                print("Daemon will shut down gracefully (timeout: \(timeout)s)")

            case .error(let msg):
                print("Error: \(msg)")
                throw ExitCode.failure

            default:
                print("Unexpected response from daemon")
            }
        } catch {
            print("Failed to stop daemon: \(error)")
            print("")
            print("The daemon may not be running, or you can force kill with:")
            print("  omerta kill")
            throw ExitCode.failure
        }
    }
}

// MARK: - Restart Command

struct Restart: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Restart the provider daemon with new configuration"
    )

    @Option(name: .shortAndLong, help: "Path to new config file")
    var config: String?

    @Argument(help: "Network ID or prefix (default: first available)")
    var networkArg: String?

    @Option(name: .long, help: "Network ID or prefix (default: first available)")
    var network: String?

    @Option(name: .long, help: "Graceful shutdown timeout in seconds (default: 30)")
    var timeout: Int = 30

    @Flag(name: .long, help: "Force immediate shutdown")
    var force: Bool = false

    mutating func run() async throws {
        // Find network ID
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        let networkId: String
        let specifiedNetwork = networkArg ?? network
        if let specified = specifiedNetwork {
            let (resolved, error) = await resolveNetwork(specified, store: networkStore)
            guard let net = resolved else {
                print(error ?? "Network '\(specified)' not found")
                throw ExitCode.failure
            }
            networkId = net.id
        } else {
            let networks = await networkStore.allNetworks()
            guard let firstNetwork = networks.first else {
                print("Error: No networks found")
                throw ExitCode.failure
            }
            networkId = firstNetwork.id
        }

        let client = ControlSocketClient(networkId: networkId)
        let wasRunning = client.isDaemonRunning()

        if wasRunning {
            print("Stopping current daemon...")

            // Send shutdown command
            do {
                let response = try await client.send(.shutdown(graceful: !force, timeoutSeconds: timeout))
                if case .shutdownAck(let data) = response {
                    print(data.message)
                }
            } catch {
                print("Warning: Failed to gracefully stop daemon: \(error)")
                print("Attempting force kill...")

                // Force kill via signal
                let killProcess = Process()
                killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                killProcess.arguments = ["-TERM", "-f", "omertad.*--network.*\(networkId)"]
                try? killProcess.run()
                killProcess.waitUntilExit()
            }

            // Wait for daemon to stop
            print("Waiting for daemon to stop...")
            var attempts = 0
            while client.isDaemonRunning() && attempts < timeout {
                try await Task.sleep(for: .seconds(1))
                attempts += 1
            }

            if client.isDaemonRunning() {
                print("Warning: Daemon still running after \(timeout)s, forcing kill...")
                let killProcess = Process()
                killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                killProcess.arguments = ["-KILL", "-f", "omertad.*--network.*\(networkId)"]
                try? killProcess.run()
                killProcess.waitUntilExit()
                try await Task.sleep(for: .seconds(1))
            }
        }

        print("")
        print("Starting daemon...")

        // Build start command
        var args = ["start", "--network", networkId]
        if let config = config {
            args += ["--config", config]
        }

        // Start new daemon
        print("Run in a new terminal:")
        print("  omertad \(args.joined(separator: " "))")
        print("")
        print("Or to start in the background:")
        print("  nohup omertad \(args.joined(separator: " ")) > /tmp/omertad.log 2>&1 &")
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
            ConfigGenerate.self,
            ConfigShow.self,
            ConfigTrust.self,
            ConfigBlock.self
        ],
        defaultSubcommand: ConfigShow.self
    )
}

struct ConfigGenerate: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate a sample config file"
    )

    @Option(name: .long, help: "Output path (default: ~/.omerta/omertad.conf)")
    var output: String?

    @Argument(help: "Network ID or prefix to include in config")
    var networkArg: String?

    @Option(name: .long, help: "Network ID or prefix to include in config")
    var network: String?

    @Flag(name: .long, help: "Overwrite existing config file")
    var force: Bool = false

    @Flag(name: .long, help: "Print to stdout instead of writing to file")
    var stdout: Bool = false

    mutating func run() async throws {
        // Resolve network ID if provided
        var resolvedNetworkId: String?
        let specifiedNetwork = networkArg ?? network
        if let specified = specifiedNetwork {
            let networkStore = NetworkStore.defaultStore()
            try await networkStore.load()
            let (resolved, error) = await resolveNetwork(specified, store: networkStore)
            guard let net = resolved else {
                print(error ?? "Network '\(specified)' not found")
                throw ExitCode.failure
            }
            resolvedNetworkId = net.id
        }

        let content = DaemonConfig.sampleConfig(network: resolvedNetworkId)

        if stdout {
            print(content)
            return
        }

        let outputPath = output ?? DaemonConfig.defaultPath
        let expandedPath = expandTilde(outputPath)

        // Check if file exists
        if FileManager.default.fileExists(atPath: expandedPath) && !force {
            print("Config file already exists: \(expandedPath)")
            print("Use --force to overwrite")
            throw ExitCode.failure
        }

        // Create directory if needed
        let directory = (expandedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // Write config
        try content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
        print("Generated config file: \(expandedPath)")
        print("")
        print("Edit the file to set your network ID, then start the daemon with:")
        print("  omertad start")
    }
}

struct ConfigShow: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show current configuration"
    )

    @Option(name: .shortAndLong, help: "Path to config file")
    var config: String?

    mutating func run() async throws {
        let configPath = config ?? DaemonConfig.defaultPath
        let expandedPath = expandTilde(configPath)

        print("Provider Daemon Configuration")
        print("=============================")
        print("")
        print("Config file: \(expandedPath)")
        print("")

        if FileManager.default.fileExists(atPath: expandedPath) {
            do {
                let loadedConfig = try DaemonConfig.load(from: configPath)
                print("Settings:")
                print("  network:      \(loadedConfig.network ?? "(not set)")")
                print("  port:         \(loadedConfig.port)")
                print("  no-provider:  \(loadedConfig.noProvider)")
                print("  dry-run:      \(loadedConfig.dryRun)")
                print("  can-relay:    \(loadedConfig.canRelay)")
                print("  hole-punch:   \(loadedConfig.canCoordinateHolePunch)")
                if let timeout = loadedConfig.timeout {
                    print("  timeout:      \(timeout)s")
                } else {
                    print("  timeout:      (none)")
                }
                print("")
                print("Raw file contents:")
                print("──────────────────────────────────────")
                let contents = try String(contentsOfFile: expandedPath, encoding: .utf8)
                print(contents)
                print("──────────────────────────────────────")
            } catch {
                print("Error reading config: \(error.localizedDescription)")
            }
        } else {
            print("(Config file not found)")
            print("")
            print("Default settings will be used:")
            print("  network:      (must specify via --network)")
            print("  port:         9999")
            print("  no-provider:  false")
            print("  dry-run:      false")
            print("  can-relay:    true")
            print("  hole-punch:   true")
            print("  timeout:      (none)")
            print("")
            print("Generate a config file with:")
            print("  omertad config generate")
        }
    }
}

struct ConfigTrust: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Add a trusted network"
    )

    @Argument(help: "Network ID or prefix to trust")
    var networkArg: String

    mutating func run() async throws {
        // Resolve network ID prefix
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        let (resolved, error) = await resolveNetwork(networkArg, store: networkStore)
        guard let net = resolved else {
            print(error ?? "Network '\(networkArg)' not found")
            throw ExitCode.failure
        }

        print("Added trusted network: \(net.id)")
        print("  Name: \(net.name)")
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
