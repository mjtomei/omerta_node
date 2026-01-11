// DHTTransport.swift
// UDP transport for DHT protocol
//
// TODO: The current implementation uses blocking recvfrom with a timeout.
// For production use, this should be refactored to use:
// - NIO DatagramChannel for proper async/await integration, or
// - A dedicated thread pool for blocking I/O
//
// The current implementation works but integration tests are disabled
// until the blocking I/O issues are resolved.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Logging

/// UDP transport for DHT protocol messages
public actor DHTTransport {
    private let port: UInt16
    private var socket: Int32 = -1
    private var isRunning = false
    private let logger: Logger
    private var receiveTask: Task<Void, Never>?

    /// Handler for incoming messages
    public var messageHandler: ((DHTPacket, DHTNodeInfo) async -> DHTPacket?)?

    /// The actual bound port
    public private(set) var boundPort: UInt16 = 0

    public init(port: UInt16 = 4000) {
        self.port = port
        self.logger = Logger(label: "io.omerta.dht.transport")
    }

    /// Start the UDP transport
    public func start() throws {
        guard !isRunning else { return }

        // Create UDP socket
        #if canImport(Darwin)
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        #else
        socket = Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif

        guard socket >= 0 else {
            throw DHTTransportError.socketCreationFailed
        }

        // Set socket options for reuse
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Set receive timeout so recvfrom doesn't block indefinitely
        var timeout = timeval(tv_sec: 1, tv_usec: 0) // 1 second timeout
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Bind to port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let err = getErrno()
            closeSocket()
            throw DHTTransportError.bindFailed(err)
        }

        // Get actual bound port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(socket, sockaddrPtr, &addrLen)
            }
        }
        boundPort = UInt16(bigEndian: boundAddr.sin_port)

        isRunning = true
        logger.info("DHT transport started on port \(boundPort)")

        // Start receive loop
        startReceiveLoop()
    }

    /// Stop the UDP transport
    public func stop() {
        guard isRunning else { return }

        isRunning = false
        receiveTask?.cancel()
        receiveTask = nil
        closeSocket()

        logger.info("DHT transport stopped")
    }

    /// Send a packet to a node
    public func send(_ packet: DHTPacket, to node: DHTNodeInfo) throws {
        guard isRunning else { throw DHTTransportError.notRunning }

        let data = try packet.encode()

        // Parse address
        guard let addr = parseAddress(node.address, port: node.port) else {
            throw DHTTransportError.invalidAddress
        }

        var destAddr = addr
        let result = withUnsafePointer(to: &destAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                data.withUnsafeBytes { buffer in
                    sendto(socket, buffer.baseAddress, buffer.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard result >= 0 else {
            throw DHTTransportError.sendFailed(getErrno())
        }

        logger.debug("Sent \(data.count) bytes to \(node.fullAddress)")
    }

    /// Send a request and wait for response
    public func sendRequest(_ packet: DHTPacket, to node: DHTNodeInfo, timeout: TimeInterval = 5.0) async throws -> DHTPacket {
        try send(packet, to: node)

        // Wait for response with matching transaction ID
        return try await withTimeout(timeout) {
            try await self.waitForResponse(transactionId: packet.transactionId)
        }
    }

    // MARK: - Private

    private var pendingResponses: [String: CheckedContinuation<DHTPacket, Error>] = [:]

    private func waitForResponse(transactionId: String) async throws -> DHTPacket {
        try await withCheckedThrowingContinuation { continuation in
            pendingResponses[transactionId] = continuation
        }
    }

    private func startReceiveLoop() {
        let sock = socket // Capture socket before starting task
        receiveTask = Task.detached { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)

            while true {
                guard let self = self else { break }
                guard await self.isRunning else { break }

                var senderAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

                // Blocking receive (with socket timeout set to 1 second)
                let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        recvfrom(sock, &buffer, buffer.count, 0, sockaddrPtr, &addrLen)
                    }
                }

                guard bytesRead > 0 else {
                    // Timeout or error - just continue the loop
                    continue
                }

                let data = Data(buffer.prefix(bytesRead))
                let senderAddress = self.addressToStringSync(senderAddr)
                let senderPort = UInt16(bigEndian: senderAddr.sin_port)

                await self.handleReceivedData(data, from: senderAddress, port: senderPort)
            }
        }
    }

    private nonisolated func addressToStringSync(_ addr: sockaddr_in) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addrCopy = addr.sin_addr
        inet_ntop(AF_INET, &addrCopy, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    private func handleReceivedData(_ data: Data, from address: String, port: UInt16) async {
        do {
            let packet = try DHTPacket.decode(from: data)

            // Check if this is a response to a pending request
            if let continuation = pendingResponses.removeValue(forKey: packet.transactionId) {
                continuation.resume(returning: packet)
                return
            }

            // Otherwise, handle as incoming request
            let sender = DHTNodeInfo(
                peerId: extractPeerId(from: packet.message),
                address: address,
                port: port
            )

            if let handler = messageHandler {
                if let response = await handler(packet, sender) {
                    try? send(response, to: sender)
                }
            }
        } catch {
            logger.warning("Failed to decode DHT packet: \(error)")
        }
    }

    private func extractPeerId(from message: DHTMessage) -> String {
        switch message {
        case .ping(let fromId), .pong(let fromId),
             .findNode(_, let fromId), .foundNodes(_, let fromId),
             .store(_, _, let fromId), .stored(_, let fromId),
             .findValue(_, let fromId), .foundValue(_, let fromId),
             .valueNotFound(_, let fromId), .error(_, let fromId):
            return fromId
        }
    }

    private func parseAddress(_ address: String, port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else {
            return nil
        }

        return addr
    }

    private func closeSocket() {
        if socket >= 0 {
            #if canImport(Darwin)
            Darwin.close(socket)
            #else
            Glibc.close(socket)
            #endif
            socket = -1
        }
    }

    private func getErrno() -> Int32 {
        #if canImport(Darwin)
        return Darwin.errno
        #else
        return Glibc.errno
        #endif
    }
}

/// DHT transport errors
public enum DHTTransportError: Error, Sendable {
    case socketCreationFailed
    case bindFailed(Int32)
    case sendFailed(Int32)
    case notRunning
    case invalidAddress
    case timeout
}

/// Helper for timeout
private func withTimeout<T: Sendable>(_ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw DHTTransportError.timeout
        }

        guard let result = try await group.next() else {
            throw DHTTransportError.timeout
        }

        group.cancelAll()
        return result
    }
}
