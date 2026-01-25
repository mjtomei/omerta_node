// VMNetworkFileHandle.swift - macOS file handle packet source
//
// Captures packets from file handles connected to a VM via Virtualization.framework.
// The VM's network traffic goes through VZFileHandleNetworkDeviceAttachment,
// which we read/write via file handles.

#if os(macOS)
import Foundation
import Logging

/// macOS file handle-based packet source for VM traffic capture
public actor FileHandlePacketSource: PacketSource {
    /// Stream of inbound packets from the VM
    public nonisolated var inbound: AsyncStream<Data> {
        inboundStream
    }

    private let vmId: UUID
    private let logger: Logger

    // File handles for communication with VM
    // hostRead: we read packets the VM sends
    // hostWrite: we write packets to send to the VM
    private let hostRead: FileHandle
    private let hostWrite: FileHandle

    private var isRunning: Bool = false
    private var readTask: Task<Void, Never>?

    private let inboundStream: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation

    /// Initialize a file handle packet source
    /// - Parameters:
    ///   - hostRead: File handle to read packets from (VM -> host)
    ///   - hostWrite: File handle to write packets to (host -> VM)
    ///   - vmId: The VM identifier
    public init(hostRead: FileHandle, hostWrite: FileHandle, vmId: UUID) {
        self.hostRead = hostRead
        self.hostWrite = hostWrite
        self.vmId = vmId
        self.logger = Logger(label: "io.omerta.provider.filehandle")

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.inboundStream = stream
        self.inboundContinuation = continuation
    }

    /// Start capturing packets
    public func start() async throws {
        guard !isRunning else {
            throw PacketCaptureError.alreadyStarted
        }

        logger.info("Starting file handle packet capture", metadata: ["vmId": "\(vmId)"])

        // Start reading packets in a detached task
        readTask = Task.detached { [weak self] in
            await self?.readLoop()
        }

        isRunning = true
        logger.info("File handle packet capture started", metadata: ["vmId": "\(vmId)"])
    }

    /// Stop capturing packets
    public func stop() async {
        guard isRunning else { return }

        logger.info("Stopping file handle packet capture", metadata: ["vmId": "\(vmId)"])

        readTask?.cancel()
        readTask = nil

        inboundContinuation.finish()
        isRunning = false
    }

    /// Write a packet to the VM
    public func write(_ packet: Data) async throws {
        guard isRunning else {
            throw PacketCaptureError.notStarted
        }

        // Unix datagram sockets: each write is a complete message, no length prefix needed
        let fd = hostWrite.fileDescriptor
        let result = packet.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress, packet.count)
        }

        if result < 0 {
            let err = errno
            throw PacketCaptureError.writeFailed("Socket write failed: errno \(err)")
        }

        logger.debug("Wrote packet to VM", metadata: [
            "vmId": "\(vmId)",
            "size": "\(packet.count)"
        ])
    }

    // MARK: - Private

    private func readLoop() async {
        // Buffer for reading datagrams - max Ethernet frame is ~1518 bytes, jumbo is ~9000
        let maxPacketSize = 10000
        var buffer = [UInt8](repeating: 0, count: maxPacketSize)
        let fd = hostRead.fileDescriptor

        logger.info("Starting packet read loop", metadata: ["vmId": "\(vmId)", "fd": "\(fd)"])

        while !Task.isCancelled {
            // Use raw socket read for datagram sockets (FileHandle.read may not work correctly)
            let bytesRead = Darwin.read(fd, &buffer, maxPacketSize)

            if bytesRead > 0 {
                let packetData = Data(buffer.prefix(bytesRead))
                logger.debug("Read packet from VM", metadata: [
                    "vmId": "\(vmId)",
                    "size": "\(bytesRead)"
                ])
                inboundContinuation.yield(packetData)
            } else if bytesRead == 0 {
                // EOF
                logger.info("Socket EOF", metadata: ["vmId": "\(vmId)"])
                break
            } else {
                // Error
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Non-blocking and no data available, sleep briefly
                    try? await Task.sleep(for: .milliseconds(1))
                    continue
                }
                if !Task.isCancelled {
                    logger.warning("Socket read error", metadata: [
                        "vmId": "\(vmId)",
                        "errno": "\(err)"
                    ])
                }
                break
            }
        }

        logger.info("Packet read loop ended", metadata: ["vmId": "\(vmId)"])
    }
}

/// Creates file handle pairs for VM network attachment
/// Returns (vmRead, vmWrite, hostRead, hostWrite)
/// - vmRead/vmWrite: Pass to VZFileHandleNetworkDeviceAttachment
/// - hostRead/hostWrite: Use with FileHandlePacketSource
public func createVMNetworkPipes() throws -> (
    vmRead: FileHandle,
    vmWrite: FileHandle,
    hostRead: FileHandle,
    hostWrite: FileHandle
) {
    // Create two pipes:
    // Pipe 1: VM writes -> Host reads
    // Pipe 2: Host writes -> VM reads

    var vmToHostPipe: [Int32] = [0, 0]
    var hostToVMPipe: [Int32] = [0, 0]

    guard pipe(&vmToHostPipe) == 0 else {
        throw PacketCaptureError.writeFailed("Failed to create vmToHost pipe")
    }

    guard pipe(&hostToVMPipe) == 0 else {
        close(vmToHostPipe[0])
        close(vmToHostPipe[1])
        throw PacketCaptureError.writeFailed("Failed to create hostToVM pipe")
    }

    return (
        vmRead: FileHandle(fileDescriptor: hostToVMPipe[0], closeOnDealloc: true),
        vmWrite: FileHandle(fileDescriptor: vmToHostPipe[1], closeOnDealloc: true),
        hostRead: FileHandle(fileDescriptor: vmToHostPipe[0], closeOnDealloc: true),
        hostWrite: FileHandle(fileDescriptor: hostToVMPipe[1], closeOnDealloc: true)
    )
}

#endif
