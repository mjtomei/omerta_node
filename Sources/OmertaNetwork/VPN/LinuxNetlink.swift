// LinuxNetlink.swift
// Native Linux netlink implementation for network interface management
// Avoids dependency on external tools like `ip` command

#if os(Linux)
import Foundation
import Glibc

// MARK: - Netlink Socket Address (not always exposed in Glibc module)

/// Netlink socket address structure (struct sockaddr_nl)
/// Defined here as it may not be exposed in all Swift/Glibc configurations
private struct sockaddr_nl {
    var nl_family: sa_family_t = 0   // AF_NETLINK
    var nl_pad: UInt16 = 0           // zero padding
    var nl_pid: UInt32 = 0           // port ID
    var nl_groups: UInt32 = 0        // multicast groups mask

    init() {}
}

// MARK: - Netlink Constants

/// Netlink protocol families
enum NetlinkProtocol: Int32 {
    case route = 0      // NETLINK_ROUTE - routing/device hook
    case generic = 16   // NETLINK_GENERIC - generic netlink
}

/// RTNetlink message types
enum RTMType: UInt16 {
    case newLink = 16   // RTM_NEWLINK
    case delLink = 17   // RTM_DELLINK
    case getLink = 18   // RTM_GETLINK
    case newAddr = 20   // RTM_NEWADDR
    case delAddr = 21   // RTM_DELADDR
}

/// Netlink message flags
struct NLMFlags: OptionSet {
    let rawValue: UInt16

    static let request = NLMFlags(rawValue: 0x01)   // NLM_F_REQUEST
    static let multi = NLMFlags(rawValue: 0x02)     // NLM_F_MULTI
    static let ack = NLMFlags(rawValue: 0x04)       // NLM_F_ACK
    static let echo = NLMFlags(rawValue: 0x08)      // NLM_F_ECHO
    static let create = NLMFlags(rawValue: 0x400)   // NLM_F_CREATE
    static let excl = NLMFlags(rawValue: 0x200)     // NLM_F_EXCL
}

/// Interface link attribute types (IFLA_*)
enum IFLAType: UInt16 {
    case unspec = 0
    case address = 1      // IFLA_ADDRESS
    case broadcast = 2    // IFLA_BROADCAST
    case ifname = 3       // IFLA_IFNAME
    case mtu = 4          // IFLA_MTU
    case link = 5         // IFLA_LINK
    case linkInfo = 18    // IFLA_LINKINFO
}

/// Link info attribute types (IFLA_INFO_*)
enum IFLAInfoType: UInt16 {
    case unspec = 0
    case kind = 1         // IFLA_INFO_KIND
    case data = 2         // IFLA_INFO_DATA
}

/// Interface address attribute types (IFA_*)
enum IFAType: UInt16 {
    case unspec = 0
    case address = 1      // IFA_ADDRESS
    case local = 2        // IFA_LOCAL
    case label = 3        // IFA_LABEL
}

// MARK: - Netlink Message Header

/// Netlink message header (struct nlmsghdr)
struct NetlinkMessageHeader {
    var length: UInt32      // nlmsg_len
    var type: UInt16        // nlmsg_type
    var flags: UInt16       // nlmsg_flags
    var sequence: UInt32    // nlmsg_seq
    var pid: UInt32         // nlmsg_pid

    static let size = 16

    func serialize() -> Data {
        var data = Data(capacity: Self.size)
        withUnsafeBytes(of: length.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: type.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: flags.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: pid.littleEndian) { data.append(contentsOf: $0) }
        return data
    }
}

/// Interface info message (struct ifinfomsg)
struct InterfaceInfoMessage {
    var family: UInt8 = 0       // ifi_family (AF_UNSPEC)
    var pad: UInt8 = 0          // padding
    var type: UInt16 = 0        // ifi_type (ARPHRD_*)
    var index: Int32 = 0        // ifi_index
    var flags: UInt32 = 0       // ifi_flags (IFF_*)
    var change: UInt32 = 0      // ifi_change

    static let size = 16

    func serialize() -> Data {
        var data = Data(capacity: Self.size)
        data.append(family)
        data.append(pad)
        withUnsafeBytes(of: type.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: flags.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: change.littleEndian) { data.append(contentsOf: $0) }
        return data
    }
}

/// Interface address message (struct ifaddrmsg)
struct InterfaceAddressMessage {
    var family: UInt8           // ifa_family (AF_INET or AF_INET6)
    var prefixLen: UInt8        // ifa_prefixlen
    var flags: UInt8 = 0        // ifa_flags
    var scope: UInt8 = 0        // ifa_scope (RT_SCOPE_UNIVERSE = 0)
    var index: UInt32           // ifa_index

    static let size = 8

    func serialize() -> Data {
        var data = Data(capacity: Self.size)
        data.append(family)
        data.append(prefixLen)
        data.append(flags)
        data.append(scope)
        withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        return data
    }
}

/// Netlink attribute (struct nlattr)
struct NetlinkAttribute {
    var length: UInt16
    var type: UInt16
    var data: Data

    static let headerSize = 4

    init(type: UInt16, data: Data) {
        self.type = type
        self.data = data
        self.length = UInt16(Self.headerSize + data.count)
    }

    init(type: UInt16, string: String) {
        let strData = string.data(using: .utf8)! + Data([0]) // null terminated
        self.init(type: type, data: strData)
    }

    init(type: UInt16, uint32: UInt32) {
        var value = uint32.littleEndian
        let data = withUnsafeBytes(of: &value) { Data($0) }
        self.init(type: type, data: data)
    }

    func serialize() -> Data {
        var result = Data(capacity: Int(alignedLength))
        withUnsafeBytes(of: length.littleEndian) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: type.littleEndian) { result.append(contentsOf: $0) }
        result.append(data)
        // Pad to 4-byte alignment
        let padding = Int(alignedLength) - Int(length)
        if padding > 0 {
            result.append(Data(repeating: 0, count: padding))
        }
        return result
    }

    /// Length aligned to 4 bytes (NLA_ALIGN)
    var alignedLength: UInt16 {
        (length + 3) & ~3
    }
}

// MARK: - RTNetlink Socket

/// RTNetlink socket for network interface management
public class RTNetlinkSocket {
    private let fd: Int32
    private var sequence: UInt32 = 1

    public init() throws {
        fd = socket(AF_NETLINK, Int32(SOCK_RAW.rawValue), NetlinkProtocol.route.rawValue)
        guard fd >= 0 else {
            throw NetlinkError.socketCreationFailed(errno: errno)
        }

        // Bind to netlink
        var addr = sockaddr_nl()
        addr.nl_family = sa_family_t(AF_NETLINK)
        addr.nl_pid = 0  // kernel assigns
        addr.nl_groups = 0

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_nl>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw NetlinkError.bindFailed(errno: errno)
        }
    }

    deinit {
        close(fd)
    }

    /// Create a WireGuard interface
    public func createWireGuardInterface(name: String) throws {
        guard name.utf8.count <= 15 else {
            throw NetlinkError.interfaceNameTooLong
        }

        // Build the nested attributes for link info
        let kindAttr = NetlinkAttribute(type: IFLAInfoType.kind.rawValue, string: "wireguard")

        // IFLA_LINKINFO contains nested attributes
        var linkInfoData = Data()
        linkInfoData.append(kindAttr.serialize())
        let linkInfoAttr = NetlinkAttribute(type: IFLAType.linkInfo.rawValue, data: linkInfoData)

        // Interface name attribute
        let nameAttr = NetlinkAttribute(type: IFLAType.ifname.rawValue, string: name)

        // Build message
        let ifinfo = InterfaceInfoMessage()

        var payload = Data()
        payload.append(ifinfo.serialize())
        payload.append(nameAttr.serialize())
        payload.append(linkInfoAttr.serialize())

        let seq = nextSequence()
        let flags: [NLMFlags] = [.request, .ack, .create, .excl]
        let header = NetlinkMessageHeader(
            length: UInt32(NetlinkMessageHeader.size + payload.count),
            type: RTMType.newLink.rawValue,
            flags: flags.reduce(0) { $0 | $1.rawValue },
            sequence: seq,
            pid: 0
        )

        var message = Data()
        message.append(header.serialize())
        message.append(payload)

        try sendAndWaitForAck(message: message, sequence: seq)
    }

    /// Delete a network interface
    public func deleteInterface(name: String) throws {
        let index = try getInterfaceIndex(name: name)

        var ifinfo = InterfaceInfoMessage()
        ifinfo.index = index

        var payload = Data()
        payload.append(ifinfo.serialize())

        let seq = nextSequence()
        let flags: [NLMFlags] = [.request, .ack]
        let header = NetlinkMessageHeader(
            length: UInt32(NetlinkMessageHeader.size + payload.count),
            type: RTMType.delLink.rawValue,
            flags: flags.reduce(0) { $0 | $1.rawValue },
            sequence: seq,
            pid: 0
        )

        var message = Data()
        message.append(header.serialize())
        message.append(payload)

        try sendAndWaitForAck(message: message, sequence: seq)
    }

    /// Set interface up/down
    public func setInterfaceUp(name: String, up: Bool) throws {
        let index = try getInterfaceIndex(name: name)

        var ifinfo = InterfaceInfoMessage()
        ifinfo.index = index
        ifinfo.flags = up ? UInt32(IFF_UP) : 0
        ifinfo.change = UInt32(IFF_UP)

        var payload = Data()
        payload.append(ifinfo.serialize())

        let seq = nextSequence()
        let setFlags: [NLMFlags] = [.request, .ack]
        let header = NetlinkMessageHeader(
            length: UInt32(NetlinkMessageHeader.size + payload.count),
            type: RTMType.newLink.rawValue,
            flags: setFlags.reduce(0) { $0 | $1.rawValue },
            sequence: seq,
            pid: 0
        )

        var message = Data()
        message.append(header.serialize())
        message.append(payload)

        try sendAndWaitForAck(message: message, sequence: seq)
    }

    /// Add an IPv4 address to an interface
    public func addIPv4Address(interface: String, address: String, prefixLength: UInt8) throws {
        let index = try getInterfaceIndex(name: interface)

        guard let ipBytes = parseIPv4(address) else {
            throw NetlinkError.invalidIPAddress
        }

        var ifaddr = InterfaceAddressMessage(
            family: UInt8(AF_INET),
            prefixLen: prefixLength,
            index: UInt32(index)
        )

        let localAttr = NetlinkAttribute(type: IFAType.local.rawValue, data: Data(ipBytes))
        let addrAttr = NetlinkAttribute(type: IFAType.address.rawValue, data: Data(ipBytes))

        var payload = Data()
        payload.append(ifaddr.serialize())
        payload.append(localAttr.serialize())
        payload.append(addrAttr.serialize())

        let seq = nextSequence()
        let addrFlags: [NLMFlags] = [.request, .ack, .create, .excl]
        let header = NetlinkMessageHeader(
            length: UInt32(NetlinkMessageHeader.size + payload.count),
            type: RTMType.newAddr.rawValue,
            flags: addrFlags.reduce(0) { $0 | $1.rawValue },
            sequence: seq,
            pid: 0
        )

        var message = Data()
        message.append(header.serialize())
        message.append(payload)

        try sendAndWaitForAck(message: message, sequence: seq)
    }

    /// Get interface index by name
    public func getInterfaceIndex(name: String) throws -> Int32 {
        var index = if_nametoindex(name)
        guard index > 0 else {
            throw NetlinkError.interfaceNotFound(name)
        }
        return Int32(index)
    }

    // MARK: - Private Helpers

    private func nextSequence() -> UInt32 {
        let seq = sequence
        sequence += 1
        return seq
    }

    private func sendAndWaitForAck(message: Data, sequence: UInt32) throws {
        // Send message
        let sent = message.withUnsafeBytes { ptr in
            send(fd, ptr.baseAddress, message.count, 0)
        }
        guard sent == message.count else {
            throw NetlinkError.sendFailed(errno: errno)
        }

        // Receive response
        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else {
            throw NetlinkError.receiveFailed(errno: errno)
        }

        // Parse response header
        guard received >= NetlinkMessageHeader.size else {
            throw NetlinkError.invalidResponse
        }

        let responseType = UInt16(buffer[4]) | (UInt16(buffer[5]) << 8)

        // Check for error (NLMSG_ERROR = 2)
        if responseType == 2 {
            // Error message format: nlmsghdr + int32 error code
            guard received >= NetlinkMessageHeader.size + 4 else {
                throw NetlinkError.invalidResponse
            }

            let errorCode = Int32(buffer[16]) |
                           (Int32(buffer[17]) << 8) |
                           (Int32(buffer[18]) << 16) |
                           (Int32(buffer[19]) << 24)

            if errorCode < 0 {
                throw NetlinkError.operationFailed(errno: -errorCode)
            }
            // errorCode == 0 means success (ACK)
        }
    }

    private func parseIPv4(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts
    }
}

// MARK: - Netlink Errors

public enum NetlinkError: Error, CustomStringConvertible {
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case sendFailed(errno: Int32)
    case receiveFailed(errno: Int32)
    case operationFailed(errno: Int32)
    case interfaceNotFound(String)
    case interfaceNameTooLong
    case invalidIPAddress
    case invalidResponse

    public var description: String {
        switch self {
        case .socketCreationFailed(let errno):
            return "Failed to create netlink socket: \(String(cString: strerror(errno)))"
        case .bindFailed(let errno):
            return "Failed to bind netlink socket: \(String(cString: strerror(errno)))"
        case .sendFailed(let errno):
            return "Failed to send netlink message: \(String(cString: strerror(errno)))"
        case .receiveFailed(let errno):
            return "Failed to receive netlink response: \(String(cString: strerror(errno)))"
        case .operationFailed(let errno):
            return "Netlink operation failed: \(String(cString: strerror(errno)))"
        case .interfaceNotFound(let name):
            return "Interface not found: \(name)"
        case .interfaceNameTooLong:
            return "Interface name must be 15 characters or less"
        case .invalidIPAddress:
            return "Invalid IP address format"
        case .invalidResponse:
            return "Invalid netlink response"
        }
    }
}

#endif
