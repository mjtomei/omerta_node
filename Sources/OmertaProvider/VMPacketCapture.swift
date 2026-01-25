// VMPacketCapture.swift - Captures VM traffic and routes through TunnelSession
//
// Connects a VM's network interface to the mesh tunnel, forwarding packets
// bidirectionally between the VM and the tunnel session.

import Foundation
import OmertaTunnel
import Logging

/// Protocol for packet sources (abstracts Linux TAP vs macOS file handles)
public protocol PacketSource: Sendable {
    /// Stream of inbound packets from the VM
    var inbound: AsyncStream<Data> { get }

    /// Write a packet to the VM
    func write(_ packet: Data) async throws

    /// Start capturing packets
    func start() async throws

    /// Stop capturing packets
    func stop() async
}

/// Errors for packet capture operations
public enum PacketCaptureError: Error, Sendable {
    case notStarted
    case alreadyStarted
    case writeFailed(String)
    case sessionNotActive
    case tunnelError(String)
}

/// Captures VM traffic and routes it through a TunnelSession
public actor VMPacketCapture {
    /// The VM this capture is associated with
    public let vmId: UUID

    /// Whether the capture is currently running
    public private(set) var isRunning: Bool = false

    // Components
    private let packetSource: any PacketSource
    private let tunnelSession: TunnelSession
    private let logger: Logger

    // Tasks for packet forwarding
    private var outboundTask: Task<Void, Never>?
    private var inboundTask: Task<Void, Never>?

    // Stats
    private var packetsToTunnel: UInt64 = 0
    private var packetsFromTunnel: UInt64 = 0
    private var bytesToTunnel: UInt64 = 0
    private var bytesFromTunnel: UInt64 = 0

    /// Initialize packet capture for a VM
    /// - Parameters:
    ///   - vmId: The VM identifier
    ///   - packetSource: The source of packets from the VM (TAP, file handle, etc.)
    ///   - tunnelSession: The tunnel session to route packets through
    public init(vmId: UUID, packetSource: any PacketSource, tunnelSession: TunnelSession) {
        self.vmId = vmId
        self.packetSource = packetSource
        self.tunnelSession = tunnelSession
        self.logger = Logger(label: "io.omerta.provider.packetcapture")
    }

    /// Start capturing and forwarding packets
    public func start() async throws {
        guard !isRunning else {
            throw PacketCaptureError.alreadyStarted
        }

        logger.info("Starting packet capture", metadata: ["vmId": "\(vmId)"])

        // Start the packet source
        try await packetSource.start()

        // Start outbound forwarding (VM -> Tunnel)
        outboundTask = Task {
            await forwardOutbound()
        }

        // Start inbound forwarding (Tunnel -> VM)
        inboundTask = Task {
            await forwardInbound()
        }

        isRunning = true
        logger.info("Packet capture started", metadata: ["vmId": "\(vmId)"])
    }

    /// Stop capturing packets
    public func stop() async {
        guard isRunning else { return }

        logger.info("Stopping packet capture", metadata: ["vmId": "\(vmId)"])

        // Cancel forwarding tasks
        outboundTask?.cancel()
        inboundTask?.cancel()
        outboundTask = nil
        inboundTask = nil

        // Stop the packet source
        await packetSource.stop()

        isRunning = false

        logger.info("Packet capture stopped", metadata: [
            "vmId": "\(vmId)",
            "packetsToTunnel": "\(packetsToTunnel)",
            "packetsFromTunnel": "\(packetsFromTunnel)",
            "bytesToTunnel": "\(bytesToTunnel)",
            "bytesFromTunnel": "\(bytesFromTunnel)"
        ])
    }

    /// Get current capture statistics
    public func getStats() -> PacketCaptureStats {
        PacketCaptureStats(
            packetsToTunnel: packetsToTunnel,
            packetsFromTunnel: packetsFromTunnel,
            bytesToTunnel: bytesToTunnel,
            bytesFromTunnel: bytesFromTunnel
        )
    }

    // MARK: - Private

    /// Forward packets from VM to tunnel
    private func forwardOutbound() async {
        for await packet in packetSource.inbound {
            guard !Task.isCancelled else { break }

            do {
                try await tunnelSession.injectPacket(packet)
                packetsToTunnel += 1
                bytesToTunnel += UInt64(packet.count)
            } catch {
                logger.warning("Failed to inject packet to tunnel", metadata: [
                    "error": "\(error)",
                    "size": "\(packet.count)"
                ])
            }
        }
    }

    /// Forward packets from tunnel to VM
    private func forwardInbound() async {
        for await packet in await tunnelSession.returnPackets {
            guard !Task.isCancelled else { break }

            do {
                try await packetSource.write(packet)
                packetsFromTunnel += 1
                bytesFromTunnel += UInt64(packet.count)
            } catch {
                logger.warning("Failed to write packet to VM", metadata: [
                    "error": "\(error)",
                    "size": "\(packet.count)"
                ])
            }
        }
    }
}

/// Statistics for packet capture
public struct PacketCaptureStats: Sendable {
    public let packetsToTunnel: UInt64
    public let packetsFromTunnel: UInt64
    public let bytesToTunnel: UInt64
    public let bytesFromTunnel: UInt64

    public var totalPackets: UInt64 {
        packetsToTunnel + packetsFromTunnel
    }

    public var totalBytes: UInt64 {
        bytesToTunnel + bytesFromTunnel
    }
}
