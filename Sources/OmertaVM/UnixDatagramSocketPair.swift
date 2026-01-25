// UnixDatagramSocketPair.swift
// Unix datagram socket pair for VM packet capture on macOS

import Foundation

#if os(macOS)
import Darwin

/// Creates a connected pair of Unix datagram sockets for VM network communication
/// One socket is for the VM (via VZFileHandleNetworkDeviceAttachment)
/// The other is for the host to read/write packets for packet capture
public struct UnixDatagramSocketPair: Sendable {
    /// Socket file descriptor for VM side (use with VZFileHandleNetworkDeviceAttachment)
    public let vmSocket: Int32
    /// Socket file descriptor for host side (for packet capture)
    public let hostSocket: Int32

    /// Create a connected Unix datagram socket pair
    public static func create() throws -> UnixDatagramSocketPair {
        var sockets: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets)
        guard result == 0 else {
            throw SocketPairError.creationFailed(errno: errno)
        }

        // Set socket buffer sizes to handle large packets
        let bufferSize: Int32 = 65536
        var size = bufferSize
        setsockopt(sockets[0], SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sockets[1], SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sockets[1], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))

        return UnixDatagramSocketPair(vmSocket: sockets[0], hostSocket: sockets[1])
    }

    /// Close both sockets
    public func close() {
        Darwin.close(vmSocket)
        Darwin.close(hostSocket)
    }

    /// Send data from host to VM
    @discardableResult
    public func sendToVM(_ data: Data) throws -> Int {
        return try data.withUnsafeBytes { buffer in
            let sent = write(hostSocket, buffer.baseAddress, data.count)
            if sent < 0 {
                throw SocketPairError.sendFailed(errno: errno)
            }
            return sent
        }
    }

    /// Send data from VM to host
    @discardableResult
    public func sendFromVM(_ data: Data) throws -> Int {
        return try data.withUnsafeBytes { buffer in
            let sent = write(vmSocket, buffer.baseAddress, data.count)
            if sent < 0 {
                throw SocketPairError.sendFailed(errno: errno)
            }
            return sent
        }
    }

    /// Receive data on VM side (sent from host)
    public func receiveFromHost(maxLength: Int = 1500) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let received = read(vmSocket, &buffer, maxLength)
        if received < 0 {
            throw SocketPairError.receiveFailed(errno: errno)
        }
        return Data(buffer.prefix(received))
    }

    /// Receive data on host side (sent from VM)
    public func receiveOnHost(maxLength: Int = 1500) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let received = read(hostSocket, &buffer, maxLength)
        if received < 0 {
            throw SocketPairError.receiveFailed(errno: errno)
        }
        return Data(buffer.prefix(received))
    }

    public enum SocketPairError: Error, CustomStringConvertible {
        case creationFailed(errno: Int32)
        case sendFailed(errno: Int32)
        case receiveFailed(errno: Int32)

        public var description: String {
            switch self {
            case .creationFailed(let err):
                return "Failed to create socket pair: errno \(err)"
            case .sendFailed(let err):
                return "Failed to send on socket: errno \(err)"
            case .receiveFailed(let err):
                return "Failed to receive on socket: errno \(err)"
            }
        }
    }
}
#endif
