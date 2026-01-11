// Phase2Tests.swift - Tests for NAT detection (Phase 2)

import XCTest
import NIOCore
import NIOPosix
@testable import OmertaMesh

final class Phase2Tests: XCTestCase {

    // MARK: - STUN Message Tests

    /// Test STUN binding request encoding
    func testBindingRequestEncoding() throws {
        let request = STUNMessage.bindingRequest()

        let data = request.encode()

        // Minimum STUN header is 20 bytes
        XCTAssertGreaterThanOrEqual(data.count, 20)

        // Check message type (0x0001 = Binding Request)
        XCTAssertEqual(data[0], 0x00)
        XCTAssertEqual(data[1], 0x01)

        // Check magic cookie
        XCTAssertEqual(data[4], 0x21)
        XCTAssertEqual(data[5], 0x12)
        XCTAssertEqual(data[6], 0xA4)
        XCTAssertEqual(data[7], 0x42)

        // Transaction ID should be 12 bytes
        XCTAssertEqual(request.transactionId.count, 12)
    }

    /// Test STUN binding response decoding
    func testBindingResponseDecoding() throws {
        // Create a mock binding response with XOR-MAPPED-ADDRESS
        // Response for 192.0.2.1:32853
        let response = createMockSTUNResponse(
            transactionId: Data(repeating: 0xAB, count: 12),
            publicIP: "192.0.2.1",
            publicPort: 32853
        )

        let message = try STUNMessage.decode(from: response)

        XCTAssertEqual(message.type, .bindingResponse)
        XCTAssertEqual(message.transactionId, Data(repeating: 0xAB, count: 12))

        let mapped = message.xorMappedAddress
        XCTAssertNotNil(mapped)
        XCTAssertEqual(mapped?.host, "192.0.2.1")
        XCTAssertEqual(mapped?.port, 32853)
    }

    /// Test XOR-MAPPED-ADDRESS decoding with different values
    func testXorMappedAddressDecoding() throws {
        // Test with 8.8.8.8:12345
        let response = createMockSTUNResponse(
            transactionId: STUNMessage.generateTransactionId(),
            publicIP: "8.8.8.8",
            publicPort: 12345
        )

        let message = try STUNMessage.decode(from: response)
        let mapped = message.xorMappedAddress

        XCTAssertNotNil(mapped)
        XCTAssertEqual(mapped?.host, "8.8.8.8")
        XCTAssertEqual(mapped?.port, 12345)
    }

    /// Test CHANGE-REQUEST encoding
    func testChangeRequestEncoding() throws {
        let request = STUNMessage.bindingRequest(changeIP: true, changePort: true)
        let data = request.encode()

        // Should include CHANGE-REQUEST attribute
        XCTAssertGreaterThan(data.count, 20)

        // Find CHANGE-REQUEST attribute (type 0x0003)
        var found = false
        var offset = 20
        while offset + 4 <= data.count {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            if attrType == 0x0003 {
                found = true
                // Check flags (0x06 = both change IP and change port)
                let flags = UInt32(data[offset + 4]) << 24 | UInt32(data[offset + 5]) << 16 |
                           UInt32(data[offset + 6]) << 8 | UInt32(data[offset + 7])
                XCTAssertEqual(flags, 0x00000006)
                break
            }
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4 + ((attrLength + 3) & ~3)
        }
        XCTAssertTrue(found, "CHANGE-REQUEST attribute not found")
    }

    /// Test transaction ID generation is random
    func testTransactionIdGeneration() {
        let id1 = STUNMessage.generateTransactionId()
        let id2 = STUNMessage.generateTransactionId()

        XCTAssertEqual(id1.count, 12)
        XCTAssertEqual(id2.count, 12)
        XCTAssertNotEqual(id1, id2, "Transaction IDs should be unique")
    }

    // MARK: - Mock STUN Server Tests

    /// Test endpoint discovery with mock server
    func testMockSTUNEndpointDiscovery() async throws {
        let mockServer = MockSTUNServer()
        try await mockServer.start(port: 0)
        let serverPort = await mockServer.port!

        defer {
            Task { await mockServer.stop() }
        }

        // Configure response
        await mockServer.setResponse(publicIP: "203.0.113.5", publicPort: 54321)

        let client = STUNClient()
        let result = try await client.discoverEndpoint(
            server: "127.0.0.1:\(serverPort)",
            timeout: 5.0
        )

        XCTAssertEqual(result.publicAddress, "203.0.113.5")
        XCTAssertEqual(result.publicPort, 54321)
        XCTAssertGreaterThan(result.rtt, 0)
    }

    /// Test NAT detection with consistent mapping (cone NAT)
    func testMockConeNATDetection() async throws {
        // Two mock servers returning same mapping = cone NAT
        let server1 = MockSTUNServer()
        let server2 = MockSTUNServer()

        try await server1.start(port: 0)
        try await server2.start(port: 0)
        let port1 = await server1.port!
        let port2 = await server2.port!

        defer {
            Task {
                await server1.stop()
                await server2.stop()
            }
        }

        // Both servers return same mapping
        await server1.setResponse(publicIP: "198.51.100.10", publicPort: 40000)
        await server2.setResponse(publicIP: "198.51.100.10", publicPort: 40000)

        let detector = NATDetector(stunServers: [
            "127.0.0.1:\(port1)",
            "127.0.0.1:\(port2)"
        ])

        let result = try await detector.detect(timeout: 5.0)

        XCTAssertEqual(result.type, .portRestrictedCone)
        XCTAssertEqual(result.publicAddress, "198.51.100.10")
        XCTAssertEqual(result.publicPort, 40000)
    }

    /// Test NAT detection with different port mappings (symmetric NAT)
    func testMockSymmetricNATDetection() async throws {
        let server1 = MockSTUNServer()
        let server2 = MockSTUNServer()

        try await server1.start(port: 0)
        try await server2.start(port: 0)
        let port1 = await server1.port!
        let port2 = await server2.port!

        defer {
            Task {
                await server1.stop()
                await server2.stop()
            }
        }

        // Servers return different ports = symmetric NAT
        await server1.setResponse(publicIP: "198.51.100.10", publicPort: 40000)
        await server2.setResponse(publicIP: "198.51.100.10", publicPort: 40001)

        let detector = NATDetector(stunServers: [
            "127.0.0.1:\(port1)",
            "127.0.0.1:\(port2)"
        ])

        let result = try await detector.detect(timeout: 5.0)

        XCTAssertEqual(result.type, .symmetric)
    }

    /// Test quick endpoint discovery
    func testQuickEndpointDiscovery() async throws {
        let mockServer = MockSTUNServer()
        try await mockServer.start(port: 0)
        let serverPort = await mockServer.port!

        defer {
            Task { await mockServer.stop() }
        }

        await mockServer.setResponse(publicIP: "192.0.2.50", publicPort: 55555)

        let detector = NATDetector(stunServers: ["127.0.0.1:\(serverPort)"])
        let result = try await detector.discoverEndpoint(timeout: 5.0)

        XCTAssertEqual(result.publicEndpoint, "192.0.2.50:55555")
        XCTAssertEqual(result.type, .unknown) // Quick discovery doesn't detect type
    }

    // MARK: - NATType Tests

    /// Test NATType properties
    func testNATTypeProperties() {
        // Hole punchable types
        XCTAssertTrue(NATType.public.holePunchable)
        XCTAssertTrue(NATType.fullCone.holePunchable)
        XCTAssertTrue(NATType.restrictedCone.holePunchable)
        XCTAssertTrue(NATType.portRestrictedCone.holePunchable)
        XCTAssertFalse(NATType.symmetric.holePunchable)
        XCTAssertFalse(NATType.unknown.holePunchable)

        // Can relay
        XCTAssertTrue(NATType.public.canRelay)
        XCTAssertTrue(NATType.fullCone.canRelay)
        XCTAssertFalse(NATType.restrictedCone.canRelay)
        XCTAssertFalse(NATType.symmetric.canRelay)
    }

    /// Test NATType encoding
    func testNATTypeCodable() throws {
        let types: [NATType] = [.public, .fullCone, .restrictedCone, .portRestrictedCone, .symmetric, .unknown]

        for type in types {
            let encoded = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(NATType.self, from: encoded)
            XCTAssertEqual(type, decoded)
        }
    }

    /// Test NATDetectionResult
    func testNATDetectionResult() {
        let result = NATDetectionResult(
            type: .portRestrictedCone,
            publicEndpoint: "203.0.113.1:12345",
            publicAddress: "203.0.113.1",
            publicPort: 12345,
            localPort: 50000,
            rtt: 0.025
        )

        XCTAssertEqual(result.type, .portRestrictedCone)
        XCTAssertEqual(result.publicEndpoint, "203.0.113.1:12345")
        XCTAssertEqual(result.publicAddress, "203.0.113.1")
        XCTAssertEqual(result.publicPort, 12345)
        XCTAssertEqual(result.localPort, 50000)
        XCTAssertEqual(result.rtt, 0.025, accuracy: 0.001)
    }

    // MARK: - Error Handling Tests

    /// Test timeout handling
    func testSTUNTimeout() async throws {
        let client = STUNClient()

        // Connect to a port that won't respond
        do {
            _ = try await client.discoverEndpoint(
                server: "127.0.0.1:59998",
                timeout: 0.5
            )
            XCTFail("Should have timed out")
        } catch let error as STUNError {
            if case .timeout = error {
                // Expected
            } else {
                XCTFail("Expected timeout error, got \(error)")
            }
        }
    }

    /// Test invalid server address
    func testInvalidServerAddress() async throws {
        let client = STUNClient()

        do {
            _ = try await client.discoverEndpoint(server: "not-a-valid-address")
            XCTFail("Should have thrown")
        } catch let error as STUNError {
            if case .invalidServerAddress = error {
                // Expected
            } else {
                XCTFail("Expected invalid server address error, got \(error)")
            }
        }
    }

    /// Test insufficient servers for NAT detection
    func testInsufficientServers() async throws {
        let detector = NATDetector(stunServers: ["only.one.server:19302"])

        do {
            _ = try await detector.detect()
            XCTFail("Should have thrown")
        } catch let error as NATDetectorError {
            if case .insufficientServers = error {
                // Expected
            } else {
                XCTFail("Expected insufficient servers error, got \(error)")
            }
        }
    }

    // MARK: - Real STUN Server Test (Requires Internet)

    /// Test with real Google STUN servers
    /// This test requires internet connectivity
    func testRealSTUNDetection() async throws {
        // Skip in CI environments or if no network
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Skipping network test in CI")
        }

        let detector = NATDetector(stunServers: [
            "stun.l.google.com:19302",
            "stun1.l.google.com:19302"
        ])

        do {
            let result = try await detector.detect(timeout: 5.0)

            // We should get some result
            XCTAssertNotEqual(result.type, .unknown)
            XCTAssertNotNil(result.publicEndpoint)
            XCTAssertNotNil(result.publicAddress)
            XCTAssertNotNil(result.publicPort)
            XCTAssertGreaterThan(result.rtt, 0)

            print("Real STUN detection result:")
            print("  Type: \(result.type)")
            print("  Public endpoint: \(result.publicEndpoint ?? "nil")")
            print("  RTT: \(String(format: "%.3f", result.rtt))s")
        } catch let error as STUNError {
            if case .timeout = error {
                throw XCTSkip("Network not available or STUN servers unreachable")
            }
            throw error
        }
    }

    // MARK: - Helper Methods

    /// Create a mock STUN binding response
    private func createMockSTUNResponse(transactionId: Data, publicIP: String, publicPort: UInt16) -> Data {
        var data = Data()

        // Message type: Binding Response (0x0101)
        data.append(contentsOf: [0x01, 0x01])

        // Message length (will be set after attributes)
        let attrData = createXorMappedAddressAttribute(ip: publicIP, port: publicPort)
        let length = UInt16(attrData.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))

        // Magic cookie
        data.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])

        // Transaction ID
        data.append(transactionId)

        // Attributes
        data.append(attrData)

        return data
    }

    /// Create XOR-MAPPED-ADDRESS attribute
    private func createXorMappedAddressAttribute(ip: String, port: UInt16) -> Data {
        var data = Data()

        // Attribute type: XOR-MAPPED-ADDRESS (0x0020)
        data.append(contentsOf: [0x00, 0x20])

        // Attribute length: 8 bytes for IPv4
        data.append(contentsOf: [0x00, 0x08])

        // Reserved byte
        data.append(0x00)

        // Family: IPv4 (0x01)
        data.append(0x01)

        // XOR'd port
        let xorPort = port ^ UInt16(0x2112)
        data.append(UInt8(xorPort >> 8))
        data.append(UInt8(xorPort & 0xFF))

        // XOR'd address
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return data }

        let addr = UInt32(parts[0]) << 24 | UInt32(parts[1]) << 16 |
                   UInt32(parts[2]) << 8 | UInt32(parts[3])
        let xorAddr = addr ^ 0x2112A442

        data.append(UInt8((xorAddr >> 24) & 0xFF))
        data.append(UInt8((xorAddr >> 16) & 0xFF))
        data.append(UInt8((xorAddr >> 8) & 0xFF))
        data.append(UInt8(xorAddr & 0xFF))

        return data
    }
}

// MARK: - Mock STUN Server

/// Thread-safe storage for mock STUN response config
final class MockSTUNConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var _responseIP: String = "192.0.2.1"
    private var _responsePort: UInt16 = 12345

    var responseIP: String {
        lock.lock()
        defer { lock.unlock() }
        return _responseIP
    }

    var responsePort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return _responsePort
    }

    func setResponse(publicIP: String, publicPort: UInt16) {
        lock.lock()
        _responseIP = publicIP
        _responsePort = publicPort
        lock.unlock()
    }

    func createResponse(transactionId: Data) -> Data {
        lock.lock()
        let ip = _responseIP
        let port = _responsePort
        lock.unlock()

        var data = Data()

        // Message type: Binding Response (0x0101)
        data.append(contentsOf: [0x01, 0x01])

        // Message length
        let attrData = createXorMappedAddress(ip: ip, port: port)
        let length = UInt16(attrData.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))

        // Magic cookie
        data.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])

        // Transaction ID
        data.append(transactionId)

        // Attributes
        data.append(attrData)

        return data
    }

    private func createXorMappedAddress(ip: String, port: UInt16) -> Data {
        var data = Data()

        // Attribute type: XOR-MAPPED-ADDRESS (0x0020)
        data.append(contentsOf: [0x00, 0x20])

        // Attribute length: 8 bytes for IPv4
        data.append(contentsOf: [0x00, 0x08])

        // Reserved byte
        data.append(0x00)

        // Family: IPv4 (0x01)
        data.append(0x01)

        // XOR'd port
        let xorPort = port ^ UInt16(0x2112)
        data.append(UInt8(xorPort >> 8))
        data.append(UInt8(xorPort & 0xFF))

        // XOR'd address
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return data }

        let addr = UInt32(parts[0]) << 24 | UInt32(parts[1]) << 16 |
                   UInt32(parts[2]) << 8 | UInt32(parts[3])
        let xorAddr = addr ^ 0x2112A442

        data.append(UInt8((xorAddr >> 24) & 0xFF))
        data.append(UInt8((xorAddr >> 16) & 0xFF))
        data.append(UInt8((xorAddr >> 8) & 0xFF))
        data.append(UInt8(xorAddr & 0xFF))

        return data
    }
}

/// Mock STUN server for testing
actor MockSTUNServer {
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    let config = MockSTUNConfig()

    var port: Int? {
        channel?.localAddress?.port
    }

    func setResponse(publicIP: String, publicPort: UInt16) {
        config.setResponse(publicIP: publicIP, publicPort: publicPort)
    }

    func start(port: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let cfg = self.config

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(MockSTUNHandler(config: cfg))
            }

        self.channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
    }

    func stop() async {
        try? channel?.close().wait()
        try? eventLoopGroup?.syncShutdownGracefully()
        channel = nil
        eventLoopGroup = nil
    }
}

/// Handler for mock STUN server
private final class MockSTUNHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let config: MockSTUNConfig

    init(config: MockSTUNConfig) {
        self.config = config
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
              bytes.count >= 20 else {
            return
        }

        // Extract transaction ID
        let transactionId = Data(bytes[8..<20])

        // Create response synchronously (no actor involved)
        let response = config.createResponse(transactionId: transactionId)

        var responseBuffer = context.channel.allocator.buffer(capacity: response.count)
        responseBuffer.writeBytes(response)

        let responseEnvelope = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: responseBuffer)
        context.writeAndFlush(self.wrapOutboundOut(responseEnvelope), promise: nil)
    }
}
