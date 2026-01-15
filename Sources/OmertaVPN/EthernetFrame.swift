// EthernetFrame.swift
// Ethernet frame parsing and building for VM network filtering

import Foundation

// MARK: - EtherType

/// Ethernet frame type identifier
public enum EtherType: Equatable, Hashable, Sendable {
    case ipv4       // 0x0800
    case arp        // 0x0806
    case ipv6       // 0x86DD
    case other(UInt16)

    public var rawValue: UInt16 {
        switch self {
        case .ipv4: return 0x0800
        case .arp: return 0x0806
        case .ipv6: return 0x86DD
        case .other(let value): return value
        }
    }

    public init(rawValue: UInt16) {
        switch rawValue {
        case 0x0800: self = .ipv4
        case 0x0806: self = .arp
        case 0x86DD: self = .ipv6
        default: self = .other(rawValue)
        }
    }
}

// MARK: - EthernetFrame

/// Parsed ethernet frame
///
/// Frame format:
/// ```
/// [6 bytes] Destination MAC
/// [6 bytes] Source MAC
/// [2 bytes] EtherType
/// [N bytes] Payload
/// ```
///
/// Minimum frame size: 14 bytes (header only, no payload)
public struct EthernetFrame: Equatable, Sendable {

    /// Ethernet header size in bytes
    public static let headerSize = 14

    /// Broadcast MAC address (FF:FF:FF:FF:FF:FF)
    public static let broadcastMAC = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

    /// Destination MAC address (6 bytes)
    public let destinationMAC: Data

    /// Source MAC address (6 bytes)
    public let sourceMAC: Data

    /// Frame type (IPv4, ARP, IPv6, etc.)
    public let etherType: EtherType

    /// Frame payload (IP packet, ARP packet, etc.)
    public let payload: Data

    /// Check if this frame is addressed to broadcast
    public var isBroadcast: Bool {
        destinationMAC == Self.broadcastMAC
    }

    // MARK: - Initialization

    /// Create a new ethernet frame
    public init(
        destinationMAC: Data,
        sourceMAC: Data,
        etherType: EtherType,
        payload: Data
    ) {
        precondition(destinationMAC.count == 6, "Destination MAC must be 6 bytes")
        precondition(sourceMAC.count == 6, "Source MAC must be 6 bytes")

        self.destinationMAC = destinationMAC
        self.sourceMAC = sourceMAC
        self.etherType = etherType
        self.payload = payload
    }

    /// Parse an ethernet frame from raw bytes
    /// Returns nil if data is too short or malformed
    public init?(_ data: Data) {
        // Need at least 14 bytes for the header
        guard data.count >= Self.headerSize else {
            return nil
        }

        // Extract destination MAC (bytes 0-5)
        self.destinationMAC = data[0..<6]

        // Extract source MAC (bytes 6-11)
        self.sourceMAC = data[6..<12]

        // Extract etherType (bytes 12-13, big-endian)
        let etherTypeValue = UInt16(data[12]) << 8 | UInt16(data[13])
        self.etherType = EtherType(rawValue: etherTypeValue)

        // Extract payload (bytes 14+)
        if data.count > Self.headerSize {
            self.payload = data[Self.headerSize...]
        } else {
            self.payload = Data()
        }
    }

    // MARK: - Serialization

    /// Serialize the frame to bytes
    public func toData() -> Data {
        var frame = Data(capacity: Self.headerSize + payload.count)
        frame.append(destinationMAC)
        frame.append(sourceMAC)
        frame.append(UInt8(etherType.rawValue >> 8))
        frame.append(UInt8(etherType.rawValue & 0xFF))
        frame.append(payload)
        return frame
    }
}

// MARK: - Data Slicing Helper

private extension Data {
    subscript(range: Range<Int>) -> Data {
        return self.subdata(in: range)
    }

    subscript(range: PartialRangeFrom<Int>) -> Data {
        return self.subdata(in: range.lowerBound..<self.count)
    }
}
