import Foundation
import ArgumentParser
import OmertaCore
import OmertaVM
import OmertaNetwork
import OmertaConsumer
import OmertaProvider
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
            Status.self,
            CheckDeps.self,
            Kill.self
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
            VMStatus.self,
            VMRelease.self,
            VMConnect.self,
            VMCleanup.self,
            VMTest.self
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

    @Option(name: .long, help: "Network key (hex encoded, 64 chars). Uses local key from config if not specified.")
    var networkKey: String?

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

        // Load config to get local key if not specified
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        // Determine network key - use provided key or fall back to local key
        let keyData: Data
        if let providedKey = networkKey {
            guard let data = Data(hexString: providedKey), data.count == 32 else {
                print("Error: Network key must be a 64-character hex string (32 bytes)")
                throw ExitCode.failure
            }
            keyData = data
        } else if let localKeyData = config.localKeyData() {
            keyData = localKeyData
            print("Using local encryption key from config")
        } else {
            print("Error: No network key specified and no local key in config.")
            print("Run 'omerta init' to generate a local key, or specify --network-key")
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

        // Load SSH config
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("")
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        guard let sshPublicKey = config.ssh.publicKey else {
            print("")
            print("Error: SSH public key not found in config. Run 'omerta init' to regenerate.")
            throw ExitCode.failure
        }

        print("Using SSH key: \(config.ssh.expandedPrivateKeyPath())")
        print("")

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

        // Request VM with SSH config from omerta settings
        let connection = try await client.requestVM(
            in: "direct",
            requirements: requirements,
            sshPublicKey: sshPublicKey,
            sshKeyPath: config.ssh.privateKeyPath,
            sshUser: config.ssh.defaultUser,
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

        // Load SSH config
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("")
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        guard let sshPublicKey = config.ssh.publicKey else {
            print("")
            print("Error: SSH public key not found in config. Run 'omerta init' to regenerate.")
            throw ExitCode.failure
        }

        print("Using SSH key: \(config.ssh.expandedPrivateKeyPath())")
        print("")

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

        // Request VM with SSH config from omerta settings
        let connection = try await client.requestVM(
            in: networkId,
            requirements: requirements,
            sshPublicKey: sshPublicKey,
            sshKeyPath: config.ssh.privateKeyPath,
            sshUser: config.ssh.defaultUser,
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
        print("  omerta vm release \(connection.vmId)")
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
        print("  omerta vm release <vm-id>")
        print("")
        print("To clean up orphaned resources:")
        print("  omerta vm cleanup")
    }

    private func formatDate(_ date: Date) -> String {
        formatRelativeDate(date)
    }
}

// MARK: - VM Status Command
struct VMStatus: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Query VM status from provider"
    )

    @Option(name: .long, help: "Provider endpoint (ip:port)")
    var provider: String

    @Option(name: .long, help: "Network key (hex encoded). Uses local key from config if not specified.")
    var networkKey: String?

    @Option(name: .long, help: "Specific VM ID to query (default: all)")
    var vmId: String?

    mutating func run() async throws {
        // Load config to get local key if not specified
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        // Determine network key
        let keyData: Data
        if let providedKey = networkKey {
            guard let data = Data(hexString: providedKey), data.count == 32 else {
                print("Error: Network key must be a 64-character hex string (32 bytes)")
                throw ExitCode.failure
            }
            keyData = data
        } else if let localKeyData = config.localKeyData() {
            keyData = localKeyData
        } else {
            print("Error: No network key specified and no local key in config.")
            throw ExitCode.failure
        }

        // Parse VM ID if provided
        var queryVmId: UUID? = nil
        if let vmIdStr = vmId {
            // Handle both full UUID and short prefix
            if vmIdStr.count == 36 {
                queryVmId = UUID(uuidString: vmIdStr)
            } else {
                // Try to find matching VM from local tracking
                let tracker = VMTracker()
                let vms = try await tracker.loadPersistedVMs()
                let matchingVM = vms.first { vm in
                    vm.vmId.uuidString.lowercased().hasPrefix(vmIdStr.lowercased())
                }
                queryVmId = matchingVM?.vmId
            }

            if queryVmId == nil {
                print("Error: Invalid VM ID: \(vmIdStr)")
                throw ExitCode.failure
            }
        }

        print("Querying VM status from \(provider)...")
        print("")

        let client = UDPControlClient(networkId: "direct", networkKey: keyData)

        do {
            let response = try await client.queryVMStatus(
                providerEndpoint: provider,
                vmId: queryVmId
            )

            if response.vms.isEmpty {
                print("No VMs found on provider")
                return
            }

            print("Provider VMs")
            print("============")
            print("")

            for vm in response.vms {
                let statusIcon = vm.status == OmertaConsumer.VMStatus.running ? "●" : "○"
                print("\(statusIcon) [\(vm.vmId.uuidString.prefix(8))...] \(vm.vmIP)")
                print("   Status: \(vm.status.rawValue.uppercased())")
                print("   Uptime: \(formatUptime(vm.uptimeSeconds))")
                print("   Created: \(formatDate(vm.createdAt))")

                if let console = vm.consoleOutput, !console.isEmpty {
                    print("   Console:")
                    for line in console.split(separator: "\n").suffix(3) {
                        print("     \(line)")
                    }
                }
                print("")
            }

            print("Total: \(response.vms.count) VMs")

        } catch {
            print("Error querying status: \(error)")
            throw ExitCode.failure
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }

    private func formatDate(_ date: Date) -> String {
        formatRelativeDate(date)
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

    @Option(name: .long, help: "Network key (hex encoded). Uses local key from config if not specified.")
    var networkKey: String?

    @Flag(name: .long, help: "Skip confirmation")
    var force: Bool = false

    mutating func run() async throws {
        // Load config to get local key if not specified
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        // Determine network key
        let keyData: Data
        if let providedKey = networkKey {
            guard let data = Data(hexString: providedKey), data.count == 32 else {
                print("Error: Network key must be a 64-character hex string (32 bytes)")
                throw ExitCode.failure
            }
            keyData = data
        } else if let localKeyData = config.localKeyData() {
            keyData = localKeyData
        } else {
            print("Error: No network key specified and no local key in config.")
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
        abstract: "Clean up orphaned WireGuard interfaces, firewall rules, and resources"
    )

    @Flag(name: .long, help: "Clean up all Omerta interfaces, not just orphaned ones")
    var all: Bool = false

    @Flag(name: .long, help: "Show status only, don't actually clean up")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Skip confirmation")
    var force: Bool = false

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

        if !hasInterfacesToClean && !hasConfigFiles && !hasOrphanedProcesses && !hasFirewallWork && (!hasStaleVMs || !all) {
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

        print("")
        print("Cleanup complete!")
        if processesKilled > 0 {
            print("  Processes killed: \(processesKilled)")
        }
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
    }
}

// MARK: - VM Test Command
struct VMTest: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Test end-to-end VM request and SSH access"
    )

    @Option(name: .long, help: "Provider address (ip:port)")
    var provider: String

    @Option(name: .long, help: "Timeout in seconds for VM boot (default: 120)")
    var timeout: Int = 120

    @Option(name: .long, help: "Command to run via SSH (default: 'echo ok')")
    var command: String = "echo ok"

    @Flag(name: .long, help: "Keep the VM after test (don't release)")
    var keep: Bool = false

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        print("=== Omerta VM End-to-End Test ===")
        print("")

        // Load config
        let configManager = ConfigManager()
        let config: OmertaConfig
        do {
            config = try await configManager.load()
        } catch ConfigError.notInitialized {
            print("Error: Omerta not initialized. Run 'omerta init' first.")
            throw ExitCode.failure
        }

        guard let sshPublicKey = config.ssh.publicKey else {
            print("Error: SSH public key not found. Run 'omerta init' to regenerate.")
            throw ExitCode.failure
        }

        let sshKeyPath = config.ssh.expandedPrivateKeyPath()
        let sshUser = config.ssh.defaultUser

        // Get network key from config
        guard let networkKeyData = config.localKeyData() else {
            print("Error: No network key in config. Run 'omerta init' to generate one.")
            throw ExitCode.failure
        }

        print("1. Configuration")
        print("   SSH Key: \(sshKeyPath)")
        print("   SSH User: \(sshUser)")
        print("   Provider: \(provider)")
        print("   Timeout: \(timeout)s")
        print("   Test Command: '\(command)'")
        print("")

        // Step 2: Request VM
        print("2. Requesting VM...")
        let client = DirectProviderClient(networkKey: networkKeyData)
        let connection: VMConnection

        do {
            connection = try await client.requestVM(
                fromProvider: provider,
                sshPublicKey: sshPublicKey,
                sshKeyPath: sshKeyPath,
                sshUser: sshUser,
                timeout: 60.0
            )

            print("   ✓ VM requested successfully")
            print("   VM ID: \(connection.vmId)")
            print("   VM IP: \(connection.vmIP)")
            print("   VPN Interface: \(connection.vpnInterface)")
            print("")
        } catch {
            print("   ✗ Failed to request VM: \(error)")
            throw ExitCode.failure
        }

        // Step 3: Wait for VM to boot
        print("3. Waiting for VM to boot...")
        let startTime = Date()
        var sshReady = false
        var lastError: String = ""

        while Date().timeIntervalSince(startTime) < Double(timeout) {
            let elapsed = Int(Date().timeIntervalSince(startTime))
            print("   Checking SSH (\(elapsed)s / \(timeout)s)...", terminator: "")

            // Try SSH connection test
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-i", sshKeyPath,
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=5",
                "-o", "BatchMode=yes",
                "\(sshUser)@\(connection.vmIP)",
                "true"
            ]
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    print(" connected!")
                    sshReady = true
                    break
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    lastError = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
                    if verbose {
                        print(" not ready (\(lastError))")
                    } else {
                        print(" not ready")
                    }
                }
            } catch {
                print(" error: \(error)")
            }

            // Wait before retrying
            try await Task.sleep(for: .seconds(5))
        }

        if !sshReady {
            print("")
            print("   ✗ SSH connection timed out after \(timeout)s")
            print("   Last error: \(lastError)")
            if !keep {
                print("")
                print("   Releasing VM...")
                try? await client.releaseVM(vmId: connection.vmId)
            }
            throw ExitCode.failure
        }
        print("   ✓ VM is ready")
        print("")

        // Step 4: Run test command via SSH
        print("4. Running test command via SSH...")
        print("   Command: \(command)")

        let sshProcess = Process()
        sshProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        sshProcess.arguments = [
            "-i", sshKeyPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "\(sshUser)@\(connection.vmIP)",
            command
        ]
        let outputPipe = Pipe()
        let sshErrorPipe = Pipe()
        sshProcess.standardOutput = outputPipe
        sshProcess.standardError = sshErrorPipe

        do {
            try sshProcess.run()
            sshProcess.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if sshProcess.terminationStatus == 0 {
                print("   ✓ Command executed successfully")
                print("   Output: \(output)")
            } else {
                let errorData = sshErrorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                print("   ✗ Command failed (exit code: \(sshProcess.terminationStatus))")
                print("   Output: \(output)")
                print("   Error: \(errorOutput)")
                if !keep {
                    try? await client.releaseVM(vmId: connection.vmId)
                }
                throw ExitCode.failure
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            print("   ✗ SSH execution failed: \(error)")
            if !keep {
                try? await client.releaseVM(vmId: connection.vmId)
            }
            throw ExitCode.failure
        }
        print("")

        // Step 5: Cleanup
        if keep {
            print("5. Keeping VM (--keep specified)")
            print("   VM ID: \(connection.vmId)")
            print("   SSH Command: \(connection.sshCommand)")
        } else {
            print("5. Releasing VM...")
            do {
                try await client.releaseVM(vmId: connection.vmId)
                print("   ✓ VM released")
            } catch {
                print("   ⚠ Failed to release VM: \(error)")
            }
        }

        print("")
        print("=== Test completed successfully ===")
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
            // On Linux, remove wg interfaces
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
                let del = Process()
                del.executableURL = URL(fileURLWithPath: "/sbin/ip")
                del.arguments = ["link", "delete", String(iface)]
                del.standardOutput = FileHandle.nullDevice
                del.standardError = FileHandle.nullDevice
                try? del.run()
                del.waitUntilExit()
                print("  Deleted \(iface)")
            }
            #endif

            print("Cleanup complete")
        }
    }
}

// Data.init?(hexString:) is provided by OmertaCore
