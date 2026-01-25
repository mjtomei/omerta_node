// VMNetworkNamespace.swift - Linux network namespace packet source
//
// Captures packets from a TAP interface in a Linux network namespace.
// The VM's network traffic goes through the TAP interface, which we read/write directly.

#if os(Linux)
import Foundation
import Glibc
import Logging

/// Linux TAP-based packet source for VM traffic capture
public actor TAPPacketSource: PacketSource {
    /// Stream of inbound packets from the VM
    public nonisolated var inbound: AsyncStream<Data> {
        inboundStream
    }

    private let tapName: String
    private let vmId: UUID
    private let mtu: Int
    private let logger: Logger

    private var tapFd: Int32 = -1
    private var isRunning: Bool = false
    private var readTask: Task<Void, Never>?

    private let inboundStream: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation

    /// Initialize a TAP packet source
    /// - Parameters:
    ///   - tapName: Name of the TAP interface (e.g., "tap-vm-1")
    ///   - vmId: The VM identifier
    ///   - mtu: Maximum transmission unit (default: 1500)
    public init(tapName: String, vmId: UUID, mtu: Int = 1500) {
        self.tapName = tapName
        self.vmId = vmId
        self.mtu = mtu
        self.logger = Logger(label: "io.omerta.provider.tap")

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.inboundStream = stream
        self.inboundContinuation = continuation
    }

    /// Start capturing packets from the TAP interface
    public func start() async throws {
        guard !isRunning else {
            throw PacketCaptureError.alreadyStarted
        }

        logger.info("Opening TAP interface", metadata: ["tap": "\(tapName)"])

        // Open the TAP device
        tapFd = try openTAP(name: tapName)

        // Start reading packets
        readTask = Task.detached { [weak self] in
            await self?.readLoop()
        }

        isRunning = true
        logger.info("TAP interface opened", metadata: ["tap": "\(tapName)", "fd": "\(tapFd)"])
    }

    /// Stop capturing packets
    public func stop() async {
        guard isRunning else { return }

        logger.info("Closing TAP interface", metadata: ["tap": "\(tapName)"])

        readTask?.cancel()
        readTask = nil

        if tapFd >= 0 {
            close(tapFd)
            tapFd = -1
        }

        inboundContinuation.finish()
        isRunning = false
    }

    /// Write a packet to the VM
    public func write(_ packet: Data) async throws {
        guard isRunning, tapFd >= 0 else {
            throw PacketCaptureError.notStarted
        }

        let result = packet.withUnsafeBytes { buffer in
            Glibc.write(tapFd, buffer.baseAddress, buffer.count)
        }

        if result < 0 {
            let error = String(cString: strerror(errno))
            throw PacketCaptureError.writeFailed(error)
        }
    }

    // MARK: - Private

    private func readLoop() async {
        var buffer = [UInt8](repeating: 0, count: mtu + 18) // MTU + ethernet header + some slack

        while !Task.isCancelled && tapFd >= 0 {
            let bytesRead = Glibc.read(tapFd, &buffer, buffer.count)

            if bytesRead > 0 {
                let packet = Data(buffer[0..<bytesRead])
                inboundContinuation.yield(packet)
            } else if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                let error = String(cString: strerror(errno))
                logger.warning("TAP read error", metadata: ["error": "\(error)"])
                break
            } else {
                // EOF
                break
            }
        }
    }

    private func openTAP(name: String) throws -> Int32 {
        // Open /dev/net/tun
        let tunFd = open("/dev/net/tun", O_RDWR)
        guard tunFd >= 0 else {
            let error = String(cString: strerror(errno))
            throw PacketCaptureError.writeFailed("Failed to open /dev/net/tun: \(error)")
        }

        // Set up the interface request
        var ifr = ifreq()

        // Set interface name
        withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { nameBuffer in
            let bytes = name.utf8
            for (i, byte) in bytes.enumerated() where i < nameBuffer.count {
                nameBuffer[i] = byte
            }
            // Null terminate if space
            if bytes.count < nameBuffer.count {
                nameBuffer[bytes.count] = 0
            }
        }

        // IFF_TAP: Layer 2 (ethernet frames)
        // IFF_NO_PI: No packet information header
        let IFF_TAP: Int16 = 0x0002
        let IFF_NO_PI: Int16 = 0x1000
        ifr.ifr_ifru.ifru_flags = IFF_TAP | IFF_NO_PI

        // Attach to the interface
        let result = withUnsafeMutablePointer(to: &ifr) { ifrPtr in
            ioctl(tunFd, UInt(TUNSETIFF), ifrPtr)
        }

        if result < 0 {
            close(tunFd)
            let error = String(cString: strerror(errno))
            throw PacketCaptureError.writeFailed("Failed to attach to TAP \(name): \(error)")
        }

        // Set non-blocking mode
        let flags = fcntl(tunFd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(tunFd, F_SETFL, flags | O_NONBLOCK)
        }

        return tunFd
    }
}

// MARK: - Linux ioctl constants

private let TUNSETIFF: Int32 = 0x400454ca

#endif
