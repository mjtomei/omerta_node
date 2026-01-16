// ControlSocket.swift - Unix domain socket for CLI communication with omertad

import Foundation
import Logging
import NIOCore
import NIOPosix
import OmertaMesh

#if canImport(Darwin)
import Darwin
private let systemSend = Darwin.send
private let systemRecv = Darwin.recv
private let SOCK_STREAM_VALUE = SOCK_STREAM
#elseif canImport(Glibc)
import Glibc
private let systemSend = Glibc.send
private let systemRecv = Glibc.recv
private let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
#endif

/// Commands that can be sent to the daemon via control socket
public enum ControlCommand: Codable {
    case ping(peerId: String, timeout: Int)
    case vmRequest(peerId: String, requirements: Data, sshPublicKey: String, sshUser: String, timeoutMinutes: Int)
    case vmRelease(vmId: UUID)
    case vmList
    case status
    case peers
    case shutdown(graceful: Bool, timeoutSeconds: Int)
}

/// Response from the daemon
public enum ControlResponse: Codable {
    case pingResult(PingResultData?)
    case vmRequestResult(VMRequestResultData)
    case vmReleaseResult(success: Bool, error: String?)
    case vmList([VMInfoData])
    case status(StatusData)
    case peers([PeerData])
    case shutdownAck(ShutdownData)
    case error(String)

    public struct PingResultData: Codable {
        public let peerId: String
        public let endpoint: String
        public let latencyMs: Int
        public let sentPeers: [String: String]
        public let receivedPeers: [String: String]
        public let newPeers: [String: String]

        public init(peerId: String, endpoint: String, latencyMs: Int, sentPeers: [String: String], receivedPeers: [String: String], newPeers: [String: String]) {
            self.peerId = peerId
            self.endpoint = endpoint
            self.latencyMs = latencyMs
            self.sentPeers = sentPeers
            self.receivedPeers = receivedPeers
            self.newPeers = newPeers
        }
    }

    public struct VMRequestResultData: Codable {
        public let success: Bool
        public let vmId: UUID?
        public let vmIP: String?
        public let sshCommand: String?
        public let error: String?

        public init(success: Bool, vmId: UUID?, vmIP: String?, sshCommand: String?, error: String?) {
            self.success = success
            self.vmId = vmId
            self.vmIP = vmIP
            self.sshCommand = sshCommand
            self.error = error
        }
    }

    public struct VMInfoData: Codable {
        public let vmId: UUID
        public let providerPeerId: String
        public let vmIP: String
        public let createdAt: Date

        public init(vmId: UUID, providerPeerId: String, vmIP: String, createdAt: Date) {
            self.vmId = vmId
            self.providerPeerId = providerPeerId
            self.vmIP = vmIP
            self.createdAt = createdAt
        }
    }

    public struct StatusData: Codable {
        public let isRunning: Bool
        public let peerId: String
        public let natType: String
        public let publicEndpoint: String?
        public let peerCount: Int
        public let activeVMs: Int
        public let uptime: TimeInterval?

        public init(isRunning: Bool, peerId: String, natType: String, publicEndpoint: String?, peerCount: Int, activeVMs: Int, uptime: TimeInterval?) {
            self.isRunning = isRunning
            self.peerId = peerId
            self.natType = natType
            self.publicEndpoint = publicEndpoint
            self.peerCount = peerCount
            self.activeVMs = activeVMs
            self.uptime = uptime
        }
    }

    public struct PeerData: Codable {
        public let peerId: String
        public let endpoint: String
        public let lastSeen: Date?

        public init(peerId: String, endpoint: String, lastSeen: Date?) {
            self.peerId = peerId
            self.endpoint = endpoint
            self.lastSeen = lastSeen
        }
    }

    public struct ShutdownData: Codable {
        public let accepted: Bool
        public let inFlightRequests: Int
        public let activeVMs: Int
        public let message: String

        public init(accepted: Bool, inFlightRequests: Int, activeVMs: Int, message: String) {
            self.accepted = accepted
            self.inFlightRequests = inFlightRequests
            self.activeVMs = activeVMs
            self.message = message
        }
    }
}

/// Control socket server that runs in omertad
public actor ControlSocketServer {
    private let socketPath: String
    private let networkId: String
    private let logger: Logger
    private var serverChannel: Channel?
    private var eventLoopGroup: EventLoopGroup?

    /// Handler for incoming commands - set by the daemon
    private var commandHandler: ((ControlCommand) async -> ControlResponse)?

    public init(networkId: String) {
        self.networkId = networkId
        self.socketPath = Self.socketPath(forNetwork: networkId)
        self.logger = Logger(label: "io.omerta.control.server")
    }

    /// Set the command handler
    public func setCommandHandler(_ handler: @escaping (ControlCommand) async -> ControlResponse) {
        self.commandHandler = handler
    }

    /// Check if another daemon is already running for this network
    public func checkNoOtherDaemonRunning() throws {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return // No socket file, we're good
        }

        // Try to connect to see if it's a live daemon
        let testSocket = socket(AF_UNIX, SOCK_STREAM_VALUE, 0)
        guard testSocket >= 0 else {
            // Can't create socket, assume it's stale
            try? FileManager.default.removeItem(atPath: socketPath)
            return
        }
        defer { close(testSocket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { cstr in
                strcpy(ptr, cstr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(testSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            // Successfully connected - another daemon IS running
            throw ControlSocketError.anotherDaemonRunning(networkId: networkId)
        }

        // Connection failed - socket is stale, remove it
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Start listening for connections
    public func start() async throws {
        // First check no other daemon is running
        try checkNoOtherDaemonRunning()

        // Remove any stale socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        // Ensure directory exists
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: socketDir,
            withIntermediateDirectories: true
        )

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let handler = self

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(ControlMessageDecoder()),
                    MessageToByteHandler(ControlMessageEncoder()),
                    ControlServerHandler(server: handler)
                ])
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        self.serverChannel = channel

        // Set socket permissions so any user can connect
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: socketPath
        )

        logger.info("Control socket listening at \(socketPath)")
    }

    /// Stop the server
    public func stop() async {
        do {
            try await serverChannel?.close()
            try await eventLoopGroup?.shutdownGracefully()
        } catch {
            logger.warning("Error shutting down control socket: \(error)")
        }

        // Clean up socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        logger.info("Control socket stopped")
    }

    /// Handle incoming command
    func handleCommand(_ command: ControlCommand) async -> ControlResponse {
        guard let handler = commandHandler else {
            return .error("No command handler configured")
        }
        return await handler(command)
    }

    /// Socket path for a specific network
    public static func socketPath(forNetwork networkId: String) -> String {
        return "/tmp/omertad-\(networkId).sock"
    }
}

// MARK: - NIO Handlers

private final class ControlMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = ControlCommand

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Protocol: 4-byte length prefix + JSON data
        guard buffer.readableBytes >= 4 else {
            return .needMoreData
        }

        let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self)!
        guard buffer.readableBytes >= 4 + Int(length) else {
            return .needMoreData
        }

        buffer.moveReaderIndex(forwardBy: 4)
        guard let bytes = buffer.readBytes(length: Int(length)) else {
            throw ControlSocketError.invalidMessage
        }

        let command = try JSONDecoder().decode(ControlCommand.self, from: Data(bytes))
        context.fireChannelRead(wrapInboundOut(command))
        return .continue
    }
}

private final class ControlMessageEncoder: MessageToByteEncoder {
    typealias OutboundIn = ControlResponse

    func encode(data: ControlResponse, out: inout ByteBuffer) throws {
        let jsonData = try JSONEncoder().encode(data)
        out.writeInteger(UInt32(jsonData.count))
        out.writeBytes(Array(jsonData))
    }
}

private final class ControlServerHandler: ChannelInboundHandler {
    typealias InboundIn = ControlCommand
    typealias OutboundOut = ControlResponse

    private let server: ControlSocketServer

    init(server: ControlSocketServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let command = unwrapInboundIn(data)

        // Handle command asynchronously
        let channel = context.channel
        Task {
            let response = await server.handleCommand(command)
            try? await channel.writeAndFlush(response)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Client

/// Control socket client for CLI to communicate with omertad
public actor ControlSocketClient {
    private let socketPath: String
    private let logger: Logger

    public init(networkId: String) {
        self.socketPath = ControlSocketServer.socketPath(forNetwork: networkId)
        self.logger = Logger(label: "io.omerta.control.client")
    }

    public init(socketPath: String) {
        self.socketPath = socketPath
        self.logger = Logger(label: "io.omerta.control.client")
    }

    /// Check if daemon is running (nonisolated for sync calls)
    public nonisolated func isDaemonRunning() -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// Send command and get response
    public func send(_ command: ControlCommand, timeout: TimeInterval = 60) async throws -> ControlResponse {
        guard isDaemonRunning() else {
            throw ControlSocketError.daemonNotRunning
        }

        // Create socket connection
        let socket = socket(AF_UNIX, SOCK_STREAM_VALUE, 0)
        guard socket >= 0 else {
            throw ControlSocketError.connectionFailed
        }
        defer { close(socket) }

        // Connect to socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { cstr in
                strcpy(ptr, cstr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw ControlSocketError.connectionFailed
        }

        // Set timeout
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Send command
        let commandData = try JSONEncoder().encode(command)
        var length = UInt32(commandData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)

        _ = lengthData.withUnsafeBytes { ptr in
            systemSend(socket, ptr.baseAddress!, ptr.count, 0)
        }
        _ = commandData.withUnsafeBytes { ptr in
            systemSend(socket, ptr.baseAddress!, ptr.count, 0)
        }

        // Receive response
        var responseLengthData = Data(count: 4)
        let bytesRead = responseLengthData.withUnsafeMutableBytes { ptr in
            systemRecv(socket, ptr.baseAddress!, 4, 0)
        }
        guard bytesRead == 4 else {
            throw ControlSocketError.invalidResponse
        }

        let responseLength = responseLengthData.withUnsafeBytes { ptr in
            UInt32(bigEndian: ptr.load(as: UInt32.self))
        }

        var responseData = Data(count: Int(responseLength))
        var totalRead = 0
        while totalRead < Int(responseLength) {
            let remaining = Int(responseLength) - totalRead
            let read = responseData.withUnsafeMutableBytes { ptr in
                systemRecv(socket, ptr.baseAddress! + totalRead, remaining, 0)
            }
            guard read > 0 else {
                throw ControlSocketError.invalidResponse
            }
            totalRead += read
        }

        let response = try JSONDecoder().decode(ControlResponse.self, from: responseData)
        return response
    }
}

// MARK: - Errors

public enum ControlSocketError: Error, CustomStringConvertible {
    case daemonNotRunning
    case anotherDaemonRunning(networkId: String)
    case connectionFailed
    case invalidMessage
    case invalidResponse
    case timeout

    public var description: String {
        switch self {
        case .daemonNotRunning:
            return "omertad is not running. Start it with: omertad start --network <id>"
        case .anotherDaemonRunning(let networkId):
            return "Another omertad is already running for network '\(networkId)'"
        case .connectionFailed:
            return "Failed to connect to omertad control socket"
        case .invalidMessage:
            return "Invalid message format"
        case .invalidResponse:
            return "Invalid response from daemon"
        case .timeout:
            return "Request timed out"
        }
    }
}
