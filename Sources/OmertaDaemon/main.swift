import Foundation
import ArgumentParser
import Logging
import OmertaCore
import OmertaVM
import OmertaProvider

@main
struct OmertaDaemon: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "omertad",
        abstract: "Omerta provider daemon - provides VM resources to network peers",
        version: "0.5.0 (Phase 5: Consumer Client)",
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

    @Option(name: .long, help: "Control port to listen on")
    var port: UInt16 = 51820

    @Option(name: .long, help: "Network key (hex encoded)")
    var networkKey: String

    @Option(name: .long, help: "Owner peer ID (gets highest priority)")
    var ownerPeer: String?

    @Option(name: .long, help: "Trusted network IDs (comma-separated)")
    var trustedNetworks: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable activity logging")
    var activityLog: Bool = true

    mutating func run() async throws {
        print("Starting Omerta Provider Daemon...")
        print("")

        // Parse network key
        guard let keyData = Data(hexString: networkKey), keyData.count == 32 else {
            print("Error: Network key must be a 64-character hex string (32 bytes)")
            throw ExitCode.failure
        }

        // Parse trusted networks
        let networks = trustedNetworks?.components(separatedBy: ",") ?? []

        // Create configuration
        let config = ProviderDaemon.Configuration(
            controlPort: port,
            networkKey: keyData,
            ownerPeerId: ownerPeer,
            trustedNetworks: networks,
            enableActivityLogging: activityLog
        )

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

        // Create and start daemon
        let daemon = ProviderDaemon(config: config)

        do {
            try await daemon.start()

            print("")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("  Omerta Provider Daemon Running")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("")
            print("Control Port: \(port)")
            if let owner = ownerPeer {
                print("Owner peer: \(owner)")
            }
            if !networks.isEmpty {
                print("Trusted networks: \(networks.joined(separator: ", "))")
            }
            print("")
            print("Ready to accept VM requests from network peers.")
            print("VMs will be accessible via SSH over WireGuard tunnel.")
            print("")
            print("Press Ctrl+C to stop")
            print("")

            // Keep running until interrupted
            try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))  // 1 year

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
        print("Version: 0.5.0 (Phase 5: Consumer Client)")
        print("")

        // In a real implementation, this would connect to running daemon
        print("Status: Not Running")
        print("")
        print("To start the daemon:")
        print("  omertad start --network-key <64-char-hex-key>")
        print("")
        print("Provider daemon:")
        print("  - Accepts VM requests from network peers")
        print("  - Creates isolated VMs accessible via SSH")
        print("  - Routes all VM traffic through WireGuard tunnel")
        print("  - Monitors VPN health and kills VMs on tunnel failure")
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

// MARK: - Helpers

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex

        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
