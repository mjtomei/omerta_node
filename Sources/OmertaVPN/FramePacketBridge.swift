// FramePacketBridge.swift
// Converts between ethernet frames and IP packets for VM network filtering

import Foundation

// MARK: - FramePacketBridge

/// Bridge between ethernet frames (from VM) and IP packets (for filtering/forwarding)
///
/// Handles:
/// - Extracting IPv4 packets from ethernet frames
/// - Tracking VM's MAC and IP addresses
/// - Wrapping response packets in ethernet frames for delivery to VM
public struct FramePacketBridge: Sendable {

    /// Default MAC address for the virtual gateway
    public static let defaultGatewayMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0xFF])

    /// The gateway's MAC address (used as source in responses)
    public let gatewayMAC: Data

    /// The VM's MAC address (learned from outgoing frames)
    public private(set) var vmMAC: Data?

    /// The VM's IP address (learned from outgoing frames)
    public private(set) var vmIP: IPv4Address?

    // MARK: - Initialization

    /// Create a bridge with optional custom gateway MAC
    public init(gatewayMAC: Data = defaultGatewayMAC) {
        self.gatewayMAC = gatewayMAC
    }

    // MARK: - Frame Processing

    /// Process an outgoing ethernet frame from the VM
    /// - Parameter frame: The ethernet frame to process
    /// - Returns: The extracted IPv4 packet, or nil if not IPv4 or malformed
    public mutating func processFrame(_ frame: EthernetFrame) -> IPv4Packet? {
        // Only handle IPv4 frames
        guard frame.etherType == .ipv4 else {
            return nil
        }

        // Try to parse the IP packet
        guard let packet = IPv4Packet(frame.payload) else {
            return nil
        }

        // Learn VM's addresses from outgoing traffic
        vmMAC = frame.sourceMAC
        vmIP = packet.sourceAddress

        return packet
    }

    // MARK: - Response Wrapping

    /// Wrap a UDP response in an ethernet frame for delivery to VM
    /// - Parameters:
    ///   - udpPayload: The UDP payload data
    ///   - from: The source endpoint (consumer)
    ///   - vmPort: The destination port on the VM
    /// - Returns: An ethernet frame ready to send to VM, or nil if VM address unknown
    public func wrapResponse(
        udpPayload: Data,
        from source: Endpoint,
        vmPort: UInt16
    ) -> EthernetFrame? {
        // Need to know VM's addresses to build response
        guard let vmMAC = vmMAC, let vmIP = vmIP else {
            return nil
        }

        // Build UDP header
        let udpLength = UInt16(8 + udpPayload.count)
        var udp = Data(count: 8)
        udp[0] = UInt8(source.port >> 8)
        udp[1] = UInt8(source.port & 0xFF)
        udp[2] = UInt8(vmPort >> 8)
        udp[3] = UInt8(vmPort & 0xFF)
        udp[4] = UInt8(udpLength >> 8)
        udp[5] = UInt8(udpLength & 0xFF)
        udp[6] = 0x00  // Checksum (optional for UDP)
        udp[7] = 0x00
        udp.append(udpPayload)

        // Build IPv4 header (20 bytes, no options)
        let totalLength = UInt16(20 + udp.count)
        var ip = Data(count: 20)
        ip[0] = 0x45  // Version 4, IHL 5
        ip[1] = 0x00  // DSCP/ECN
        ip[2] = UInt8(totalLength >> 8)
        ip[3] = UInt8(totalLength & 0xFF)
        ip[4] = 0x00  // ID high
        ip[5] = 0x01  // ID low
        ip[6] = 0x00  // Flags/Fragment high
        ip[7] = 0x00  // Fragment low
        ip[8] = 64    // TTL
        ip[9] = 17    // Protocol: UDP
        ip[10] = 0x00 // Checksum (set to 0, not validated by most stacks)
        ip[11] = 0x00

        // Source IP (consumer)
        ip[12] = source.address.octets.0
        ip[13] = source.address.octets.1
        ip[14] = source.address.octets.2
        ip[15] = source.address.octets.3

        // Destination IP (VM)
        ip[16] = vmIP.octets.0
        ip[17] = vmIP.octets.1
        ip[18] = vmIP.octets.2
        ip[19] = vmIP.octets.3

        ip.append(udp)

        // Calculate IP checksum
        var checksum = calculateIPChecksum(ip)
        ip[10] = UInt8(checksum >> 8)
        ip[11] = UInt8(checksum & 0xFF)

        // Build ethernet frame
        return EthernetFrame(
            destinationMAC: vmMAC,
            sourceMAC: gatewayMAC,
            etherType: .ipv4,
            payload: ip
        )
    }

    // MARK: - Helpers

    /// Calculate IP header checksum
    private func calculateIPChecksum(_ header: Data) -> UInt16 {
        var sum: UInt32 = 0

        // Sum all 16-bit words (only the 20-byte header, not payload)
        let headerLength = min(header.count, 20)
        for i in stride(from: 0, to: headerLength, by: 2) {
            if i == 10 {
                // Skip checksum field
                continue
            }
            let word = UInt32(header[i]) << 8 | UInt32(header[i + 1])
            sum += word
        }

        // Fold 32-bit sum to 16 bits
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        // One's complement
        return ~UInt16(sum)
    }
}
