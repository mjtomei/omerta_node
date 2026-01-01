import Foundation
import ArgumentParser
import OmertaCore
import OmertaVM
import OmertaNetwork
import Logging

@main
struct OmertaCLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "omerta",
        abstract: "Omerta compute sharing client",
        version: "0.4.0 (Phase 4: Network Discovery)",
        subcommands: [
            Execute.self,
            Submit.self,
            Network.self,
            VPN.self,
            Status.self,
            CheckDeps.self
        ],
        defaultSubcommand: Status.self
    )
}

// MARK: - Execute Command (Local VM execution)
struct Execute: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Execute a job locally in an ephemeral VM"
    )

    @Option(name: .long, help: "Script content to execute")
    var script: String

    @Option(name: .long, help: "Script language (bash, python, etc.)")
    var language: String = "bash"

    @Option(name: .long, help: "Number of CPU cores")
    var cpu: UInt32 = 2

    @Option(name: .long, help: "Memory in MB")
    var memory: UInt64 = 2048

    @Option(name: .long, help: "Max runtime in seconds")
    var maxRuntime: UInt64 = 300

    @Option(name: .long, help: "VPN endpoint (IP:port)")
    var vpnEndpoint: String

    @Option(name: .long, help: "VPN server IP within VPN network")
    var vpnServerIP: String

    @Option(name: .long, help: "WireGuard config file path")
    var vpnConfig: String

    mutating func run() async throws {
        print("🚀 Executing job locally with VPN routing...")

        // Check dependencies first
        let checker = DependencyChecker()
        do {
            try await checker.verifyProviderMode()
        } catch let error as DependencyChecker.MissingDependenciesError {
            print("\n❌ Missing required dependencies:")
            print(error.description)
            print("\nRun setup script to install:")
            print("  curl -sSL https://raw.githubusercontent.com/omerta/omerta/main/Scripts/install.sh | bash")
            throw ExitCode.failure
        }

        // Load VPN config
        let wireguardConfig = try String(contentsOfFile: vpnConfig)

        let vpnConfiguration = VPNConfiguration(
            wireguardConfig: wireguardConfig,
            endpoint: vpnEndpoint,
            publicKey: Data("placeholder".utf8), // Would be parsed from config
            vpnServerIP: vpnServerIP
        )

        let job = ComputeJob(
            requesterId: "local",
            networkId: "local",
            requirements: ResourceRequirements(
                type: .cpuOnly,
                cpuCores: cpu,
                memoryMB: memory,
                maxRuntimeSeconds: maxRuntime
            ),
            workload: .script(ScriptWorkload(
                language: language,
                scriptContent: script
            )),
            vpnConfig: vpnConfiguration
        )

        let vmManager = VirtualizationManager()

        do {
            let result = try await vmManager.executeJob(job)

            print("\n✅ Job completed successfully!")
            print("Exit code: \(result.exitCode)")
            print("Execution time: \(result.metrics.executionTimeMs)ms")
            print("\nStdout:")
            if let stdout = String(data: result.stdout, encoding: .utf8) {
                print(stdout)
            }

            if !result.stderr.isEmpty {
                print("\nStderr:")
                if let stderr = String(data: result.stderr, encoding: .utf8) {
                    print(stderr)
                }
            }
        } catch {
            print("\n❌ Job failed: \(error)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Submit Command (Remote submission)
struct Submit: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Submit a job to a remote provider"
    )

    @Option(name: .long, help: "Script content to execute")
    var script: String

    @Option(name: .long, help: "Script language")
    var language: String = "bash"

    @Option(name: .long, help: "Number of CPU cores")
    var cpu: UInt32 = 2

    @Option(name: .long, help: "Memory in MB")
    var memory: UInt64 = 2048

    @Flag(name: .long, help: "Automatically create ephemeral VPN")
    var createVPN: Bool = false

    @Option(name: .long, help: "Activity description")
    var description: String?

    mutating func run() async throws {
        print("📤 Submitting job to network...")

        // Check dependencies first
        let checker = DependencyChecker()
        do {
            try await checker.verifyRequesterMode()
        } catch let error as DependencyChecker.MissingDependenciesError {
            print("\n❌ Missing required dependencies:")
            print(error.description)
            print("\nRun setup script to install:")
            print("  curl -sSL https://raw.githubusercontent.com/omerta/omerta/main/Scripts/install.sh | bash")
            throw ExitCode.failure
        }

        if createVPN {
            print("🔐 Creating ephemeral VPN for job...")

            let ephemeralVPN = EphemeralVPN()
            let jobId = UUID()

            let vpnConfig = try await ephemeralVPN.createVPNForJob(jobId)

            print("✅ VPN created successfully")
            print("   Endpoint: \(vpnConfig.endpoint)")
            print("   VPN Server IP: \(vpnConfig.vpnServerIP)")

            // In a real implementation, would submit job to provider here
            print("\n⚠️  Phase 3 (Provider Mode) not yet implemented")
            print("Job would be submitted with VPN configuration to remote provider")

            // Cleanup
            try await ephemeralVPN.destroyVPN(for: jobId)
        } else {
            print("⚠️  Please provide VPN configuration or use --create-vpn")
            throw ExitCode.failure
        }
    }
}

// MARK: - Network Command
struct Network: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Network management commands",
        subcommands: [
            NetworkCreate.self,
            NetworkJoin.self,
            NetworkList.self,
            NetworkLeave.self,
            NetworkShow.self
        ]
    )
}

struct NetworkCreate: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new network and get shareable key"
    )

    @Option(name: .long, help: "Network name")
    var name: String

    @Option(name: .long, help: "Local endpoint (IP:port) for bootstrap")
    var endpoint: String

    mutating func run() async throws {
        print("🌐 Creating new network: \(name)")

        let networkManager = NetworkManager()
        try await networkManager.loadNetworks()

        let key = await networkManager.createNetwork(
            name: name,
            bootstrapEndpoint: endpoint
        )

        print("\n✅ Network created successfully!")
        print("")
        print("Network: \(name)")
        print("Network ID: \(key.deriveNetworkId())")
        print("")
        print("Share this key with others to invite them:")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        do {
            let encodedKey = try key.encode()
            print(encodedKey)
        } catch {
            print("Error encoding key: \(error)")
        }

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print("To join this network:")
        print("  omerta network join --key <key-above>")
    }
}

struct NetworkJoin: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "join",
        abstract: "Join a network using a shared key"
    )

    @Option(name: .long, help: "Network key (omerta://join/...)")
    var key: String

    @Option(name: .long, help: "Optional custom name for the network")
    var name: String?

    mutating func run() async throws {
        print("🌐 Joining network...")

        do {
            let networkKey = try NetworkKey.decode(from: key)

            let networkManager = NetworkManager()
            try await networkManager.loadNetworks()

            let networkId = try await networkManager.joinNetwork(
                key: networkKey,
                name: name
            )

            print("\n✅ Successfully joined network!")
            print("")
            print("Network: \(name ?? networkKey.networkName)")
            print("Network ID: \(networkId)")
            print("Bootstrap peers: \(networkKey.bootstrapPeers.joined(separator: ", "))")
            print("")
            print("To see all networks:")
            print("  omerta network list")

        } catch {
            print("❌ Failed to join network: \(error)")
            throw ExitCode.failure
        }
    }
}

struct NetworkList: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all joined networks"
    )

    @Flag(name: .long, help: "Show detailed information")
    var detailed: Bool = false

    mutating func run() async throws {
        let networkManager = NetworkManager()
        try await networkManager.loadNetworks()

        let networks = await networkManager.getNetworks()

        if networks.isEmpty {
            print("No networks joined yet.")
            print("")
            print("To create a network:")
            print("  omerta network create --name \"My Network\" --endpoint \"<your-ip>:50051\"")
            print("")
            print("To join a network:")
            print("  omerta network join --key <network-key>")
            return
        }

        print("Joined Networks")
        print("===============")
        print("")

        for network in networks.sorted(by: { $0.joinedAt > $1.joinedAt }) {
            let isEnabled = await networkManager.isNetworkEnabled(network.id)
            let status = isEnabled ? "✅ Active" : "⏸  Paused"

            print("\(status) \(network.name)")
            print("   ID: \(network.id.prefix(16))...")
            print("   Joined: \(formatDate(network.joinedAt))")

            if detailed {
                print("   Bootstrap peers: \(network.key.bootstrapPeers.joined(separator: ", "))")
            }

            print("")
        }

        print("Total: \(networks.count) networks")
        print("")
        print("To see network details:")
        print("  omerta network show --id <network-id>")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct NetworkLeave: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "leave",
        abstract: "Leave a network"
    )

    @Option(name: .long, help: "Network ID")
    var id: String

    @Flag(name: .long, help: "Skip confirmation")
    var force: Bool = false

    mutating func run() async throws {
        let networkManager = NetworkManager()
        try await networkManager.loadNetworks()

        guard let network = await networkManager.getNetwork(id: id) else {
            print("❌ Network not found: \(id)")
            throw ExitCode.failure
        }

        if !force {
            print("Are you sure you want to leave '\(network.name)'?")
            print("You will need the network key to rejoin.")
            print("")
            print("Type 'yes' to confirm: ", terminator: "")

            guard let response = readLine()?.lowercased(), response == "yes" else {
                print("Cancelled.")
                return
            }
        }

        do {
            try await networkManager.leaveNetwork(networkId: id)
            print("\n✅ Left network: \(network.name)")
        } catch {
            print("❌ Failed to leave network: \(error)")
            throw ExitCode.failure
        }
    }
}

struct NetworkShow: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show detailed information about a network"
    )

    @Option(name: .long, help: "Network ID")
    var id: String

    mutating func run() async throws {
        let networkManager = NetworkManager()
        try await networkManager.loadNetworks()

        guard let network = await networkManager.getNetwork(id: id) else {
            print("❌ Network not found: \(id)")
            throw ExitCode.failure
        }

        let isEnabled = await networkManager.isNetworkEnabled(id)

        print("Network Details")
        print("===============")
        print("")
        print("Name: \(network.name)")
        print("ID: \(network.id)")
        print("Status: \(isEnabled ? "Active" : "Paused")")
        print("Joined: \(network.joinedAt)")
        print("")
        print("Bootstrap Peers:")
        for peer in network.key.bootstrapPeers {
            print("  • \(peer)")
        }
        print("")
        print("Network Key (for sharing):")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        do {
            let encodedKey = try network.key.encode()
            print(encodedKey)
        } catch {
            print("Error encoding key: \(error)")
        }

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print("To enable/disable this network:")
        print("  omerta network enable --id \(network.id)")
        print("  omerta network disable --id \(network.id)")
    }
}

// MARK: - VPN Command
struct VPN: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "VPN management commands",
        subcommands: [
            VPNStatus.self,
            VPNTest.self
        ]
    )
}

struct VPNStatus: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show VPN tunnel status for a job"
    )

    @Option(name: .long, help: "Job ID")
    var jobId: String

    mutating func run() async throws {
        guard let uuid = UUID(uuidString: jobId) else {
            print("❌ Invalid job ID")
            throw ExitCode.failure
        }

        print("🔍 Checking VPN status for job \(jobId)...")

        // In real implementation, would query VPNManager
        print("⚠️  VPN status checking not yet fully implemented")
        print("Would show:")
        print("  - Tunnel interface status")
        print("  - Bytes transmitted/received")
        print("  - Last handshake time")
        print("  - Connection health")
    }
}

struct VPNTest: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Test VPN connectivity"
    )

    @Option(name: .long, help: "VPN server IP")
    var serverIP: String

    mutating func run() async throws {
        print("🔍 Testing VPN connectivity to \(serverIP)...")

        // Simple ping test
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "3", serverIP]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("✅ VPN server is reachable")
        } else {
            print("❌ Cannot reach VPN server")
            throw ExitCode.failure
        }
    }
}

// MARK: - Status Command
struct Status: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Show Omerta status and version information"
    )

    @Flag(name: .long, help: "Check system dependencies")
    var checkDeps: Bool = false

    mutating func run() async throws {
        print("Omerta Compute Sharing Platform")
        print("Version: 0.4.0")
        print("")
        print("✅ Phase 0: Project Bootstrap - Complete")
        print("✅ Phase 1: Core VM Management - Complete")
        print("✅ Phase 2: VPN Routing & Network Isolation - Complete")
        print("✅ Phase 3: Local Request Processing - Complete")
        print("✅ Phase 4: Network Discovery & Multi-Network - Complete")
        print("⏳ Phase 5: Consumer Client & E2E - Pending")
        print("")

        if checkDeps {
            print("System Dependencies:")
            print("===================")
            print("")
            let checker = DependencyChecker()
            await checker.printProviderReport()
            print("")
        }

        print("Available commands:")
        print("  execute   - Execute job locally with VPN routing")
        print("  submit    - Submit job to remote provider")
        print("  network   - Network management (create, join, list, etc.)")
        print("  vpn       - VPN management commands")
        print("  status    - Show this status information")
        print("")
        print("For help on a specific command, run:")
        print("  omerta <command> --help")
        print("")
        print("To check system dependencies:")
        print("  omerta status --check-deps")
    }
}

// MARK: - Check Dependencies Command
struct CheckDeps: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "check-deps",
        abstract: "Check system dependencies"
    )

    mutating func run() async throws {
        let checker = DependencyChecker()
        await checker.printProviderReport()

        // Try to verify (will throw if missing)
        do {
            try await checker.verifyProviderMode()
            print("")
            print("✅ All dependencies satisfied - ready to run!")
        } catch let error as DependencyChecker.MissingDependenciesError {
            print("")
            print("❌ Missing dependencies detected")
            print("")
            print("Run the installation script to install missing dependencies:")
            print("  curl -sSL https://raw.githubusercontent.com/omerta/omerta/main/Scripts/install.sh | bash")
            print("")
            print("Or install manually:")
            print(error.description)
            throw ExitCode.failure
        }
    }
}
