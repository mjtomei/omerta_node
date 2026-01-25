// NetstackBridge.swift - Swift wrapper for Go netstack
//
// This provides a Swift-friendly interface to the Go netstack library,
// which is compiled as a C archive (libnetstack.a).

import Foundation
import CNetstack
import Logging

/// Errors from netstack operations
public enum NetstackError: Error, LocalizedError {
    case initializationFailed
    case notStarted
    case injectionFailed
    case invalidPacket

    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "Failed to initialize netstack"
        case .notStarted:
            return "Netstack not started"
        case .injectionFailed:
            return "Failed to inject packet"
        case .invalidPacket:
            return "Invalid packet data"
        }
    }
}

/// Statistics from netstack
public struct NetstackStats: Sendable {
    public let tcpConnections: UInt32
    public let udpConnections: UInt32
}

/// Swift wrapper for the Go netstack userspace TCP/IP stack
public final class NetstackBridge: @unchecked Sendable {
    /// Handle to the Go netstack instance
    private var handle: UInt64 = 0

    /// Whether the stack is running
    private var isRunning: Bool = false

    /// Callback for returned packets
    private var returnCallback: ((Data) -> Void)?

    /// Lock for thread safety
    private let lock = NSLock()

    /// Logger
    private let logger = Logger(label: "io.omerta.tunnel.netstack")

    /// Configuration for the netstack
    public struct Config {
        /// Gateway IP address (the stack's address)
        public let gatewayIP: String

        /// MTU (default: 1500)
        public let mtu: UInt32

        public init(gatewayIP: String, mtu: UInt32 = 1500) {
            self.gatewayIP = gatewayIP
            self.mtu = mtu
        }
    }

    /// Initialize with configuration
    public init(config: Config) throws {
        let cGatewayIP = config.gatewayIP.withCString { strdup($0) }
        defer { free(cGatewayIP) }

        handle = NetstackCreate(cGatewayIP, config.mtu)
        if handle == 0 {
            throw NetstackError.initializationFailed
        }

        logger.info("Netstack initialized", metadata: [
            "gatewayIP": "\(config.gatewayIP)",
            "mtu": "\(config.mtu)"
        ])
    }

    deinit {
        stop()
    }

    /// Set the callback for returned packets (responses from internet)
    public func setReturnCallback(_ callback: @escaping (Data) -> Void) {
        lock.lock()
        returnCallback = callback
        lock.unlock()

        // Set up the C callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        NetstackSetCallback(handle, netstackReturnPacketCallback, context)
    }

    /// Start processing packets
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let result = NetstackStart(handle)
        if result != 0 {
            throw NetstackError.initializationFailed
        }

        isRunning = true
        logger.info("Netstack started")
    }

    /// Stop processing and clean up
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard handle != 0 else { return }

        NetstackStop(handle)
        handle = 0
        isRunning = false
        returnCallback = nil

        logger.info("Netstack stopped")
    }

    /// Inject a raw IP packet for processing
    public func injectPacket(_ packet: Data) throws {
        lock.lock()
        let running = isRunning
        let h = handle
        lock.unlock()

        guard running, h != 0 else {
            throw NetstackError.notStarted
        }

        guard !packet.isEmpty else {
            throw NetstackError.invalidPacket
        }

        let result = packet.withUnsafeBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return NetstackInjectPacket(h, baseAddress.assumingMemoryBound(to: UInt8.self), buffer.count)
        }

        if result != 0 {
            throw NetstackError.injectionFailed
        }
    }

    /// Get current statistics
    public func getStats() -> NetstackStats? {
        lock.lock()
        let h = handle
        lock.unlock()

        guard h != 0 else { return nil }

        var tcpConns: UInt32 = 0
        var udpConns: UInt32 = 0

        let result = NetstackGetStats(h, &tcpConns, &udpConns)
        if result != 0 {
            return nil
        }

        return NetstackStats(tcpConnections: tcpConns, udpConnections: udpConns)
    }

    /// Called from C when a packet is returned
    fileprivate func handleReturnPacket(_ data: Data) {
        lock.lock()
        let callback = returnCallback
        lock.unlock()

        callback?(data)
    }
}

/// C callback function for returned packets
private func netstackReturnPacketCallback(
    context: UnsafeMutableRawPointer?,
    data: UnsafePointer<UInt8>?,
    length: Int
) {
    guard let context = context,
          let data = data,
          length > 0 else {
        return
    }

    let bridge = Unmanaged<NetstackBridge>.fromOpaque(context).takeUnretainedValue()
    let packetData = Data(bytes: data, count: length)
    bridge.handleReturnPacket(packetData)
}
