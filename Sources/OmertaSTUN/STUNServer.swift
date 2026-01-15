// STUNServer.swift
// STUN server for NAT type detection (RFC 5389 subset)

import Foundation
import NIOCore
import NIOPosix
import Logging

/// STUN message types (subset of RFC 5389)
private enum STUNMessageType: UInt16 {
    case bindingRequest = 0x0001
    case bindingResponse = 0x0101
    case bindingErrorResponse = 0x0111
}

/// STUN attribute types
private enum STUNAttributeType: UInt16 {
    case mappedAddress = 0x0001
    case xorMappedAddress = 0x0020
    case software = 0x8022
    case fingerprint = 0x8028
}

/// STUN server for endpoint discovery
public actor STUNServer {
    private let port: UInt16
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    private let logger: Logger

    /// Magic cookie for STUN (RFC 5389)
    private static let magicCookie: UInt32 = 0x2112A442

    public init(port: UInt16 = 3478) {
        self.port = port
        self.logger = Logger(label: "io.omerta.stun")
    }

    /// Start the STUN server
    public func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let handler = STUNHandler(server: self)

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        do {
            let chan = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
            self.channel = chan
            logger.info("STUN server started", metadata: ["port": "\(port)"])
        } catch {
            try? await group.shutdownGracefully()
            self.eventLoopGroup = nil
            throw error
        }
    }

    /// Stop the STUN server
    public func stop() async {
        if let channel = channel {
            try? await channel.close()
        }
        channel = nil

        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil

        logger.info("STUN server stopped")
    }

    /// Handle a STUN binding request and return response
    func handleBindingRequest(from remoteAddress: SocketAddress, data: Data, transactionId: Data) -> Data {
        // Build STUN binding response
        var response = Data()

        // Message type: Binding Response (0x0101)
        response.append(contentsOf: [0x01, 0x01])

        // Message length (will be filled later)
        let lengthOffset = response.count
        response.append(contentsOf: [0x00, 0x00])

        // Magic cookie
        response.append(contentsOf: withUnsafeBytes(of: Self.magicCookie.bigEndian) { Array($0) })

        // Transaction ID (12 bytes from request)
        response.append(transactionId)

        // XOR-MAPPED-ADDRESS attribute
        if let xorMapped = encodeXORMappedAddress(remoteAddress, transactionId: transactionId) {
            response.append(xorMapped)
        }

        // SOFTWARE attribute
        let software = encodeSoftwareAttribute("Omerta STUN 1.0")
        response.append(software)

        // Update message length (excluding 20-byte header)
        let messageLength = UInt16(response.count - 20)
        response[lengthOffset] = UInt8(messageLength >> 8)
        response[lengthOffset + 1] = UInt8(messageLength & 0xFF)

        logger.debug("STUN binding response", metadata: [
            "remoteAddress": "\(remoteAddress)"
        ])

        return response
    }

    /// Parse a STUN message and extract transaction ID
    func parseSTUNMessage(_ data: Data) -> (type: UInt16, transactionId: Data)? {
        guard data.count >= 20 else { return nil }

        // Check magic cookie
        let cookie = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
        guard cookie == Self.magicCookie else { return nil }

        let messageType = UInt16(data[0]) << 8 | UInt16(data[1])
        let transactionId = data[8..<20]

        return (messageType, Data(transactionId))
    }

    // MARK: - Attribute Encoding

    private func encodeXORMappedAddress(_ address: SocketAddress, transactionId: Data) -> Data? {
        var attribute = Data()

        // Attribute type: XOR-MAPPED-ADDRESS
        attribute.append(contentsOf: [0x00, 0x20])

        // Get port from SocketAddress
        guard let addressPort = address.port else { return nil }

        switch address {
        case .v4(let addr):
            // Length: 8 bytes (1 reserved + 1 family + 2 port + 4 address)
            attribute.append(contentsOf: [0x00, 0x08])

            // Reserved byte
            attribute.append(0x00)

            // Family: IPv4 (0x01)
            attribute.append(0x01)

            // XOR'd port (port XOR upper 16 bits of magic cookie)
            let port = UInt16(addressPort)
            let xorPort = port ^ UInt16(Self.magicCookie >> 16)
            attribute.append(contentsOf: withUnsafeBytes(of: xorPort.bigEndian) { Array($0) })

            // XOR'd address (address XOR magic cookie)
            let ipParts = addr.host.split(separator: ".").compactMap { UInt8($0) }
            guard ipParts.count == 4 else { return nil }

            let ipAddr = UInt32(ipParts[0]) << 24 | UInt32(ipParts[1]) << 16 | UInt32(ipParts[2]) << 8 | UInt32(ipParts[3])
            let xorAddr = ipAddr ^ Self.magicCookie
            attribute.append(contentsOf: withUnsafeBytes(of: xorAddr.bigEndian) { Array($0) })

        case .v6:
            // Length: 20 bytes (1 reserved + 1 family + 2 port + 16 address)
            attribute.append(contentsOf: [0x00, 0x14])

            // Reserved byte
            attribute.append(0x00)

            // Family: IPv6 (0x02)
            attribute.append(0x02)

            // XOR'd port
            let port = UInt16(addressPort)
            let xorPort = port ^ UInt16(Self.magicCookie >> 16)
            attribute.append(contentsOf: withUnsafeBytes(of: xorPort.bigEndian) { Array($0) })

            // XOR'd IPv6 address (XOR with magic cookie + transaction ID)
            // For simplicity, just return nil for IPv6 for now
            return nil

        default:
            return nil
        }

        return attribute
    }

    private func encodeSoftwareAttribute(_ software: String) -> Data {
        var attribute = Data()

        // Attribute type: SOFTWARE
        attribute.append(contentsOf: [0x80, 0x22])

        let softwareData = software.data(using: .utf8) ?? Data()
        let paddedLength = (softwareData.count + 3) & ~3 // Pad to 4-byte boundary

        // Length
        attribute.append(contentsOf: withUnsafeBytes(of: UInt16(softwareData.count).bigEndian) { Array($0) })

        // Value
        attribute.append(softwareData)

        // Padding
        let padding = paddedLength - softwareData.count
        if padding > 0 {
            attribute.append(contentsOf: [UInt8](repeating: 0, count: padding))
        }

        return attribute
    }
}

// MARK: - STUN Channel Handler

private final class STUNHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let server: STUNServer

    init(server: STUNServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let remoteAddress = envelope.remoteAddress

        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        let requestData = Data(bytes)

        Task {
            // Parse STUN message
            guard let (messageType, transactionId) = await server.parseSTUNMessage(requestData) else {
                return
            }

            // Only handle binding requests
            guard messageType == STUNMessageType.bindingRequest.rawValue else {
                return
            }

            // Generate response
            let responseData = await server.handleBindingRequest(
                from: remoteAddress,
                data: requestData,
                transactionId: transactionId
            )

            // Send response - must allocate buffer on event loop
            context.eventLoop.execute {
                var responseBuffer = context.channel.allocator.buffer(capacity: responseData.count)
                responseBuffer.writeBytes(responseData)
                let responseEnvelope = AddressedEnvelope(remoteAddress: remoteAddress, data: responseBuffer)
                context.writeAndFlush(self.wrapOutboundOut(responseEnvelope), promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log but don't close - UDP is connectionless
        print("STUN server error: \(error)")
    }
}

// MARK: - STUN Client Utilities

public extension STUNServer {
    /// Parse a STUN binding response to extract the mapped address
    static func parseMappedAddress(from data: Data) -> (host: String, port: UInt16)? {
        guard data.count >= 20 else { return nil }

        // Verify message type is binding response
        let messageType = UInt16(data[0]) << 8 | UInt16(data[1])
        guard messageType == STUNMessageType.bindingResponse.rawValue else { return nil }

        // Get message length
        let messageLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        guard data.count >= 20 + messageLength else { return nil }

        // Parse attributes
        var offset = 20
        while offset + 4 <= 20 + messageLength {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))

            if attrType == STUNAttributeType.xorMappedAddress.rawValue {
                guard offset + 4 + attrLength <= data.count else { break }

                let family = data[offset + 5]

                if family == 0x01 { // IPv4
                    let xorPort = UInt16(data[offset + 6]) << 8 | UInt16(data[offset + 7])
                    let port = xorPort ^ UInt16(magicCookie >> 16)

                    let xorAddr = UInt32(data[offset + 8]) << 24 | UInt32(data[offset + 9]) << 16 |
                                  UInt32(data[offset + 10]) << 8 | UInt32(data[offset + 11])
                    let addr = xorAddr ^ magicCookie

                    let host = "\(addr >> 24).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
                    return (host, port)
                }
            }

            // Move to next attribute (with padding to 4-byte boundary)
            offset += 4 + ((attrLength + 3) & ~3)
        }

        return nil
    }

    /// Create a STUN binding request
    static func createBindingRequest() -> Data {
        var request = Data()

        // Message type: Binding Request
        request.append(contentsOf: [0x00, 0x01])

        // Message length: 0 (no attributes)
        request.append(contentsOf: [0x00, 0x00])

        // Magic cookie
        request.append(contentsOf: withUnsafeBytes(of: magicCookie.bigEndian) { Array($0) })

        // Transaction ID (12 random bytes)
        var transactionId = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 {
            transactionId[i] = UInt8.random(in: 0...255)
        }
        request.append(contentsOf: transactionId)

        return request
    }
}
