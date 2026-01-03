import Foundation
import Virtualization
import Logging
import OmertaCore

/// Simplified VM manager for VM infrastructure only (no job execution)
/// Starts VMs with SSH access, user controls everything after that
public actor SimpleVMManager {
    private let logger: Logger
    private var activeVMs: [UUID: RunningVM] = [:]
    private let basePort: UInt16 = 10000

    public struct RunningVM: Sendable {
        public let vmId: UUID
        public let vm: VZVirtualMachine
        public let sshPort: UInt16
        public let vmIP: String
        public let createdAt: Date
    }

    public init() {
        var logger = Logger(label: "com.omerta.vm.simple")
        logger.logLevel = .info
        self.logger = logger
    }

    // MARK: - VM Lifecycle

    /// Start a VM with specified resources
    /// Returns VM IP address within VPN network for SSH access
    public func startVM(
        vmId: UUID,
        requirements: ResourceRequirements,
        vpnConfig: VPNConfiguration
    ) async throws -> String {
        logger.info("Starting VM", metadata: [
            "vm_id": "\(vmId)",
            "cpu_cores": "\(requirements.cpuCores ?? 0)",
            "memory_mb": "\(requirements.memoryMB ?? 0)"
        ])

        // 1. Create VM configuration
        let config = try await createVMConfiguration(requirements: requirements)

        // 2. Create and start VM (must be on main queue)
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

        // 3. Generate VM IP (from VPN config client IP + offset)
        let vmIP = generateVMIP(vpnConfig: vpnConfig)

        // 4. Allocate SSH port
        let sshPort = allocatePort()

        // 5. Track running VM
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

    /// Stop and destroy a VM
    public func stopVM(vmId: UUID) async throws {
        guard let runningVM = activeVMs[vmId] else {
            logger.warning("VM not found", metadata: ["vm_id": "\(vmId)"])
            return
        }

        logger.info("Stopping VM", metadata: ["vm_id": "\(vmId)"])

        // Stop VM
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            runningVM.vm.stop { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

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

    private func createVMConfiguration(
        requirements: ResourceRequirements
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

        // 2. Cloud-init seed ISO
        if let seedURL = try? getCloudInitSeedURL() {
            let seedAttachment = try VZDiskImageStorageDeviceAttachment(
                url: seedURL,
                readOnly: true
            )
            let seedDisk = VZVirtioBlockDeviceConfiguration(attachment: seedAttachment)
            storageDevices.append(seedDisk)
        }

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

    private func getCloudInitSeedURL() throws -> URL {
        let paths = [
            "~/Library/Application Support/Omerta/seed.iso",
            "/usr/local/share/omerta/seed.iso",
            "/opt/omerta/seed.iso"
        ]

        for path in paths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        throw VMError.cloudInitNotFound
    }

    private func generateVMIP(vpnConfig: VPNConfiguration) -> String {
        // Extract base IP from VPN server IP and increment
        // e.g., "10.99.0.1" -> "10.99.0.2", "10.99.0.3", etc.
        let components = vpnConfig.vpnServerIP.split(separator: ".")
        guard components.count == 4 else {
            // Fallback
            return "10.99.0.\(activeVMs.count + 2)"
        }

        let octet1 = String(components[0])
        let octet2 = String(components[1])
        let octet3 = String(components[2])
        let offset = activeVMs.count + 2
        return "\(octet1).\(octet2).\(octet3).\(offset)"
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
        }
    }
}
