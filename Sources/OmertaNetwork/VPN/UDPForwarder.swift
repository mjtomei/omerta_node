// UDPForwarder.swift
// UDP socket wrapper for forwarding VM traffic to consumer

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - UDPForwarderError

/// Errors that can occur during UDP forwarding
public enum UDPForwarderError: Error, Equatable {
    case socketCreationFailed
    case bindFailed(Int32)
    case sendFailed(Int32)
    case receiveFailed(Int32)
    case receiveTimeout
    case closed
    case invalidAddress
}

// MARK: - UDPForwarder

/// Thread-safe UDP forwarder for sending packets to consumer and receiving responses
///
/// Uses BSD sockets for cross-platform compatibility.
public actor UDPForwarder {

    /// The local port the socket is bound to
    public private(set) var localPort: UInt16 = 0

    /// The underlying socket file descriptor
    private var socket: Int32 = -1

    /// Whether the forwarder has been closed
    private var isClosed = false

    // MARK: - Initialization

    /// Create a new UDP forwarder
    /// - Parameter localPort: The local port to bind to (0 for ephemeral)
    public init(localPort: UInt16 = 0) throws {
        // Create UDP socket
        #if canImport(Darwin)
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        #else
        socket = Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif

        guard socket >= 0 else {
            throw UDPForwarderError.socketCreationFailed
        }

        // Bind to local port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = localPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            #if canImport(Darwin)
            let err = Darwin.errno
            Darwin.close(socket)
            #else
            let err = Glibc.errno
            Glibc.close(socket)
            #endif
            socket = -1
            throw UDPForwarderError.bindFailed(err)
        }

        // Get the actual bound port (important if localPort was 0)
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(socket, sockaddrPtr, &boundLen)
            }
        }
        self.localPort = UInt16(bigEndian: boundAddr.sin_port)

        // Set socket to non-blocking for timeout support
        var flags = fcntl(socket, F_GETFL)
        flags |= O_NONBLOCK
        fcntl(socket, F_SETFL, flags)
    }

    deinit {
        if socket >= 0 {
            #if canImport(Darwin)
            Darwin.close(socket)
            #else
            Glibc.close(socket)
            #endif
        }
    }

    // MARK: - Sending

    /// Send data to an endpoint
    /// - Parameters:
    ///   - data: The data to send
    ///   - endpoint: The destination endpoint
    public func send(_ data: Data, to endpoint: Endpoint) throws {
        guard !isClosed else {
            throw UDPForwarderError.closed
        }

        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = endpoint.port.bigEndian
        destAddr.sin_addr.s_addr = UInt32(endpoint.address.octets.0) |
                                   (UInt32(endpoint.address.octets.1) << 8) |
                                   (UInt32(endpoint.address.octets.2) << 16) |
                                   (UInt32(endpoint.address.octets.3) << 24)

        let result = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(socket, buffer.baseAddress, buffer.count, 0,
                           sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if result < 0 {
            #if canImport(Darwin)
            let err = Darwin.errno
            #else
            let err = Glibc.errno
            #endif
            // EAGAIN/EWOULDBLOCK is okay for non-blocking socket
            if err != EAGAIN && err != EWOULDBLOCK {
                throw UDPForwarderError.sendFailed(err)
            }
        }
    }

    // MARK: - Receiving

    /// Receive data with timeout
    /// - Parameter timeout: Maximum time to wait in seconds
    /// - Returns: Tuple of received data and source endpoint
    public func receive(timeout: TimeInterval) throws -> (data: Data, from: Endpoint) {
        guard !isClosed else {
            throw UDPForwarderError.closed
        }

        // Use select() for timeout
        var readSet = fd_set()
        fdZero(&readSet)
        fdSet(socket, &readSet)

        var tv = timeval()
        tv.tv_sec = Int(timeout)
        #if canImport(Darwin)
        tv.tv_usec = Int32((timeout - Double(Int(timeout))) * 1_000_000)
        #else
        tv.tv_usec = Int((timeout - Double(Int(timeout))) * 1_000_000)
        #endif

        let selectResult = select(socket + 1, &readSet, nil, nil, &tv)

        if selectResult == 0 {
            throw UDPForwarderError.receiveTimeout
        } else if selectResult < 0 {
            #if canImport(Darwin)
            throw UDPForwarderError.receiveFailed(Darwin.errno)
            #else
            throw UDPForwarderError.receiveFailed(Glibc.errno)
            #endif
        }

        // Data is available, read it
        var buffer = [UInt8](repeating: 0, count: 65536)
        var srcAddr = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bytesRead = withUnsafeMutablePointer(to: &srcAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                recvfrom(socket, &buffer, buffer.count, 0, sockaddrPtr, &srcLen)
            }
        }

        if bytesRead < 0 {
            #if canImport(Darwin)
            throw UDPForwarderError.receiveFailed(Darwin.errno)
            #else
            throw UDPForwarderError.receiveFailed(Glibc.errno)
            #endif
        }

        let data = Data(buffer[0..<bytesRead])

        // Extract source endpoint
        let addrBytes = withUnsafeBytes(of: srcAddr.sin_addr.s_addr) { Array($0) }
        let srcIP = IPv4Address(addrBytes[0], addrBytes[1], addrBytes[2], addrBytes[3])
        let srcPort = UInt16(bigEndian: srcAddr.sin_port)

        return (data, Endpoint(address: srcIP, port: srcPort))
    }

    // MARK: - Cleanup

    /// Close the forwarder and release resources
    public func close() {
        guard !isClosed else { return }
        isClosed = true

        if socket >= 0 {
            #if canImport(Darwin)
            Darwin.close(socket)
            #else
            Glibc.close(socket)
            #endif
            socket = -1
        }
    }
}

// MARK: - fd_set helpers

// These are needed because Swift doesn't have direct access to FD_ZERO, FD_SET, etc.

private func fdZero(_ set: inout fd_set) {
    #if canImport(Darwin)
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    #else
    // Linux fd_set has different structure
    withUnsafeMutableBytes(of: &set) { ptr in
        ptr.baseAddress?.initializeMemory(as: UInt8.self, repeating: 0, count: ptr.count)
    }
    #endif
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    #if canImport(Darwin)
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutableBytes(of: &set.fds_bits) { ptr in
        let ints = ptr.bindMemory(to: Int32.self)
        ints[intOffset] |= Int32(1 << bitOffset)
    }
    #else
    // Linux implementation
    let intOffset = Int(fd) / (MemoryLayout<__fd_mask>.size * 8)
    let bitOffset = Int(fd) % (MemoryLayout<__fd_mask>.size * 8)
    withUnsafeMutableBytes(of: &set.__fds_bits) { ptr in
        let masks = ptr.bindMemory(to: __fd_mask.self)
        masks[intOffset] |= __fd_mask(1 << bitOffset)
    }
    #endif
}
