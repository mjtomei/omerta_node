import Foundation
import ArgumentParser
import OmertaCore
import OmertaVM
import OmertaNetwork
import OmertaConsumer
import Logging
#if canImport(NetworkExtension)
import NetworkExtension
#endif
#if canImport(SystemExtensions)
import SystemExtensions
#endif

@main
struct OmertaCLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "omerta",
        abstract: "Omerta - Decentralized VM Infrastructure",
        version: "0.5.0 (Phase 5: VM Infrastructure)",
        subcommands: [
            Setup.self,
            Network.self,
            VPN.self,
            VM.self,
            Status.self,
            CheckDeps.self
        ],
        defaultSubcommand: Status.self
    )
}

// MARK: - Setup Command
struct Setup: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Set up Omerta VPN extension (one-time setup)"
    )

    @Flag(name: .long, help: "Check status only, don't install")
    var statusOnly: Bool = false

    @Flag(name: .long, help: "Force reinstall even if already installed")
    var force: Bool = false

    mutating func run() async throws {
        print("Omerta VPN Setup")
        print("================")
        print("")

        #if canImport(NetworkExtension)
        // Check current status
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let extensionBundleId = "com.matthewtomei.Omerta.OmertaVPNExtension"

        let existingManager = managers.first { manager in
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == extensionBundleId
        }

        if let manager = existingManager {
            print("[✓] VPN extension is installed")
            print("    Enabled: \(manager.isEnabled ? "Yes" : "No")")
            print("    Status: \(connectionStatusString(manager.connection.status))")

            if statusOnly {
                return
            }

            if !force {
                print("")
                print("Setup is already complete. Use --force to reinstall.")
                return
            }

            print("")
            print("Removing existing configuration...")
            try await manager.removeFromPreferences()
        } else {
            print("[!] VPN extension not installed")

            if statusOnly {
                print("")
                print("Run 'omerta setup' to install the VPN extension.")
                throw ExitCode.failure
            }
        }

        print("")
        print("Installing VPN extension...")
        print("")
        print("You will be prompted to:")
        print("  1. Allow the VPN configuration")
        print("  2. Allow the System Extension in System Preferences")
        print("")

        // Create new VPN configuration
        let manager = NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleId
        proto.serverAddress = "Omerta VPN"

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Omerta VPN"
        manager.isEnabled = true

        // This will trigger the VPN permission dialog
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        print("[✓] VPN configuration created")
        print("")

        #if canImport(SystemExtensions)
        // Request system extension activation
        print("Requesting system extension activation...")
        print("")
        print("Please approve the extension in System Preferences when prompted.")
        print("")

        // Note: This requires the CLI to be inside the app bundle
        let bundleId = extensionBundleId
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleId,
            queue: .main
        )

        // For CLI, we use a simple delegate
        let delegate = ExtensionRequestDelegate()
        request.delegate = delegate

        OSSystemExtensionManager.shared.submitRequest(request)

        // Wait for completion (with timeout)
        print("Waiting for extension approval...")
        let result = await delegate.waitForResult(timeout: 120)

        switch result {
        case .success:
            print("[✓] System extension activated successfully")
        case .needsApproval:
            print("[!] Extension requires approval")
            print("")
            print("Open System Preferences > Privacy & Security and click 'Allow'")
            print("Then run 'omerta setup --status-only' to verify")
        case .failed(let error):
            print("[✗] Extension activation failed: \(error)")
            throw ExitCode.failure
        case .timeout:
            print("[!] Extension approval timed out")
            print("")
            print("Check System Preferences > Privacy & Security")
            print("Then run 'omerta setup --status-only' to verify")
        }
        #endif

        print("")
        print("Setup complete! You can now use 'omerta vm request' without sudo.")

        #else
        print("Error: NetworkExtension framework not available")
        print("This command requires macOS with Network Extension support.")
        throw ExitCode.failure
        #endif
    }

    #if canImport(NetworkExtension)
    private func connectionStatusString(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "Invalid"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reasserting"
        case .disconnecting: return "Disconnecting"
        @unknown default: return "Unknown"
        }
    }
    #endif
}

#if canImport(SystemExtensions)
/// Helper delegate for handling system extension requests
class ExtensionRequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    enum Result {
        case success
        case needsApproval
        case failed(String)
        case timeout
    }

    private var continuation: CheckedContinuation<Result, Never>?

    func waitForResult(timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            // Set up timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if self.continuation != nil {
                    self.continuation?.resume(returning: .timeout)
                    self.continuation = nil
                }
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        continuation?.resume(returning: .needsApproval)
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            continuation?.resume(returning: .success)
        case .willCompleteAfterReboot:
            continuation?.resume(returning: .success)
        @unknown default:
            continuation?.resume(returning: .failed("Unknown result"))
        }
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        continuation?.resume(returning: .failed(error.localizedDescription))
        continuation = nil
    }
}
#endif

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
        print("Creating new network: \(name)")

        let networkManager = NetworkManager()
        try await networkManager.loadNetworks()

        let key = await networkManager.createNetwork(
            name: name,
            bootstrapEndpoint: endpoint
        )

        print("\nNetwork created successfully!")
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
        print("Joining network...")

        do {
            let networkKey = try NetworkKey.decode(from: key)

            let networkManager = NetworkManager()
            try await networkManager.loadNetworks()

            let networkId = try await networkManager.joinNetwork(
                key: networkKey,
                name: name
            )

            print("\nSuccessfully joined network!")
            print("")
            print("Network: \(name ?? networkKey.networkName)")
            print("Network ID: \(networkId)")
            print("Bootstrap peers: \(networkKey.bootstrapPeers.joined(separator: ", "))")
            print("")
            print("To see all networks:")
            print("  omerta network list")

        } catch {
            print("Failed to join network: \(error)")
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
            print("  omerta network create --name \"My Network\" --endpoint \"<your-ip>:51820\"")
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
            let status = isEnabled ? "[Active]" : "[Paused]"

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
            print("Network not found: \(id)")
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
            print("\nLeft network: \(network.name)")
        } catch {
            print("Failed to leave network: \(error)")
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
            print("Network not found: \(id)")
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
            print("  - \(peer)")
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
        abstract: "Show VPN tunnel status"
    )

    @Option(name: .long, help: "VM ID")
    var vmId: String?

    mutating func run() async throws {
        print("VPN Status")
        print("==========")
        print("")

        // List WireGuard interfaces
        let process = Process()
        process.executableURL = URL(fileURLWithPath: WireGuardPaths.wg)
        process.arguments = ["show"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if output.isEmpty {
            print("No active WireGuard tunnels")
        } else {
            print(output)
        }
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
        print("Testing VPN connectivity to \(serverIP)...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "3", serverIP]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("VPN server is reachable")
        } else {
            print("Cannot reach VPN server")
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
        print("Omerta VM Infrastructure")
        print("Version: 0.5.0")
        print("")
        print("[Complete] Phase 0: Project Bootstrap")
        print("[Complete] Phase 1: Core VM Management")
        print("[Complete] Phase 2: VPN Routing & Network Isolation")
        print("[Complete] Phase 3: Local Request Processing")
        print("[Complete] Phase 4: Network Discovery & Multi-Network")
        print("[Active]   Phase 5: Consumer Client & E2E")
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
        print("  vm        - Request, list, release, and cleanup VMs")
        print("  network   - Network management (create, join, list)")
        print("  vpn       - VPN management commands")
        print("  status    - Show this status information")
        print("")
        print("Quick start:")
        print("  omerta vm request --provider <ip:port> --network-key <key>")
        print("")
        print("For help on a specific command:")
        print("  omerta <command> --help")
    }
}

// MARK: - VM Command Group
struct VM: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Manage remote VMs (request, list, release)",
        subcommands: [
            VMRequest.self,
            VMList.self,
            VMRelease.self,
            VMConnect.self,
            VMCleanup.self
        ]
    )
}

// MARK: - VM Request Command
struct VMRequest: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "request",
        abstract: "Request a VM from a provider"
    )

    @Option(name: .long, help: "Provider endpoint (ip:port) - for direct connection")
    var provider: String?

    @Option(name: .long, help: "Network ID - for network-based discovery")
    var network: String?

    @Option(name: .long, help: "Network key (hex encoded, 64 chars)")
    var networkKey: String

    @Option(name: .long, help: "Number of CPU cores")
    var cpu: UInt32?

    @Option(name: .long, help: "CPU architecture (x86_64 or arm64)")
    var arch: String?

    @Option(name: .long, help: "Memory in MB")
    var memory: UInt64?

    @Option(name: .long, help: "Storage in MB")
    var storage: UInt64?

    @Option(name: .long, help: "GPU model (e.g., 'RTX 4090')")
    var gpu: String?

    @Option(name: .long, help: "GPU VRAM in MB")
    var vram: UInt64?

    @Option(name: .long, help: "GPU vendor (nvidia, amd, apple, intel)")
    var gpuVendor: String?

    @Flag(name: .long, help: "Retry on failure with different providers")
    var retry: Bool = false

    @Option(name: .long, help: "Maximum retry attempts")
    var maxRetries: Int = 3

    @Flag(name: .long, help: "Dry run - skip VPN setup (for testing without sudo)")
    var dryRun: Bool = false

    mutating func run() async throws {
        // Validate inputs
        guard provider != nil || network != nil else {
            print("Error: Must specify either --provider or --network")
            throw ExitCode.failure
        }

        // Parse network key
        guard let keyData = Data(hexString: networkKey), keyData.count == 32 else {
            print("Error: Network key must be a 64-character hex string (32 bytes)")
            throw ExitCode.failure
        }

        // Build requirements
        var gpuReq: GPURequirements? = nil
        if let gpuModel = gpu {
            var vendor: GPUVendor? = nil
            if let vendorStr = gpuVendor {
                vendor = GPUVendor(rawValue: vendorStr.lowercased())
            }
            gpuReq = GPURequirements(
                model: gpuModel,
                vramMB: vram,
                vendor: vendor
            )
        }

        var cpuArch: CPUArchitecture? = nil
        if let archStr = arch {
            cpuArch = CPUArchitecture(rawValue: archStr.lowercased())
        }

        let requirements = ResourceRequirements(
            cpuCores: cpu,
            cpuArchitecture: cpuArch,
            memoryMB: memory,
            storageMB: storage,
            gpu: gpuReq,
            networkBandwidthMbps: nil,
            imageId: nil
        )

        print("Requesting VM...")

        if let providerEndpoint = provider {
            // Direct provider mode
            try await requestVMDirect(
                providerEndpoint: providerEndpoint,
                networkKey: keyData,
                requirements: requirements,
                dryRun: dryRun
            )
        } else if let networkId = network {
            // Network discovery mode
            try await requestVMFromNetwork(
                networkId: networkId,
                networkKey: keyData,
                requirements: requirements,
                retry: retry,
                maxRetries: maxRetries,
                dryRun: dryRun
            )
        }
    }

    private func requestVMDirect(
        providerEndpoint: String,
        networkKey: Data,
        requirements: ResourceRequirements,
        dryRun: Bool
    ) async throws {
        print("Connecting to provider: \(providerEndpoint)")
        if dryRun {
            print("[DRY RUN] Skipping VPN setup")
        }

        // Create a minimal peer registry with just this provider
        let peerRegistry = PeerRegistry()

        // Create consumer client
        let client = ConsumerClient(
            peerRegistry: peerRegistry,
            networkKey: networkKey,
            dryRun: dryRun
        )

        // For direct mode, we need to manually add the provider
        // Create a fake peer announcement
        let announcement = PeerAnnouncement(
            peerId: "direct-\(providerEndpoint)",
            networkId: "direct",
            endpoint: providerEndpoint,
            capabilities: [
                ResourceCapability(
                    cpuCores: 8,
                    cpuArchitecture: .arm64,
                    cpuModel: nil,
                    totalMemoryMB: 16384,
                    availableMemoryMB: 12288,
                    totalStorageMB: 500_000,
                    availableStorageMB: 400_000,
                    gpu: nil,
                    networkBandwidthMbps: nil,
                    availableImages: ["ubuntu-22.04"]
                )
            ],
            metadata: PeerMetadata(reputationScore: 100, jobsCompleted: 0, jobsRejected: 0, averageResponseTimeMs: 50),
            signature: Data()
        )
        await peerRegistry.registerPeer(from: announcement)

        // Request VM
        let connection = try await client.requestVM(
            in: "direct",
            requirements: requirements,
            retryOnFailure: false
        )

        printVMConnection(connection)
    }

    private func requestVMFromNetwork(
        networkId: String,
        networkKey: Data,
        requirements: ResourceRequirements,
        retry: Bool,
        maxRetries: Int,
        dryRun: Bool
    ) async throws {
        print("Discovering providers in network: \(networkId)")
        if dryRun {
            print("[DRY RUN] Skipping VPN setup")
        }

        // Load network state
        let networkManager = NetworkManager()
        try await networkManager.loadNetworks()

        guard let _ = await networkManager.getNetwork(id: networkId) else {
            print("Error: Network not found. Join it first with 'omerta network join'")
            throw ExitCode.failure
        }

        // Create peer registry and start discovery
        let peerRegistry = PeerRegistry()
        let discoveryConfig = PeerDiscovery.Configuration(
            localPeerId: UUID().uuidString,
            localEndpoint: "0.0.0.0:0"  // Not providing, just consuming
        )
        let peerDiscovery = PeerDiscovery(
            config: discoveryConfig,
            networkManager: networkManager,
            peerRegistry: peerRegistry
        )

        try await peerDiscovery.start()

        // Wait a moment for discovery
        print("Discovering peers...")
        try await Task.sleep(for: .seconds(2))

        // Create consumer client
        let client = ConsumerClient(
            peerRegistry: peerRegistry,
            networkKey: networkKey,
            dryRun: dryRun
        )

        // Request VM
        let connection = try await client.requestVM(
            in: networkId,
            requirements: requirements,
            retryOnFailure: retry,
            maxRetries: maxRetries
        )

        await peerDiscovery.stop()

        printVMConnection(connection)
    }

    private func printVMConnection(_ connection: VMConnection) {
        print("")
        print("VM Created Successfully!")
        print("========================")
        print("")
        print("VM ID: \(connection.vmId)")
        print("Provider: \(connection.provider.endpoint)")
        print("VM IP: \(connection.vmIP)")
        print("VPN Interface: \(connection.vpnInterface)")
        print("")
        print("Connect with SSH:")
        print("  \(connection.sshCommand)")
        print("")
        print("Copy files with SCP:")
        print("  \(connection.scpCommand)")
        print("")
        print("To release this VM:")
        print("  omerta vm release \(connection.vmId) --network-key \(networkKey)")
    }
}

// MARK: - VM List Command
struct VMList: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List active VMs"
    )

    @Flag(name: .long, help: "Show detailed information")
    var detailed: Bool = false

    mutating func run() async throws {
        let tracker = VMTracker()
        let vms = try await tracker.loadPersistedVMs()

        if vms.isEmpty {
            print("No active VMs")
            print("")
            print("To request a VM:")
            print("  omerta vm request --provider <ip:port> --network-key <key>")
            return
        }

        print("Active VMs")
        print("==========")
        print("")

        for vm in vms {
            print("[\(vm.vmId.uuidString.prefix(8))...] \(vm.vmIP)")
            print("   Provider: \(vm.provider.endpoint)")
            print("   Network: \(vm.networkId)")
            print("   Created: \(formatDate(vm.createdAt))")

            if detailed {
                print("   VPN: \(vm.vpnInterface)")
                print("   SSH: \(vm.sshCommand)")
            }

            print("")
        }

        print("Total: \(vms.count) VMs")
        print("")
        print("To connect to a VM:")
        print("  omerta vm connect <vm-id>")
        print("")
        print("To release a VM:")
        print("  omerta vm release <vm-id> --network-key <key>")
        print("")
        print("To clean up orphaned resources:")
        print("  omerta vm cleanup")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - VM Release Command
struct VMRelease: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Release a VM"
    )

    @Argument(help: "VM ID to release (or prefix)")
    var vmId: String

    @Option(name: .long, help: "Network key (hex encoded)")
    var networkKey: String

    @Flag(name: .long, help: "Skip confirmation")
    var force: Bool = false

    mutating func run() async throws {
        // Parse network key
        guard let keyData = Data(hexString: networkKey), keyData.count == 32 else {
            print("Error: Network key must be a 64-character hex string (32 bytes)")
            throw ExitCode.failure
        }

        // Find VM by ID or prefix
        let tracker = VMTracker()
        let vms = try await tracker.loadPersistedVMs()

        let matchingVMs = vms.filter {
            $0.vmId.uuidString.lowercased().hasPrefix(vmId.lowercased()) ||
            $0.vmId.uuidString.lowercased() == vmId.lowercased()
        }

        guard let vm = matchingVMs.first else {
            print("Error: VM not found: \(vmId)")
            print("")
            print("Active VMs:")
            for v in vms {
                print("  \(v.vmId.uuidString.prefix(8))... - \(v.vmIP)")
            }
            throw ExitCode.failure
        }

        if matchingVMs.count > 1 {
            print("Error: Multiple VMs match '\(vmId)'. Be more specific:")
            for v in matchingVMs {
                print("  \(v.vmId)")
            }
            throw ExitCode.failure
        }

        if !force {
            print("Release VM \(vm.vmId.uuidString.prefix(8))... at \(vm.vmIP)?")
            print("Type 'yes' to confirm: ", terminator: "")

            guard let response = readLine()?.lowercased(), response == "yes" else {
                print("Cancelled.")
                return
            }
        }

        print("Releasing VM...")

        // Create consumer client
        let peerRegistry = PeerRegistry()
        let client = ConsumerClient(
            peerRegistry: peerRegistry,
            networkKey: keyData
        )

        try await client.releaseVM(vm)

        print("")
        print("VM released successfully")
    }
}

// MARK: - VM Connect Command
struct VMConnect: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "SSH into a VM"
    )

    @Argument(help: "VM ID to connect to (or prefix)")
    var vmId: String

    mutating func run() async throws {
        // Find VM by ID or prefix
        let tracker = VMTracker()
        let vms = try await tracker.loadPersistedVMs()

        let matchingVMs = vms.filter {
            $0.vmId.uuidString.lowercased().hasPrefix(vmId.lowercased()) ||
            $0.vmId.uuidString.lowercased() == vmId.lowercased()
        }

        guard let vm = matchingVMs.first else {
            print("Error: VM not found: \(vmId)")
            throw ExitCode.failure
        }

        if matchingVMs.count > 1 {
            print("Error: Multiple VMs match '\(vmId)'. Be more specific:")
            for v in matchingVMs {
                print("  \(v.vmId)")
            }
            throw ExitCode.failure
        }

        print("Connecting to VM \(vm.vmId.uuidString.prefix(8))... at \(vm.vmIP)")
        print("")

        // Execute SSH
        let expandedKeyPath = NSString(string: vm.sshKeyPath).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-i", expandedKeyPath, "\(vm.sshUser)@\(vm.vmIP)"]

        // Connect stdin/stdout/stderr
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()
    }
}

// MARK: - VM Cleanup Command
struct VMCleanup: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Clean up orphaned WireGuard interfaces and resources"
    )

    @Flag(name: .long, help: "Clean up all Omerta interfaces, not just orphaned ones")
    var all: Bool = false

    @Flag(name: .long, help: "Show status only, don't actually clean up")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Skip confirmation")
    var force: Bool = false

    mutating func run() async throws {
        print("WireGuard Cleanup")
        print("=================")
        print("")

        // Check if we have sudo access (needed for killing processes and stopping interfaces)
        if !checkSudoAccess() {
            print("Error: This command requires sudo privileges.")
            print("")
            print("Run with sudo:")
            print("  sudo omerta vm cleanup")
            throw ExitCode.failure
        }

        // Get current status
        let status: CleanupStatus
        do {
            status = try WireGuardCleanup.getCleanupStatus()
        } catch {
            print("Error checking WireGuard status: \(error)")
            print("")
            print("Make sure you have sudo access for 'wg' and 'wg-quick'")
            throw ExitCode.failure
        }

        // Load tracked VMs
        let tracker = VMTracker()
        let trackedVMs = try await tracker.loadPersistedVMs()
        let trackedInterfaces = Set(trackedVMs.map { $0.vpnInterface })

        // Identify orphaned vs tracked interfaces
        var orphanedInterfaces: [String] = []
        var trackedActiveInterfaces: [String] = []

        for iface in status.activeInterfaces {
            if trackedInterfaces.contains(iface) {
                trackedActiveInterfaces.append(iface)
            } else {
                orphanedInterfaces.append(iface)
            }
        }

        // Display status
        print("Active Omerta interfaces: \(status.activeInterfaces.count)")
        for iface in status.activeInterfaces {
            let isTracked = trackedInterfaces.contains(iface)
            let marker = isTracked ? "[tracked]" : "[orphaned]"
            print("  \(marker) \(iface)")
        }
        if status.activeInterfaces.isEmpty {
            print("  (none)")
        }
        print("")

        if !status.orphanedProcesses.isEmpty {
            print("Orphaned wireguard-go processes: \(status.orphanedProcesses.count)")
            for proc in status.orphanedProcesses {
                print("  PID \(proc.pid): \(proc.command)")
            }
            print("")
        }

        if !status.configFiles.isEmpty {
            print("Config files: \(status.configFiles.count)")
            for file in status.configFiles {
                print("  \(file)")
            }
            print("  in: \(status.configDirectory)")
            print("")
        }

        print("Tracked VMs: \(trackedVMs.count)")
        for vm in trackedVMs {
            let hasInterface = status.activeInterfaces.contains(vm.vpnInterface)
            let marker = hasInterface ? "[active]" : "[no interface]"
            print("  \(marker) \(vm.vmId.uuidString.prefix(8))... \(vm.vmIP) (\(vm.vpnInterface))")
        }
        print("")

        // Determine what to clean
        let interfacesToClean: [String]
        if all {
            interfacesToClean = status.activeInterfaces
        } else {
            interfacesToClean = orphanedInterfaces
        }

        // Check for stale VMs (tracked but no interface)
        let staleVMs = trackedVMs.filter { !status.activeInterfaces.contains($0.vpnInterface) }

        let hasOrphanedProcesses = !status.orphanedProcesses.isEmpty
        let hasInterfacesToClean = !interfacesToClean.isEmpty
        let hasConfigFiles = !status.configFiles.isEmpty
        let hasStaleVMs = !staleVMs.isEmpty

        if !hasInterfacesToClean && !hasConfigFiles && !hasOrphanedProcesses && (!hasStaleVMs || !all) {
            print("Nothing to clean up!")
            if hasStaleVMs {
                print("")
                print("Note: \(staleVMs.count) stale VM(s) tracked with no interface.")
                print("Use --all to clear stale tracking.")
            }
            return
        }

        if dryRun {
            print("[DRY RUN] Would clean up:")
            for proc in status.orphanedProcesses {
                print("  - Kill orphaned process: PID \(proc.pid)")
            }
            for iface in interfacesToClean {
                print("  - Stop interface: \(iface)")
            }
            for file in status.configFiles {
                print("  - Remove config: \(file)")
            }
            if all {
                for vm in staleVMs {
                    print("  - Remove stale tracking: \(vm.vmId.uuidString.prefix(8))...")
                }
            }
            return
        }

        // Confirm
        if !force {
            if hasOrphanedProcesses {
                print("This will kill \(status.orphanedProcesses.count) orphaned wireguard-go process(es).")
            }
            if all {
                if hasInterfacesToClean {
                    print("This will stop ALL Omerta WireGuard interfaces (\(interfacesToClean.count)).")
                    print("WARNING: Active VMs will lose connectivity!")
                }
                if hasStaleVMs {
                    print("This will remove \(staleVMs.count) stale VM tracking entries.")
                }
            } else if hasInterfacesToClean {
                print("This will clean up \(interfacesToClean.count) orphaned interfaces.")
            }
            print("")
            print("Type 'yes' to confirm: ", terminator: "")

            guard let response = readLine()?.lowercased(), response == "yes" else {
                print("Cancelled.")
                return
            }
        }

        // Perform cleanup
        print("")
        print("Cleaning up...")

        // Kill orphaned processes first
        var processesKilled = 0
        if hasOrphanedProcesses {
            for proc in status.orphanedProcesses {
                print("  Killing PID \(proc.pid)...", terminator: " ")
                do {
                    let killed = try WireGuardCleanup.killOrphanedProcesses([proc])
                    if killed > 0 {
                        print("done")
                        processesKilled += 1
                    } else {
                        print("failed")
                    }
                } catch {
                    print("failed: \(error)")
                }
            }
        }

        // Stop interfaces
        var cleanedCount = 0
        for iface in interfacesToClean {
            print("  Stopping \(iface)...", terminator: " ")
            do {
                try WireGuardCleanup.stopInterface(iface)
                print("done")
                cleanedCount += 1
            } catch {
                print("failed: \(error)")
            }
        }

        // Clean up config files
        WireGuardCleanup.cleanupConfigFiles()

        // If --all, also clear stale VM tracking
        if all && !staleVMs.isEmpty {
            print("")
            print("Clearing stale VM tracking...")
            for vm in staleVMs {
                try await tracker.removeVM(vm.vmId)
                print("  Removed \(vm.vmId.uuidString.prefix(8))...")
            }
        }

        print("")
        print("Cleanup complete!")
        if processesKilled > 0 {
            print("  Processes killed: \(processesKilled)")
        }
        if cleanedCount > 0 {
            print("  Interfaces stopped: \(cleanedCount)")
        }
        if all && hasStaleVMs {
            print("  Stale VMs removed: \(staleVMs.count)")
        }
    }
}

/// Check if we have sudo access without prompting for password
private func checkSudoAccess() -> Bool {
    // Check if running as root
    if getuid() == 0 {
        return true
    }

    // Check if we have cached sudo credentials or NOPASSWD
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-n", "true"]  // -n = non-interactive, fails if password needed
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
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

        do {
            try await checker.verifyProviderMode()
            print("")
            print("All dependencies satisfied - ready to run!")
        } catch let error as DependencyChecker.MissingDependenciesError {
            print("")
            print("Missing dependencies detected")
            print("")
            print("Run the installation script:")
            print("  curl -sSL https://raw.githubusercontent.com/omerta/omerta/main/Scripts/install.sh | bash")
            print("")
            print("Or install manually:")
            print(error.description)
            throw ExitCode.failure
        }
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
