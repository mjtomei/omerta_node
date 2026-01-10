// FilteredNAT.swift
// Core network filtering NAT for VM isolation

import Foundation

// MARK: - FilterResult

/// Result of processing an outbound frame
public enum FilterResult: Sendable {
    /// Frame was forwarded to destination
    case forwarded
    /// Frame was dropped with reason
    case dropped(reason: String)
    /// An error occurred during processing
    case error(Error)
}

// MARK: - FilterStatistics

/// Statistics for filtering operations
public struct FilterStatistics: Sendable {
    public var framesProcessed: UInt64 = 0
    public var framesForwarded: UInt64 = 0
    public var framesDropped: UInt64 = 0
    public var bytesForwarded: UInt64 = 0
    public var inboundPackets: UInt64 = 0
    public var inboundDropped: UInt64 = 0
}

// MARK: - FilteredNAT

/// Userspace NAT with strict destination filtering for VM network isolation
///
/// This actor processes ethernet frames from a VM, extracts IPv4/UDP packets,
/// checks them against an allowlist, and forwards permitted traffic.
/// It also handles inbound traffic from allowed sources.
public actor FilteredNAT {

    /// The endpoint allowlist
    private let allowlist: EndpointAllowlist

    /// Bridge for frame/packet conversion
    private var bridge: FramePacketBridge

    /// Port mapping for responses (VM source port -> outbound request)
    private var portMapping: [UInt16: UInt16] = [:]

    /// Statistics
    public private(set) var statistics = FilterStatistics()

    // MARK: - Initialization

    /// Create a FilteredNAT with a single allowed consumer endpoint
    public init(consumerEndpoint: Endpoint) {
        self.allowlist = EndpointAllowlist([consumerEndpoint])
        self.bridge = FramePacketBridge()
    }

    /// Create a FilteredNAT with multiple allowed endpoints
    public init(allowedEndpoints: [Endpoint]) {
        self.allowlist = EndpointAllowlist(allowedEndpoints)
        self.bridge = FramePacketBridge()
    }

    /// Create a FilteredNAT with a custom allowlist
    public init(allowlist: EndpointAllowlist) {
        self.allowlist = allowlist
        self.bridge = FramePacketBridge()
    }

    // MARK: - Configuration

    /// Update the allowed endpoints
    public func setAllowedEndpoints(_ endpoints: [Endpoint]) async {
        await allowlist.setAllowed(endpoints)
    }

    /// Add an allowed endpoint
    public func addAllowedEndpoint(_ endpoint: Endpoint) async {
        await allowlist.add(endpoint)
    }

    // MARK: - Outbound Processing

    /// Process an outbound ethernet frame from the VM
    /// - Parameter frameData: Raw ethernet frame data
    /// - Returns: Result indicating if frame was forwarded, dropped, or errored
    public func processOutbound(_ frameData: Data) async -> FilterResult {
        statistics.framesProcessed += 1

        // Parse ethernet frame
        guard let frame = EthernetFrame(frameData) else {
            statistics.framesDropped += 1
            return .dropped(reason: "Failed to parse ethernet frame")
        }

        // Only handle IPv4
        guard frame.etherType == .ipv4 else {
            statistics.framesDropped += 1
            return .dropped(reason: "Non-IPv4 frame (etherType: \(frame.etherType))")
        }

        // Extract IPv4 packet and learn VM addresses
        guard let packet = bridge.processFrame(frame) else {
            statistics.framesDropped += 1
            return .dropped(reason: "Failed to parse IPv4 packet")
        }

        // Check destination against allowlist
        guard let destPort = packet.destinationPort else {
            statistics.framesDropped += 1
            return .dropped(reason: "No destination port (non-UDP/TCP)")
        }

        let isAllowed = await allowlist.isAllowed(
            address: packet.destinationAddress,
            port: destPort
        )

        guard isAllowed else {
            statistics.framesDropped += 1
            return .dropped(reason: "Destination not in allowlist: \(packet.destinationAddress):\(destPort)")
        }

        // Track port mapping for responses
        if let srcPort = packet.sourcePort {
            portMapping[srcPort] = srcPort
        }

        // In a real implementation, we'd forward via UDPForwarder here
        // For now, we just return success
        statistics.framesForwarded += 1
        if let payload = packet.udpPayload {
            statistics.bytesForwarded += UInt64(payload.count)
        }

        return .forwarded
    }

    // MARK: - Inbound Processing

    /// Process an inbound UDP packet from the network
    /// - Parameters:
    ///   - data: UDP payload data
    ///   - from: Source endpoint
    /// - Returns: Ethernet frame to send to VM, or nil if blocked/error
    public func processInbound(_ data: Data, from source: Endpoint) async -> Data? {
        statistics.inboundPackets += 1

        // Check if source is in allowlist
        let isAllowed = await allowlist.isAllowed(source)
        guard isAllowed else {
            statistics.inboundDropped += 1
            return nil
        }

        // Need VM address to build response
        guard bridge.vmIP != nil, bridge.vmMAC != nil else {
            statistics.inboundDropped += 1
            return nil
        }

        // Find the VM port to send to (use a default if not tracked)
        // In a real implementation, we'd track the original source port
        let vmPort: UInt16 = portMapping.values.first ?? 12345

        // Wrap response in ethernet frame
        guard let responseFrame = bridge.wrapResponse(
            udpPayload: data,
            from: source,
            vmPort: vmPort
        ) else {
            statistics.inboundDropped += 1
            return nil
        }

        return responseFrame.toData()
    }

    // MARK: - Queries

    /// Get current VM IP address (if known)
    public var vmIP: IPv4Address? {
        bridge.vmIP
    }

    /// Get current VM MAC address (if known)
    public var vmMAC: Data? {
        bridge.vmMAC
    }
}
