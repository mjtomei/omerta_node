// LinuxWireGuardNetlink.swift
// WireGuard configuration via Generic Netlink
// Allows configuring WireGuard interfaces without the `wg` binary

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

// MARK: - Generic Netlink Constants

/// Generic netlink control family
private let GENL_ID_CTRL: UInt16 = 0x10

/// Generic netlink control commands
private enum GenlCtrlCmd: UInt8 {
    case getFamily = 3  // CTRL_CMD_GETFAMILY
}

/// Generic netlink control attributes
private enum GenlCtrlAttr: UInt16 {
    case familyId = 1    // CTRL_ATTR_FAMILY_ID
    case familyName = 2  // CTRL_ATTR_FAMILY_NAME
}

// MARK: - WireGuard Netlink Constants

/// WireGuard netlink commands
private enum WGCmd: UInt8 {
    case getDevice = 0  // WG_CMD_GET_DEVICE
    case setDevice = 1  // WG_CMD_SET_DEVICE
}

/// WireGuard device attributes
private enum WGDeviceAttr: UInt16 {
    case unspec = 0
    case ifindex = 1      // WG_DEVICE_A_IFINDEX
    case ifname = 2       // WG_DEVICE_A_IFNAME
    case privateKey = 3   // WG_DEVICE_A_PRIVATE_KEY
    case publicKey = 4    // WG_DEVICE_A_PUBLIC_KEY
    case flags = 5        // WG_DEVICE_A_FLAGS
    case listenPort = 6   // WG_DEVICE_A_LISTEN_PORT
    case fwmark = 7       // WG_DEVICE_A_FWMARK
    case peers = 8        // WG_DEVICE_A_PEERS
}

/// WireGuard peer attributes
private enum WGPeerAttr: UInt16 {
    case unspec = 0
    case publicKey = 1           // WG_PEER_A_PUBLIC_KEY
    case presharedKey = 2        // WG_PEER_A_PRESHARED_KEY
    case flags = 3               // WG_PEER_A_FLAGS
    case endpoint = 4            // WG_PEER_A_ENDPOINT
    case persistentKeepalive = 5 // WG_PEER_A_PERSISTENT_KEEPALIVE_INTERVAL
    case lastHandshake = 6       // WG_PEER_A_LAST_HANDSHAKE_TIME
    case rxBytes = 7             // WG_PEER_A_RX_BYTES
    case txBytes = 8             // WG_PEER_A_TX_BYTES
    case allowedIPs = 9          // WG_PEER_A_ALLOWEDIPS
    case protocolVersion = 10    // WG_PEER_A_PROTOCOL_VERSION
}

/// WireGuard allowed IP attributes
private enum WGAllowedIPAttr: UInt16 {
    case unspec = 0
    case family = 1   // WG_ALLOWEDIP_A_FAMILY
    case ipaddr = 2   // WG_ALLOWEDIP_A_IPADDR
    case cidrMask = 3 // WG_ALLOWEDIP_A_CIDR_MASK
}

/// WireGuard peer flags
private struct WGPeerFlags: OptionSet {
    let rawValue: UInt32
    static let removeMe = WGPeerFlags(rawValue: 1 << 0)
    static let replaceAllowedIPs = WGPeerFlags(rawValue: 1 << 1)
    static let updateOnly = WGPeerFlags(rawValue: 1 << 2)
}

// MARK: - Generic Netlink Header

/// Generic netlink message header (struct genlmsghdr)
private struct GenlMessageHeader {
    var cmd: UInt8
    var version: UInt8
    var reserved: UInt16

    static let size = 4

    func serialize() -> Data {
        var data = Data(capacity: Self.size)
        data.append(cmd)
        data.append(version)
        withUnsafeBytes(of: reserved.littleEndian) { data.append(contentsOf: $0) }
        return data
    }
}

// MARK: - WireGuard Netlink Socket

/// WireGuard configuration via Generic Netlink
public class WireGuardNetlinkSocket {
    private let fd: Int32
    private var sequence: UInt32 = 1
    private var wgFamilyId: UInt16?

    public init() throws {
        fd = socket(AF_NETLINK, Int32(SOCK_RAW.rawValue), 16) // NETLINK_GENERIC = 16
        guard fd >= 0 else {
            throw WireGuardNetlinkError.socketCreationFailed(errno: errno)
        }

        // Bind to netlink
        var addr = sockaddr_nl()
        addr.nl_family = sa_family_t(AF_NETLINK)
        addr.nl_pid = 0
        addr.nl_groups = 0

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_nl>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw WireGuardNetlinkError.bindFailed(errno: errno)
        }
    }

    deinit {
        close(fd)
    }

    // MARK: - Public API

    /// Configure a WireGuard interface with private key
    public func setPrivateKey(interface: String, privateKey: Data) throws {
        guard privateKey.count == 32 else {
            throw WireGuardNetlinkError.invalidKeyLength
        }

        let familyId = try getWireGuardFamilyId()

        // Build WireGuard set device message
        let ifnameAttr = makeAttribute(type: WGDeviceAttr.ifname.rawValue, string: interface)
        let keyAttr = makeAttribute(type: WGDeviceAttr.privateKey.rawValue, data: privateKey)

        var payload = Data()
        payload.append(ifnameAttr)
        payload.append(keyAttr)

        try sendWireGuardCommand(familyId: familyId, cmd: .setDevice, payload: payload)
    }

    /// Set listen port for a WireGuard interface
    public func setListenPort(interface: String, port: UInt16) throws {
        let familyId = try getWireGuardFamilyId()

        let ifnameAttr = makeAttribute(type: WGDeviceAttr.ifname.rawValue, string: interface)
        let portAttr = makeAttribute(type: WGDeviceAttr.listenPort.rawValue, uint16: port)

        var payload = Data()
        payload.append(ifnameAttr)
        payload.append(portAttr)

        try sendWireGuardCommand(familyId: familyId, cmd: .setDevice, payload: payload)
    }

    /// Add a peer to a WireGuard interface
    public func addPeer(
        interface: String,
        publicKey: Data,
        endpoint: (host: String, port: UInt16)?,
        allowedIPs: [(ip: String, cidr: UInt8)],
        persistentKeepalive: UInt16? = nil
    ) throws {
        guard publicKey.count == 32 else {
            throw WireGuardNetlinkError.invalidKeyLength
        }

        let familyId = try getWireGuardFamilyId()

        // Build peer attributes
        var peerAttrs = Data()
        peerAttrs.append(makeAttribute(type: WGPeerAttr.publicKey.rawValue, data: publicKey))

        // Add endpoint if provided
        if let endpoint = endpoint {
            if let endpointData = makeEndpointSockaddr(host: endpoint.host, port: endpoint.port) {
                peerAttrs.append(makeAttribute(type: WGPeerAttr.endpoint.rawValue, data: endpointData))
            }
        }

        // Add persistent keepalive if provided
        if let keepalive = persistentKeepalive {
            peerAttrs.append(makeAttribute(type: WGPeerAttr.persistentKeepalive.rawValue, uint16: keepalive))
        }

        // Replace all allowed IPs flag
        peerAttrs.append(makeAttribute(type: WGPeerAttr.flags.rawValue, uint32: WGPeerFlags.replaceAllowedIPs.rawValue))

        // Add allowed IPs
        if !allowedIPs.isEmpty {
            var allowedIPsData = Data()
            for (index, allowedIP) in allowedIPs.enumerated() {
                if let ipData = makeAllowedIPAttribute(ip: allowedIP.ip, cidr: allowedIP.cidr) {
                    // Nested attribute with index
                    allowedIPsData.append(makeNestedAttribute(type: UInt16(index), data: ipData))
                }
            }
            peerAttrs.append(makeNestedAttribute(type: WGPeerAttr.allowedIPs.rawValue, data: allowedIPsData))
        }

        // Wrap peer in nested attribute (peers is a list)
        let peerNested = makeNestedAttribute(type: 0, data: peerAttrs) // index 0
        let peersAttr = makeNestedAttribute(type: WGDeviceAttr.peers.rawValue, data: peerNested)

        // Build full payload
        var payload = Data()
        payload.append(makeAttribute(type: WGDeviceAttr.ifname.rawValue, string: interface))
        payload.append(peersAttr)

        try sendWireGuardCommand(familyId: familyId, cmd: .setDevice, payload: payload)
    }

    // MARK: - Private Helpers

    private func nextSequence() -> UInt32 {
        let seq = sequence
        sequence += 1
        return seq
    }

    /// Resolve the WireGuard generic netlink family ID
    private func getWireGuardFamilyId() throws -> UInt16 {
        if let id = wgFamilyId {
            return id
        }

        // Query for "wireguard" family
        let familyNameAttr = makeAttribute(type: GenlCtrlAttr.familyName.rawValue, string: "wireguard")

        // Build generic netlink header
        let genlHeader = GenlMessageHeader(cmd: GenlCtrlCmd.getFamily.rawValue, version: 1, reserved: 0)

        var payload = Data()
        payload.append(genlHeader.serialize())
        payload.append(familyNameAttr)

        let seq = nextSequence()
        let nlHeader = NetlinkMessageHeader(
            length: UInt32(NetlinkMessageHeader.size + payload.count),
            type: GENL_ID_CTRL,
            flags: 0x01, // NLM_F_REQUEST
            sequence: seq,
            pid: 0
        )

        var message = Data()
        message.append(nlHeader.serialize())
        message.append(payload)

        // Send and receive
        let sent = message.withUnsafeBytes { ptr in
            send(fd, ptr.baseAddress, message.count, 0)
        }
        guard sent == message.count else {
            throw WireGuardNetlinkError.sendFailed(errno: errno)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else {
            throw WireGuardNetlinkError.receiveFailed(errno: errno)
        }

        // Parse response to find family ID
        // Skip netlink header (16 bytes) + genl header (4 bytes)
        let attrOffset = NetlinkMessageHeader.size + GenlMessageHeader.size
        guard received > attrOffset else {
            throw WireGuardNetlinkError.familyNotFound
        }

        // Parse attributes looking for CTRL_ATTR_FAMILY_ID
        var offset = attrOffset
        while offset + 4 <= received {
            let attrLen = UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
            let attrType = UInt16(buffer[offset + 2]) | (UInt16(buffer[offset + 3]) << 8)

            if attrType == GenlCtrlAttr.familyId.rawValue && attrLen >= 6 {
                let familyId = UInt16(buffer[offset + 4]) | (UInt16(buffer[offset + 5]) << 8)
                wgFamilyId = familyId
                return familyId
            }

            // Move to next attribute (aligned to 4 bytes)
            let alignedLen = Int((attrLen + 3) & ~3)
            offset += alignedLen
        }

        throw WireGuardNetlinkError.familyNotFound
    }

    private func sendWireGuardCommand(familyId: UInt16, cmd: WGCmd, payload: Data) throws {
        let genlHeader = GenlMessageHeader(cmd: cmd.rawValue, version: 1, reserved: 0)

        var fullPayload = Data()
        fullPayload.append(genlHeader.serialize())
        fullPayload.append(payload)

        let seq = nextSequence()
        let nlHeader = NetlinkMessageHeader(
            length: UInt32(NetlinkMessageHeader.size + fullPayload.count),
            type: familyId,
            flags: 0x05, // NLM_F_REQUEST | NLM_F_ACK
            sequence: seq,
            pid: 0
        )

        var message = Data()
        message.append(nlHeader.serialize())
        message.append(fullPayload)

        let sent = message.withUnsafeBytes { ptr in
            send(fd, ptr.baseAddress, message.count, 0)
        }
        guard sent == message.count else {
            throw WireGuardNetlinkError.sendFailed(errno: errno)
        }

        // Wait for ACK
        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else {
            throw WireGuardNetlinkError.receiveFailed(errno: errno)
        }

        // Check for error (NLMSG_ERROR = 2)
        guard received >= NetlinkMessageHeader.size else {
            throw WireGuardNetlinkError.invalidResponse
        }

        let responseType = UInt16(buffer[4]) | (UInt16(buffer[5]) << 8)
        if responseType == 2 && received >= NetlinkMessageHeader.size + 4 {
            let errorCode = Int32(buffer[16]) |
                           (Int32(buffer[17]) << 8) |
                           (Int32(buffer[18]) << 16) |
                           (Int32(buffer[19]) << 24)

            if errorCode < 0 {
                throw WireGuardNetlinkError.operationFailed(errno: -errorCode)
            }
        }
    }

    // MARK: - Attribute Helpers

    private func makeAttribute(type: UInt16, data: Data) -> Data {
        let length = UInt16(4 + data.count)
        var result = Data()
        withUnsafeBytes(of: length.littleEndian) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: type.littleEndian) { result.append(contentsOf: $0) }
        result.append(data)
        // Pad to 4-byte alignment
        let padding = (4 - (data.count % 4)) % 4
        if padding > 0 {
            result.append(Data(repeating: 0, count: padding))
        }
        return result
    }

    private func makeAttribute(type: UInt16, string: String) -> Data {
        var strData = string.data(using: .utf8)!
        strData.append(0) // null terminate
        return makeAttribute(type: type, data: strData)
    }

    private func makeAttribute(type: UInt16, uint16: UInt16) -> Data {
        var value = uint16.littleEndian
        let data = withUnsafeBytes(of: &value) { Data($0) }
        return makeAttribute(type: type, data: data)
    }

    private func makeAttribute(type: UInt16, uint32: UInt32) -> Data {
        var value = uint32.littleEndian
        let data = withUnsafeBytes(of: &value) { Data($0) }
        return makeAttribute(type: type, data: data)
    }

    private func makeNestedAttribute(type: UInt16, data: Data) -> Data {
        // Nested attributes have NLA_F_NESTED (0x8000) flag
        let nestedType = type | 0x8000
        return makeAttribute(type: nestedType, data: data)
    }

    private func makeEndpointSockaddr(host: String, port: UInt16) -> Data? {
        // Try IPv4 first
        var addr4 = sockaddr_in()
        if inet_pton(AF_INET, host, &addr4.sin_addr) == 1 {
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port = port.bigEndian
            return withUnsafeBytes(of: &addr4) { Data($0) }
        }

        // Try IPv6
        var addr6 = sockaddr_in6()
        if inet_pton(AF_INET6, host, &addr6.sin6_addr) == 1 {
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = port.bigEndian
            return withUnsafeBytes(of: &addr6) { Data($0) }
        }

        return nil
    }

    private func makeAllowedIPAttribute(ip: String, cidr: UInt8) -> Data? {
        var attrs = Data()

        // Try IPv4
        var addr4 = in_addr()
        if inet_pton(AF_INET, ip, &addr4) == 1 {
            attrs.append(makeAttribute(type: WGAllowedIPAttr.family.rawValue, uint16: UInt16(AF_INET)))
            let ipData = withUnsafeBytes(of: &addr4) { Data($0) }
            attrs.append(makeAttribute(type: WGAllowedIPAttr.ipaddr.rawValue, data: ipData))
            attrs.append(makeAttribute(type: WGAllowedIPAttr.cidrMask.rawValue, data: Data([cidr])))
            return attrs
        }

        // Try IPv6
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, ip, &addr6) == 1 {
            attrs.append(makeAttribute(type: WGAllowedIPAttr.family.rawValue, uint16: UInt16(AF_INET6)))
            let ipData = withUnsafeBytes(of: &addr6) { Data($0) }
            attrs.append(makeAttribute(type: WGAllowedIPAttr.ipaddr.rawValue, data: ipData))
            attrs.append(makeAttribute(type: WGAllowedIPAttr.cidrMask.rawValue, data: Data([cidr])))
            return attrs
        }

        return nil
    }
}

// MARK: - WireGuard Netlink Errors

public enum WireGuardNetlinkError: Error, CustomStringConvertible {
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case sendFailed(errno: Int32)
    case receiveFailed(errno: Int32)
    case operationFailed(errno: Int32)
    case familyNotFound
    case invalidKeyLength
    case invalidResponse

    public var description: String {
        switch self {
        case .socketCreationFailed(let errno):
            return "Failed to create generic netlink socket: \(String(cString: strerror(errno)))"
        case .bindFailed(let errno):
            return "Failed to bind generic netlink socket: \(String(cString: strerror(errno)))"
        case .sendFailed(let errno):
            return "Failed to send generic netlink message: \(String(cString: strerror(errno)))"
        case .receiveFailed(let errno):
            return "Failed to receive generic netlink response: \(String(cString: strerror(errno)))"
        case .operationFailed(let errno):
            return "WireGuard netlink operation failed: \(String(cString: strerror(errno)))"
        case .familyNotFound:
            return "WireGuard generic netlink family not found (is the wireguard kernel module loaded?)"
        case .invalidKeyLength:
            return "WireGuard key must be exactly 32 bytes"
        case .invalidResponse:
            return "Invalid netlink response"
        }
    }
}

#endif
