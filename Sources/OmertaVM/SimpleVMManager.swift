import Foundation
import Logging
import OmertaCore

#if os(Linux)
import Glibc
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
        public let qemuPid: Int32?  // QEMU process ID, nil in dry-run mode
        public let sshPort: UInt16
        public let vmIP: String
        public let overlayDiskPath: String?
        public let seedISOPath: String?
        public let createdAt: Date
    }

    public init(dryRun: Bool = false) {
        var logger = Logger(label: "com.omerta.vm.simple")
        logger.logLevel = .info
        self.logger = logger

        // Check if QEMU is available
        let qemuAvailable = Self.checkQEMUAvailable()
        let accelAvailable = Self.checkAccelerationAvailable()

        if !qemuAvailable {
            #if os(macOS)
            logger.warning("QEMU not found - forcing DRY RUN mode. Install: brew install qemu")
            #else
            logger.warning("QEMU not found - forcing DRY RUN mode. Install: sudo apt install qemu-system-x86")
            #endif
            self.dryRun = true
        } else if !accelAvailable {
            #if os(macOS)
            logger.warning("HVF not available - VMs will use software emulation (slow).")
            #else
            logger.warning("KVM not available - VMs will use software emulation (slow). Check /dev/kvm for hardware acceleration.")
            #endif
            self.dryRun = dryRun  // Allow running without acceleration (TCG mode)
        } else {
            self.dryRun = dryRun
        }

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
        self.baseImagePath = "\(homeDir)/.omerta/images/ubuntu-22.04-server-cloudimg-\(archSuffix).img"
        self.vmDiskDir = "\(homeDir)/.omerta/vm-disks"

        // Create VM disk directory if it doesn't exist
        try? FileManager.default.createDirectory(
            atPath: vmDiskDir,
            withIntermediateDirectories: true
        )

        if self.dryRun {
            logger.info("SimpleVMManager initialized in DRY RUN mode - no actual VMs will be created")
        } else {
            logger.info("SimpleVMManager initialized with QEMU/KVM support")
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

    /// Start a VM with specified resources
    /// - Parameters:
    ///   - vmId: Unique identifier for this VM
    ///   - requirements: CPU/memory requirements
    ///   - sshPublicKey: Consumer's SSH public key for access
    ///   - sshUser: Username for SSH access
    ///   - vpnIP: The VPN IP to assign to the VM (e.g., "10.166.104.2")
    ///   - vpnGateway: The VPN gateway IP (e.g., "10.166.104.254")
    /// - Returns: The VM's IP address (same as vpnIP when using TAP networking)
    public func startVM(
        vmId: UUID,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshUser: String = "omerta",
        vpnIP: String? = nil,
        vpnGateway: String? = nil
    ) async throws -> String {
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
            let runningVM = RunningVM(
                vmId: vmId,
                qemuPid: nil,
                sshPort: sshPort,
                vmIP: vmIP,
                overlayDiskPath: nil,
                seedISOPath: nil,
                createdAt: Date()
            )
            activeVMs[vmId] = runningVM

            logger.info("DRY RUN: VM simulated successfully", metadata: [
                "vm_id": "\(vmId)",
                "vm_ip": "\(vmIP)",
                "ssh_port": "\(sshPort)"
            ])

            return vmIP
        }

        // Use QEMU on all platforms
        return try await startVMQEMU(
            vmId: vmId,
            requirements: requirements,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser,
            vpnIP: vpnIP,
            vpnGateway: vpnGateway
        )
    }

    private func startVMQEMU(
        vmId: UUID,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshUser: String,
        vpnIP: String?,
        vpnGateway: String?
    ) async throws -> String {
        // 1. Verify base image exists
        guard FileManager.default.fileExists(atPath: baseImagePath) else {
            throw VMError.diskImageNotFound
        }

        // 2. Create overlay disk for this VM (copy-on-write)
        let overlayPath = "\(vmDiskDir)/\(vmId.uuidString).qcow2"
        try await createOverlayDisk(basePath: baseImagePath, overlayPath: overlayPath)
        logger.info("Created overlay disk", metadata: ["path": "\(overlayPath)"])

        // 3. Determine if we're using TAP networking (when vpnIP is provided)
        // TAP networking is only supported on Linux; macOS uses SLIRP
        #if os(Linux)
        if let vpnIPValue = vpnIP, let vpnGatewayValue = vpnGateway {
            // TAP networking: VM gets VPN IP directly (Linux only)
            let vmIP = vpnIPValue
            let sshPort: UInt16 = 22  // SSH directly on VPN IP

            // Create TAP interface
            let tapInterface = "tap-\(vmId.uuidString.prefix(8))"
            try await createTapInterface(name: tapInterface)
            vmTapInterfaces[vmId] = tapInterface

            logger.info("Created TAP interface for VM", metadata: [
                "vm_id": "\(vmId)",
                "tap": "\(tapInterface)",
                "vpn_ip": "\(vmIP)"
            ])

            // Generate cloud-init ISO with VPN network config
            let seedISOPath = "\(vmDiskDir)/\(vmId.uuidString)-seed.iso"
            try CloudInitGenerator.createSeedISO(
                at: seedISOPath,
                sshPublicKey: sshPublicKey,
                sshUser: sshUser,
                instanceId: vmId,
                networkConfig: CloudInitGenerator.NetworkConfig(
                    ipAddress: vpnIPValue,
                    gateway: vpnGatewayValue,
                    prefixLength: 24
                )
            )
            logger.info("Created cloud-init ISO with TAP network config", metadata: ["path": "\(seedISOPath)"])

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
                "vpn_ip": "\(vmIP)"
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

            return vmIP
        }
        #else
        if vpnIP != nil {
            logger.warning("TAP networking requested but not supported on macOS VMs - using NAT")
        }
        #endif

        // SLIRP user-mode networking (used on macOS always, and on Linux as fallback)
        let vmIP = generateVMNATIP()
        let sshPort = allocatePort()

        // Generate cloud-init ISO with DHCP (default)
        let seedISOPath = "\(vmDiskDir)/\(vmId.uuidString)-seed.iso"
        try CloudInitGenerator.createSeedISO(
            at: seedISOPath,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser,
            instanceId: vmId
        )
        logger.info("Created cloud-init ISO", metadata: ["path": "\(seedISOPath)"])

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

        return vmIP
    }

    #if os(Linux)
    /// Create a TAP interface for VM networking (Linux only)
    private func createTapInterface(name: String) async throws {
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

        // Bring interface up
        let upProcess = Process()
        upProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        upProcess.arguments = ["ip", "link", "set", name, "up"]

        try upProcess.run()
        upProcess.waitUntilExit()

        // Enable proxy ARP on the TAP interface so it can reach the gateway
        let proxyArpProcess = Process()
        proxyArpProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proxyArpProcess.arguments = ["sysctl", "-w", "net.ipv4.conf.\(name).proxy_arp=1"]

        try? proxyArpProcess.run()
        proxyArpProcess.waitUntilExit()

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

    // Virtualization.framework support disabled - using QEMU instead
    // To re-enable, define ENABLE_VIRTUALIZATION_FRAMEWORK
    #if ENABLE_VIRTUALIZATION_FRAMEWORK
    private func startVMMacOS(
        vmId: UUID,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshUser: String,
        vpnIP: String?,
        vpnGateway: String?
    ) async throws -> String {
        // Note: macOS Virtualization.framework uses its own NAT networking
        // TAP networking is not supported on macOS VMs in the same way as Linux
        // For macOS provider, we would need a different approach (e.g., bridged networking)
        if vpnIP != nil {
            logger.warning("TAP networking requested but not supported on macOS VMs - using NAT")
        }

        // 1. Generate dynamic cloud-init ISO with consumer's SSH key
        let seedISOPath = try await generateCloudInitISO(
            vmId: vmId,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser
        )

        logger.info("Cloud-init ISO created", metadata: ["path": "\(seedISOPath)"])

        // 2. Create VM configuration
        let config = try await createVMConfiguration(
            requirements: requirements,
            seedISOPath: seedISOPath
        )

        // 3. Create and start VM (must be on main queue)
        let vm = try await MainActor.run {
            let vm = VZVirtualMachine(configuration: config)
            return vm
        }

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

        // 4. Use VPN IP if provided (for tracking), otherwise generate NAT IP
        let vmIP = vpnIP ?? generateVMNATIP()

        // 5. Allocate SSH port
        let sshPort = allocatePort()

        // 6. Track running VM
        let runningVM = RunningVM(
            vmId: vmId,
            vm: vm,
            sshPort: sshPort,
            vmIP: vmIP,
            createdAt: Date()
        )
        activeVMs[vmId] = runningVM

        logger.info("VM started successfully", metadata: [
            "vm_id": "\(vmId)",
            "vm_ip": "\(vmIP)",
            "ssh_port": "\(sshPort)"
        ])

        return vmIP
    }
    #endif

    /// Stop and destroy a VM
    public func stopVM(vmId: UUID) async throws {
        guard let runningVM = activeVMs[vmId] else {
            logger.warning("VM not found", metadata: ["vm_id": "\(vmId)"])
            return
        }

        logger.info("Stopping VM", metadata: ["vm_id": "\(vmId)", "dry_run": "\(dryRun)"])

        // Stop QEMU process and clean up
        if dryRun || runningVM.qemuPid == nil {
            logger.info("DRY RUN: Simulating VM stop")
        } else if let pid = runningVM.qemuPid {
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

        #if os(Linux)
        // Clean up TAP interface if present (Linux only)
        if let tapInterface = vmTapInterfaces[vmId] {
            await deleteTapInterface(name: tapInterface)
            vmTapInterfaces.removeValue(forKey: vmId)
            logger.info("Cleaned up TAP interface", metadata: ["tap": "\(tapInterface)"])
        }
        #endif

        // Clean up overlay disk and seed ISO
        if let overlayPath = runningVM.overlayDiskPath {
            try? FileManager.default.removeItem(atPath: overlayPath)
            logger.info("Removed overlay disk", metadata: ["path": "\(overlayPath)"])
        }
        if let seedPath = runningVM.seedISOPath {
            try? FileManager.default.removeItem(atPath: seedPath)
            logger.info("Removed seed ISO", metadata: ["path": "\(seedPath)"])
        }

        // Clean up log files and pid file
        let pidFilePath = "\(vmDiskDir)/\(vmId.uuidString).pid"
        try? FileManager.default.removeItem(atPath: pidFilePath)
        try? FileManager.default.removeItem(atPath: "\(vmDiskDir)/\(vmId.uuidString)-stdout.log")
        try? FileManager.default.removeItem(atPath: "\(vmDiskDir)/\(vmId.uuidString)-stderr.log")

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

    /// Check if VM's QEMU process is still running
    public func isQEMURunning(vmId: UUID) -> Bool {
        guard let vm = activeVMs[vmId], let pid = vm.qemuPid else {
            return false
        }
        // kill with signal 0 checks if process exists
        return kill(pid, 0) == 0
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
            "ssh_port": "\(vm.sshPort)",
            "timeout": "\(timeoutSeconds)s"
        ])

        while Date().timeIntervalSince(startTime) < Double(timeoutSeconds) {
            // Check if QEMU is still running
            if let pid = vm.qemuPid, kill(pid, 0) != 0 {
                throw VMError.startFailed(NSError(domain: "QEMU", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "QEMU process terminated unexpectedly"]))
            }

            // Try to connect to SSH port
            if await checkPortOpen(port: vm.sshPort) {
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
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo("127.0.0.1", String(port), &hints, &result)

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

    #if ENABLE_VIRTUALIZATION_FRAMEWORK
    /// Generate a dynamic cloud-init ISO for this VM (Virtualization.framework)
    private func generateCloudInitISO(
        vmId: UUID,
        sshPublicKey: String,
        sshUser: String
    ) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let isoPath = tempDir.appendingPathComponent("omerta-seed-\(vmId.uuidString).iso").path

        try CloudInitGenerator.createSeedISO(
            at: isoPath,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser,
            instanceId: vmId
        )

        return isoPath
    }

    private func createVMConfiguration(
        requirements: ResourceRequirements,
        seedISOPath: String
    ) async throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        // CPU configuration (minimum 2 for Ubuntu)
        let cpuCores = max(2, Int(requirements.cpuCores ?? 2))
        config.cpuCount = cpuCores

        // Memory configuration (minimum 1GB for Ubuntu)
        let memoryMB = max(1024, requirements.memoryMB ?? 2048)
        let memoryBytes = memoryMB * 1024 * 1024
        config.memorySize = memoryBytes

        // Platform configuration for ARM64
        let platform = VZGenericPlatformConfiguration()
        config.platform = platform

        // EFI boot loader for Ubuntu cloud image
        let efiVariableStore = try getOrCreateEFIVariableStore()
        let bootloader = VZEFIBootLoader()
        bootloader.variableStore = efiVariableStore
        config.bootLoader = bootloader

        // Entropy device (required for Linux)
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon device
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Network device with NAT
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // Storage devices
        var storageDevices: [VZStorageDeviceConfiguration] = []

        // 1. Main Ubuntu disk image
        let ubuntuDiskURL = try getUbuntuDiskURL()
        let mainDiskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: ubuntuDiskURL,
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

        // Serial port for console output
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        config.serialPorts = [serialPort]

        // Keyboard and pointer for GUI (optional but recommended)
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Validate configuration
        try config.validate()

        return config
    }

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

    private func getOrCreateEFIVariableStore() throws -> VZEFIVariableStore {
        let homeDir = getRealUserHomeDir()
        let efiPath = "\(homeDir)/Library/Application Support/Omerta/efi-vars.bin"
        let efiURL = URL(fileURLWithPath: efiPath)

        if FileManager.default.fileExists(atPath: efiPath) {
            return try VZEFIVariableStore(url: efiURL)
        } else {
            // Create new EFI variable store
            return try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
        }
    }

    private func getUbuntuDiskURL() throws -> URL {
        let homeDir = getRealUserHomeDir()
        let paths = [
            "\(homeDir)/Library/Application Support/Omerta/ubuntu-22.04.raw",
            "/usr/local/share/omerta/ubuntu-22.04.raw",
            "/opt/omerta/ubuntu-22.04.raw"
        ]

        for path in paths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        throw VMError.diskImageNotFound
    }
    #endif

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
            #else
            return "Ubuntu disk image not found. Install to ~/Library/Application Support/Omerta/ubuntu-22.04.raw"
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
