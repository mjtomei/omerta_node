import Foundation
import ArgumentParser
import OmertaCore
import OmertaVM
import OmertaVPN
import OmertaConsumer
import OmertaProvider
import OmertaMesh
import Logging
import Crypto
#if canImport(NetworkExtension)
import NetworkExtension
#endif
#if canImport(SystemExtensions)
import SystemExtensions
#endif

// MARK: - Cross-platform date formatting helper

/// Format a date as relative time (cross-platform replacement for RelativeDateTimeFormatter)
func formatRelativeDate(_ date: Date) -> String {
    let now = Date()
    let interval = now.timeIntervalSince(date)

    if interval < 0 {
        // Future date
        return "in the future"
    }

    let seconds = Int(interval)
    let minutes = seconds / 60
    let hours = minutes / 60
    let days = hours / 24

    if seconds < 60 {
        return "just now"
    } else if minutes < 60 {
        return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
    } else if hours < 24 {
        return "\(hours) hour\(hours == 1 ? "" : "s") ago"
    } else if days < 7 {
        return "\(days) day\(days == 1 ? "" : "s") ago"
    } else {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

@main
struct OmertaCLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "omerta",
        abstract: "Omerta - Decentralized VM Infrastructure",
        version: "0.5.0 (Phase 5: VM Infrastructure)",
        subcommands: [
            Init.self,
            Setup.self,
            Network.self,
            VPN.self,
            VM.self,
            Mesh.self,
            NAT.self,
            Status.self,
            CheckDeps.self,
            Kill.self,
            Ping.self
        ],
        defaultSubcommand: Status.self
    )
}

// MARK: - Init Command
struct Init: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize Omerta configuration and SSH keys"
    )

    @Flag(name: .long, help: "Force reinitialize even if already initialized")
    var force: Bool = false

    @Option(name: .long, help: "Path to existing SSH private key to import")
    var importKey: String?

    @Option(name: .long, help: "Default SSH username for VMs")
    var sshUser: String = "omerta"

    mutating func run() async throws {
        print("Omerta Initialization")
        print("=====================")
        print("")

        let configManager = ConfigManager()

        // Check if already initialized
        if await configManager.exists() && !force {
            print("[✓] Already initialized")
            print("")
            print("Configuration: \(OmertaConfig.configFilePath)")

            do {
                let config = try await configManager.load()
                print("SSH Key: \(config.ssh.expandedPrivateKeyPath())")
                if let pubKey = config.ssh.publicKey {
                    print("Public Key: \(pubKey.prefix(50))...")
                }
                print("Default SSH User: \(config.ssh.defaultUser)")
                print("Networks: \(config.networks.count)")
            } catch {
                print("Error loading config: \(error)")
            }

            print("")
            print("Use --force to reinitialize.")
            return
        }

        // Create SSH keypair
        let sshDir = "\(OmertaConfig.defaultConfigDir)/ssh"
        let privateKeyPath = "\(sshDir)/id_ed25519"
        let publicKeyPath = "\(sshDir)/id_ed25519.pub"

        var publicKey: String

        if let importPath = importKey {
            // Import existing key
            print("Importing SSH key from: \(importPath)")

            let expandedPath = expandPath(importPath)
            let pubPath = expandedPath + ".pub"

            guard FileManager.default.fileExists(atPath: expandedPath) else {
                print("Error: Private key not found at \(importPath)")
                throw ExitCode.failure
            }

            guard FileManager.default.fileExists(atPath: pubPath) else {
                print("Error: Public key not found at \(importPath).pub")
                throw ExitCode.failure
            }

            // Copy keys to omerta directory
            try FileManager.default.createDirectory(
                atPath: sshDir,
                withIntermediateDirectories: true
            )

            // Read and copy keys
            let privateKeyContent = try String(contentsOfFile: expandedPath)
            let publicKeyContent = try String(contentsOfFile: pubPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            try privateKeyContent.write(
                toFile: expandPath(privateKeyPath),
                atomically: true,
                encoding: .utf8
            )
            try publicKeyContent.write(
                toFile: expandPath(publicKeyPath),
                atomically: true,
                encoding: .utf8
            )

            // Set permissions
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: expandPath(privateKeyPath)
            )

            publicKey = publicKeyContent
            print("[✓] SSH key imported")

        } else {
            // Generate new keypair
            print("Generating SSH keypair...")

            // Check if keys already exist
            if SSHKeyGenerator.keyPairExists(privateKeyPath: privateKeyPath, publicKeyPath: publicKeyPath) {
                if force {
                    print("  Removing existing keys...")
                    try? FileManager.default.removeItem(atPath: expandPath(privateKeyPath))
                    try? FileManager.default.removeItem(atPath: expandPath(publicKeyPath))
                } else {
                    print("  Using existing keys")
                    publicKey = try SSHKeyGenerator.readPublicKey(path: publicKeyPath)
                }
            }

            // Generate if needed
            if !SSHKeyGenerator.keyPairExists(privateKeyPath: privateKeyPath, publicKeyPath: publicKeyPath) {
                let hostname = ProcessInfo.processInfo.hostName
                let username = ProcessInfo.processInfo.environment["USER"] ?? "user"
                let comment = "\(username)@\(hostname)-omerta"

                let (_, pubKey) = try SSHKeyGenerator.generateKeyPair(
                    privateKeyPath: privateKeyPath,
                    publicKeyPath: publicKeyPath,
                    comment: comment
                )
                publicKey = pubKey
                print("[✓] SSH keypair generated")
            } else {
                publicKey = try SSHKeyGenerator.readPublicKey(path: publicKeyPath)
            }
        }

        print("  Private: \(privateKeyPath)")
        print("  Public:  \(publicKeyPath)")
        print("")

        // Create config with auto-generated local key
        print("Creating configuration...")

        let localKey = OmertaConfig.generateLocalKey()
        print("[✓] Local encryption key generated")

        let sshConfig = SSHConfig(
            privateKeyPath: privateKeyPath,
            publicKeyPath: publicKeyPath,
            publicKey: publicKey,
            defaultUser: sshUser
        )

        let config = OmertaConfig(
            ssh: sshConfig,
            networks: [:],
            defaultNetwork: nil,
            localKey: localKey
        )

        try await configManager.save(config)
        print("[✓] Configuration saved")
        print("  Path: \(OmertaConfig.configFilePath)")
        print("")

        print("Initialization complete!")
        print("")
        print("Your SSH public key (add to VMs):")
        print("  \(publicKey)")
        print("")
        print("Quick start (local testing):")
        print("  Terminal 1: sudo omertad start")
        print("  Terminal 2: omerta vm request --provider 127.0.0.1:51820")
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let homeDir = OmertaConfig.defaultConfigDir.replacingOccurrences(
                of: "/.omerta",
                with: ""
            )
            return homeDir + String(path.dropFirst(1))
        }
        return path
    }
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

        // Generate identity for this network
        let identityStore = IdentityStore.defaultStore()
        try await identityStore.load()

        // We need a temporary network ID to store identity - use a placeholder first
        // then update after we know the real network ID
        let tempIdentity = IdentityKeypair()
        let peerId = tempIdentity.peerId

        // Generate a new network key with peerId@endpoint as bootstrap
        let bootstrapPeer = "\(peerId)@\(endpoint)"
        let key = NetworkKey.generate(
            networkName: name,
            bootstrapPeers: [bootstrapPeer]
        )

        let networkId = key.deriveNetworkId()

        // Save identity for this network
        // Store the identity we generated (not a new one from getOrCreate)
        let identityStorePath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: "/tmp")
        let identitiesPath = identityStorePath
            .appendingPathComponent("OmertaMesh")
            .appendingPathComponent("identities.json")

        // Read existing identities, add ours, save
        var identities: [String: [String: String]] = [:]
        if FileManager.default.fileExists(atPath: identitiesPath.path),
           let data = try? Data(contentsOf: identitiesPath),
           let existing = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            identities = existing
        }
        identities[networkId] = [
            "privateKeyBase64": tempIdentity.privateKeyBase64,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]

        try FileManager.default.createDirectory(
            at: identitiesPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let identityData = try encoder.encode(identities)
        try identityData.write(to: identitiesPath)

        // Join the network we just created
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()
        _ = try await networkStore.join(key, name: name)

        print("\nNetwork created successfully!")
        print("")
        print("Network: \(name)")
        print("Network ID: \(networkId)")
        print("Your Peer ID: \(peerId)")
        print("Bootstrap: \(bootstrapPeer)")
        print("")
        print("Share this invite link with others:")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        do {
            let encodedKey = try key.encode()
            print(encodedKey)
        } catch {
            print("Error encoding key: \(error)")
        }

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("")
        print("To start the provider daemon:")
        print("  omertad start --network \(networkId) --port \(endpoint.split(separator: ":").last ?? "9999")")
        print("")
        print("Others can join with:")
        print("  omerta network join --key '<invite-link>'")
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
            let networkId = networkKey.deriveNetworkId()

            // Generate identity for this network
            let identity = IdentityKeypair()

            // Save identity for this network
            let identityStorePath = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: "/tmp")
            let identitiesPath = identityStorePath
                .appendingPathComponent("OmertaMesh")
                .appendingPathComponent("identities.json")

            // Read existing identities, add ours (if not already present), save
            var identities: [String: [String: String]] = [:]
            if FileManager.default.fileExists(atPath: identitiesPath.path),
               let data = try? Data(contentsOf: identitiesPath),
               let existing = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
                identities = existing
            }

            // Only create identity if one doesn't already exist for this network
            if identities[networkId] == nil {
                identities[networkId] = [
                    "privateKeyBase64": identity.privateKeyBase64,
                    "createdAt": ISO8601DateFormatter().string(from: Date())
                ]

                try FileManager.default.createDirectory(
                    at: identitiesPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let identityData = try encoder.encode(identities)
                try identityData.write(to: identitiesPath)
            }

            let networkStore = NetworkStore.defaultStore()
            try await networkStore.load()

            let network = try await networkStore.join(networkKey, name: name)

            print("\nSuccessfully joined network!")
            print("")
            print("Network: \(network.name)")
            print("Network ID: \(network.id)")
            print("Your Peer ID: \(identity.peerId)")
            print("Bootstrap peers: \(networkKey.bootstrapPeers.joined(separator: ", "))")
            print("")
            print("To start participating in this network:")
            print("  omertad start --network \(network.id)")

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
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        let networks = await networkStore.allNetworks()

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
            let status = network.isActive ? "[Active]" : "[Paused]"

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
        formatRelativeDate(date)
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
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        guard let network = await networkStore.network(id: id) else {
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
            try await networkStore.leave(id)
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
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        guard let network = await networkStore.network(id: id) else {
            print("Network not found: \(id)")
            throw ExitCode.failure
        }

        print("Network Details")
        print("===============")
        print("")
        print("Name: \(network.name)")
        print("ID: \(network.id)")
        print("Status: \(network.isActive ? "Active" : "Paused")")
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
            VPNTest.self,
            VPNNetlinkTest.self,
            VPNMacOSTest.self
        ]
    )
}

struct VPNMacOSTest: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "macos-test",
        abstract: "Test native macOS WireGuard implementation (macOS only)"
    )

    @Flag(name: .long, help: "Dry run - don't actually create interfaces")
    var dryRun: Bool = false

    mutating func run() async throws {
        #if os(macOS)
        print("=== Native macOS VPN Test ===")
        print("")

        // 1. Test /dev/pf access
        print("1. Testing /dev/pf access...")
        let pfFd = open("/dev/pf", O_RDWR)
        if pfFd >= 0 {
            print("   ✓ Successfully opened /dev/pf (fd=\(pfFd))")
            close(pfFd)
        } else {
            print("   ✗ Failed to open /dev/pf: \(String(cString: strerror(errno)))")
            print("     (This requires root privileges)")
        }

        // 2. Test routing socket
        print("")
        print("2. Testing PF_ROUTE socket...")
        let routeSock = socket(PF_ROUTE, SOCK_RAW, 0)
        if routeSock >= 0 {
            print("   ✓ Successfully created routing socket (fd=\(routeSock))")
            close(routeSock)
        } else {
            print("   ✗ Failed to create routing socket: \(String(cString: strerror(errno)))")
        }

        // 3. Test utun creation
        print("")
        print("3. Testing utun interface creation...")

        if dryRun {
            print("   [DRY RUN] Would create utun interface")
            print("")
            print("=== Test completed (dry run) ===")
            return
        }

        do {
            let (fd, ifName) = try MacOSUtunManager.createInterface()
            print("   ✓ Created utun interface: \(ifName) (fd=\(fd))")

            // 4. Configure interface
            print("")
            print("4. Configuring interface...")
            let testIP = "10.200.200.1"
            try MacOSUtunManager.addIPv4Address(interface: ifName, address: testIP, prefixLength: 24)
            print("   ✓ Added IP address: \(testIP)/24")

            try MacOSUtunManager.setMTU(interface: ifName, mtu: 1420)
            print("   ✓ Set MTU to 1420")

            try MacOSUtunManager.setInterfaceUp(interface: ifName, up: true)
            print("   ✓ Interface is UP")

            // 5. Verify with ifconfig
            print("")
            print("5. Verifying interface with ifconfig...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
            process.arguments = [ifName]
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print(output)

            // 6. Test routing
            print("6. Testing route addition...")
            try MacOSRoutingManager.addRoute(destination: "10.200.201.0", prefixLength: 24, interface: ifName)
            print("   ✓ Added route 10.200.201.0/24 via \(ifName)")

            // Verify route
            let routeProcess = Process()
            routeProcess.executableURL = URL(fileURLWithPath: "/sbin/route")
            routeProcess.arguments = ["get", "10.200.201.1"]
            let routePipe = Pipe()
            routeProcess.standardOutput = routePipe
            routeProcess.standardError = routePipe
            try? routeProcess.run()
            routeProcess.waitUntilExit()
            let routeOutput = String(data: routePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if routeOutput.contains(ifName) {
                print("   ✓ Route verified")
            }

            // Clean up route
            try? MacOSRoutingManager.deleteRoute(destination: "10.200.201.0", prefixLength: 24)
            print("   ✓ Route deleted")

            // 7. Test pf rules (if /dev/pf accessible)
            print("")
            print("7. Testing pf rules...")
            do {
                try MacOSPacketFilterManager.enable()
                print("   ✓ pf enabled")

                let anchor = "omerta/test-\(Int.random(in: 1000...9999))"
                // pf rules - macOS pf syntax (needs newline at end)
                let rules = "pass on \(ifName)\n"
                try MacOSPacketFilterManager.loadRulesIntoAnchor(anchor: anchor, rules: rules)
                print("   ✓ Loaded rules into anchor: \(anchor)")

                try MacOSPacketFilterManager.flushAnchor(anchor: anchor)
                print("   ✓ Flushed anchor")
            } catch {
                print("   ⚠ pf test skipped: \(error)")
            }

            // 8. Clean up - close fd destroys interface
            print("")
            print("8. Cleaning up...")
            MacOSUtunManager.closeInterface(fd: fd)
            print("   ✓ Interface \(ifName) destroyed")

            print("")
            print("=== Test completed successfully ===")

        } catch {
            print("   ✗ Failed: \(error)")
            throw ExitCode.failure
        }
        #else
        print("Native macOS implementation is only available on macOS")
        throw ExitCode.failure
        #endif
    }
}

struct VPNNetlinkTest: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "netlink-test",
        abstract: "Test native Linux WireGuard netlink implementation (Linux only)"
    )

    @Flag(name: .long, help: "Dry run - don't actually create interfaces")
    var dryRun: Bool = false

    mutating func run() async throws {
        #if os(Linux)
        print("=== WireGuard Native Netlink Test ===")
        print("")

        // 1. Generate test keys
        print("1. Generating WireGuard keys using Swift Crypto...")
        let keyData = SymmetricKey(size: .bits256)
        let privateKeyData = keyData.withUnsafeBytes { Data($0) }
        let privateKey = privateKeyData.base64EncodedString()

        let curve25519Private = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        let publicKey = curve25519Private.publicKey.rawRepresentation.base64EncodedString()

        print("   Private key: \(privateKey.prefix(20))...")
        print("   Public key:  \(publicKey.prefix(20))...")

        let interfaceName = "wg-test-\(Int.random(in: 1000...9999))"
        let vpnAddress = "10.200.200.1"
        let prefixLength: UInt8 = 24

        print("")
        print("2. Creating WireGuard interface '\(interfaceName)' with native netlink...")

        if dryRun {
            print("   [DRY RUN] Would create interface with:")
            print("     - Name: \(interfaceName)")
            print("     - Address: \(vpnAddress)/\(prefixLength)")
            print("     - Private key: \(privateKey.prefix(20))...")
            print("")
            print("=== Test completed (dry run) ===")
            return
        }

        let wg = LinuxWireGuardManager()

        // Create interface
        try wg.createInterface(
            name: interfaceName,
            privateKeyBase64: privateKey,
            listenPort: 0,
            address: vpnAddress,
            prefixLength: prefixLength,
            peers: []
        )
        print("   ✓ Interface created successfully")

        // Verify with ip command
        print("")
        print("3. Verifying interface with 'ip link show'...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ip")
        process.arguments = ["link", "show", interfaceName]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print(output)

        // Check IP address
        print("4. Checking IP address with 'ip addr show'...")
        let addrProcess = Process()
        addrProcess.executableURL = URL(fileURLWithPath: "/sbin/ip")
        addrProcess.arguments = ["addr", "show", interfaceName]
        let addrPipe = Pipe()
        addrProcess.standardOutput = addrPipe
        addrProcess.standardError = addrPipe
        try addrProcess.run()
        addrProcess.waitUntilExit()
        let addrOutput = String(data: addrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print(addrOutput)

        // Clean up
        print("5. Cleaning up - deleting interface...")
        try wg.deleteInterface(name: interfaceName)
        print("   ✓ Interface deleted successfully")

        print("")
        print("=== Test completed successfully ===")
        #else
        print("Native netlink implementation is only available on Linux")
        throw ExitCode.failure
        #endif
    }
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
        print("  omerta vm request --network <network-id> --peer <provider-peer-id>")
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
            VMStatus.self,
            VMRelease.self,
            VMConnect.self,
            VMCleanup.self,
            VMTest.self,
            VMBootTest.self
        ]
    )
}

// MARK: - VM Request Command
struct VMRequest: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "request",
        abstract: "Request a VM from a provider"
    )

    @Option(name: .long, help: "Network ID (from 'omerta network join' or 'omerta network list')")
    var network: String?

    @Option(name: .long, help: "Provider peer ID to request VM from")
    var peer: String?

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

    @Flag(name: .long, help: "Wait for WireGuard connection before exiting")
    var wait: Bool = false

    @Option(name: .long, help: "Timeout in seconds when using --wait (default: 120)")
    var waitTimeout: Int = 120

    @Option(name: .long, help: "Heartbeat timeout in minutes - VM will be reclaimed if no heartbeat (default: 10)")
    var timeout: Int = 10

    mutating func run() async throws {
        // Check for root/sudo (required for WireGuard)
        if !dryRun && getuid() != 0 {
            print("Error: This command requires sudo to create WireGuard tunnels.")
            print("Run with: sudo omerta vm request ...")
            print("Or use --dry-run to skip VPN setup (for testing)")
            throw ExitCode.failure
        }

        // Validate inputs
        guard let networkId = network else {
            print("Error: --network <id> is required")
            print("")
            print("To join a network:")
            print("  omerta network join --key '<invite-link>'")
            print("")
            print("To list networks:")
            print("  omerta network list")
            throw ExitCode.failure
        }

        guard let providerPeerId = peer else {
            print("Error: --peer <provider-peer-id> is required")
            print("")
            print("The provider will display their peer ID when they start omertad.")
            throw ExitCode.failure
        }

        // Load network from store
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
                print("Join a network with:")
                print("  omerta network join --key '<invite-link>'")
            } else {
                for n in networks {
                    print("  \(n.id) - \(n.name)")
                }
            }
            throw ExitCode.failure
        }

        print("Network: \(storedNetwork.name) (\(networkId))")
        print("Provider: \(providerPeerId)")

        // Load config for SSH key
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("Error: Omerta not initialized. Run 'omerta init' first.")
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

        // Check omertad is running
        let controlClient = ControlSocketClient(networkId: networkId)
        guard controlClient.isDaemonRunning() else {
            print("Error: omertad is not running for network '\(networkId)'")
            print("")
            print("Start the daemon with:")
            print("  omertad start --network \(networkId)")
            throw ExitCode.failure
        }

        if dryRun {
            print("[DRY RUN] Skipping VPN setup")
        }

        guard let sshPublicKey = config.ssh.publicKey else {
            print("")
            print("Error: SSH public key not found in config. Run 'omerta init' to regenerate.")
            throw ExitCode.failure
        }

        print("Using SSH key: \(config.ssh.expandedPrivateKeyPath())")

        // Encode requirements for IPC
        guard let requirementsData = try? JSONEncoder().encode(requirements) else {
            print("Error: Failed to encode requirements")
            throw ExitCode.failure
        }

        print("")
        print("Requesting VM via daemon (timeout: \(timeout) minutes)...")

        // Send VM request through daemon IPC
        let response = try await controlClient.send(
            .vmRequest(
                peerId: providerPeerId,
                requirements: requirementsData,
                sshPublicKey: sshPublicKey,
                sshUser: config.ssh.defaultUser,
                timeoutMinutes: timeout
            ),
            timeout: 120  // Allow 2 minutes for the request to complete
        )

        // Handle response
        guard case .vmRequestResult(let result) = response else {
            print("Error: Unexpected response from daemon")
            throw ExitCode.failure
        }

        guard result.success, let vmId = result.vmId, let vmIP = result.vmIP else {
            print("")
            print("VM request failed: \(result.error ?? "Unknown error")")
            throw ExitCode.failure
        }

        let vmIdPrefix = vmId.uuidString.prefix(8)

        print("")
        print("VM Created Successfully!")
        print("========================")
        print("")
        print("VM ID: \(vmId)")
        print("VM IP: \(vmIP)")
        if let sshCommand = result.sshCommand {
            print("SSH: \(sshCommand)")
        } else {
            print("SSH: ssh -i \(config.ssh.expandedPrivateKeyPath()) \(config.ssh.defaultUser)@\(vmIP)")
        }
        print("VPN Interface: wg\(vmIdPrefix)")
        print("Heartbeat Timeout: \(timeout) minutes")

        // Wait for WireGuard connection if requested
        if wait && !dryRun {
            print("")
            print("Waiting for VM to establish WireGuard connection...")
            var connected = false
            for _ in 0..<waitTimeout {
                try await Task.sleep(for: .seconds(1))
                if await pingHost(vmIP) {
                    connected = true
                    break
                }
            }
            if !connected {
                print("Warning: Could not verify VM connectivity within \(waitTimeout)s")
                print("The VM may still be booting. You can check connection status with:")
                print("  sudo wg show wg\(vmIdPrefix)")
            } else {
                print("WireGuard connection established!")
            }
        }

        print("")
        print("To release this VM when done:")
        print("  omerta vm release \(vmIdPrefix)")
    }

    /// Simple ping check (non-blocking, quick timeout)
    private func pingHost(_ host: String) async -> Bool {
        // Use nc (netcat) for a quick check - try SSH port
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-w", "1", host, "22"]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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

            // Still check for orphaned resources even if no tracked VMs
            await checkForOrphanedResources(trackedInterfaces: [])
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
        print("  omerta vm release <vm-id>")

        // Check for orphaned resources
        let trackedInterfaces = Set(vms.map { $0.vpnInterface })
        await checkForOrphanedResources(trackedInterfaces: trackedInterfaces)
    }

    private func checkForOrphanedResources(trackedInterfaces: Set<String>) async {
        // Try to get WireGuard status (may fail without sudo, that's OK)
        guard let status = try? WireGuardCleanup.getCleanupStatus() else {
            return
        }

        // Find orphaned interfaces (active but not tracked)
        let orphanedInterfaces = status.activeInterfaces.filter { !trackedInterfaces.contains($0) }
        let orphanedProcessCount = status.orphanedProcesses.count

        if orphanedInterfaces.isEmpty && orphanedProcessCount == 0 {
            return
        }

        print("")
        print("⚠️  Orphaned resources detected:")
        if !orphanedInterfaces.isEmpty {
            print("   \(orphanedInterfaces.count) WireGuard interface\(orphanedInterfaces.count == 1 ? "" : "s") not tracked")
        }
        if orphanedProcessCount > 0 {
            print("   \(orphanedProcessCount) orphaned wireguard-go process\(orphanedProcessCount == 1 ? "" : "es")")
        }
        print("")
        print("Run 'sudo omerta vm cleanup' to remove orphaned resources.")
    }

    private func formatDate(_ date: Date) -> String {
        formatRelativeDate(date)
    }
}

// MARK: - VM Status Command
struct VMStatus: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Query VM status from provider (deprecated)"
    )

    @Option(name: .long, help: "Provider endpoint (ip:port)")
    var provider: String

    @Option(name: .long, help: "Network key (hex encoded)")
    var networkKey: String?

    @Option(name: .long, help: "Specific VM ID to query (default: all)")
    var vmId: String?

    mutating func run() async throws {
        // Direct status queries are deprecated - use local VM tracking
        print("Error: Direct provider status queries are deprecated.")
        print("")
        print("To list your active VMs:")
        print("  omerta vm list")
        print("")
        print("The mesh network tracks VM state automatically.")
        throw ExitCode.failure
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

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompt")
    var yes: Bool = false

    @Flag(name: .long, help: "Force local cleanup even if provider communication fails")
    var forceLocal: Bool = false

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

        if !yes {
            print("Release VM \(vm.vmId.uuidString.prefix(8))... at \(vm.vmIP)?")
            print("Type 'yes' to confirm: ", terminator: "")

            guard let response = readLine()?.lowercased(), response == "yes" else {
                print("Cancelled.")
                return
            }
        }

        print("Releasing VM...")

        // Load network for mesh communication
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        var providerNotified = false

        // Try to notify provider via mesh
        if let network = await networkStore.network(id: vm.networkId) {
            // Check omertad is running
            let controlClient = ControlSocketClient(networkId: vm.networkId)
            if controlClient.isDaemonRunning() {
                // Ping provider first to ensure they know where to respond
                do {
                    let _ = try await controlClient.send(.ping(peerId: vm.provider.peerId, timeout: 5))
                } catch {
                    print("Warning: Could not ping provider: \(error)")
                }
            }

            do {
                let keyData = network.key.networkKey

                // Load shared identity from store
                let identityStore = IdentityStore.defaultStore()
                try await identityStore.load()

                guard let identity = try await identityStore.getIdentity(forNetwork: vm.networkId) else {
                    print("Warning: No identity found for network, skipping provider notification")
                    throw NSError(domain: "VMRelease", code: 1, userInfo: nil)
                }

                let meshConfig = MeshConfig(
                    encryptionKey: keyData,
                    bootstrapPeers: network.key.bootstrapPeers
                )

                let mesh = MeshNetwork(identity: identity, config: meshConfig)
                try await mesh.start()

                // Send release request to provider
                print("Notifying provider...")
                let releaseRequest = ["type": "vm_release", "vmId": vm.vmId.uuidString]
                if let requestData = try? JSONEncoder().encode(releaseRequest) {
                    try await mesh.send(requestData, to: vm.provider.peerId)
                    // Wait briefly for acknowledgment
                    try await Task.sleep(nanoseconds: 500_000_000)
                    providerNotified = true
                    print("Provider notified")
                }

                await mesh.stop()
            } catch {
                print("Warning: Could not notify provider: \(error)")
            }
        } else {
            print("Warning: Network '\(vm.networkId)' not found, skipping provider notification")
        }

        // Local cleanup
        do {
            // 1. Tear down VPN tunnel
            let ephemeralVPN = EphemeralVPN()
            try await ephemeralVPN.destroyVPN(for: vm.vmId)

            // 2. Remove from tracker
            try await tracker.removeVM(vm.vmId)

            print("")
            print("VM released successfully")
            if providerNotified {
                print("Provider has been notified to stop the VM.")
            } else {
                print("Note: Provider was not notified. VM may still be running on provider.")
            }
        } catch {
            print("")
            print("Error: Failed to release VM locally: \(error)")
            if !forceLocal {
                print("")
                print("Use --force-local to force cleanup of local resources.")
                throw ExitCode.failure
            }

            // Force local cleanup
            print("Forcing local cleanup...")
            try? await tracker.removeVM(vm.vmId)
            print("Local cleanup complete")
        }
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

// MARK: - QEMU Cleanup Utilities

/// Represents an orphaned QEMU process
struct OrphanedQEMUProcess: Sendable {
    let pid: Int32
    let vmId: String?
    let command: String
}

/// Cleanup utilities for QEMU processes and VM files
enum QEMUCleanup {
    /// List all running QEMU processes
    static func listQEMUProcesses() -> [OrphanedQEMUProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "qemu-system"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var processes: [OrphanedQEMUProcess] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if let pidStr = parts.first, let pid = Int32(pidStr) {
                let command = parts.count > 1 ? String(parts[1]) : "qemu-system"
                // Try to extract VM ID from command line (look for UUID pattern)
                var vmId: String? = nil
                if let range = command.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", options: .regularExpression) {
                    vmId = String(command[range])
                }
                processes.append(OrphanedQEMUProcess(pid: pid, vmId: vmId, command: command))
            }
        }

        return processes
    }

    /// Check if a QEMU process is orphaned (PID file exists but process doesn't match)
    static func findOrphanedQEMUProcesses(vmDisksDir: String) -> [(process: OrphanedQEMUProcess, pidFile: String?)] {
        var orphaned: [(process: OrphanedQEMUProcess, pidFile: String?)] = []

        // Get all PID files
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: vmDisksDir) else {
            return orphaned
        }

        let pidFiles = files.filter { $0.hasSuffix(".pid") }
        var pidFileMap: [Int32: String] = [:]  // PID -> PID file path
        var orphanedPidFiles: [String] = []     // PID files with dead processes

        for pidFile in pidFiles {
            let fullPath = "\(vmDisksDir)/\(pidFile)"
            if let pidStr = try? String(contentsOfFile: fullPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidStr) {
                // Check if process is still running
                if kill(pid, 0) == 0 {
                    pidFileMap[pid] = fullPath
                } else {
                    orphanedPidFiles.append(fullPath)
                }
            }
        }

        // Find running QEMU processes that match orphaned PID files
        let runningProcesses = listQEMUProcesses()

        // Any running QEMU process without a valid PID file is orphaned
        for proc in runningProcesses {
            if pidFileMap[proc.pid] == nil {
                orphaned.append((process: proc, pidFile: nil))
            }
        }

        return orphaned
    }

    /// Kill a QEMU process
    static func killProcess(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["kill", "-9", String(pid)]
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

    #if os(Linux)
    /// List all TAP interfaces created by Omerta (tap-XXXXXXXX pattern)
    static func listTAPInterfaces() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ip")
        process.arguments = ["link", "show"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var tapInterfaces: [String] = []
        // Look for lines like "117: tap-F0F03B68: <BROADCAST,..."
        for line in output.split(separator: "\n") {
            let lineStr = String(line)
            if let range = lineStr.range(of: "tap-[0-9A-Fa-f]{8}", options: .regularExpression) {
                tapInterfaces.append(String(lineStr[range]))
            }
        }

        return tapInterfaces
    }

    /// Delete a TAP interface
    static func deleteTAPInterface(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["ip", "link", "delete", name]
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
    #endif

    /// Get all VM-related files in the vm-disks directory grouped by VM ID
    static func getVMFiles(vmDisksDir: String) -> [String: VMFiles] {
        var vmFilesMap: [String: VMFiles] = [:]

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: vmDisksDir) else {
            return vmFilesMap
        }

        for file in files {
            // Extract VM ID from filename (UUID at the start)
            guard let range = file.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", options: .regularExpression) else {
                continue
            }

            let vmId = String(file[range])
            let fullPath = "\(vmDisksDir)/\(file)"

            var vmFiles = vmFilesMap[vmId] ?? VMFiles(vmId: vmId)

            if file.hasSuffix(".pid") {
                vmFiles.pidFile = fullPath
                // Check if process is running
                if let pidStr = try? String(contentsOfFile: fullPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   let pid = Int32(pidStr) {
                    vmFiles.pid = pid
                    vmFiles.isRunning = kill(pid, 0) == 0
                }
            } else if file.hasSuffix(".qcow2") || file.hasSuffix(".raw") {
                vmFiles.diskFile = fullPath
            } else if file.hasSuffix("-seed.iso") {
                vmFiles.seedISO = fullPath
            } else if file.hasSuffix("-stdout.log") {
                vmFiles.stdoutLog = fullPath
            } else if file.hasSuffix("-stderr.log") {
                vmFiles.stderrLog = fullPath
            }

            vmFilesMap[vmId] = vmFiles
        }

        return vmFilesMap
    }

    /// Remove a file, using sudo if needed for permission errors
    static func removeFile(_ path: String) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
            // Try with sudo
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["rm", "-f", path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        } catch {
            return false
        }
    }
}

/// VM files group
struct VMFiles {
    let vmId: String
    var pidFile: String?
    var diskFile: String?
    var seedISO: String?
    var stdoutLog: String?
    var stderrLog: String?
    var pid: Int32?
    var isRunning: Bool = false

    var allFiles: [String] {
        [pidFile, diskFile, seedISO, stdoutLog, stderrLog].compactMap { $0 }
    }

    var isOrphaned: Bool {
        // Orphaned if has PID file but process is not running
        pidFile != nil && !isRunning
    }
}

// MARK: - VM Cleanup Command
struct VMCleanup: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Clean up orphaned WireGuard interfaces, QEMU processes, VM disks, and resources"
    )

    @Flag(name: .long, help: "Clean up all Omerta resources, not just orphaned ones")
    var all: Bool = false

    @Flag(name: .long, help: "Show status only, don't actually clean up")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Skip confirmation")
    var force: Bool = false

    @Flag(name: .long, help: "Clean up VM disk files (seed ISOs, overlay disks, PID files, logs)")
    var disks: Bool = false

    mutating func run() async throws {
        print("Omerta Cleanup")
        print("==============")
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

        // ========== WireGuard Interfaces ==========
        print("WireGuard Interfaces")
        print("--------------------")
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
        if trackedVMs.isEmpty {
            print("  (none)")
        }
        print("")

        // ========== Firewall Rules (macOS pf anchors) ==========
        #if os(macOS)
        print("Firewall Rules (pf anchors)")
        print("---------------------------")

        // Get firewall markers (created by omerta)
        let markers = ProviderVPNManager.listFirewallMarkers()

        // Get all omerta pf anchors
        let anchors = ProviderVPNManager.listOmertaAnchors()

        // Categorize anchors
        var markeredAnchors: [(anchor: String, marker: ProviderVPNManager.FirewallMarker)] = []
        var unmarkedAnchors: [String] = []

        for anchor in anchors {
            if let marker = markers.first(where: { $0.anchor == anchor }) {
                markeredAnchors.append((anchor, marker))
            } else {
                unmarkedAnchors.append(anchor)
            }
        }

        // Show orphaned markers (marker exists but no anchor - already cleaned)
        let orphanedMarkers = markers.filter { marker in
            guard let anchor = marker.anchor else { return true }
            return !anchors.contains(anchor)
        }

        if anchors.isEmpty {
            print("  No omerta pf anchors found")
        } else {
            print("  Active anchors: \(anchors.count)")
            for (anchor, marker) in markeredAnchors {
                print("    [omerta] \(anchor) (created: \(marker.createdAt ?? "unknown"))")
            }
            for anchor in unmarkedAnchors {
                print("    [unknown] \(anchor)")
            }
        }

        if !orphanedMarkers.isEmpty {
            print("  Orphaned markers (no anchor): \(orphanedMarkers.count)")
            for marker in orphanedMarkers {
                print("    \(marker.path)")
            }
        }
        print("")
        #endif

        // ========== QEMU Processes ==========
        let vmDisksDir = "\(OmertaConfig.defaultConfigDir)/vm-disks"
        let qemuProcesses = QEMUCleanup.listQEMUProcesses()
        let vmFilesMap = QEMUCleanup.getVMFiles(vmDisksDir: vmDisksDir)

        // Identify orphaned VMs (have files but QEMU not running)
        let orphanedVMs = vmFilesMap.values.filter { $0.isOrphaned }
        // Identify running VMs
        let runningVMs = vmFilesMap.values.filter { $0.isRunning }

        #if os(Linux)
        print("QEMU Processes")
        print("--------------")
        if qemuProcesses.isEmpty {
            print("  No QEMU processes running")
        } else {
            print("  Running QEMU processes: \(qemuProcesses.count)")
            for proc in qemuProcesses {
                let vmIdStr = proc.vmId.map { "[\($0.prefix(8))...]" } ?? "[unknown]"
                print("    PID \(proc.pid): \(vmIdStr)")
            }
        }
        print("")
        #endif

        // ========== VM Disk Files ==========
        var vmFilesToClean: [VMFiles] = []
        var allVMFiles: [String] = []

        print("VM Disk Files")
        print("-------------")

        if vmFilesMap.isEmpty {
            print("  No VM files found in: \(vmDisksDir)")
        } else {
            // Show orphaned VMs (not running)
            if !orphanedVMs.isEmpty {
                print("  Orphaned VMs (not running): \(orphanedVMs.count)")
                for vm in orphanedVMs.prefix(5) {
                    let fileCount = vm.allFiles.count
                    print("    [\(vm.vmId.prefix(8))...] \(fileCount) file(s)")
                }
                if orphanedVMs.count > 5 {
                    print("    ... and \(orphanedVMs.count - 5) more")
                }
            }

            // Show running VMs
            if !runningVMs.isEmpty {
                print("  Running VMs: \(runningVMs.count)")
                for vm in runningVMs {
                    print("    [\(vm.vmId.prefix(8))...] PID \(vm.pid ?? 0)")
                }
            }

            if orphanedVMs.isEmpty && runningVMs.isEmpty {
                print("  No VM files found")
            }

            // Determine what to clean based on --disks and --all flags
            if disks {
                if all {
                    // Clean ALL VMs (including running ones - will kill QEMU first)
                    vmFilesToClean = Array(vmFilesMap.values)
                } else {
                    // Clean only orphaned VMs
                    vmFilesToClean = orphanedVMs
                }
                allVMFiles = vmFilesToClean.flatMap { $0.allFiles }
            }
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
        let hasVMFilesToClean = !vmFilesToClean.isEmpty
        let hasRunningVMsToKill = all && !runningVMs.isEmpty && disks

        #if os(macOS)
        let hasMarkeredAnchors = !markeredAnchors.isEmpty
        let hasUnmarkedAnchors = !unmarkedAnchors.isEmpty
        let hasOrphanedMarkers = !orphanedMarkers.isEmpty
        let hasFirewallWork = hasMarkeredAnchors || hasUnmarkedAnchors || hasOrphanedMarkers
        #else
        let hasFirewallWork = false
        let hasMarkeredAnchors = false
        let hasUnmarkedAnchors = false
        let hasOrphanedMarkers = false
        let markeredAnchors: [(anchor: String, marker: ProviderVPNManager.FirewallMarker)] = []
        let unmarkedAnchors: [String] = []
        let orphanedMarkers: [ProviderVPNManager.FirewallMarker] = []
        #endif

        if !hasInterfacesToClean && !hasConfigFiles && !hasOrphanedProcesses && !hasFirewallWork && !hasVMFilesToClean && !hasRunningVMsToKill && (!hasStaleVMs || !all) {
            print("Nothing to clean up!")
            if hasStaleVMs {
                print("")
                print("Note: \(staleVMs.count) stale VM(s) tracked with no interface.")
                print("Use --all to clear stale tracking.")
            }
            if !orphanedVMs.isEmpty && !disks {
                print("")
                print("Note: \(orphanedVMs.count) orphaned VM file set(s) found.")
                print("Use --disks to clean up VM files.")
            }
            return
        }

        if dryRun {
            print("[DRY RUN] Would clean up:")
            for proc in status.orphanedProcesses {
                print("  - Kill orphaned wireguard-go process: PID \(proc.pid)")
            }
            for iface in interfacesToClean {
                print("  - Stop interface: \(iface)")
            }
            for file in status.configFiles {
                print("  - Remove config: \(file)")
            }
            #if os(macOS)
            for (anchor, _) in markeredAnchors {
                print("  - Remove pf anchor: \(anchor) [auto - has marker]")
            }
            for anchor in unmarkedAnchors {
                print("  - Remove pf anchor: \(anchor) [requires confirmation]")
            }
            for marker in orphanedMarkers {
                print("  - Remove orphaned marker: \(marker.path)")
            }
            #endif
            if all {
                for vm in staleVMs {
                    print("  - Remove stale tracking: \(vm.vmId.uuidString.prefix(8))...")
                }
            }
            if hasRunningVMsToKill {
                for vm in runningVMs {
                    print("  - Kill QEMU process: PID \(vm.pid ?? 0) [\(vm.vmId.prefix(8))...]")
                }
            }
            if hasVMFilesToClean {
                let orphanedCount = vmFilesToClean.filter { $0.isOrphaned }.count
                let runningCount = vmFilesToClean.filter { $0.isRunning }.count
                print("  - Remove VM files for \(vmFilesToClean.count) VM(s) (\(orphanedCount) orphaned, \(runningCount) running)")
                print("    Total files: \(allVMFiles.count)")
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
            #if os(macOS)
            if hasMarkeredAnchors {
                print("This will remove \(markeredAnchors.count) pf anchor(s) created by omerta.")
            }
            #endif
            if hasRunningVMsToKill {
                print("This will KILL \(runningVMs.count) running QEMU process(es).")
                print("WARNING: Running VMs will be terminated!")
            }
            if hasVMFilesToClean {
                print("This will remove \(allVMFiles.count) VM file(s) for \(vmFilesToClean.count) VM(s).")
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

        // ========== Firewall Cleanup ==========
        #if os(macOS)
        var anchorsRemoved = 0

        // Remove anchors with markers automatically
        for (anchor, marker) in markeredAnchors {
            print("  Removing pf anchor \(anchor)...", terminator: " ")
            if ProviderVPNManager.removePFAnchor(anchor) {
                print("done")
                anchorsRemoved += 1
                // Also remove the marker file
                try? FileManager.default.removeItem(atPath: marker.path)
            } else {
                print("failed")
            }
        }

        // For unmarked anchors, ask user unless --force
        for anchor in unmarkedAnchors {
            if force {
                print("  Removing unknown pf anchor \(anchor)...", terminator: " ")
                if ProviderVPNManager.removePFAnchor(anchor) {
                    print("done")
                    anchorsRemoved += 1
                } else {
                    print("failed")
                }
            } else {
                print("")
                print("  Found pf anchor '\(anchor)' without marker file.")
                print("  This may have been created by omerta or another tool.")
                print("  Remove this anchor? (y/n): ", terminator: "")

                if let response = readLine()?.lowercased(), response == "y" || response == "yes" {
                    print("  Removing...", terminator: " ")
                    if ProviderVPNManager.removePFAnchor(anchor) {
                        print("done")
                        anchorsRemoved += 1
                    } else {
                        print("failed")
                    }
                } else {
                    print("  Skipped.")
                }
            }
        }

        // Clean up orphaned markers
        for marker in orphanedMarkers {
            try? FileManager.default.removeItem(atPath: marker.path)
        }
        #endif

        // If --all, also clear stale VM tracking
        if all && !staleVMs.isEmpty {
            print("")
            print("Clearing stale VM tracking...")
            for vm in staleVMs {
                try await tracker.removeVM(vm.vmId)
                print("  Removed \(vm.vmId.uuidString.prefix(8))...")
            }
        }

        // Kill running QEMU processes (if --all --disks)
        var qemuProcessesKilled = 0
        if hasRunningVMsToKill {
            print("")
            print("Killing QEMU processes...")
            for vm in runningVMs {
                if let pid = vm.pid {
                    print("  Killing PID \(pid) [\(vm.vmId.prefix(8))...]...", terminator: " ")
                    if QEMUCleanup.killProcess(pid: pid) {
                        print("done")
                        qemuProcessesKilled += 1
                    } else {
                        print("failed")
                    }
                }
            }
        }

        // Clean up TAP interfaces (Linux only)
        #if os(Linux)
        var tapInterfacesCleaned = 0
        let tapInterfaces = QEMUCleanup.listTAPInterfaces()
        if !tapInterfaces.isEmpty && (all || hasRunningVMsToKill) {
            print("")
            print("Cleaning TAP interfaces...")
            for tap in tapInterfaces {
                print("  Removing \(tap)...", terminator: " ")
                if QEMUCleanup.deleteTAPInterface(tap) {
                    print("done")
                    tapInterfacesCleaned += 1
                } else {
                    print("failed")
                }
            }
        }
        #endif

        // Clean up VM files (disk, ISO, PID, logs)
        var vmFilesRemoved = 0
        var vmsCleanedUp = 0
        if hasVMFilesToClean {
            print("")
            print("Removing VM files...")
            for vm in vmFilesToClean {
                let shortId = vm.vmId.prefix(8)
                print("  [\(shortId)...] ", terminator: "")

                var filesRemoved = 0
                for file in vm.allFiles {
                    if QEMUCleanup.removeFile(file) {
                        filesRemoved += 1
                    }
                }

                if filesRemoved == vm.allFiles.count {
                    print("\(filesRemoved) file(s) removed")
                    vmsCleanedUp += 1
                } else {
                    print("\(filesRemoved)/\(vm.allFiles.count) file(s) removed")
                }
                vmFilesRemoved += filesRemoved
            }
        }

        // Clean up Omerta known_hosts file (if --all)
        var knownHostsCleared = false
        if all {
            let knownHostsPath = NSString(string: VMConnection.knownHostsPath).expandingTildeInPath
            if FileManager.default.fileExists(atPath: knownHostsPath) {
                print("")
                print("Clearing Omerta known_hosts...")
                do {
                    try FileManager.default.removeItem(atPath: knownHostsPath)
                    print("  Removed \(knownHostsPath)")
                    knownHostsCleared = true
                } catch {
                    print("  Failed to remove known_hosts: \(error)")
                }
            }
        }

        print("")
        print("Cleanup complete!")
        if processesKilled > 0 {
            print("  WireGuard processes killed: \(processesKilled)")
        }
        if qemuProcessesKilled > 0 {
            print("  QEMU processes killed: \(qemuProcessesKilled)")
        }
        #if os(Linux)
        if tapInterfacesCleaned > 0 {
            print("  TAP interfaces removed: \(tapInterfacesCleaned)")
        }
        #endif
        if cleanedCount > 0 {
            print("  Interfaces stopped: \(cleanedCount)")
        }
        #if os(macOS)
        if anchorsRemoved > 0 {
            print("  Firewall anchors removed: \(anchorsRemoved)")
        }
        #endif
        if all && hasStaleVMs {
            print("  Stale VMs removed: \(staleVMs.count)")
        }
        if vmsCleanedUp > 0 {
            print("  VMs cleaned up: \(vmsCleanedUp) (\(vmFilesRemoved) files)")
        }
        if knownHostsCleared {
            print("  SSH known_hosts cleared")
        }
    }
}

// MARK: - VM Test Command (Deprecated)
struct VMTest: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Test end-to-end VM request and SSH access (deprecated - use mesh)"
    )

    @Option(name: .long, help: "Provider address (ip:port)")
    var provider: String = "127.0.0.1:51820"

    @Option(name: .long, help: "Timeout in seconds for VM boot (default: 120)")
    var timeout: Int = 120

    @Option(name: .long, help: "Command to run via SSH (default: 'echo ok')")
    var command: String = "echo ok"

    @Flag(name: .long, help: "Keep the VM after test (don't release)")
    var keep: Bool = false

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        // Direct IP tests are deprecated
        print("Error: Direct IP VM tests are deprecated.")
        print("")
        print("The UDP control protocol has been replaced by mesh networking.")
        print("To test VM connectivity, use the mesh-based connect command:")
        print("")
        print("  omerta connect --peer <provider-peer-id> --bootstrap <bootstrap>")
        print("")
        print("To run the daemon in test mode:")
        print("  sudo omertad start --dry-run")
        throw ExitCode.failure
    }
}

// MARK: - VM Boot Test Command (Standalone)

/// Test modes for VM boot testing
enum VMTestMode: String, ExpressibleByArgument, CaseIterable {
    case tapPing = "tap-ping"        // Test TAP connectivity with ping (Linux only)
    case directSSH = "direct-ssh"    // Test SSH over TAP (no WireGuard firewall)
    case consoleBoot = "console-boot" // Test boot via console log (macOS - no network needed)
    case reverseSSH = "reverse-ssh"  // Test SSH via reverse tunnel (macOS - requires SSH server on host)
}

struct VMBootTest: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "boot-test",
        abstract: "Test VM boot and connectivity (deprecated - use mesh mode)"
    )

    @Option(name: .long, help: "Provider address (ip:port)")
    var provider: String = "127.0.0.1:51820"

    @Option(name: .long, help: "Test mode")
    var mode: VMTestMode = .directSSH

    @Option(name: .long, help: "Timeout in seconds")
    var timeout: Int = 180

    @Flag(name: .long, help: "Keep the VM after test")
    var keep: Bool = false

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        // Direct UDP boot tests are deprecated - use mesh mode
        print("Error: Direct VM boot tests are deprecated.")
        print("")
        print("The UDP control protocol has been replaced by mesh networking.")
        print("To test VM connectivity, use the mesh-based test command:")
        print("")
        print("  omerta test mesh-vm --provider <provider-peer-id> --bootstrap <bootstrap>")
        print("")
        print("Or run a full VM request:")
        print("  omerta connect --peer <provider-peer-id> --bootstrap <bootstrap>")
        throw ExitCode.failure
    }
}

// MARK: - Utility Functions

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

// MARK: - Kill Command

struct Kill: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Kill all running omerta/omertad processes"
    )

    @Flag(name: .long, help: "Force kill (SIGKILL instead of SIGTERM)")
    var force: Bool = false

    @Flag(name: .long, help: "Also clean up WireGuard interfaces")
    var cleanup: Bool = false

    mutating func run() async throws {
        print("Killing omerta processes...")

        let signal = force ? "KILL" : "TERM"

        // Kill omertad processes
        let killDaemon = Process()
        killDaemon.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killDaemon.arguments = ["-\(signal)", "-f", "omertad"]
        killDaemon.standardOutput = FileHandle.nullDevice
        killDaemon.standardError = FileHandle.nullDevice
        try? killDaemon.run()
        killDaemon.waitUntilExit()

        // Kill omerta processes (but not this one)
        let myPid = ProcessInfo.processInfo.processIdentifier
        let killCli = Process()
        killCli.executableURL = URL(fileURLWithPath: "/bin/bash")
        killCli.arguments = ["-c", "pgrep -f 'omerta ' | grep -v \(myPid) | xargs -r kill -\(signal) 2>/dev/null || true"]
        killCli.standardOutput = FileHandle.nullDevice
        killCli.standardError = FileHandle.nullDevice
        try? killCli.run()
        killCli.waitUntilExit()

        // Wait a moment
        try await Task.sleep(for: .milliseconds(500))

        // Check remaining processes
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkProcess.arguments = ["-f", "omerta"]
        let pipe = Pipe()
        checkProcess.standardOutput = pipe
        checkProcess.standardError = FileHandle.nullDevice

        try? checkProcess.run()
        checkProcess.waitUntilExit()

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Filter out our own PID
        let remainingPids = pids.split(separator: "\n").filter { $0 != "\(myPid)" }

        if remainingPids.isEmpty {
            print("All omerta processes killed")
        } else {
            print("Some processes still running: \(remainingPids.joined(separator: ", "))")
            if !force {
                print("Try: omerta kill --force")
            }
        }

        // Cleanup WireGuard interfaces if requested
        if cleanup {
            print("")
            print("Cleaning up WireGuard interfaces...")

            #if os(macOS)
            // On macOS, remove utun interfaces created by omerta
            let listUtun = Process()
            listUtun.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
            listUtun.arguments = ["-l"]
            let utunPipe = Pipe()
            listUtun.standardOutput = utunPipe
            try? listUtun.run()
            listUtun.waitUntilExit()

            let interfaces = String(data: utunPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let utunInterfaces = interfaces.split(separator: " ").filter { $0.hasPrefix("utun") && Int($0.dropFirst(4)) ?? 0 >= 10 }

            for iface in utunInterfaces {
                let down = Process()
                down.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
                down.arguments = [String(iface), "down"]
                down.standardOutput = FileHandle.nullDevice
                down.standardError = FileHandle.nullDevice
                try? down.run()
                down.waitUntilExit()
                print("  Brought down \(iface)")
            }
            #else
            // On Linux, use WireGuardCleanup to properly stop interfaces with sudo
            do {
                let status = try WireGuardCleanup.getCleanupStatus()
                for iface in status.activeInterfaces {
                    do {
                        try WireGuardCleanup.stopInterface(iface)
                        print("  Deleted \(iface)")
                    } catch {
                        print("  Failed to delete \(iface): \(error)")
                    }
                }
            } catch {
                // Fallback: try listing interfaces manually
                let listWg = Process()
                listWg.executableURL = URL(fileURLWithPath: "/bin/bash")
                listWg.arguments = ["-c", "ip link show | grep -oE 'wg[0-9A-F]+' | sort -u"]
                let wgPipe = Pipe()
                listWg.standardOutput = wgPipe
                try? listWg.run()
                listWg.waitUntilExit()

                let wgInterfaces = String(data: wgPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n") ?? []

                for iface in wgInterfaces {
                    do {
                        try WireGuardCleanup.stopInterface(String(iface))
                        print("  Deleted \(iface)")
                    } catch {
                        print("  Failed to delete \(iface): \(error)")
                    }
                }
            }
            #endif

            print("Cleanup complete")
        }
    }
}

// MARK: - Ping Command (Top-level alias for mesh ping)

struct Ping: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Ping a mesh peer (alias for 'omerta mesh ping')"
    )

    @Argument(help: "Peer ID to ping")
    var peerIdArg: String?

    @Option(name: .long, help: "Peer ID to ping")
    var peer: String?

    @Option(name: .long, help: "Network ID (default: first available)")
    var network: String?

    @Option(name: .long, help: "Ping timeout in seconds")
    var timeout: Int = 5

    @Option(name: .shortAndLong, help: "Number of pings to send")
    var count: Int = 1

    @Flag(name: .shortAndLong, help: "Show detailed gossip information")
    var verbose: Bool = false

    mutating func run() async throws {
        // Delegate to MeshPing implementation
        var meshPing = MeshPing()
        meshPing.peerIdArg = peerIdArg
        meshPing.peer = peer
        meshPing.network = network
        meshPing.timeout = timeout
        meshPing.count = count
        meshPing.verbose = verbose
        try await meshPing.run()
    }
}

// MARK: - Mesh Commands

struct Mesh: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "mesh",
        abstract: "Mesh network operations",
        subcommands: [
            MeshStatus.self,
            MeshPeers.self,
            MeshConnect.self,
            MeshPing.self
        ]
    )
}

struct MeshStatus: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show mesh network status"
    )

    @Option(name: .long, help: "Bootstrap peer (format: peerId@host:port)")
    var bootstrap: String?

    @Option(name: .long, help: "Discovery timeout in seconds")
    var timeout: Int = 10

    mutating func run() async throws {
        // Load config
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        // Build mesh config
        var meshOptions = config.mesh ?? MeshConfigOptions.consumer
        meshOptions.enabled = true
        if let bootstrap = bootstrap {
            meshOptions.bootstrapPeers = [bootstrap]
        }

        // Create mesh consumer client
        var configWithMesh = config
        configWithMesh.mesh = meshOptions

        guard let keyData = config.localKeyData() else {
            print("Error: No local key in config. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        let identity = IdentityKeypair()
        let meshConfig = MeshConfig(
            encryptionKey: keyData,
            stunServers: meshOptions.stunServers,
            bootstrapPeers: meshOptions.bootstrapPeers
        )

        let mesh = MeshNetwork(identity: identity, config: meshConfig)

        print("Starting mesh network...")
        try await mesh.start()

        // Wait for discovery
        if timeout > 0 {
            print("Discovering peers for \(timeout) seconds...")
            try await Task.sleep(for: .seconds(timeout))
        }

        // Get statistics
        let stats = await mesh.statistics()
        let natType = await mesh.currentNATType
        let publicEndpoint = await mesh.currentPublicEndpoint

        print("")
        print("Mesh Network Status")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Peer ID:           \(identity.peerId)")
        print("NAT Type:          \(natType.rawValue)")
        print("Public Endpoint:   \(publicEndpoint ?? "none")")
        print("Known Peers:       \(stats.peerCount)")
        print("Direct Connections: \(stats.directConnectionCount)")
        print("Relay Connections:  \(stats.relayCount)")
        print("")

        await mesh.stop()
    }
}

struct MeshPeers: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "peers",
        abstract: "List discovered mesh peers"
    )

    @Option(name: .long, help: "Bootstrap peer (format: peerId@host:port)")
    var bootstrap: String?

    @Option(name: .long, help: "Discovery timeout in seconds")
    var timeout: Int = 5

    mutating func run() async throws {
        // Load config
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        // Build mesh config
        var meshOptions = config.mesh ?? MeshConfigOptions.consumer
        meshOptions.enabled = true
        if let bootstrap = bootstrap {
            meshOptions.bootstrapPeers = [bootstrap]
        }

        guard let keyData = config.localKeyData() else {
            print("Error: No local key in config. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        let identity = IdentityKeypair()
        let meshConfig = MeshConfig(
            encryptionKey: keyData,
            stunServers: meshOptions.stunServers,
            bootstrapPeers: meshOptions.bootstrapPeers
        )

        let mesh = MeshNetwork(identity: identity, config: meshConfig)

        print("Starting mesh network...")
        try await mesh.start()

        // Wait for discovery
        print("Discovering peers...")
        try await Task.sleep(for: .seconds(timeout))

        // List peers
        let peers = await mesh.knownPeers()

        print("")
        if peers.isEmpty {
            print("No peers discovered")
        } else {
            print("Discovered Peers (\(peers.count)):")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            for peer in peers {
                let connection = await mesh.connection(to: peer)
                let status = connection != nil ? "connected" : "discovered"
                let method = connection?.method.rawValue ?? "-"
                print("  \(peer.prefix(20))...  [\(status)] via \(method)")
            }
        }
        print("")

        await mesh.stop()
    }
}

struct MeshConnect: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect to a mesh peer"
    )

    @Argument(help: "Peer ID to connect to")
    var peerId: String

    @Option(name: .long, help: "Bootstrap peer (format: peerId@host:port)")
    var bootstrap: String?

    @Option(name: .long, help: "Connection timeout in seconds")
    var timeout: Int = 30

    mutating func run() async throws {
        // Load config
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        // Build mesh config
        var meshOptions = config.mesh ?? MeshConfigOptions.consumer
        meshOptions.enabled = true
        if let bootstrap = bootstrap {
            meshOptions.bootstrapPeers = [bootstrap]
        }

        guard let keyData = config.localKeyData() else {
            print("Error: No local key in config. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        let localIdentity = IdentityKeypair()
        let meshConfig = MeshConfig(
            encryptionKey: keyData,
            connectionTimeout: Double(timeout),
            stunServers: meshOptions.stunServers,
            bootstrapPeers: meshOptions.bootstrapPeers
        )

        let mesh = MeshNetwork(identity: localIdentity, config: meshConfig)

        print("Starting mesh network...")
        try await mesh.start()

        print("Connecting to \(peerId)...")
        do {
            let connection = try await mesh.connect(to: peerId)
            print("")
            print("Connected!")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("Peer ID:    \(peerId)")
            print("Endpoint:   \(connection.endpoint)")
            print("Direct:     \(connection.isDirect)")
            print("Method:     \(connection.method.rawValue)")
            if let rtt = connection.rttMs {
                print("RTT:        \(String(format: "%.1f", rtt)) ms")
            }
            print("")
        } catch {
            print("Failed to connect: \(error)")
        }

        await mesh.stop()
    }
}

struct MeshPing: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Ping a mesh peer and show gossip info (requires omertad to be running)"
    )

    @Argument(help: "Peer ID to ping")
    var peerIdArg: String?

    @Option(name: .long, help: "Peer ID to ping")
    var peer: String?

    @Option(name: .long, help: "Network ID (default: first available)")
    var network: String?

    @Option(name: .long, help: "Ping timeout in seconds")
    var timeout: Int = 5

    @Option(name: .shortAndLong, help: "Number of pings to send")
    var count: Int = 1

    @Flag(name: .shortAndLong, help: "Show detailed gossip information")
    var verbose: Bool = false

    mutating func run() async throws {
        // Get peer ID from either argument or --peer flag
        guard let peerId = peerIdArg ?? peer else {
            print("Error: Peer ID is required")
            print("")
            print("Usage:")
            print("  omerta mesh ping <peer-id>")
            print("  omerta mesh ping --peer <peer-id>")
            print("  omerta ping <peer-id>")
            print("  omerta ping --peer <peer-id>")
            throw ExitCode.failure
        }

        // Find network ID
        let networkStore = NetworkStore.defaultStore()
        try await networkStore.load()

        let networkId: String
        if let specifiedNetwork = network {
            guard await networkStore.network(id: specifiedNetwork) != nil else {
                print("Error: Network '\(specifiedNetwork)' not found")
                throw ExitCode.failure
            }
            networkId = specifiedNetwork
        } else {
            let networks = await networkStore.allNetworks()
            guard let firstNetwork = networks.first else {
                print("Error: No networks found. Join a network first with 'omerta network join'")
                throw ExitCode.failure
            }
            networkId = firstNetwork.id
        }

        // Connect to daemon via control socket
        let client = ControlSocketClient(networkId: networkId)
        guard client.isDaemonRunning() else {
            print("Error: omertad is not running for network '\(networkId)'")
            print("")
            print("Start the daemon with:")
            print("  omertad start --network \(networkId)")
            throw ExitCode.failure
        }

        print("Pinging \(peerId) via omertad...")
        print("")

        var successCount = 0
        var totalLatency = 0

        for i in 0..<count {
            do {
                let response = try await client.send(.ping(peerId: peerId, timeout: timeout))

                switch response {
                case .pingResult(let result):
                    if let result = result {
                        successCount += 1
                        totalLatency += result.latencyMs

                        if verbose {
                            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                            print("Ping \(i + 1): \(result.latencyMs)ms from \(result.peerId.prefix(16))...")
                            print("")
                            print("Peers we sent (\(result.sentPeers.count)):")
                            if result.sentPeers.isEmpty {
                                print("  (none)")
                            } else {
                                for (id, endpoint) in result.sentPeers {
                                    print("  \(id.prefix(16))... @ \(endpoint)")
                                }
                            }
                            print("")
                            print("Peers they sent (\(result.receivedPeers.count)):")
                            if result.receivedPeers.isEmpty {
                                print("  (none)")
                            } else {
                                for (id, endpoint) in result.receivedPeers {
                                    let isNew = result.newPeers[id] != nil
                                    let marker = isNew ? " [NEW]" : ""
                                    print("  \(id.prefix(16))... @ \(endpoint)\(marker)")
                                }
                            }
                            if !result.newPeers.isEmpty {
                                print("")
                                print("New peers discovered: \(result.newPeers.count)")
                            }
                        } else {
                            print("Reply from \(result.peerId.prefix(16))...: time=\(result.latencyMs)ms peers=\(result.receivedPeers.count)")
                        }
                    } else {
                        print("Request timeout for \(peerId.prefix(16))...")
                    }

                case .error(let msg):
                    print("Error: \(msg)")
                    throw ExitCode.failure

                default:
                    print("Unexpected response from daemon")
                    throw ExitCode.failure
                }

                if i < count - 1 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second between pings
                }
            } catch let error as ControlSocketError {
                print("Error: \(error.description)")
                throw ExitCode.failure
            }
        }

        print("")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Ping statistics for \(peerId.prefix(16))...")
        print("  \(count) packets transmitted, \(successCount) received, \(100 - (successCount * 100 / max(count, 1)))% packet loss")
        if successCount > 0 {
            let avgLatency = totalLatency / successCount
            print("  avg latency: \(avgLatency)ms")
        }
    }
}

// MARK: - NAT Commands

struct NAT: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "nat",
        abstract: "NAT traversal testing and diagnostics",
        subcommands: [
            NATDetect.self,
            NATStatus.self,
            NATConfig.self
        ],
        defaultSubcommand: NATStatus.self
    )
}

// MARK: - NAT Detect Command

struct NATDetect: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "detect",
        abstract: "Detect NAT type and discover public endpoint"
    )

    @Option(name: .long, help: "STUN server to use (default: stun.l.google.com:19302)")
    var stunServer: String?

    @Option(name: .long, help: "Local port to use (default: auto)")
    var localPort: UInt16 = 0

    @Flag(name: .long, help: "Show detailed output")
    var verbose: Bool = false

    mutating func run() async throws {
        print("NAT Type Detection")
        print("==================")
        print("")

        // Load config for STUN servers
        let configManager = OmertaCore.ConfigManager()
        let natConfig = (try? await configManager.load())?.nat ?? OmertaCore.NATConfig()

        // Determine STUN server
        let server = stunServer ?? natConfig.stunServers.first ?? "stun.l.google.com:19302"

        if verbose {
            print("Using STUN server: \(server)")
            if localPort > 0 {
                print("Local port: \(localPort)")
            }
            print("")
        }

        print("Discovering endpoint...")

        do {
            let servers = [server] + natConfig.stunServers.filter { $0 != server }.prefix(2)
            let detector = OmertaMesh.NATDetector(stunServers: Array(servers))

            let result = try await detector.detect(timeout: natConfig.timeoutInterval)

            print("")
            print("Results:")
            print("  NAT Type: \(result.type.rawValue)")
            print("  Public Endpoint: \(result.publicEndpoint)")

            if verbose {
                print("")
                print("Details:")
                print("  Local Port: \(result.localPort)")
                print("  RTT: \(String(format: "%.1f", result.rtt * 1000))ms")
            }

            // Provide connectivity assessment
            print("")
            print("Connectivity:")
            switch result.type {
            case .public:
                print("  ✓ Excellent - Public IP, direct connections from any peer")
            case .fullCone:
                print("  ✓ Excellent - Direct connections from any peer")
            case .restrictedCone:
                print("  ✓ Good - Direct connections with hole punching")
            case .portRestrictedCone:
                print("  ○ Fair - Direct connections usually possible")
            case .symmetric:
                print("  △ Limited - May require relay for some peers")
            case .unknown:
                print("  ? Unknown - Could not determine NAT type")
            }

        } catch {
            print("")
            print("Error: \(error)")
            throw ExitCode.failure
        }
    }
}

// MARK: - NAT Status Command

struct NATStatus: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show NAT traversal status and configuration"
    )

    @Flag(name: .long, help: "Show detailed output")
    var verbose: Bool = false

    mutating func run() async throws {
        print("NAT Traversal Status")
        print("====================")
        print("")

        // Load config
        let configManager = OmertaCore.ConfigManager()
        let config = try? await configManager.load()
        let natConfig = config?.nat

        // Configuration
        print("Configuration:")
        if let natConfig = natConfig {
            print("  STUN Servers: \(natConfig.stunServers.joined(separator: ", "))")
            print("  Prefer Direct: \(natConfig.preferDirect)")
            print("  Hole Punch Timeout: \(natConfig.holePunchTimeout)ms")
            print("  Probe Count: \(natConfig.probeCount)")
            if natConfig.localPort > 0 {
                print("  Local Port: \(natConfig.localPort)")
            } else {
                print("  Local Port: auto")
            }
        } else {
            print("  (using defaults - no NAT configuration in ~/.omerta/config.json)")
            print("  STUN Servers: \(OmertaCore.NATConfig.defaultSTUNServers.joined(separator: ", "))")
        }

        print("")

        // Quick NAT detection
        print("Current Status:")
        print("  Detecting NAT type...")

        do {
            let servers = natConfig?.stunServers ?? OmertaCore.NATConfig.defaultSTUNServers
            let detector = OmertaMesh.NATDetector(stunServers: servers)

            let result = try await detector.detect(timeout: natConfig?.timeoutInterval ?? 5.0)

            print("  NAT Type: \(result.type.rawValue)")
            print("  Public Endpoint: \(result.publicEndpoint)")

            if verbose {
                print("")
                print("Detailed Info:")
                print("  Local Port: \(result.localPort)")
                print("  RTT: \(String(format: "%.1f", result.rtt * 1000))ms")
            }

        } catch {
            print("  Error detecting NAT type: \(error)")
        }

        print("")
        print("Commands:")
        print("  omerta nat detect      - Detailed NAT detection")
        print("  omerta nat config      - Configure NAT settings")
        print("  omerta mesh connect    - Test connection to mesh peer")
    }
}

// MARK: - NAT Config Command

struct NATConfig: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Configure NAT traversal settings"
    )

    @Option(name: .long, help: "Add STUN server")
    var addStun: String?

    @Option(name: .long, help: "Remove STUN server")
    var removeStun: String?

    @Option(name: .long, help: "Set hole punch timeout (ms)")
    var timeout: Int?

    @Option(name: .long, help: "Set probe count")
    var probeCount: Int?

    @Option(name: .long, help: "Set local port (0 for auto)")
    var localPort: UInt16?

    @Flag(name: .long, help: "Reset to defaults")
    var reset: Bool = false

    @Flag(name: .long, help: "Show current configuration")
    var show: Bool = false

    mutating func run() async throws {
        let configManager = OmertaCore.ConfigManager()

        // Show current config
        if show || (addStun == nil && removeStun == nil &&
                    timeout == nil && probeCount == nil && localPort == nil && !reset) {
            let config = try? await configManager.load()
            let natConfig = config?.nat ?? OmertaCore.NATConfig()

            print("NAT Configuration")
            print("=================")
            print("")
            print("STUN Servers:")
            for server in natConfig.stunServers {
                print("  - \(server)")
            }
            print("Prefer Direct: \(natConfig.preferDirect)")
            print("Hole Punch Timeout: \(natConfig.holePunchTimeout)ms")
            print("Probe Count: \(natConfig.probeCount)")
            print("Local Port: \(natConfig.localPort == 0 ? "auto" : String(natConfig.localPort))")
            return
        }

        // Reset to defaults
        if reset {
            try await configManager.update { config in
                config.nat = OmertaCore.NATConfig()
            }
            print("NAT configuration reset to defaults")
            return
        }

        // Update configuration
        try await configManager.update { config in
            var natConfig = config.nat ?? OmertaCore.NATConfig()

            if let server = addStun {
                if !natConfig.stunServers.contains(server) {
                    natConfig.stunServers.append(server)
                    print("Added STUN server: \(server)")
                } else {
                    print("STUN server already configured: \(server)")
                }
            }

            if let server = removeStun {
                if let index = natConfig.stunServers.firstIndex(of: server) {
                    natConfig.stunServers.remove(at: index)
                    print("Removed STUN server: \(server)")
                } else {
                    print("STUN server not found: \(server)")
                }
            }

            if let t = timeout {
                natConfig.holePunchTimeout = t
                print("Set hole punch timeout: \(t)ms")
            }

            if let count = probeCount {
                natConfig.probeCount = count
                print("Set probe count: \(count)")
            }

            if let port = localPort {
                natConfig.localPort = port
                print("Set local port: \(port == 0 ? "auto" : String(port))")
            }

            config.nat = natConfig
        }

        print("")
        print("Configuration saved to ~/.omerta/config.json")
    }
}

// Data.init?(hexString:) is provided by OmertaCore
