import Foundation
import Logging
import OmertaCore

#if os(macOS)
import Virtualization
#endif

/// Simplified VM manager for VM infrastructure only (no job execution)
/// Starts VMs with SSH access, user controls everything after that
/// On Linux, only dry-run mode is currently supported (full VM support requires libvirt)
public actor SimpleVMManager {
    private let logger: Logger
    private var activeVMs: [UUID: RunningVM] = [:]
    private let basePort: UInt16 = 10000
    private let dryRun: Bool

    #if os(macOS)
    public struct RunningVM: Sendable {
        public let vmId: UUID
        public let vm: VZVirtualMachine?  // nil in dry-run mode
        public let sshPort: UInt16
        public let vmIP: String
        public let createdAt: Date
    }
    #else
    public struct RunningVM: Sendable {
        public let vmId: UUID
        public let sshPort: UInt16
        public let vmIP: String
        public let createdAt: Date
    }
    #endif

    public init(dryRun: Bool = false) {
        var logger = Logger(label: "com.omerta.vm.simple")
        logger.logLevel = .info
        self.logger = logger

        #if os(Linux)
        // On Linux, force dry-run mode until libvirt support is added
        self.dryRun = true
        if !dryRun {
            logger.warning("Linux VM support not yet implemented - forcing DRY RUN mode")
        }
        #else
        self.dryRun = dryRun
        #endif

        if self.dryRun {
            logger.info("SimpleVMManager initialized in DRY RUN mode - no actual VMs will be created")
        }
    }

    // MARK: - VM Lifecycle

    /// Start a VM with specified resources
    /// Returns VM's NAT IP address (e.g., 192.168.64.x)
    public func startVM(
        vmId: UUID,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshUser: String = "omerta"
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

            // Generate simulated VM NAT IP
            let vmNATIP = generateVMNATIP()
            let sshPort = allocatePort()

            // Track "running" VM
            #if os(macOS)
            let runningVM = RunningVM(
                vmId: vmId,
                vm: nil,
                sshPort: sshPort,
                vmIP: vmNATIP,
                createdAt: Date()
            )
            #else
            let runningVM = RunningVM(
                vmId: vmId,
                sshPort: sshPort,
                vmIP: vmNATIP,
                createdAt: Date()
            )
            #endif
            activeVMs[vmId] = runningVM

            logger.info("DRY RUN: VM simulated successfully", metadata: [
                "vm_id": "\(vmId)",
                "vm_nat_ip": "\(vmNATIP)",
                "ssh_port": "\(sshPort)"
            ])

            return vmNATIP
        }

        #if os(macOS)
        // macOS: Use Virtualization.framework
        return try await startVMMacOS(
            vmId: vmId,
            requirements: requirements,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser
        )
        #else
        // Linux: Not yet implemented
        throw VMError.platformNotSupported
        #endif
    }

    #if os(macOS)
    private func startVMMacOS(
        vmId: UUID,
        requirements: ResourceRequirements,
        sshPublicKey: String,
        sshUser: String
    ) async throws -> String {
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

        // 4. Generate VM NAT IP
        let vmNATIP = generateVMNATIP()

        // 5. Allocate SSH port
        let sshPort = allocatePort()

        // 6. Track running VM
        let runningVM = RunningVM(
            vmId: vmId,
            vm: vm,
            sshPort: sshPort,
            vmIP: vmNATIP,
            createdAt: Date()
        )
        activeVMs[vmId] = runningVM

        logger.info("VM started successfully", metadata: [
            "vm_id": "\(vmId)",
            "vm_nat_ip": "\(vmNATIP)",
            "ssh_port": "\(sshPort)"
        ])

        return vmNATIP
    }
    #endif

    /// Stop and destroy a VM
    public func stopVM(vmId: UUID) async throws {
        guard let runningVM = activeVMs[vmId] else {
            logger.warning("VM not found", metadata: ["vm_id": "\(vmId)"])
            return
        }

        logger.info("Stopping VM", metadata: ["vm_id": "\(vmId)", "dry_run": "\(dryRun)"])

        #if os(macOS)
        // In dry-run mode or if VM is nil, just remove from tracking
        if dryRun || runningVM.vm == nil {
            logger.info("DRY RUN: Simulating VM stop")
            activeVMs.removeValue(forKey: vmId)
            logger.info("DRY RUN: VM removed from tracking", metadata: ["vm_id": "\(vmId)"])
            return
        }

        // Stop VM
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            runningVM.vm!.stop { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        #else
        // Linux: Just remove from tracking (dry-run only)
        logger.info("DRY RUN: Simulating VM stop")
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

    // MARK: - Private Helpers

    #if os(macOS)
    /// Generate a dynamic cloud-init ISO for this VM
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

    private func getOrCreateEFIVariableStore() throws -> VZEFIVariableStore {
        let efiPath = NSString(string: "~/Library/Application Support/Omerta/efi-vars.bin").expandingTildeInPath
        let efiURL = URL(fileURLWithPath: efiPath)

        if FileManager.default.fileExists(atPath: efiPath) {
            return try VZEFIVariableStore(url: efiURL)
        } else {
            // Create new EFI variable store
            return try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
        }
    }

    private func getUbuntuDiskURL() throws -> URL {
        let paths = [
            "~/Library/Application Support/Omerta/ubuntu-22.04.raw",
            "/usr/local/share/omerta/ubuntu-22.04.raw",
            "/opt/omerta/ubuntu-22.04.raw"
        ]

        for path in paths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
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

    public var description: String {
        switch self {
        case .kernelNotFound:
            return "Linux kernel not found. Install to ~/Library/Application Support/Omerta/vmlinuz"
        case .initrdNotFound:
            return "Initial ramdisk not found. Install to ~/Library/Application Support/Omerta/initrd.img"
        case .diskImageNotFound:
            return "Ubuntu disk image not found. Install to ~/Library/Application Support/Omerta/ubuntu-22.04.raw"
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
        }
    }
}
