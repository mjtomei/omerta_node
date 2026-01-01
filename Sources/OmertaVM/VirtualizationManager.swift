import Foundation
import Virtualization
import OmertaCore
import Logging

/// Actor managing VM lifecycle using macOS Virtualization.framework
public actor VirtualizationManager {
    private let logger = Logger(label: "com.omerta.vm")
    private var activeVMs: [UUID: VMInstance] = [:]
    private let resourceAllocator: ResourceAllocator
    private let networkIsolation: NetworkIsolation
    private let rogueDetector: RogueConnectionDetector

    public init(
        resourceAllocator: ResourceAllocator = ResourceAllocator(),
        networkIsolation: NetworkIsolation = NetworkIsolation(),
        rogueDetector: RogueConnectionDetector = RogueConnectionDetector()
    ) {
        self.resourceAllocator = resourceAllocator
        self.networkIsolation = networkIsolation
        self.rogueDetector = rogueDetector
    }
    
    /// Execute a compute job in an ephemeral VM
    public func executeJob(_ job: ComputeJob) async throws -> ExecutionResult {
        logger.info("Starting job execution", metadata: ["job_id": "\(job.id)"])
        let startTime = Date()
        
        // 1. Validate resource availability
        guard await resourceAllocator.canAllocate(job.requirements) else {
            logger.error("Insufficient resources for job", metadata: ["job_id": "\(job.id)"])
            throw VMError.insufficientResources
        }
        
        // 2. Allocate resources
        try await resourceAllocator.allocate(job.requirements)
        
        defer {
            // Always release resources when done
            Task {
                await resourceAllocator.release(job.requirements)
            }
        }
        
        // 3. Prepare workload initramfs
        let initramfsURL = try await prepareWorkloadInitramfs(for: job)

        // 4. Configure VPN routing in initramfs
        let vpnInitramfsURL = try await networkIsolation.configureVPNRouting(
            initramfsPath: initramfsURL,
            vpnConfig: job.vpnConfig,
            jobId: job.id
        )

        // 5. Create VM configuration with VPN-routed network
        let config = try await createVMConfiguration(for: job, initramfsURL: vpnInitramfsURL)

        // 6. Start VM and capture output
        let vmInstance = try await startVM(config: config, jobId: job.id)
        activeVMs[job.id] = vmInstance

        // 7. Start rogue connection monitoring (automatic security)
        let rogueDetectionState = RogueDetectionState()
        try await rogueDetector.startMonitoring(
            jobId: job.id,
            vpnConfig: job.vpnConfig
        ) { [rogueDetectionState] event in
            self.logger.error("ROGUE CONNECTION DETECTED - Terminating VM immediately!", metadata: [
                "job_id": "\(event.jobId)",
                "destination": "\(event.connection.destinationIP):\(event.connection.destinationPort)"
            ])
            rogueDetectionState.detected = true
        }

        // 8. Wait for VM to complete and capture output
        let result = try await waitForCompletion(
            vmInstance,
            job: job,
            startTime: startTime,
            rogueDetectionState: rogueDetectionState
        )
        
        // 9. Cleanup
        await rogueDetector.stopMonitoring(jobId: job.id)
        await destroyVM(vmInstance)
        activeVMs.removeValue(forKey: job.id)

        // Cleanup temp initramfs files
        try? FileManager.default.removeItem(at: initramfsURL)
        try? FileManager.default.removeItem(at: vpnInitramfsURL)
        
        logger.info("Job execution completed", metadata: [
            "job_id": "\(job.id)", 
            "exit_code": "\(result.exitCode)",
            "duration_ms": "\(result.metrics.executionTimeMs)"
        ])
        
        return result
    }
    
    /// Prepare initramfs with workload script injected
    private func prepareWorkloadInitramfs(for job: ComputeJob) async throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-\(job.id.uuidString)")
        
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        
        // Extract script content based on workload type
        let scriptContent: String
        switch job.workload {
        case .script(let script):
            scriptContent = script.scriptContent
        case .binary:
            throw VMError.unsupportedWorkloadType("Binary workloads not yet implemented")
        }
        
        // Create workload script
        let workloadScript = """
        #!/bin/sh
        # Workload script for job \(job.id)
        
        \(scriptContent)
        """
        
        let workloadPath = tmpDir.appendingPathComponent("workload.sh")
        try workloadScript.write(to: workloadPath, atomically: true, encoding: .utf8)
        
        // Create minimal init that executes the workload
        let initScript = """
        #!/bin/sh
        set -e
        
        # Mount pseudo-filesystems
        mount -t proc none /proc 2>/dev/null || true
        mount -t sysfs none /sys 2>/dev/null || true
        mount -t devtmpfs none /dev 2>/dev/null || true
        
        echo "=== OMERTA VM STARTED ==="
        
        # Execute workload
        if [ -f /workload.sh ]; then
            chmod +x /workload.sh
            echo "=== WORKLOAD OUTPUT START ==="
            /workload.sh
            EXIT_CODE=\0
            echo "=== WORKLOAD OUTPUT END ==="
            echo "OMERTA_EXIT_CODE:\"
        else
            echo "ERROR: No workload found"
            EXIT_CODE=1
        fi
        
        # Shutdown
        echo "=== OMERTA VM SHUTTING DOWN ==="
        sync
        poweroff -f
        """
        
        let initPath = tmpDir.appendingPathComponent("init")
        try initScript.write(to: initPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: initPath.path)
        
        // Create initramfs with cpio
        let initramfsURL = tmpDir.appendingPathComponent("initramfs.gz")
        let createInitramfs = """
        cd \(tmpDir.path) &&         find init workload.sh | cpio -o -H newc 2>/dev/null | gzip > \(initramfsURL.path)
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", createInitramfs]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw VMError.initramfsCreationFailed
        }
        
        return initramfsURL
    }
    
    /// Create VM configuration for a job
    private func createVMConfiguration(
        for job: ComputeJob,
        initramfsURL: URL
    ) async throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        
        // CPU configuration
        let availableCPUs = ProcessInfo.processInfo.processorCount
        let requestedCPUs = Int(job.requirements.cpuCores)
        config.cpuCount = min(requestedCPUs, max(1, availableCPUs - 2))
        
        // Memory configuration (in bytes)
        let memoryBytes = job.requirements.memoryMB * 1024 * 1024
        config.memorySize = UInt64(memoryBytes)
        
        // Bootloader - Linux kernel with initramfs
        let kernelURL = try await getLinuxKernelURL()
        let bootloader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootloader.initialRamdiskURL = initramfsURL
        bootloader.commandLine = "console=hvc0" // Use console for output
        config.bootLoader = bootloader
        
        // Storage - ephemeral disk (minimal for now)
        config.storageDevices = [try createEphemeralDisk()]
        
        // Network - isolated NAT
        config.networkDevices = [createIsolatedNetworkDevice()]
        
        // Entropy device for randomness
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        
        // Validate configuration
        try config.validate()
        
        return config
    }
    
    /// Create ephemeral storage device
    private func createEphemeralDisk() throws -> VZVirtioBlockDeviceConfiguration {
        let diskURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("img")
        
        // Create 1GB sparse disk image
        let diskSize: Int64 = 1024 * 1024 * 1024
        FileManager.default.createFile(atPath: diskURL.path, contents: nil)
        
        let fileHandle = try FileHandle(forWritingTo: diskURL)
        try fileHandle.truncate(atOffset: UInt64(diskSize))
        try fileHandle.close()
        
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false
        )
        
        return VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
    }
    
    /// Create isolated network device
    private func createIsolatedNetworkDevice() -> VZVirtioNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        return networkDevice
    }
    
    /// Get Linux kernel URL
    private func getLinuxKernelURL() async throws -> URL {
        let kernelPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omerta")
            .appendingPathComponent("kernel")
            .appendingPathComponent("vmlinuz")
        
        guard FileManager.default.fileExists(atPath: kernelPath.path) else {
            throw VMError.kernelNotFound
        }
        
        return kernelPath
    }
    
    /// Start a VM instance
    private func startVM(config: VZVirtualMachineConfiguration, jobId: UUID) async throws -> VMInstance {
        let vm = VZVirtualMachine(configuration: config)
        
        // Create pipe for console output capture
        let outputPipe = Pipe()
        
        let instance = VMInstance(
            id: jobId,
            vm: vm,
            startedAt: Date(),
            consoleOutput: outputPipe
        )
        
        // Start the VM
        try await vm.start()
        
        logger.info("VM started", metadata: ["job_id": "\(jobId)"])
        
        return instance
    }
    
    /// Wait for VM to complete and capture output
    private func waitForCompletion(
        _ vmInstance: VMInstance,
        job: ComputeJob,
        startTime: Date,
        rogueDetectionState: RogueDetectionState
    ) async throws -> ExecutionResult {
        
        // Read console output asynchronously
        var consoleOutput = Data()
        let outputHandle = vmInstance.consoleOutput.fileHandleForReading
        
        // Wait for VM to stop (with timeout)
        let timeout = TimeInterval(job.requirements.maxRuntimeSeconds)
        let deadline = Date().addingTimeInterval(timeout)
        
        while vmInstance.vm.state == .running {
            // Check for rogue connections
            if rogueDetectionState.detected {
                logger.error("Terminating VM due to rogue connection", metadata: ["job_id": "\(job.id)"])
                try await vmInstance.vm.stop()
                throw VMError.rogueConnectionDetected
            }

            if Date() > deadline {
                logger.warning("Job timeout", metadata: ["job_id": "\(job.id)"])
                try await vmInstance.vm.stop()
                throw VMError.executionTimeout
            }

            // Read available output
            if let data = try? outputHandle.availableData, !data.isEmpty {
                consoleOutput.append(data)
            }

            try await Task.sleep(for: .milliseconds(100))
        }
        
        // Read any remaining output
        if let data = try? outputHandle.availableData {
            consoleOutput.append(data)
        }
        
        let endTime = Date()
        let executionTimeMs = UInt64((endTime.timeIntervalSince(startTime)) * 1000)

        // Parse output
        let outputString = String(data: consoleOutput, encoding: .utf8) ?? ""

        // Verify VPN was set up correctly
        if !outputString.contains("=== VPN ROUTING ACTIVE ===") {
            logger.error("VPN routing was not activated", metadata: ["job_id": "\(job.id)"])
            throw VMError.vpnSetupFailed
        }

        let (stdout, stderr, exitCode) = parseConsoleOutput(outputString)
        
        let metrics = ExecutionMetrics(
            executionTimeMs: executionTimeMs,
            cpuTimeMs: executionTimeMs, // Approximate for now
            memoryPeakMB: job.requirements.memoryMB,
            networkEgressBytes: 0,
            networkIngressBytes: 0
        )
        
        return ExecutionResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            metrics: metrics
        )
    }
    
    /// Parse console output to extract stdout, stderr, and exit code
    private func parseConsoleOutput(_ output: String) -> (Data, Data, Int32) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        
        var workloadOutput: [String] = []
        var inWorkloadSection = false
        var exitCode: Int32 = -1
        
        for line in lines {
            let lineStr = String(line)
            
            if lineStr.contains("=== WORKLOAD OUTPUT START ===") {
                inWorkloadSection = true
                continue
            }
            
            if lineStr.contains("=== WORKLOAD OUTPUT END ===") {
                inWorkloadSection = false
                continue
            }
            
            if lineStr.hasPrefix("OMERTA_EXIT_CODE:") {
                if let code = Int32(lineStr.dropFirst("OMERTA_EXIT_CODE:".count).trimmingCharacters(in: .whitespaces)) {
                    exitCode = code
                }
                continue
            }
            
            if inWorkloadSection {
                workloadOutput.append(lineStr)
            }
        }
        
        let stdout = workloadOutput.joined(separator: "\n").data(using: .utf8) ?? Data()
        let stderr = Data() // For now, stderr is captured in stdout
        
        return (stdout, stderr, exitCode)
    }
    
    /// Destroy VM and cleanup resources
    private func destroyVM(_ vmInstance: VMInstance) async {
        logger.info("Destroying VM", metadata: ["job_id": "\(vmInstance.id)"])
        
        if vmInstance.vm.state == .running {
            do {
                try await vmInstance.vm.stop()
            } catch {
                logger.warning("Error stopping VM", metadata: ["error": "\(error)"])
            }
        }
        
        logger.info("VM destroyed", metadata: ["job_id": "\(vmInstance.id)"])
    }
    
    /// Get current active VMs
    public func getActiveVMs() -> [UUID] {
        Array(activeVMs.keys)
    }
}

/// VM instance wrapper
struct VMInstance {
    let id: UUID
    let vm: VZVirtualMachine
    let startedAt: Date
    let consoleOutput: Pipe
}

/// VM errors
public enum VMError: Error {
    case insufficientResources
    case kernelNotFound
    case initramfsCreationFailed
    case configurationInvalid
    case executionFailed(String)
    case executionTimeout
    case unsupportedWorkloadType(String)
    case rogueConnectionDetected
    case vpnSetupFailed
}

/// Thread-safe state holder for rogue connection detection
final class RogueDetectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _detected = false

    var detected: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _detected
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _detected = newValue
        }
    }
}
