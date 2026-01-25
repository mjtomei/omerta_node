// VMNetworkFileHandle.swift - macOS file handle packet source
//
// Captures packets from file handles connected to a VM via Virtualization.framework.
// The VM's network traffic goes through VZFileHandleNetworkDeviceAttachment,
// which we read/write via file handles.
//
// This acts as a virtual network gateway:
// - Responds to ARP requests from the VM for the gateway IP
// - Forwards IP packets to/from the mesh tunnel

#if os(macOS)
import Foundation
import Logging

// Ethernet frame constants
private let ETH_ALEN = 6  // MAC address length
private let ETH_HLEN = 14 // Ethernet header length
private let ETH_P_IP: UInt16 = 0x0800   // IPv4 EtherType
private let ETH_P_ARP: UInt16 = 0x0806  // ARP EtherType
private let ETH_P_IPV6: UInt16 = 0x86DD // IPv6 EtherType

// ARP operation codes
private let ARP_REQUEST: UInt16 = 1
private let ARP_REPLY: UInt16 = 2

/// macOS file handle-based packet source for VM traffic capture
/// Acts as a virtual gateway, responding to ARPs and forwarding IP traffic
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

    // Virtual gateway MAC address (locally administered)
    // 02:00:00:00:00:01 - the 02 prefix indicates locally administered
    private let gatewayMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]

    // Track VM's MAC address (learned from first packet)
    private var vmMAC: [UInt8]?

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
    /// The packet should be an IP packet (L3); we wrap it in an Ethernet frame (L2)
    public func write(_ packet: Data) async throws {
        guard isRunning else {
            throw PacketCaptureError.notStarted
        }

        guard packet.count > 0 else { return }

        // Determine if IPv4 or IPv6 based on version nibble
        let version = (packet[0] >> 4) & 0x0F
        let etherType: UInt16
        switch version {
        case 4:
            etherType = ETH_P_IP
        case 6:
            etherType = ETH_P_IPV6
        default:
            logger.warning("Unknown IP version", metadata: [
                "vmId": "\(vmId)",
                "version": "\(version)"
            ])
            return
        }

        // Build Ethernet frame
        var frame = [UInt8](repeating: 0, count: ETH_HLEN + packet.count)

        // Destination MAC (VM's MAC, or broadcast if not known)
        if let mac = vmMAC {
            for i in 0..<6 { frame[i] = mac[i] }
        } else {
            // Broadcast until we learn the VM's MAC
            for i in 0..<6 { frame[i] = 0xFF }
        }

        // Source MAC (our gateway MAC)
        for i in 0..<6 { frame[6 + i] = gatewayMAC[i] }

        // EtherType
        frame[12] = UInt8(etherType >> 8)
        frame[13] = UInt8(etherType & 0xFF)

        // Copy IP packet as payload
        for (i, byte) in packet.enumerated() {
            frame[ETH_HLEN + i] = byte
        }

        // Send the frame
        let fd = hostWrite.fileDescriptor
        let result = frame.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress, frame.count)
        }

        if result < 0 {
            let err = errno
            throw PacketCaptureError.writeFailed("Socket write failed: errno \(err)")
        }

        logger.debug("Wrote packet to VM", metadata: [
            "vmId": "\(vmId)",
            "size": "\(packet.count)",
            "frameSize": "\(frame.count)"
        ])
    }

    // MARK: - Private

    private func readLoop() async {
        // Buffer for reading datagrams - max Ethernet frame is ~1518 bytes, jumbo is ~9000
        let maxPacketSize = 10000
        var buffer = [UInt8](repeating: 0, count: maxPacketSize)
        let fd = hostRead.fileDescriptor

        logger.info("Starting packet read loop", metadata: ["vmId": "\(vmId)", "fd": "\(fd)"])

        var packetCount = 0
        var lastLogTime = Date()

        while !Task.isCancelled {
            // Use raw socket read for datagram sockets (FileHandle.read may not work correctly)
            let bytesRead = Darwin.read(fd, &buffer, maxPacketSize)

            if bytesRead > 0 {
                packetCount += 1
                let packetData = Data(buffer.prefix(bytesRead))

                // Log periodically (every 10 packets or every 5 seconds)
                let now = Date()
                if packetCount <= 5 || packetCount % 10 == 0 || now.timeIntervalSince(lastLogTime) > 5 {
                    logger.info("Read packet from VM", metadata: [
                        "vmId": "\(vmId)",
                        "size": "\(bytesRead)",
                        "count": "\(packetCount)"
                    ])
                    lastLogTime = now
                }

                // Process the Ethernet frame
                await processEthernetFrame(packetData)
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

        logger.info("Packet read loop ended", metadata: ["vmId": "\(vmId)", "totalPackets": "\(packetCount)"])
    }

    /// Process an Ethernet frame from the VM
    /// - Responds to ARP requests
    /// - Forwards IP packets to the tunnel
    private func processEthernetFrame(_ frame: Data) async {
        guard frame.count >= ETH_HLEN else {
            logger.warning("Frame too short", metadata: ["size": "\(frame.count)"])
            return
        }

        // Extract source MAC (bytes 6-11)
        let srcMAC = Array(frame[6..<12])
        if vmMAC == nil {
            vmMAC = srcMAC
            logger.info("Learned VM MAC address", metadata: [
                "vmId": "\(vmId)",
                "mac": "\(srcMAC.map { String(format: "%02x", $0) }.joined(separator: ":"))"
            ])
        }

        // Extract EtherType (bytes 12-13, big-endian)
        let etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])

        switch etherType {
        case ETH_P_ARP:
            await handleARP(frame)
        case ETH_P_IP, ETH_P_IPV6:
            // Forward IP packets to the tunnel (strip Ethernet header for L3 tunnel)
            let ipPacket = frame.dropFirst(ETH_HLEN)
            inboundContinuation.yield(Data(ipPacket))
        default:
            logger.debug("Unknown EtherType", metadata: [
                "vmId": "\(vmId)",
                "etherType": "0x\(String(format: "%04x", etherType))"
            ])
        }
    }

    /// Handle an ARP packet from the VM
    /// Responds to ARP requests with our virtual gateway MAC
    private func handleARP(_ frame: Data) async {
        // ARP packet structure (after Ethernet header):
        // 0-1: Hardware type (1 for Ethernet)
        // 2-3: Protocol type (0x0800 for IPv4)
        // 4: Hardware address length (6 for Ethernet)
        // 5: Protocol address length (4 for IPv4)
        // 6-7: Operation (1=request, 2=reply)
        // 8-13: Sender hardware address (MAC)
        // 14-17: Sender protocol address (IP)
        // 18-23: Target hardware address (MAC)
        // 24-27: Target protocol address (IP)

        guard frame.count >= ETH_HLEN + 28 else {
            logger.warning("ARP packet too short", metadata: ["size": "\(frame.count)"])
            return
        }

        let arpStart = ETH_HLEN
        let operation = UInt16(frame[arpStart + 6]) << 8 | UInt16(frame[arpStart + 7])

        if operation == ARP_REQUEST {
            // Extract sender and target addresses
            let senderMAC = Array(frame[(arpStart + 8)..<(arpStart + 14)])
            let senderIP = Array(frame[(arpStart + 14)..<(arpStart + 18)])
            let targetIP = Array(frame[(arpStart + 24)..<(arpStart + 28)])

            logger.info("ARP request", metadata: [
                "vmId": "\(vmId)",
                "senderIP": "\(senderIP[0]).\(senderIP[1]).\(senderIP[2]).\(senderIP[3])",
                "targetIP": "\(targetIP[0]).\(targetIP[1]).\(targetIP[2]).\(targetIP[3])"
            ])

            // Respond to all ARP requests with our gateway MAC
            // This makes the VM think we're the gateway for any IP it queries
            await sendARPReply(
                targetMAC: senderMAC,
                targetIP: senderIP,
                senderIP: targetIP
            )
        }
    }

    /// Send an ARP reply to the VM
    private func sendARPReply(targetMAC: [UInt8], targetIP: [UInt8], senderIP: [UInt8]) async {
        var reply = [UInt8](repeating: 0, count: ETH_HLEN + 28)

        // Ethernet header
        // Destination MAC (VM's MAC)
        for i in 0..<6 { reply[i] = targetMAC[i] }
        // Source MAC (our gateway MAC)
        for i in 0..<6 { reply[6 + i] = gatewayMAC[i] }
        // EtherType: ARP
        reply[12] = UInt8(ETH_P_ARP >> 8)
        reply[13] = UInt8(ETH_P_ARP & 0xFF)

        // ARP header
        let arpStart = ETH_HLEN
        // Hardware type: Ethernet (1)
        reply[arpStart] = 0x00
        reply[arpStart + 1] = 0x01
        // Protocol type: IPv4 (0x0800)
        reply[arpStart + 2] = 0x08
        reply[arpStart + 3] = 0x00
        // Hardware address length: 6
        reply[arpStart + 4] = 0x06
        // Protocol address length: 4
        reply[arpStart + 5] = 0x04
        // Operation: ARP reply (2)
        reply[arpStart + 6] = 0x00
        reply[arpStart + 7] = 0x02
        // Sender hardware address (our gateway MAC)
        for i in 0..<6 { reply[arpStart + 8 + i] = gatewayMAC[i] }
        // Sender protocol address (the IP being queried)
        for i in 0..<4 { reply[arpStart + 14 + i] = senderIP[i] }
        // Target hardware address (VM's MAC)
        for i in 0..<6 { reply[arpStart + 18 + i] = targetMAC[i] }
        // Target protocol address (VM's IP)
        for i in 0..<4 { reply[arpStart + 24 + i] = targetIP[i] }

        // Send the ARP reply
        let fd = hostWrite.fileDescriptor
        let result = reply.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress, reply.count)
        }

        if result > 0 {
            logger.info("Sent ARP reply", metadata: [
                "vmId": "\(vmId)",
                "forIP": "\(senderIP[0]).\(senderIP[1]).\(senderIP[2]).\(senderIP[3])"
            ])
        } else {
            logger.warning("Failed to send ARP reply", metadata: [
                "vmId": "\(vmId)",
                "errno": "\(errno)"
            ])
        }
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
