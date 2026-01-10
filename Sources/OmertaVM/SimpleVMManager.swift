import Foundation
import Logging
import OmertaCore
import Crypto

#if os(Linux)
import Glibc
#elseif os(macOS)
import Virtualization
#endif

/// Simplified VM manager for VM infrastructure only (no job execution)
/// Starts VMs with SSH access, user controls everything after that
/// On Linux, uses QEMU/KVM for VM management
public actor SimpleVMManager {
    private let logger: Logger
    private var activeVMs: [UUID: RunningVM] = [:]
    private let basePort: UInt16 = 10000
    private let dryRun: Bool

    /// Base image path for VMs
    private let baseImagePath: String
    /// Directory for VM overlay disks
    private let vmDiskDir: String
    #if os(Linux)
    /// Track TAP interfaces for cleanup (Linux only - macOS uses vmnet)
    private var vmTapInterfaces: [UUID: String] = [:]
    #endif

    public struct RunningVM: Sendable {
        public let vmId: UUID
        public let qemuPid: Int32?  // QEMU process ID (Linux), nil in dry-run mode or when using Virtualization.framework
        public let sshPort: UInt16
        public let vmIP: String
        public let overlayDiskPath: String?
        public let seedISOPath: String?
        public let createdAt: Date
        #if os(macOS)
        // Virtualization.framework VM reference (macOS only)
        // Not Sendable by default, but we only access on main actor
        public let vzVM: VZVirtualMachine?
        #endif
    }

    /// Result of starting a VM - includes the VM's WireGuard public key
    /// so the consumer can add it as a peer
    public struct VMStartResult: Sendable {
        /// VM's IP address (NAT IP on macOS, VPN IP on Linux with TAP)
        public let vmIP: String
        /// VM's WireGuard public key (derived from generated private key)
        public let vmWireGuardPublicKey: String
    }

    public init(dryRun: Bool = false) {
        var logger = Logger(label: "com.omerta.vm.simple")
        logger.logLevel = .info
        self.logger = logger

        #if os(macOS)
        // macOS uses Virtualization.framework (no external dependencies)
        // Check if we're running on a supported macOS version (11.0+)
        if #available(macOS 11.0, *) {
            self.dryRun = dryRun
        } else {
            logger.warning("macOS 11.0+ required for Virtualization.framework - forcing DRY RUN mode")
            self.dryRun = true
        }
        #else
        // Linux uses QEMU/KVM
        let qemuAvailable = Self.checkQEMUAvailable()
        let accelAvailable = Self.checkAccelerationAvailable()

        if !qemuAvailable {
            logger.warning("QEMU not found - forcing DRY RUN mode. Install: sudo apt install qemu-system-x86")
            self.dryRun = true
        } else if !accelAvailable {
            logger.warning("KVM not available - VMs will use software emulation (slow). Check /dev/kvm for hardware acceleration.")
            self.dryRun = dryRun  // Allow running without acceleration (TCG mode)
        } else {
            self.dryRun = dryRun
        }
        #endif

        // Set up paths - use SUDO_USER's home if running with sudo
        let homeDir: String
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"] {
            // Running with sudo - use the original user's home directory
            #if os(macOS)
            homeDir = "/Users/\(sudoUser)"
            #else
            homeDir = "/home/\(sudoUser)"
            #endif
        } else {
            homeDir = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        }
        #if arch(arm64)
        let archSuffix = "arm64"
        #else
        let archSuffix = "amd64"
        #endif
        #if os(macOS)
        // macOS Virtualization.framework requires raw disk images (not QCOW2)
        self.baseImagePath = "\(homeDir)/.omerta/images/ubuntu-22.04-server-cloudimg-\(archSuffix).raw"
        #else
        // Linux QEMU supports QCOW2 directly
        self.baseImagePath = "\(homeDir)/.omerta/images/ubuntu-22.04-server-cloudimg-\(archSuffix).img"
        #endif
        self.vmDiskDir = "\(homeDir)/.omerta/vm-disks"

        // Create VM disk directory if it doesn't exist
        try? FileManager.default.createDirectory(
            atPath: vmDiskDir,
            withIntermediateDirectories: true
        )

        if self.dryRun {
            logger.info("SimpleVMManager initialized in DRY RUN mode - no actual VMs will be created")
        } else {
            #if os(macOS)
            logger.info("SimpleVMManager initialized with Virtualization.framework")
            #else
            logger.info("SimpleVMManager initialized with QEMU/KVM support")
            #endif
        }
    }

    /// Check if QEMU is available
    private static func checkQEMUAvailable() -> Bool {
        #if os(macOS)
        let paths = [
            "/opt/homebrew/bin/qemu-system-aarch64",
            "/opt/homebrew/bin/qemu-system-x86_64",
            "/usr/local/bin/qemu-system-aarch64",
            "/usr/local/bin/qemu-system-x86_64"
        ]
        #else
        let paths = [
            "/usr/bin/qemu-system-x86_64",
            "/usr/bin/qemu-system-aarch64",
            "/usr/local/bin/qemu-system-x86_64"
        ]
        #endif
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Check if hardware acceleration is available (KVM on Linux, HVF on macOS)
    private static func checkAccelerationAvailable() -> Bool {
        #if os(macOS)
        // HVF is generally available on Apple Silicon and Intel Macs with macOS 10.15+
        // We assume it's available - QEMU will fall back to TCG if not
        return true
        #else
        let kvmPath = "/dev/kvm"
        guard FileManager.default.fileExists(atPath: kvmPath) else {
            return false
        }
        // Try to open KVM device
        let fd = open(kvmPath, O_RDWR)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
        #endif
    }

    /// Get the appropriate QEMU binary for the host architecture
    private func getQEMUBinary() -> String {
        #if os(macOS)
            #if arch(arm64)
            return "/opt/homebrew/bin/qemu-system-aarch64"
            #else
            return "/opt/homebrew/bin/qemu-system-x86_64"
            #endif
        #else
            #if arch(x86_64)
            return "/usr/bin/qemu-system-x86_64"
            #elseif arch(arm64)
            return "/usr/bin/qemu-system-aarch64"
            #else
            return "/usr/bin/qemu-system-x86_64"
            #endif
        #endif
    }

    /// Get the UEFI firmware path for QEMU
    private func getUEFIFirmwarePath() -> String {
        #if os(macOS)
        return "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
        #else
        return "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
        #endif
    }

    // MARK: - VM Lifecycle

    /// Start a VM with specified resources and WireGuard network isolation
    /// - Parameters:
    ///   - vmId: Unique identifier for this VM
    ///   - requirements: CPU/memory requirements
    ///   - sshPublicKey: Consumer's SSH public key for access
    ///   - sshUser: Username for SSH access
    ///   - consumerPublicKey: Consumer's WireGuard public key (required for VM-side WireGuard)
    ///   - consumerEndpoint: Consumer's WireGuard endpoint ip:port (required for VM-side WireGuard)
    ///   - vpnIP: The WireGuard IP to assign to the VM (default: 10.200.200.2)
    ///   - reverseTunnelConfig: Optional config for VM to establish reverse SSH tunnel (macOS test mode)
    /// - Returns: VMStartResult containing the VM's IP and WireGuard public key
    public func startVM(
        vmId: UUID,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshUser: String = "omerta",
        consumerPublicKey: String,
        consumerEndpoint: String,
        vpnIP: String? = nil,
        reverseTunnelConfig: ReverseTunnelConfig? = nil
    ) async throws -> VMStartResult {
        logger.info("Starting VM", metadata: [
            "vm_id": "\(vmId)",
            "cpu_cores": "\(requirements.cpuCores ?? 0)",
            "memory_mb": "\(requirements.memoryMB ?? 0)",
            "ssh_user": "\(sshUser)",
            "dry_run": "\(dryRun)"
        ])

        // In dry-run mode, skip actual VM creation
        if dryRun {
            logger.info("DRY RUN: Simulating VM creation")

            // Use VPN IP if provided, otherwise generate simulated NAT IP
            let vmIP = vpnIP ?? generateVMNATIP()
            let sshPort = allocatePort()

            // Track "running" VM
            #if os(macOS)
            let runningVM = RunningVM(
                vmId: vmId,
                qemuPid: nil,
                sshPort: sshPort,
                vmIP: vmIP,
                overlayDiskPath: nil,
                seedISOPath: nil,
                createdAt: Date(),
                vzVM: nil
            )
            #else
            let runningVM = RunningVM(
                vmId: vmId,
                qemuPid: nil,
                sshPort: sshPort,
                vmIP: vmIP,
                overlayDiskPath: nil,
                seedISOPath: nil,
                createdAt: Date()
            )
            #endif
            activeVMs[vmId] = runningVM

            // Generate simulated WireGuard public key for dry-run
            let simulatedPublicKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

            logger.info("DRY RUN: VM simulated successfully", metadata: [
                "vm_id": "\(vmId)",
                "vm_ip": "\(vmIP)",
                "ssh_port": "\(sshPort)"
            ])

            return VMStartResult(vmIP: vmIP, vmWireGuardPublicKey: simulatedPublicKey)
        }

        #if os(macOS)
        // macOS: Use Virtualization.framework with NAT networking
        return try await startVMMacOS(
            vmId: vmId,
            requirements: requirements,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser,
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint,
            vpnIP: vpnIP,
            reverseTunnelConfig: reverseTunnelConfig
        )
        #else
        // Linux: Use QEMU/KVM
        return try await startVMQEMU(
            vmId: vmId,
            requirements: requirements,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser,
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint,
            vpnIP: vpnIP
        )
        #endif
    }

    #if os(Linux)
    private func startVMQEMU(
        vmId: UUID,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshUser: String,
        consumerPublicKey: String,
        consumerEndpoint: String,
        vpnIP: String?
    ) async throws -> VMStartResult {
        // 1. Verify base image exists
        guard FileManager.default.fileExists(atPath: baseImagePath) else {
            throw VMError.diskImageNotFound
        }

        // 2. Create overlay disk for this VM (copy-on-write)
        let overlayPath = "\(vmDiskDir)/\(vmId.uuidString).qcow2"
        try await createOverlayDisk(basePath: baseImagePath, overlayPath: overlayPath)
        logger.info("Created overlay disk", metadata: ["path": "\(overlayPath)"])

        // 3. Determine if we're using TAP networking (when vpnIP is provided)
        // TAP networking gives VM a specific IP on the host network
        #if os(Linux)
        if let vpnIPValue = vpnIP {
            // TAP networking: VM gets VPN IP directly (Linux only)
            let vmIP = vpnIPValue
            let sshPort: UInt16 = 22  // SSH directly on VPN IP

            // Use a separate subnet for TAP physical network (different from WireGuard VPN)
            // This allows the VM to reach external IPs (like consumer's WireGuard endpoint)
            // TAP network: 192.168.100.0/24, VM gets .2, gateway is .1
            let tapGatewayIP = "192.168.100.1"
            let tapVMIP = "192.168.100.2"

            // Create TAP interface with gateway IP
            let tapInterface = "tap-\(vmId.uuidString.prefix(8))"
            try await createTapInterface(name: tapInterface, gatewayIP: tapGatewayIP, vmIP: "\(tapVMIP)/24")
            vmTapInterfaces[vmId] = tapInterface

            logger.info("Created TAP interface for VM", metadata: [
                "vm_id": "\(vmId)",
                "tap": "\(tapInterface)",
                "vpn_ip": "\(vmIP)",
                "tap_gateway": "\(tapGatewayIP)",
                "tap_vm_ip": "\(tapVMIP)"
            ])

            // Generate cloud-init ISO
            let seedISOPath = "\(vmDiskDir)/\(vmId.uuidString)-seed.iso"

            // Check for test mode (used by standalone VM boot tests)
            let isTestMode = consumerEndpoint.hasPrefix("test://")
            let vmPublicKey: String

            logger.info("VM start request", metadata: [
                "vm_id": "\(vmId)",
                "is_test_mode": "\(isTestMode)",
                "consumer_endpoint": "\(consumerEndpoint)",
                "tap_gateway": "\(tapGatewayIP)",
                "tap_vm_ip": "\(tapVMIP)",
                "vpn_ip": "\(vmIP)"
            ])

            if isTestMode {
                // Test mode: simplified cloud-init with no WireGuard, internet blocked
                logger.info("Using test mode cloud-init (no WireGuard, internet blocked)", metadata: [
                    "consumer_endpoint": "\(consumerEndpoint)",
                    "ssh_user": "\(sshUser)",
                    "ssh_key_preview": "\(sshPublicKey.prefix(40))..."
                ])

                try createTestModeCloudInitISO(
                    at: seedISOPath,
                    sshPublicKey: sshPublicKey,
                    sshUser: sshUser,
                    instanceId: vmId,
                    tapVMIP: tapVMIP,
                    tapGateway: tapGatewayIP
                )

                // No WireGuard key in test mode, return a placeholder
                vmPublicKey = "test-mode-no-wireguard"
                logger.info("Created test mode cloud-init ISO", metadata: [
                    "path": "\(seedISOPath)",
                    "iso_exists": "\(FileManager.default.fileExists(atPath: seedISOPath))"
                ])
            } else {
                // Normal mode: full WireGuard + firewall cloud-init
                logger.info("Using VM-side WireGuard network isolation (Phase 9)", metadata: [
                    "consumer_endpoint": "\(consumerEndpoint)"
                ])

                // Generate VM's WireGuard keypair
                let (vmPrivateKey, generatedPublicKey) = try generateWireGuardKeypair()
                vmPublicKey = generatedPublicKey

                // Create network isolation config
                let vmAddress = "\(vpnIPValue)/24"
                let vmNetConfig = VMNetworkConfigFactory.createForConsumer(
                    consumerPublicKey: consumerPublicKey,
                    consumerEndpoint: consumerEndpoint,
                    vmPrivateKey: vmPrivateKey,
                    vmAddress: vmAddress,
                    packageConfig: .debian
                )

                // Create combined cloud-init ISO with WireGuard + firewall + SSH + TAP network config
                try createCombinedCloudInitISO(
                    at: seedISOPath,
                    vmNetConfig: vmNetConfig,
                    sshPublicKey: sshPublicKey,
                    sshUser: sshUser,
                    instanceId: vmId,
                    tapVMIP: tapVMIP,
                    tapGateway: tapGatewayIP
                )
                logger.info("Created network isolation cloud-init ISO", metadata: ["path": "\(seedISOPath)"])
            }

            // Build QEMU command with TAP networking
            let qemuArgs = try buildQEMUArgs(
                vmId: vmId,
                requirements: requirements,
                overlayPath: overlayPath,
                seedISOPath: seedISOPath,
                tapInterface: tapInterface
            )

            let qemuBinary = getQEMUBinary()
            logger.info("Starting QEMU VM with TAP networking", metadata: [
                "vm_id": "\(vmId)",
                "binary": "\(qemuBinary)",
                "tap": "\(tapInterface)",
                "vpn_ip": "\(vmIP)",
                "overlay_exists": "\(FileManager.default.fileExists(atPath: overlayPath))",
                "seed_iso_exists": "\(FileManager.default.fileExists(atPath: seedISOPath))"
            ])
            logger.info("QEMU arguments", metadata: [
                "args": "\(qemuArgs.joined(separator: " "))"
            ])

            // Start QEMU process
            let qemuPid = try await startQEMUProcess(
                binary: qemuBinary,
                arguments: qemuArgs,
                vmId: vmId
            )

            logger.info("QEMU process started", metadata: [
                "vm_id": "\(vmId)",
                "pid": "\(qemuPid)"
            ])

            // Track running VM
            let runningVM = RunningVM(
                vmId: vmId,
                qemuPid: qemuPid,
                sshPort: sshPort,
                vmIP: vmIP,
                overlayDiskPath: overlayPath,
                seedISOPath: seedISOPath,
                createdAt: Date()
            )
            activeVMs[vmId] = runningVM

            logger.info("VM started successfully with TAP networking", metadata: [
                "vm_id": "\(vmId)",
                "vm_ip": "\(vmIP)",
                "ssh_command": "ssh \(sshUser)@\(vmIP)"
            ])

            return VMStartResult(vmIP: vmIP, vmWireGuardPublicKey: vmPublicKey)
        }
        #else
        if vpnIP != nil {
            logger.warning("TAP networking requested but not supported on macOS VMs - using NAT")
        }
        #endif

        // SLIRP user-mode networking (used on Linux as fallback when no TAP)
        let vmIP = generateVMNATIP()
        let sshPort = allocatePort()

        // Generate cloud-init ISO with WireGuard + firewall (Phase 11.5)
        let seedISOPath = "\(vmDiskDir)/\(vmId.uuidString)-seed.iso"

        logger.info("Using VM-side WireGuard network isolation (Phase 9) with SLIRP", metadata: [
            "consumer_endpoint": "\(consumerEndpoint)"
        ])

        // Generate VM's WireGuard keypair
        let (vmPrivateKey, vmPublicKey) = try generateWireGuardKeypair()

        // Create network isolation config
        let vmAddress = vpnIP.map { "\($0)/24" } ?? "10.200.200.2/24"
        let vmNetConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumerPublicKey,
            consumerEndpoint: consumerEndpoint,
            vmPrivateKey: vmPrivateKey,
            vmAddress: vmAddress,
            packageConfig: .debian
        )

        // Create combined cloud-init ISO with WireGuard + firewall + SSH
        try createCombinedCloudInitISO(
            at: seedISOPath,
            vmNetConfig: vmNetConfig,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser,
            instanceId: vmId
        )
        logger.info("Created network isolation cloud-init ISO", metadata: ["path": "\(seedISOPath)"])

        // Build QEMU command with SLIRP networking
        let qemuArgs = try buildQEMUArgsSlirp(
            vmId: vmId,
            requirements: requirements,
            overlayPath: overlayPath,
            seedISOPath: seedISOPath,
            sshPort: sshPort
        )

        let qemuBinary = getQEMUBinary()
        logger.info("Starting QEMU VM with SLIRP networking", metadata: [
            "vm_id": "\(vmId)",
            "binary": "\(qemuBinary)",
            "ssh_port": "\(sshPort)"
        ])

        // Start QEMU process
        let qemuPid = try await startQEMUProcess(
            binary: qemuBinary,
            arguments: qemuArgs,
            vmId: vmId
        )

        logger.info("QEMU process started", metadata: [
            "vm_id": "\(vmId)",
            "pid": "\(qemuPid)"
        ])

        // Track running VM
        let runningVM = RunningVM(
            vmId: vmId,
            qemuPid: qemuPid,
            sshPort: sshPort,
            vmIP: vmIP,
            overlayDiskPath: overlayPath,
            seedISOPath: seedISOPath,
            createdAt: Date()
        )
        activeVMs[vmId] = runningVM

        logger.info("VM started successfully with SLIRP networking", metadata: [
            "vm_id": "\(vmId)",
            "vm_nat_ip": "\(vmIP)",
            "ssh_port": "\(sshPort)",
            "ssh_command": "ssh -p \(sshPort) \(sshUser)@localhost"
        ])

        return VMStartResult(vmIP: vmIP, vmWireGuardPublicKey: vmPublicKey)
    }

    #if os(Linux)
    /// Create a TAP interface for VM networking (Linux only)
    private func createTapInterface(name: String, gatewayIP: String? = nil, vmIP: String? = nil) async throws {
        logger.info("Creating TAP interface", metadata: ["name": "\(name)"])

        // Create TAP interface
        let createProcess = Process()
        createProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        createProcess.arguments = ["ip", "tuntap", "add", "dev", name, "mode", "tap"]

        let createError = Pipe()
        createProcess.standardError = createError
        createProcess.standardOutput = FileHandle.nullDevice

        try createProcess.run()
        createProcess.waitUntilExit()

        guard createProcess.terminationStatus == 0 else {
            let errorData = createError.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw VMError.tapCreationFailed(errorMessage)
        }

        // Assign gateway IP to TAP interface if provided
        if let gateway = gatewayIP {
            let addrProcess = Process()
            addrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            addrProcess.arguments = ["ip", "addr", "add", "\(gateway)/24", "dev", name]
            addrProcess.standardOutput = FileHandle.nullDevice
            addrProcess.standardError = FileHandle.nullDevice

            try? addrProcess.run()
            addrProcess.waitUntilExit()
            logger.info("Assigned IP to TAP interface", metadata: ["interface": "\(name)", "ip": "\(gateway)/24"])
        }

        // Bring interface up
        let upProcess = Process()
        upProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        upProcess.arguments = ["ip", "link", "set", name, "up"]

        try upProcess.run()
        upProcess.waitUntilExit()

        // Enable IP forwarding
        let forwardProcess = Process()
        forwardProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        forwardProcess.arguments = ["sysctl", "-w", "net.ipv4.ip_forward=1"]
        forwardProcess.standardOutput = FileHandle.nullDevice
        forwardProcess.standardError = FileHandle.nullDevice

        try? forwardProcess.run()
        forwardProcess.waitUntilExit()

        // Enable proxy ARP on the TAP interface so it can reach the gateway
        let proxyArpProcess = Process()
        proxyArpProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proxyArpProcess.arguments = ["sysctl", "-w", "net.ipv4.conf.\(name).proxy_arp=1"]

        try? proxyArpProcess.run()
        proxyArpProcess.waitUntilExit()

        // Add NAT/masquerade rule so VM can reach external IPs (like consumer's WireGuard)
        let natProcess = Process()
        natProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        natProcess.arguments = ["iptables", "-t", "nat", "-A", "POSTROUTING", "-o", "!lo", "-s", vmIP ?? "10.0.0.0/8", "-j", "MASQUERADE"]
        natProcess.standardOutput = FileHandle.nullDevice
        natProcess.standardError = FileHandle.nullDevice

        try? natProcess.run()
        natProcess.waitUntilExit()
        logger.info("Added NAT masquerade rule for TAP network")

        logger.info("TAP interface created and configured", metadata: ["name": "\(name)"])
    }

    /// Delete a TAP interface
    private func deleteTapInterface(name: String) async {
        logger.info("Deleting TAP interface", metadata: ["name": "\(name)"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["ip", "link", "delete", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()
    }

    /// Build QEMU arguments for TAP networking (Linux only)
    private func buildQEMUArgs(
        vmId: UUID,
        requirements: ResourceRequirements,
        overlayPath: String,
        seedISOPath: String,
        tapInterface: String
    ) throws -> [String] {
        let cpuCores = max(2, Int(requirements.cpuCores ?? 2))
        let memoryMB = max(1024, requirements.memoryMB ?? 2048)
        let kvmAvailable = Self.checkAccelerationAvailable()

        var args: [String] = []

        // Add KVM acceleration if available
        if kvmAvailable {
            args.append(contentsOf: ["-enable-kvm", "-cpu", "host"])
        } else {
            #if arch(arm64)
            args.append(contentsOf: ["-cpu", "cortex-a72"])
            #else
            args.append(contentsOf: ["-cpu", "qemu64"])
            #endif
            logger.info("Using software emulation (TCG) - VM will be slow")
        }

        args.append(contentsOf: [
            "-m", "\(memoryMB)",
            "-smp", "\(cpuCores)",
            "-drive", "file=\(overlayPath),format=qcow2,if=virtio",
            "-drive", "file=\(seedISOPath),format=raw,if=virtio,readonly=on",
            // TAP networking - VM gets direct L2 access
            "-netdev", "tap,id=net0,ifname=\(tapInterface),script=no,downscript=no",
            "-device", "virtio-net-pci,netdev=net0",
            "-nographic",
            "-serial", "mon:stdio",
            "-pidfile", "\(vmDiskDir)/\(vmId.uuidString).pid"
        ])

        // Add architecture-specific options
        #if arch(arm64)
        args.insert(contentsOf: [
            "-machine", "virt",
            "-bios", "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
        ], at: 0)
        #else
        args.insert(contentsOf: [
            "-machine", "q35"
        ], at: 0)
        #endif

        return args
    }
    #endif

    /// Build QEMU arguments for SLIRP user-mode networking
    private func buildQEMUArgsSlirp(
        vmId: UUID,
        requirements: ResourceRequirements,
        overlayPath: String,
        seedISOPath: String,
        sshPort: UInt16
    ) throws -> [String] {
        let cpuCores = max(2, Int(requirements.cpuCores ?? 2))
        let memoryMB = max(1024, requirements.memoryMB ?? 2048)
        let accelAvailable = Self.checkAccelerationAvailable()

        var args: [String] = []

        // Add hardware acceleration if available (KVM on Linux, HVF on macOS)
        #if os(macOS)
        if accelAvailable {
            args.append(contentsOf: ["-accel", "hvf", "-cpu", "host"])
        } else {
            #if arch(arm64)
            args.append(contentsOf: ["-cpu", "cortex-a72"])
            #else
            args.append(contentsOf: ["-cpu", "qemu64"])
            #endif
            logger.info("Using software emulation (TCG) - VM will be slow")
        }
        #else
        if accelAvailable {
            args.append(contentsOf: ["-enable-kvm", "-cpu", "host"])
        } else {
            #if arch(arm64)
            args.append(contentsOf: ["-cpu", "cortex-a72"])
            #else
            args.append(contentsOf: ["-cpu", "qemu64"])
            #endif
            logger.info("Using software emulation (TCG) - VM will be slow")
        }
        #endif

        args.append(contentsOf: [
            "-m", "\(memoryMB)",
            "-smp", "\(cpuCores)",
            "-drive", "file=\(overlayPath),format=qcow2,if=virtio",
            "-drive", "file=\(seedISOPath),format=raw,if=virtio,readonly=on",
            // SLIRP user-mode networking with SSH port forward
            "-netdev", "user,id=net0,hostfwd=tcp::\(sshPort)-:22",
            "-device", "virtio-net-pci,netdev=net0",
            "-nographic",
            "-serial", "mon:stdio",
            "-pidfile", "\(vmDiskDir)/\(vmId.uuidString).pid"
        ])

        // Add architecture-specific options
        #if arch(arm64)
        args.insert(contentsOf: [
            "-machine", "virt",
            "-bios", getUEFIFirmwarePath()
        ], at: 0)
        #else
        args.insert(contentsOf: [
            "-machine", "q35"
        ], at: 0)
        #endif

        return args
    }

    /// Create a QCOW2 overlay disk backed by the base image
    private func createOverlayDisk(basePath: String, overlayPath: String) async throws {
        // Remove existing overlay if present
        try? FileManager.default.removeItem(atPath: overlayPath)

        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/qemu-img")
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qemu-img")
        #endif
        process.arguments = [
            "create",
            "-f", "qcow2",
            "-b", basePath,
            "-F", "qcow2",
            overlayPath
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw VMError.startFailed(NSError(domain: "QEMU", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create overlay disk: \(errorMessage)"]))
        }
    }

    /// Start QEMU process in the background
    private func startQEMUProcess(
        binary: String,
        arguments: [String],
        vmId: UUID
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        // Redirect output to log files
        let logDir = vmDiskDir
        let stdoutPath = "\(logDir)/\(vmId.uuidString)-stdout.log"
        let stderrPath = "\(logDir)/\(vmId.uuidString)-stderr.log"

        FileManager.default.createFile(atPath: stdoutPath, contents: nil)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)

        process.standardOutput = FileHandle(forWritingAtPath: stdoutPath)
        process.standardError = FileHandle(forWritingAtPath: stderrPath)
        process.standardInput = FileHandle.nullDevice

        // Start process
        try process.run()

        // Give QEMU a moment to start
        try await Task.sleep(for: .milliseconds(500))

        // Check if process is still running
        guard process.isRunning else {
            let stderrData = FileManager.default.contents(atPath: stderrPath) ?? Data()
            let stderrMessage = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            throw VMError.startFailed(NSError(domain: "QEMU", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "QEMU failed to start: \(stderrMessage)"]))
        }

        return process.processIdentifier
    }
    #endif  // os(Linux) - QEMU functions

    #if os(macOS)
    /// Start a VM using macOS Virtualization.framework with WireGuard network isolation
    /// Returns VMStartResult with VM's IP and WireGuard public key
    private func startVMMacOS(
        vmId: UUID,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshUser: String,
        consumerPublicKey: String,
        consumerEndpoint: String,
        vpnIP: String?,
        reverseTunnelConfig: ReverseTunnelConfig?
    ) async throws -> VMStartResult {
        // 1. Verify base image exists
        guard FileManager.default.fileExists(atPath: baseImagePath) else {
            throw VMError.diskImageNotFound
        }

        // 2. Create overlay disk for this VM (copy-on-write)
        // For Virtualization.framework, we need a raw disk, not qcow2
        let rawOverlayPath = "\(vmDiskDir)/\(vmId.uuidString).raw"
        try await createRawOverlay(basePath: baseImagePath, overlayPath: rawOverlayPath)
        logger.info("Created raw overlay disk", metadata: ["path": "\(rawOverlayPath)"])

        // 3. Generate cloud-init ISO
        let seedISOPath = "\(vmDiskDir)/\(vmId.uuidString)-seed.iso"

        // Check for test mode (used by standalone VM boot tests)
        let isTestMode = consumerEndpoint.hasPrefix("test://")
        let vmPublicKey: String

        logger.info("VM start request (macOS)", metadata: [
            "vm_id": "\(vmId)",
            "is_test_mode": "\(isTestMode)",
            "consumer_endpoint": "\(consumerEndpoint)",
            "has_reverse_tunnel": "\(reverseTunnelConfig != nil)"
        ])

        if isTestMode {
            // Test mode: simplified cloud-init with optional reverse SSH tunnel
            logger.info("Using test mode cloud-init for macOS", metadata: [
                "consumer_endpoint": "\(consumerEndpoint)",
                "ssh_user": "\(sshUser)",
                "reverse_tunnel": "\(reverseTunnelConfig != nil)"
            ])

            try createTestModeCloudInitISOMacOS(
                at: seedISOPath,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser,
                instanceId: vmId,
                reverseTunnelConfig: reverseTunnelConfig
            )

            // No WireGuard key in test mode
            vmPublicKey = "test-mode-no-wireguard"
            logger.info("Created test mode cloud-init ISO (macOS)", metadata: [
                "path": "\(seedISOPath)",
                "iso_exists": "\(FileManager.default.fileExists(atPath: seedISOPath))"
            ])
        } else {
            // Normal mode: full WireGuard + firewall cloud-init
            logger.info("Using VM-side WireGuard network isolation (Phase 9)", metadata: [
                "consumer_endpoint": "\(consumerEndpoint)"
            ])

            // Generate VM's WireGuard keypair
            let (vmPrivateKey, generatedPublicKey) = try generateWireGuardKeypair()
            vmPublicKey = generatedPublicKey

            // Create network isolation config
            let vmAddress = vpnIP.map { "\($0)/24" } ?? "10.200.200.2/24"
            let vmNetConfig = VMNetworkConfigFactory.createForConsumer(
                consumerPublicKey: consumerPublicKey,
                consumerEndpoint: consumerEndpoint,
                vmPrivateKey: vmPrivateKey,
                vmAddress: vmAddress,
                packageConfig: .debian
            )

            // Create combined cloud-init ISO with WireGuard + firewall + SSH
            try createCombinedCloudInitISO(
                at: seedISOPath,
                vmNetConfig: vmNetConfig,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser,
                instanceId: vmId
            )
            logger.info("Created network isolation cloud-init ISO", metadata: ["path": "\(seedISOPath)"])
        }

        // 4. Create VM configuration
        let config = try await createVMConfiguration(
            vmId: vmId,
            requirements: requirements,
            diskPath: rawOverlayPath,
            seedISOPath: seedISOPath
        )

        // 5. Create and start VM (must be on main queue)
        let vm = try await MainActor.run {
            let vm = VZVirtualMachine(configuration: config)
            return vm
        }

        logger.info("Starting Virtualization.framework VM", metadata: ["vm_id": "\(vmId)"])

        // Start VM on main queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.start { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        // 6. Get VM's NAT IP address
        // Virtualization.framework assigns IPs from 192.168.64.0/24
        // The VM typically gets .2, .3, etc. (gateway is .1)
        let vmIP = generateVMNATIP()

        // 7. SSH is on standard port 22 (accessed via NAT IP)
        let sshPort: UInt16 = 22

        // 8. Track running VM
        let runningVM = RunningVM(
            vmId: vmId,
            qemuPid: nil,
            sshPort: sshPort,
            vmIP: vmIP,
            overlayDiskPath: rawOverlayPath,
            seedISOPath: seedISOPath,
            createdAt: Date(),
            vzVM: vm
        )
        activeVMs[vmId] = runningVM

        logger.info("VM started successfully with Virtualization.framework", metadata: [
            "vm_id": "\(vmId)",
            "vm_nat_ip": "\(vmIP)",
            "ssh_command": "ssh \(sshUser)@\(vmIP)"
        ])

        return VMStartResult(vmIP: vmIP, vmWireGuardPublicKey: vmPublicKey)
    }

    /// Create a raw disk overlay backed by the base image (for Virtualization.framework)
    private func createRawOverlay(basePath: String, overlayPath: String) async throws {
        // Remove existing overlay if present
        try? FileManager.default.removeItem(atPath: overlayPath)

        // For Virtualization.framework, we need to copy the base image
        // since it doesn't support QCOW2 overlays
        // TODO: Consider using sparse copies for efficiency
        try FileManager.default.copyItem(atPath: basePath, toPath: overlayPath)
    }

    /// Create VM configuration for Virtualization.framework
    private func createVMConfiguration(
        vmId: UUID,
        requirements: ResourceRequirements,
        diskPath: String,
        seedISOPath: String
    ) async throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        // CPU configuration (minimum 2 for Ubuntu)
        let cpuCores = max(2, Int(requirements.cpuCores ?? 2))
        config.cpuCount = cpuCores

        // Memory configuration (minimum 1GB for Ubuntu)
        let memoryMB = max(1024, requirements.memoryMB ?? 2048)
        let memoryBytes = UInt64(memoryMB) * 1024 * 1024
        config.memorySize = memoryBytes

        // Platform configuration for ARM64
        let platform = VZGenericPlatformConfiguration()
        config.platform = platform

        // EFI boot loader for Ubuntu cloud image (per-VM EFI store)
        let efiVariableStore = try getOrCreateEFIVariableStore(vmId: vmId)
        let bootloader = VZEFIBootLoader()
        bootloader.variableStore = efiVariableStore
        config.bootLoader = bootloader

        // Entropy device (required for Linux)
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon device
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Network device with NAT (doesn't require restricted entitlement)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // Storage devices
        var storageDevices: [VZStorageDeviceConfiguration] = []

        // 1. Main Ubuntu disk image
        let diskURL = URL(fileURLWithPath: diskPath)
        let mainDiskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false
        )
        let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
        storageDevices.append(mainDisk)

        // 2. Cloud-init seed ISO (dynamically generated with consumer's SSH key)
        let seedURL = URL(fileURLWithPath: seedISOPath)
        let seedAttachment = try VZDiskImageStorageDeviceAttachment(
            url: seedURL,
            readOnly: true
        )
        let seedDisk = VZVirtioBlockDeviceConfiguration(attachment: seedAttachment)
        storageDevices.append(seedDisk)

        config.storageDevices = storageDevices

        // Serial console - write to log file for debugging
        // Note: Virtualization.framework serial ports need both read and write handles
        let consoleLogPath = "\(vmDiskDir)/\(vmId.uuidString)-console.log"
        if FileManager.default.createFile(atPath: consoleLogPath, contents: nil) {
            if let logHandle = FileHandle(forWritingAtPath: consoleLogPath) {
                // Create a pipe for the read end (VM reads from this)
                let inputPipe = Pipe()
                let consolePort = VZVirtioConsoleDeviceSerialPortConfiguration()
                consolePort.attachment = VZFileHandleSerialPortAttachment(
                    fileHandleForReading: inputPipe.fileHandleForReading,
                    fileHandleForWriting: logHandle
                )
                config.serialPorts = [consolePort]
                logger.info("Console output will be logged to: \(consoleLogPath)")
            }
        }

        // Validate configuration
        try config.validate()

        logger.info("VM configuration created", metadata: [
            "cpu_cores": "\(cpuCores)",
            "memory_mb": "\(memoryMB)"
        ])

        return config
    }

    #endif  // os(macOS) - Virtualization.framework functions

    // MARK: - Cloud-Init (Cross-Platform)

    /// Create a combined cloud-init ISO with network isolation + SSH access
    private func createCombinedCloudInitISO(
        at outputPath: String,
        vmNetConfig: VMNetworkConfig,
        sshPublicKey: String,
        sshUser: String,
        instanceId: UUID,
        tapVMIP: String? = nil,
        tapGateway: String? = nil
    ) throws {
        // Generate user-data with network isolation config
        var userData = CloudInitGenerator.generateNetworkIsolationUserData(config: vmNetConfig)

        // Append SSH user configuration
        // The network isolation config sets hostname, we add SSH user separately
        let sshConfig = """

        # SSH User Configuration
        users:
          - name: \(sshUser)
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/bash
            ssh_authorized_keys:
              - \(sshPublicKey)
        """

        userData += sshConfig

        // Generate meta-data
        let metaData = CloudInitGenerator.generateNetworkIsolationMetaData(config: vmNetConfig)

        // Create temp directory for cloud-init files
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudinit-combined-\(instanceId.uuidString.prefix(8))")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Write user-data
        let userDataPath = tempDir.appendingPathComponent("user-data")
        try userData.write(to: userDataPath, atomically: true, encoding: .utf8)

        // Write meta-data
        let metaDataPath = tempDir.appendingPathComponent("meta-data")
        try metaData.write(to: metaDataPath, atomically: true, encoding: .utf8)

        // Write network-config for TAP interface if provided
        if let vmIP = tapVMIP, let gateway = tapGateway {
            let networkConfig = """
            version: 2
            ethernets:
              id0:
                match:
                  driver: virtio*
                addresses:
                  - \(vmIP)/24
                routes:
                  - to: default
                    via: \(gateway)
                nameservers:
                  addresses: ["8.8.8.8", "8.8.4.4"]
            """
            let networkConfigPath = tempDir.appendingPathComponent("network-config")
            try networkConfig.write(to: networkConfigPath, atomically: true, encoding: .utf8)
            logger.info("Added TAP network config to cloud-init", metadata: [
                "vm_ip": "\(vmIP)",
                "gateway": "\(gateway)"
            ])
        }

        // Create ISO using platform-specific method
        try CloudInitGenerator.createISOFromDirectory(from: tempDir.path, to: outputPath)
    }

    /// Create a simplified cloud-init for test mode (no WireGuard, with internet-blocking firewall)
    /// This is used for standalone VM boot tests that only need SSH access over TAP
    private func createTestModeCloudInitISO(
        at outputPath: String,
        sshPublicKey: String,
        sshUser: String,
        instanceId: UUID,
        tapVMIP: String,
        tapGateway: String
    ) throws {
        // Generate user-data with simplified config (no WireGuard, internet-blocking firewall)
        let userData = """
        #cloud-config

        # Test Mode VM Configuration
        # No WireGuard, SSH only over TAP, internet access blocked

        hostname: omerta-test-\(instanceId.uuidString.prefix(8))

        # SSH User Configuration
        users:
          - name: \(sshUser)
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/bash
            ssh_authorized_keys:
              - \(sshPublicKey)

        # Firewall rules to block internet access (only allow TAP gateway)
        runcmd:
          - echo "Setting up test mode firewall (blocking internet)..."
          # Flush existing rules
          - iptables -F
          - iptables -X
          # Default policies
          - iptables -P INPUT DROP
          - iptables -P FORWARD DROP
          - iptables -P OUTPUT DROP
          # Allow loopback
          - iptables -A INPUT -i lo -j ACCEPT
          - iptables -A OUTPUT -o lo -j ACCEPT
          # Allow established connections
          - iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
          - iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
          # Allow SSH from TAP network only
          - iptables -A INPUT -p tcp --dport 22 -s 192.168.100.0/24 -j ACCEPT
          - iptables -A OUTPUT -p tcp --sport 22 -d 192.168.100.0/24 -j ACCEPT
          # Allow ICMP (ping) from TAP network only
          - iptables -A INPUT -p icmp -s 192.168.100.0/24 -j ACCEPT
          - iptables -A OUTPUT -p icmp -d 192.168.100.0/24 -j ACCEPT
          # Allow DNS for internal resolution only (no external)
          - iptables -A OUTPUT -p udp --dport 53 -d 192.168.100.1 -j ACCEPT
          - iptables -A INPUT -p udp --sport 53 -s 192.168.100.1 -j ACCEPT
          # Block everything else (already dropped by default policy)
          - echo "Test mode firewall configured - internet access blocked"
          - iptables -L -v -n

        final_message: "Test VM ready - SSH accessible at \(tapVMIP)"
        """

        // Generate meta-data
        let metaData = """
        instance-id: omerta-test-\(instanceId.uuidString)
        local-hostname: omerta-test-\(instanceId.uuidString.prefix(8))
        """

        // Generate network-config for TAP interface
        let networkConfig = """
        version: 2
        ethernets:
          id0:
            match:
              driver: virtio*
            addresses:
              - \(tapVMIP)/24
            routes:
              - to: default
                via: \(tapGateway)
        """

        // Create temp directory for cloud-init files
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudinit-test-\(instanceId.uuidString.prefix(8))")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Write user-data
        let userDataPath = tempDir.appendingPathComponent("user-data")
        try userData.write(to: userDataPath, atomically: true, encoding: .utf8)

        // Write meta-data
        let metaDataPath = tempDir.appendingPathComponent("meta-data")
        try metaData.write(to: metaDataPath, atomically: true, encoding: .utf8)

        // Write network-config
        let networkConfigPath = tempDir.appendingPathComponent("network-config")
        try networkConfig.write(to: networkConfigPath, atomically: true, encoding: .utf8)

        logger.info("Created test mode cloud-init (no WireGuard, internet blocked)", metadata: [
            "vm_ip": "\(tapVMIP)",
            "gateway": "\(tapGateway)"
        ])

        // Create ISO using platform-specific method
        try CloudInitGenerator.createISOFromDirectory(from: tempDir.path, to: outputPath)
    }

    /// Create a cloud-init for macOS test mode with optional reverse SSH tunnel
    /// macOS VMs use NAT networking, so inbound connections require a reverse tunnel
    private func createTestModeCloudInitISOMacOS(
        at outputPath: String,
        sshPublicKey: String,
        sshUser: String,
        instanceId: UUID,
        reverseTunnelConfig: ReverseTunnelConfig?
    ) throws {
        let hostname = "omerta-vm-\(instanceId.uuidString.prefix(8).lowercased())"

        // Build user-data YAML
        var lines: [String] = [
            "#cloud-config",
            "hostname: \(hostname)",
            "",
            "users:",
            "  - name: \(sshUser)",
            "    sudo: ALL=(ALL) NOPASSWD:ALL",
            "    shell: /bin/bash",
            "    ssh_authorized_keys:",
            "      - \(sshPublicKey)",
            "",
            "ssh_pwauth: true",
            "chpasswd:",
            "  list: |",
            "    \(sshUser):omerta123",
            "  expire: false",
            ""
        ]

        // Add write_files for tunnel key if needed
        if let tunnel = reverseTunnelConfig {
            lines.append("write_files:")
            lines.append("  - path: /root/.ssh/tunnel_key")
            lines.append("    permissions: '0600'")
            lines.append("    content: |")
            // Add each line of the private key with proper indentation
            for keyLine in tunnel.privateKey.split(separator: "\n") {
                lines.append("      \(keyLine)")
            }
            lines.append("  - path: /root/.ssh/config")
            lines.append("    permissions: '0600'")
            lines.append("    content: |")
            lines.append("      Host *")
            lines.append("        StrictHostKeyChecking no")
            lines.append("        UserKnownHostsFile /dev/null")
            lines.append("")
        }

        // Add runcmd
        lines.append("runcmd:")
        lines.append("  - systemctl enable ssh")
        lines.append("  - systemctl start ssh")

        if let tunnel = reverseTunnelConfig {
            lines.append("  - mkdir -p /root/.ssh && chmod 700 /root/.ssh")
            lines.append("  - sleep 10")
            // Use nohup to run the tunnel in background
            lines.append("  - nohup ssh -i /root/.ssh/tunnel_key -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R \(tunnel.tunnelPort):localhost:22 -N \(tunnel.hostUser)@\(tunnel.hostIP) -p \(tunnel.hostPort) > /var/log/tunnel.log 2>&1 &")
            lines.append("  - echo 'Reverse SSH tunnel started'")
        }

        lines.append("  - touch /etc/cloud/cloud-init.disabled")
        lines.append("")
        lines.append("final_message: \"macOS Test VM ready - \(hostname)\"")

        let userData = lines.joined(separator: "\n")

        // Generate meta-data
        let metaData = """
        instance-id: \(instanceId.uuidString)
        local-hostname: \(hostname)
        """

        // Create temp directory for cloud-init files
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudinit-macos-test-\(instanceId.uuidString.prefix(8))")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Write user-data
        let userDataPath = tempDir.appendingPathComponent("user-data")
        try userData.write(to: userDataPath, atomically: true, encoding: .utf8)

        // Write meta-data
        let metaDataPath = tempDir.appendingPathComponent("meta-data")
        try metaData.write(to: metaDataPath, atomically: true, encoding: .utf8)

        // No network-config needed - macOS NAT handles DHCP

        logger.info("Created macOS test mode cloud-init", metadata: [
            "hostname": "\(hostname)",
            "has_reverse_tunnel": "\(reverseTunnelConfig != nil)"
        ])

        // Create ISO using platform-specific method
        try CloudInitGenerator.createISOFromDirectory(from: tempDir.path, to: outputPath)
    }

    #if os(macOS)
    // MARK: - macOS EFI Support

    /// Get the real user's home directory (handles sudo correctly)
    private func getRealUserHomeDir() -> String {
        // When running with sudo, $HOME points to root's home
        // Check SUDO_USER to get the original user's home
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"] {
            return "/Users/\(sudoUser)"
        } else if let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        } else {
            return NSHomeDirectory()
        }
    }

    private func getOrCreateEFIVariableStore(vmId: UUID) throws -> VZEFIVariableStore {
        let homeDir = getRealUserHomeDir()
        let efiDir = "\(homeDir)/.omerta/vm-disks"
        let efiPath = "\(efiDir)/\(vmId)-efi-vars.bin"
        let efiURL = URL(fileURLWithPath: efiPath)

        // Create directory if needed
        try? FileManager.default.createDirectory(
            atPath: efiDir,
            withIntermediateDirectories: true
        )

        // Always create a fresh EFI store for each VM to avoid permission/state issues
        if FileManager.default.fileExists(atPath: efiPath) {
            try? FileManager.default.removeItem(atPath: efiPath)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
    }
    #endif

    /// Stop and destroy a VM
    public func stopVM(vmId: UUID) async throws {
        guard let runningVM = activeVMs[vmId] else {
            logger.warning("VM not found", metadata: ["vm_id": "\(vmId)"])
            return
        }

        logger.info("Stopping VM", metadata: ["vm_id": "\(vmId)", "dry_run": "\(dryRun)"])

        if dryRun {
            logger.info("DRY RUN: Simulating VM stop")
        } else {
            #if os(macOS)
            // Stop Virtualization.framework VM
            if let vm = runningVM.vzVM {
                logger.info("Stopping Virtualization.framework VM")
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.main.async {
                        vm.stop { error in
                            if let error = error {
                                // Log but don't fail - VM might already be stopped
                                self.logger.warning("Error stopping VM: \(error)")
                            }
                            continuation.resume()
                        }
                    }
                }
            }
            #else
            // Stop QEMU process (Linux)
            if let pid = runningVM.qemuPid {
                // Send SIGTERM to QEMU process
                logger.info("Sending SIGTERM to QEMU", metadata: ["pid": "\(pid)"])
                kill(pid, SIGTERM)

                // Wait a moment for graceful shutdown
                try await Task.sleep(for: .seconds(2))

                // Check if still running and force kill if necessary
                if kill(pid, 0) == 0 {
                    logger.warning("QEMU didn't respond to SIGTERM, sending SIGKILL", metadata: ["pid": "\(pid)"])
                    kill(pid, SIGKILL)
                }
            }

            // Clean up TAP interface if present (Linux only)
            if let tapInterface = vmTapInterfaces[vmId] {
                await deleteTapInterface(name: tapInterface)
                vmTapInterfaces.removeValue(forKey: vmId)
                logger.info("Cleaned up TAP interface", metadata: ["tap": "\(tapInterface)"])
            }
            #endif
        }

        // Clean up overlay disk and seed ISO
        if let overlayPath = runningVM.overlayDiskPath {
            try? FileManager.default.removeItem(atPath: overlayPath)
            logger.info("Removed overlay disk", metadata: ["path": "\(overlayPath)"])
        }
        if let seedPath = runningVM.seedISOPath {
            try? FileManager.default.removeItem(atPath: seedPath)
            logger.info("Removed seed ISO", metadata: ["path": "\(seedPath)"])
        }

        // Clean up log files and pid file (QEMU only)
        #if os(Linux)
        let pidFilePath = "\(vmDiskDir)/\(vmId.uuidString).pid"
        try? FileManager.default.removeItem(atPath: pidFilePath)
        try? FileManager.default.removeItem(atPath: "\(vmDiskDir)/\(vmId.uuidString)-stdout.log")
        try? FileManager.default.removeItem(atPath: "\(vmDiskDir)/\(vmId.uuidString)-stderr.log")
        #endif

        // Remove from tracking
        activeVMs.removeValue(forKey: vmId)

        logger.info("VM stopped successfully", metadata: ["vm_id": "\(vmId)"])
    }

    /// Get active VM count
    public func getActiveVMCount() -> Int {
        activeVMs.count
    }

    /// Check if VM is running
    public func isVMRunning(vmId: UUID) -> Bool {
        activeVMs[vmId] != nil
    }

    /// Get the SSH port for a VM (for SLIRP user-mode networking)
    public func getSSHPort(vmId: UUID) -> UInt16? {
        activeVMs[vmId]?.sshPort
    }

    /// Get VM info for a running VM
    public func getVMInfo(vmId: UUID) -> (ip: String, sshPort: UInt16)? {
        guard let vm = activeVMs[vmId] else { return nil }
        return (vm.vmIP, vm.sshPort)
    }

    /// Check if VM is still running (process/framework level)
    public func isVMProcessRunning(vmId: UUID) -> Bool {
        guard let vm = activeVMs[vmId] else {
            return false
        }

        #if os(macOS)
        // Check Virtualization.framework VM state
        if let vzVM = vm.vzVM {
            // VZVirtualMachine state is only accessible from main thread
            // For now, assume it's running if we have a reference
            // A more robust check would need to be done on the main actor
            return true
        }
        return false
        #else
        // Check QEMU process (Linux)
        guard let pid = vm.qemuPid else {
            return false
        }
        // kill with signal 0 checks if process exists
        return kill(pid, 0) == 0
        #endif
    }

    /// Check if VM's QEMU process is still running (Linux only, kept for backwards compatibility)
    public func isQEMURunning(vmId: UUID) -> Bool {
        #if os(Linux)
        guard let vm = activeVMs[vmId], let pid = vm.qemuPid else {
            return false
        }
        return kill(pid, 0) == 0
        #else
        return isVMProcessRunning(vmId: vmId)
        #endif
    }

    /// Wait for VM to be ready for SSH connections
    /// This polls the SSH port until it accepts connections
    public func waitForSSHReady(vmId: UUID, timeout: Duration = .seconds(120)) async throws -> Bool {
        guard let vm = activeVMs[vmId] else {
            throw VMError.vmNotFound(vmId)
        }

        let startTime = Date()
        let timeoutSeconds = timeout.components.seconds

        logger.info("Waiting for VM SSH to be ready", metadata: [
            "vm_id": "\(vmId)",
            "vm_ip": "\(vm.vmIP)",
            "ssh_port": "\(vm.sshPort)",
            "timeout": "\(timeoutSeconds)s"
        ])

        while Date().timeIntervalSince(startTime) < Double(timeoutSeconds) {
            // Check if VM is still running
            #if os(Linux)
            if let pid = vm.qemuPid, kill(pid, 0) != 0 {
                throw VMError.startFailed(NSError(domain: "QEMU", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "QEMU process terminated unexpectedly"]))
            }
            #endif

            // Try to connect to SSH port
            // For macOS Virtualization.framework, SSH is on the NAT IP:22
            // For Linux QEMU with TAP, SSH is also on the VPN IP:22
            let sshHost = vm.vmIP
            if await checkPortOpenOnHost(host: sshHost, port: vm.sshPort) {
                logger.info("VM SSH is ready", metadata: [
                    "vm_id": "\(vmId)",
                    "elapsed": "\(Int(Date().timeIntervalSince(startTime)))s"
                ])
                return true
            }

            // Wait before next check
            try await Task.sleep(for: .seconds(2))
        }

        logger.warning("VM SSH not ready after timeout", metadata: [
            "vm_id": "\(vmId)",
            "timeout": "\(timeoutSeconds)s"
        ])
        return false
    }

    /// Check if a TCP port is open on localhost using a simple blocking connect with timeout
    private func checkPortOpen(port: UInt16) async -> Bool {
        return await checkPortOpenOnHost(host: "127.0.0.1", port: port)
    }

    /// Check if a TCP port is open on a specific host using a simple blocking connect with timeout
    private func checkPortOpenOnHost(host: String, port: UInt16) async -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)

        guard status == 0, let addrInfo = result else {
            return false
        }
        defer { freeaddrinfo(result) }

        let sock = socket(addrInfo.pointee.ai_family, addrInfo.pointee.ai_socktype, addrInfo.pointee.ai_protocol)
        guard sock >= 0 else {
            return false
        }
        defer { close(sock) }

        // Set socket timeout
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = connect(sock, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)
        return connectResult == 0
    }

    // MARK: - Private Helpers

    /// Generate a WireGuard keypair (private + public key)
    /// Returns (privateKey, publicKey) as base64-encoded strings
    private func generateWireGuardKeypair() throws -> (privateKey: String, publicKey: String) {
        // Generate random 32-byte private key
        let privateKeyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let privateKeyData = Data(privateKeyBytes)
        let privateKey = privateKeyData.base64EncodedString()

        // Derive public key using Curve25519
        let curve25519Private = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        let publicKey = curve25519Private.publicKey.rawRepresentation.base64EncodedString()

        return (privateKey, publicKey)
    }

    private func generateVMNATIP() -> String {
        // Use 192.168.64.0/24 for NAT (macOS convention, also works for libvirt)
        // Gateway is at 192.168.64.1, VMs get addresses starting at .2
        let offset = activeVMs.count + 2
        return "192.168.64.\(offset)"
    }

    private func allocatePort() -> UInt16 {
        basePort + UInt16(activeVMs.count)
    }
}

// MARK: - Errors

public enum VMError: Error, CustomStringConvertible {
    case kernelNotFound
    case initrdNotFound
    case diskImageNotFound
    case cloudInitNotFound
    case insufficientResources
    case vmNotFound(UUID)
    case startFailed(Error)
    case stopFailed(Error)
    case platformNotSupported
    case qemuNotFound
    case kvmNotAvailable
    case overlayCreationFailed(String)
    case isoToolNotFound
    case tapCreationFailed(String)

    public var description: String {
        switch self {
        case .kernelNotFound:
            return "Linux kernel not found. Install to ~/Library/Application Support/Omerta/vmlinuz"
        case .initrdNotFound:
            return "Initial ramdisk not found. Install to ~/Library/Application Support/Omerta/initrd.img"
        case .diskImageNotFound:
            #if os(Linux) && arch(arm64)
            return "Ubuntu cloud image not found. Download to ~/.omerta/images/ubuntu-22.04-server-cloudimg-arm64.img"
            #elseif os(Linux)
            return "Ubuntu cloud image not found. Download to ~/.omerta/images/ubuntu-22.04-server-cloudimg-amd64.img"
            #elseif arch(arm64)
            return "Ubuntu raw disk image not found. Convert QCOW2 to raw: qemu-img convert -f qcow2 -O raw <input>.img ~/.omerta/images/ubuntu-22.04-server-cloudimg-arm64.raw"
            #else
            return "Ubuntu raw disk image not found. Convert QCOW2 to raw: qemu-img convert -f qcow2 -O raw <input>.img ~/.omerta/images/ubuntu-22.04-server-cloudimg-amd64.raw"
            #endif
        case .cloudInitNotFound:
            return "Cloud-init seed not found. Create ~/Library/Application Support/Omerta/seed.iso"
        case .insufficientResources:
            return "Insufficient resources to start VM"
        case .vmNotFound(let vmId):
            return "VM not found: \(vmId)"
        case .startFailed(let error):
            return "Failed to start VM: \(error.localizedDescription)"
        case .stopFailed(let error):
            return "Failed to stop VM: \(error.localizedDescription)"
        case .platformNotSupported:
            return "VM functionality not yet supported on this platform. Use --dry-run mode."
        case .qemuNotFound:
            return "QEMU not found. Install with: sudo apt install qemu-system-x86 qemu-utils"
        case .kvmNotAvailable:
            return "KVM not available. Ensure /dev/kvm exists and user has permission: sudo usermod -aG kvm $USER"
        case .overlayCreationFailed(let reason):
            return "Failed to create VM overlay disk: \(reason)"
        case .isoToolNotFound:
            return "ISO creation tool not found. Install with: sudo apt install genisoimage"
        case .tapCreationFailed(let reason):
            return "Failed to create TAP interface: \(reason)"
        }
    }
}
