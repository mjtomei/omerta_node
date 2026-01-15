// MacOSUtun.swift
// Native macOS utun interface management
// Creates and manages utun (tunnel) interfaces without external tools

#if os(macOS)
import Foundation
import Darwin

/// Errors for utun operations
public enum UtunError: Error, CustomStringConvertible {
    case openFailed(Int32)
    case ioctlFailed(String, Int32)
    case socketFailed(Int32)
    case invalidAddress(String)
    case interfaceNotFound(String)

    public var description: String {
        switch self {
        case .openFailed(let errno):
            return "Failed to open utun device: \(String(cString: strerror(errno)))"
        case .ioctlFailed(let op, let errno):
            return "ioctl \(op) failed: \(String(cString: strerror(errno)))"
        case .socketFailed(let errno):
            return "Failed to create socket: \(String(cString: strerror(errno)))"
        case .invalidAddress(let addr):
            return "Invalid IP address: \(addr)"
        case .interfaceNotFound(let name):
            return "Interface not found: \(name)"
        }
    }
}

// MARK: - System Constants

// From sys/sys_domain.h
private let SYSPROTO_CONTROL: Int32 = 2
private let AF_SYS_CONTROL: Int32 = 2

// From net/if_utun.h
private let UTUN_CONTROL_NAME = "com.apple.net.utun_control"
private let UTUN_OPT_IFNAME: Int32 = 2

// ioctl commands - _IOW('i', n, size)
// These match the macOS header definitions for struct ifreq operations
private let SIOCAIFADDR_IN6 = _IOW(UInt8(ascii: "i"), 26, MemoryLayout<in6_aliasreq>.size)
private let SIOCSIFMTU_CONST: UInt = 0x80206934  // _IOW('i', 52, struct ifreq) - set IF mtu
private let SIOCGIFFLAGS_CONST: UInt = 0xc0206911  // _IOWR('i', 17, struct ifreq) - get IF flags
private let SIOCSIFFLAGS_CONST: UInt = 0x80206910  // _IOW('i', 16, struct ifreq) - set IF flags

// Interface flags
private let IFF_UP_CONST: Int16 = 0x1
private let IFF_RUNNING_CONST: Int16 = 0x40

// From sys/kern_control.h
private struct ctl_info {
    var ctl_id: UInt32 = 0
    var ctl_name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    init() {}
}

private struct sockaddr_ctl {
    var sc_len: UInt8
    var sc_family: UInt8
    var ss_sysaddr: UInt16
    var sc_id: UInt32
    var sc_unit: UInt32
    var sc_reserved: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)

    init() {
        sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        sc_family = UInt8(AF_SYSTEM)
        ss_sysaddr = UInt16(AF_SYS_CONTROL)
        sc_id = 0
        sc_unit = 0
    }
}

// For interface configuration
private struct ifaliasreq {
    var ifra_name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var ifra_addr: sockaddr_in = sockaddr_in()
    var ifra_broadaddr: sockaddr_in = sockaddr_in()
    var ifra_mask: sockaddr_in = sockaddr_in()
}

private struct in6_aliasreq {
    var ifra_name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var ifra_addr: sockaddr_in6 = sockaddr_in6()
    var ifra_dstaddr: sockaddr_in6 = sockaddr_in6()
    var ifra_prefixmask: sockaddr_in6 = sockaddr_in6()
    var ifra_flags: Int32 = 0
    var ifra_lifetime: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
}

// Helper to create _IOW macro equivalent
private func _IOW(_ group: UInt8, _ num: Int, _ size: Int) -> UInt {
    let IOC_OUT: UInt = 0x40000000
    let IOC_IN: UInt = 0x80000000
    return IOC_IN | IOC_OUT | (UInt(size) << 16) | (UInt(group) << 8) | UInt(num)
}

/// Native macOS utun interface manager
public class MacOSUtunManager {

    /// Create a new utun interface
    /// - Parameter unit: Optional unit number (0 for auto-assign)
    /// - Returns: Tuple of (file descriptor, interface name)
    public static func createInterface(unit: UInt32 = 0) throws -> (fd: Int32, name: String) {
        // Create a system control socket
        let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else {
            throw UtunError.openFailed(errno)
        }

        // Get the control ID for utun
        var info = ctl_info()
        withUnsafeMutableBytes(of: &info.ctl_name) { namePtr in
            _ = UTUN_CONTROL_NAME.withCString { cstr in
                strncpy(namePtr.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, 96)
            }
        }

        let CTLIOCGINFO: UInt = _IOW(UInt8(ascii: "N"), 3, MemoryLayout<ctl_info>.size)
        guard ioctl(fd, CTLIOCGINFO, &info) >= 0 else {
            let err = errno
            close(fd)
            throw UtunError.ioctlFailed("CTLIOCGINFO", err)
        }

        // Connect to the control
        var addr = sockaddr_ctl()
        addr.sc_id = info.ctl_id
        addr.sc_unit = unit  // 0 = auto-assign

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }

        guard connectResult >= 0 else {
            let err = errno
            close(fd)
            throw UtunError.ioctlFailed("connect", err)
        }

        // Get the interface name
        var ifname = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var ifnameLen = socklen_t(ifname.count)

        guard getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, &ifname, &ifnameLen) >= 0 else {
            let err = errno
            close(fd)
            throw UtunError.ioctlFailed("getsockopt IFNAME", err)
        }

        let name = String(cString: ifname)
        return (fd, name)
    }

    /// Set the MTU for an interface using native ioctl
    public static func setMTU(interface: String, mtu: Int32) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            throw UtunError.socketFailed(errno)
        }
        defer { close(sock) }

        var ifr = ifreq()
        _ = interface.withCString { cstr in
            strncpy(&ifr.ifr_name.0, cstr, Int(IFNAMSIZ))
        }

        // Set MTU via ifr_ifru union (ifr_mtu is at same offset)
        withUnsafeMutableBytes(of: &ifr.ifr_ifru) { ptr in
            ptr.storeBytes(of: mtu, as: Int32.self)
        }

        guard ioctl(sock, SIOCSIFMTU_CONST, &ifr) >= 0 else {
            throw UtunError.ioctlFailed("SIOCSIFMTU", errno)
        }
    }

    /// Add an IPv4 address to an interface using native ioctl
    public static func addIPv4Address(interface: String, address: String, prefixLength: UInt8) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            throw UtunError.socketFailed(errno)
        }
        defer { close(sock) }

        // Parse IP address
        var addr_in = in_addr()
        guard inet_pton(AF_INET, address, &addr_in) == 1 else {
            throw UtunError.invalidAddress(address)
        }

        // Build ifaliasreq structure
        var ifra = ifaliasreq()

        // Set interface name
        _ = interface.withCString { cstr in
            strncpy(&ifra.ifra_name.0, cstr, 16)
        }

        // Set address
        ifra.ifra_addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ifra.ifra_addr.sin_family = sa_family_t(AF_INET)
        ifra.ifra_addr.sin_addr = addr_in

        // Set destination (same as address for point-to-point)
        ifra.ifra_broadaddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ifra.ifra_broadaddr.sin_family = sa_family_t(AF_INET)
        ifra.ifra_broadaddr.sin_addr = addr_in

        // Set netmask
        let mask = prefixLength >= 32 ? UInt32.max : (UInt32.max << (32 - prefixLength))
        ifra.ifra_mask.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ifra.ifra_mask.sin_family = sa_family_t(AF_INET)
        ifra.ifra_mask.sin_addr.s_addr = mask.bigEndian

        // SIOCAIFADDR - add interface address
        let SIOCAIFADDR: UInt = 0x8040691a
        guard ioctl(sock, SIOCAIFADDR, &ifra) >= 0 else {
            throw UtunError.ioctlFailed("SIOCAIFADDR", errno)
        }
    }

    /// Bring an interface up using native ioctl
    public static func setInterfaceUp(interface: String, up: Bool) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            throw UtunError.socketFailed(errno)
        }
        defer { close(sock) }

        var ifr = ifreq()
        _ = interface.withCString { cstr in
            strncpy(&ifr.ifr_name.0, cstr, Int(IFNAMSIZ))
        }

        // Get current flags
        guard ioctl(sock, SIOCGIFFLAGS_CONST, &ifr) >= 0 else {
            throw UtunError.ioctlFailed("SIOCGIFFLAGS", errno)
        }

        // Get flags from ifr_ifru union
        var flags: Int16 = 0
        withUnsafeBytes(of: &ifr.ifr_ifru) { ptr in
            flags = ptr.load(as: Int16.self)
        }

        // Modify flags
        if up {
            flags |= IFF_UP_CONST | IFF_RUNNING_CONST
        } else {
            flags &= ~(IFF_UP_CONST | IFF_RUNNING_CONST)
        }

        // Set flags back
        withUnsafeMutableBytes(of: &ifr.ifr_ifru) { ptr in
            ptr.storeBytes(of: flags, as: Int16.self)
        }

        guard ioctl(sock, SIOCSIFFLAGS_CONST, &ifr) >= 0 else {
            throw UtunError.ioctlFailed("SIOCSIFFLAGS", errno)
        }
    }

    /// Close a utun interface
    public static func closeInterface(fd: Int32) {
        close(fd)
    }

    /// Read a packet from the utun interface
    /// Returns the raw IP packet (without the 4-byte protocol header)
    public static func readPacket(fd: Int32, buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> (data: Data, proto: UInt32) {
        // utun prepends a 4-byte protocol identifier
        var fullBuffer = [UInt8](repeating: 0, count: maxLength + 4)
        let bytesRead = read(fd, &fullBuffer, fullBuffer.count)

        guard bytesRead > 4 else {
            if bytesRead < 0 {
                throw UtunError.ioctlFailed("read", errno)
            }
            return (Data(), 0)
        }

        // First 4 bytes are the protocol (network byte order)
        let proto = UInt32(fullBuffer[0]) << 24 | UInt32(fullBuffer[1]) << 16 |
                    UInt32(fullBuffer[2]) << 8 | UInt32(fullBuffer[3])

        let packetData = Data(fullBuffer[4..<bytesRead])
        return (packetData, proto)
    }

    /// Write a packet to the utun interface
    /// The packet should be a raw IP packet; protocol header is added automatically
    public static func writePacket(fd: Int32, data: Data, isIPv6: Bool) throws {
        // Prepend 4-byte protocol identifier
        let proto: UInt32 = isIPv6 ? UInt32(AF_INET6) : UInt32(AF_INET)
        var fullBuffer = [UInt8](repeating: 0, count: data.count + 4)
        fullBuffer[0] = UInt8((proto >> 24) & 0xFF)
        fullBuffer[1] = UInt8((proto >> 16) & 0xFF)
        fullBuffer[2] = UInt8((proto >> 8) & 0xFF)
        fullBuffer[3] = UInt8(proto & 0xFF)
        data.copyBytes(to: &fullBuffer[4], count: data.count)

        let bytesWritten = write(fd, fullBuffer, fullBuffer.count)
        guard bytesWritten == fullBuffer.count else {
            throw UtunError.ioctlFailed("write", errno)
        }
    }
}

#endif
