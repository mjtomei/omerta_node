// IPv4Packet.swift
// IPv4 packet parsing for VM network filtering

import Foundation

// MARK: - IPv4Address

/// IPv4 address representation
public struct IPv4Address: Equatable, Hashable, Sendable, CustomStringConvertible {

    /// The four octets of the address
    public let octets: (UInt8, UInt8, UInt8, UInt8)

    /// Create from four octets
    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        self.octets = (a, b, c, d)
    }

    /// Create from 4 bytes of data
    /// Returns nil if data is less than 4 bytes
    public init?(_ data: Data) {
        guard data.count >= 4 else { return nil }
        self.octets = (data[data.startIndex],
                       data[data.startIndex + 1],
                       data[data.startIndex + 2],
                       data[data.startIndex + 3])
    }

    /// Convert to 4-byte Data
    public func toData() -> Data {
        return Data([octets.0, octets.1, octets.2, octets.3])
    }

    public var description: String {
        "\(octets.0).\(octets.1).\(octets.2).\(octets.3)"
    }

    // Manual Hashable conformance for tuple
    public func hash(into hasher: inout Hasher) {
        hasher.combine(octets.0)
        hasher.combine(octets.1)
        hasher.combine(octets.2)
        hasher.combine(octets.3)
    }

    public static func == (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.octets == rhs.octets
    }
}

// MARK: - IPProtocol

/// IP protocol numbers
public enum IPProtocol: Equatable, Hashable, Sendable {
    case icmp       // 1
    case tcp        // 6
    case udp        // 17
    case other(UInt8)

    public var rawValue: UInt8 {
        switch self {
        case .icmp: return 1
        case .tcp: return 6
        case .udp: return 17
        case .other(let value): return value
        }
    }

    public init(rawValue: UInt8) {
        switch rawValue {
        case 1: self = .icmp
        case 6: self = .tcp
        case 17: self = .udp
        default: self = .other(rawValue)
        }
    }

    /// Whether this protocol uses port numbers (TCP/UDP)
    public var hasPorts: Bool {
        switch self {
        case .tcp, .udp: return true
        case .icmp, .other: return false
        }
    }
}

// MARK: - IPv4Packet

/// Parsed IPv4 packet
///
/// IPv4 Header format (20-60 bytes):
/// ```
/// 0       4       8               16              24              32
/// +-------+-------+---------------+-------------------------------+
/// |Version|  IHL  |    DSCP/ECN   |         Total Length          |
/// +-------+-------+---------------+-------------------------------+
/// |         Identification        |Flags|     Fragment Offset     |
/// +---------------+---------------+-------------------------------+
/// |      TTL      |   Protocol    |        Header Checksum        |
/// +---------------+---------------+-------------------------------+
/// |                       Source Address                          |
/// +---------------------------------------------------------------+
/// |                    Destination Address                        |
/// +---------------------------------------------------------------+
/// |                    Options (if IHL > 5)                       |
/// +---------------------------------------------------------------+
/// ```
public struct IPv4Packet: Equatable, Sendable {

    /// Minimum IPv4 header size (no options)
    public static let minHeaderSize = 20

    /// IP version (should be 4)
    public let version: UInt8

    /// Header length in bytes (IHL * 4)
    public let headerLength: Int

    /// Total packet length
    public let totalLength: UInt16

    /// IP protocol (TCP, UDP, ICMP, etc.)
    public let `protocol`: IPProtocol

    /// Source IP address
    public let sourceAddress: IPv4Address

    /// Destination IP address
    public let destinationAddress: IPv4Address

    /// Payload after IP header (transport layer data)
    public let payload: Data

    // MARK: - Port Extraction

    /// Source port (TCP/UDP only, nil for other protocols)
    public var sourcePort: UInt16? {
        guard `protocol`.hasPorts, payload.count >= 2 else { return nil }
        return UInt16(payload[payload.startIndex]) << 8 |
               UInt16(payload[payload.startIndex + 1])
    }

    /// Destination port (TCP/UDP only, nil for other protocols)
    public var destinationPort: UInt16? {
        guard `protocol`.hasPorts, payload.count >= 4 else { return nil }
        return UInt16(payload[payload.startIndex + 2]) << 8 |
               UInt16(payload[payload.startIndex + 3])
    }

    /// UDP payload (data after 8-byte UDP header)
    /// Returns nil for non-UDP packets or if payload is too short
    public var udpPayload: Data? {
        guard `protocol` == .udp, payload.count >= 8 else { return nil }
        return payload.suffix(from: payload.startIndex + 8)
    }

    // MARK: - Initialization

    /// Parse an IPv4 packet from raw bytes
    /// Returns nil if data is too short, not IPv4, or malformed
    public init?(_ data: Data) {
        // Need at least 20 bytes for minimum header
        guard data.count >= Self.minHeaderSize else { return nil }

        // Extract version and IHL from first byte
        let versionIHL = data[data.startIndex]
        let version = versionIHL >> 4
        let ihl = versionIHL & 0x0F

        // Must be IPv4
        guard version == 4 else { return nil }

        // IHL must be at least 5 (20 bytes)
        guard ihl >= 5 else { return nil }

        let headerLen = Int(ihl) * 4

        // Data must be at least as long as header
        guard data.count >= headerLen else { return nil }

        self.version = version
        self.headerLength = headerLen

        // Total length (bytes 2-3)
        self.totalLength = UInt16(data[data.startIndex + 2]) << 8 |
                          UInt16(data[data.startIndex + 3])

        // Protocol (byte 9)
        self.protocol = IPProtocol(rawValue: data[data.startIndex + 9])

        // Source address (bytes 12-15)
        guard let srcAddr = IPv4Address(data.subdata(in: (data.startIndex + 12)..<(data.startIndex + 16))) else {
            return nil
        }
        self.sourceAddress = srcAddr

        // Destination address (bytes 16-19)
        guard let dstAddr = IPv4Address(data.subdata(in: (data.startIndex + 16)..<(data.startIndex + 20))) else {
            return nil
        }
        self.destinationAddress = dstAddr

        // Payload is everything after the header
        if data.count > headerLen {
            self.payload = data.suffix(from: data.startIndex + headerLen)
        } else {
            self.payload = Data()
        }
    }
}
