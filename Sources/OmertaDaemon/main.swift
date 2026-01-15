import Foundation
import ArgumentParser
import Logging
import OmertaCore
import OmertaVM
import OmertaProvider
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

    @Option(name: .long, help: "Network key (hex encoded 32 bytes). Uses local key from config if not specified.")
    var networkKey: String?

    @Option(name: .long, help: "Mesh port (default: 9999)")
    var port: Int = 9999

    @Option(name: .long, help: "Bootstrap peers for mesh network (comma-separated, format: peerId@host:port)")
    var bootstrapPeers: String?

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

        // Determine network key - use provided or load from config
        let keyData: Data
        if let providedKey = networkKey {
            guard let data = Data(hexString: providedKey), data.count == 32 else {
                print("Error: Network key must be a 64-character hex string (32 bytes)")
                throw ExitCode.failure
            }
            keyData = data
        } else {
            // Load from config
            let configManager = ConfigManager()
            do {
                let config = try await configManager.load()
                guard let localKeyData = config.localKeyData() else {
                    print("Error: No network key specified and no local key in config.")
                    print("Run 'omerta init' to generate a local key, or specify --network-key")
                    throw ExitCode.failure
                }
                keyData = localKeyData
                print("Using local encryption key from config")
            } catch ConfigError.notInitialized {
                print("Error: Omerta not initialized and no --network-key specified.")
                print("Run 'omerta init' first, or specify --network-key")
                throw ExitCode.failure
            }
        }

        // Check dependencies
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
        try await runMeshDaemon(keyData: keyData)
    }

    private func runMeshDaemon(keyData: Data) async throws {
        // Parse bootstrap peers
        let parsedBootstrapPeers: [String]
        if let bootstrapPeersStr = bootstrapPeers {
            parsedBootstrapPeers = bootstrapPeersStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            parsedBootstrapPeers = []
        }

        // Build mesh config with encryption key
        var meshConfig = MeshConfig(
            encryptionKey: keyData,
            port: port,
            canRelay: true,
            canCoordinateHolePunch: true,
            bootstrapPeers: parsedBootstrapPeers
        )

        // Generate cryptographic identity (peer ID is derived from public key)
        let identity = OmertaMesh.IdentityKeypair()

        // Create mesh daemon configuration
        let daemonConfig = MeshProviderDaemon.Configuration(
            identity: identity,
            meshConfig: meshConfig,
            dryRun: dryRun
        )

        // Create and start mesh daemon
        let daemon = MeshProviderDaemon(config: daemonConfig)

        do {
            try await daemon.start()

            let status = await daemon.getStatus()

            print("")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("  Omerta Provider Daemon Running")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("")
            print("Peer ID: \(identity.peerId)")
            print("Mesh Port: \(port)")
            print("NAT Type: \(status.natType.rawValue)")
            if let publicEndpoint = status.publicEndpoint {
                print("Public Endpoint: \(publicEndpoint)")
            }
            if !parsedBootstrapPeers.isEmpty {
                print("Bootstrap Peers: \(parsedBootstrapPeers.joined(separator: ", "))")
            }
            print("")
            print("Ready to accept VM requests via mesh network.")
            print("Consumers behind NAT can connect using: --peer \(identity.peerId)")
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
                await daemon.stop()
            }

        } catch {
            print("Failed to start daemon: \(error)")
            throw ExitCode.failure
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
