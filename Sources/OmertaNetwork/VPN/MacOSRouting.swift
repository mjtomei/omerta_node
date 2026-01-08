// MacOSRouting.swift
// Native macOS routing table management using PF_ROUTE sockets
// Manages routes without shelling out to the `route` command

#if os(macOS)
import Foundation
import Darwin

/// Errors for routing operations
public enum RoutingError: Error, CustomStringConvertible {
    case socketFailed(Int32)
    case sendFailed(Int32)
    case invalidAddress(String)
    case routeNotFound
    case operationFailed(String)

    public var description: String {
        switch self {
        case .socketFailed(let errno):
            return "Failed to create routing socket: \(String(cString: strerror(errno)))"
        case .sendFailed(let errno):
            return "Failed to send route message: \(String(cString: strerror(errno)))"
        case .invalidAddress(let addr):
            return "Invalid address: \(addr)"
        case .routeNotFound:
            return "Route not found"
        case .operationFailed(let msg):
            return "Routing operation failed: \(msg)"
        }
    }
}

// MARK: - Route Message Types (from net/route.h)
private let RTM_ADD: Int32 = 0x1
private let RTM_DELETE: Int32 = 0x2
private let RTM_CHANGE: Int32 = 0x3
private let RTM_GET: Int32 = 0x4

// Route flags
private let RTF_UP: Int32 = 0x1
private let RTF_GATEWAY: Int32 = 0x2
private let RTF_HOST: Int32 = 0x4
private let RTF_STATIC: Int32 = 0x800
private let RTF_IFSCOPE: Int32 = 0x1000000

// Address type flags for rt_msghdr
private let RTA_DST: Int32 = 0x1
private let RTA_GATEWAY: Int32 = 0x2
private let RTA_NETMASK: Int32 = 0x4
private let RTA_IFP: Int32 = 0x10
private let RTA_IFA: Int32 = 0x20

private let RTM_VERSION: UInt8 = 5

// Route message header
private struct rt_msghdr {
    var rtm_msglen: UInt16
    var rtm_version: UInt8
    var rtm_type: UInt8
    var rtm_index: UInt16
    var rtm_flags: Int32
    var rtm_addrs: Int32
    var rtm_pid: pid_t
    var rtm_seq: Int32
    var rtm_errno: Int32
    var rtm_use: Int32
    var rtm_inits: UInt32
    var rtm_rmx: rt_metrics

    init() {
        rtm_msglen = 0
        rtm_version = RTM_VERSION
        rtm_type = 0
        rtm_index = 0
        rtm_flags = 0
        rtm_addrs = 0
        rtm_pid = 0
        rtm_seq = 0
        rtm_errno = 0
        rtm_use = 0
        rtm_inits = 0
        rtm_rmx = rt_metrics()
    }
}

private struct rt_metrics {
    var rmx_locks: UInt32
    var rmx_mtu: UInt32
    var rmx_hopcount: UInt32
    var rmx_expire: Int32
    var rmx_recvpipe: UInt32
    var rmx_sendpipe: UInt32
    var rmx_ssthresh: UInt32
    var rmx_rtt: UInt32
    var rmx_rttvar: UInt32
    var rmx_pksent: UInt32
    var rmx_state: UInt32
    var rmx_filler: (UInt32, UInt32, UInt32)

    init() {
        rmx_locks = 0
        rmx_mtu = 0
        rmx_hopcount = 0
        rmx_expire = 0
        rmx_recvpipe = 0
        rmx_sendpipe = 0
        rmx_ssthresh = 0
        rmx_rtt = 0
        rmx_rttvar = 0
        rmx_pksent = 0
        rmx_state = 0
        rmx_filler = (0, 0, 0)
    }
}

// sockaddr_dl for interface specification
private struct sockaddr_dl {
    var sdl_len: UInt8
    var sdl_family: UInt8
    var sdl_index: UInt16
    var sdl_type: UInt8
    var sdl_nlen: UInt8
    var sdl_alen: UInt8
    var sdl_slen: UInt8
    var sdl_data: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    init() {
        sdl_len = UInt8(MemoryLayout<sockaddr_dl>.size)
        sdl_family = UInt8(AF_LINK)
        sdl_index = 0
        sdl_type = 0
        sdl_nlen = 0
        sdl_alen = 0
        sdl_slen = 0
    }
}

/// Native macOS routing manager
public class MacOSRoutingManager {
    private static var sequence: Int32 = 0

    /// Add a route to a destination via an interface
    /// - Parameters:
    ///   - destination: Destination IP address or network
    ///   - prefixLength: Network prefix length (32 for host route)
    ///   - interface: Interface name (e.g., "utun5")
    public static func addRoute(destination: String, prefixLength: UInt8, interface: String) throws {
        try modifyRoute(type: RTM_ADD, destination: destination, prefixLength: prefixLength, interface: interface)
    }

    /// Delete a route
    public static func deleteRoute(destination: String, prefixLength: UInt8) throws {
        try modifyRoute(type: RTM_DELETE, destination: destination, prefixLength: prefixLength, interface: nil)
    }

    private static func modifyRoute(type: Int32, destination: String, prefixLength: UInt8, interface: String?) throws {
        // Create routing socket
        let sock = socket(PF_ROUTE, SOCK_RAW, 0)
        guard sock >= 0 else {
            throw RoutingError.socketFailed(errno)
        }
        defer { close(sock) }

        // Build the route message
        sequence += 1

        var buffer = [UInt8](repeating: 0, count: 512)
        var offset = 0

        // Reserve space for header
        offset = MemoryLayout<rt_msghdr>.size

        // Add destination address
        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, destination, &destAddr.sin_addr) == 1 else {
            throw RoutingError.invalidAddress(destination)
        }

        withUnsafeBytes(of: destAddr) { bytes in
            for (i, byte) in bytes.enumerated() {
                buffer[offset + i] = byte
            }
        }
        offset += roundUp(MemoryLayout<sockaddr_in>.size)

        var addrs: Int32 = RTA_DST

        // Add interface as gateway if specified
        if let interface = interface {
            // Get interface index
            let ifIndex = if_nametoindex(interface)
            guard ifIndex > 0 else {
                throw RoutingError.operationFailed("Interface not found: \(interface)")
            }

            // Add sockaddr_dl for interface
            var sdl = sockaddr_dl()
            sdl.sdl_len = UInt8(MemoryLayout<sockaddr_dl>.size)
            sdl.sdl_family = sa_family_t(AF_LINK)
            sdl.sdl_index = UInt16(ifIndex)
            sdl.sdl_nlen = UInt8(min(interface.count, 12))
            withUnsafeMutableBytes(of: &sdl.sdl_data) { dataPtr in
                _ = interface.withCString { cstr in
                    strncpy(dataPtr.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, 12)
                }
            }

            withUnsafeBytes(of: sdl) { bytes in
                for (i, byte) in bytes.enumerated() {
                    buffer[offset + i] = byte
                }
            }
            offset += roundUp(MemoryLayout<sockaddr_dl>.size)
            addrs |= RTA_GATEWAY
        }

        // Add netmask
        if prefixLength < 32 {
            var maskAddr = sockaddr_in()
            maskAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            maskAddr.sin_family = sa_family_t(AF_INET)
            let mask = prefixLength >= 32 ? UInt32.max : (UInt32.max << (32 - prefixLength))
            maskAddr.sin_addr.s_addr = mask.bigEndian

            withUnsafeBytes(of: maskAddr) { bytes in
                for (i, byte) in bytes.enumerated() {
                    buffer[offset + i] = byte
                }
            }
            offset += roundUp(MemoryLayout<sockaddr_in>.size)
            addrs |= RTA_NETMASK
        }

        // Fill in header
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(offset)
        header.rtm_version = RTM_VERSION
        header.rtm_type = UInt8(type)
        header.rtm_flags = RTF_UP | RTF_STATIC | (prefixLength == 32 ? RTF_HOST : 0)
        header.rtm_addrs = addrs
        header.rtm_pid = getpid()
        header.rtm_seq = sequence

        withUnsafeBytes(of: header) { bytes in
            for (i, byte) in bytes.enumerated() {
                buffer[i] = byte
            }
        }

        // Send the message
        let result = write(sock, buffer, offset)
        guard result == offset else {
            throw RoutingError.sendFailed(errno)
        }
    }

    /// Add a route with a gateway IP
    public static func addRouteViaGateway(destination: String, prefixLength: UInt8, gateway: String) throws {
        let sock = socket(PF_ROUTE, SOCK_RAW, 0)
        guard sock >= 0 else {
            throw RoutingError.socketFailed(errno)
        }
        defer { close(sock) }

        sequence += 1

        var buffer = [UInt8](repeating: 0, count: 512)
        var offset = MemoryLayout<rt_msghdr>.size

        // Add destination address
        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, destination, &destAddr.sin_addr) == 1 else {
            throw RoutingError.invalidAddress(destination)
        }

        withUnsafeBytes(of: destAddr) { bytes in
            for (i, byte) in bytes.enumerated() {
                buffer[offset + i] = byte
            }
        }
        offset += roundUp(MemoryLayout<sockaddr_in>.size)

        // Add gateway address
        var gwAddr = sockaddr_in()
        gwAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        gwAddr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, gateway, &gwAddr.sin_addr) == 1 else {
            throw RoutingError.invalidAddress(gateway)
        }

        withUnsafeBytes(of: gwAddr) { bytes in
            for (i, byte) in bytes.enumerated() {
                buffer[offset + i] = byte
            }
        }
        offset += roundUp(MemoryLayout<sockaddr_in>.size)

        var addrs: Int32 = RTA_DST | RTA_GATEWAY

        // Add netmask if not a host route
        if prefixLength < 32 {
            var maskAddr = sockaddr_in()
            maskAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            maskAddr.sin_family = sa_family_t(AF_INET)
            let mask = UInt32.max << (32 - prefixLength)
            maskAddr.sin_addr.s_addr = mask.bigEndian

            withUnsafeBytes(of: maskAddr) { bytes in
                for (i, byte) in bytes.enumerated() {
                    buffer[offset + i] = byte
                }
            }
            offset += roundUp(MemoryLayout<sockaddr_in>.size)
            addrs |= RTA_NETMASK
        }

        // Fill in header
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(offset)
        header.rtm_version = RTM_VERSION
        header.rtm_type = UInt8(RTM_ADD)
        header.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_STATIC | (prefixLength == 32 ? RTF_HOST : 0)
        header.rtm_addrs = addrs
        header.rtm_pid = getpid()
        header.rtm_seq = sequence

        withUnsafeBytes(of: header) { bytes in
            for (i, byte) in bytes.enumerated() {
                buffer[i] = byte
            }
        }

        let result = write(sock, buffer, offset)
        guard result == offset else {
            throw RoutingError.sendFailed(errno)
        }
    }

    // Round up to next multiple of sizeof(long)
    private static func roundUp(_ size: Int) -> Int {
        let align = MemoryLayout<Int>.size
        return (size + align - 1) & ~(align - 1)
    }
}

#endif
