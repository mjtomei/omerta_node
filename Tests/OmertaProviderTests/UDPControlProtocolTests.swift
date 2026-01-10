// UDPControlProtocolTests.swift
// Level 3c: Protocol tests over localhost UDP

import XCTest
import NIOCore
import NIOPosix
@testable import OmertaProvider
@testable import OmertaConsumer
@testable import OmertaCore

/// Tests the UDP control protocol over localhost
/// These tests verify the full request/response cycle without needing VMs or WireGuard
final class UDPControlProtocolTests: XCTestCase {

    var tempDir: URL!
    var testNetworkKey: Data!
    var testNetworkId: String!

    override func setUp() async throws {
        try await super.setUp()

        // Create temp directory
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-protocol-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Generate test network key (32 bytes)
        testNetworkKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        testNetworkId = "test-network"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Message Roundtrip Tests

    func testMessageEnvelopeRoundtrip() throws {
        // Test that message envelope survives serialization
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let envelope = MessageEnvelope(networkId: testNetworkId, encryptedPayload: payload)

        let serialized = envelope.serialize()
        let parsed = MessageEnvelope.parse(serialized)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.networkId, testNetworkId)
        XCTAssertEqual(parsed?.encryptedPayload, payload)
    }

    func testControlMessageRoundtrip() throws {
        // Test that control message survives JSON encoding
        let vmId = UUID()
        let request = VMStatusRequest(vmId: vmId)
        let message = ControlMessage(action: .queryVMStatus(request))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ControlMessage.self, from: data)

        XCTAssertEqual(decoded.messageId, message.messageId)
        if case .queryVMStatus(let decodedRequest) = decoded.action {
            XCTAssertEqual(decodedRequest.vmId, vmId)
        } else {
            XCTFail("Action type mismatch")
        }
    }

    // MARK: - Request/Response Format Tests

    func testVMRequestMessageContainsAllFields() throws {
        let vmId = UUID()
        let requirements = ResourceRequirements(cpuCores: 4, memoryMB: 8192)
        let vpnConfig = VPNConfiguration(
            consumerPublicKey: "testKey123==",
            consumerEndpoint: "192.168.1.100:51820",
            consumerVPNIP: "10.0.0.1",
            vmVPNIP: "10.0.0.2",
            vpnSubnet: "10.0.0.0/24"
        )

        let request = RequestVMMessage(
            vmId: vmId,
            requirements: requirements,
            vpnConfig: vpnConfig,
            consumerEndpoint: "192.168.1.100:51821",
            sshPublicKey: "ssh-ed25519 AAAA...",
            sshUser: "omerta"
        )

        let message = ControlMessage(action: .requestVM(request))

        // Encode and decode to verify all fields serialize
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ControlMessage.self, from: data)

        if case .requestVM(let decodedRequest) = decoded.action {
            XCTAssertEqual(decodedRequest.vmId, vmId)
            XCTAssertEqual(decodedRequest.requirements.cpuCores, 4)
            XCTAssertEqual(decodedRequest.requirements.memoryMB, 8192)
            XCTAssertEqual(decodedRequest.vpnConfig.consumerPublicKey, "testKey123==")
            XCTAssertEqual(decodedRequest.vpnConfig.consumerEndpoint, "192.168.1.100:51820")
            XCTAssertEqual(decodedRequest.sshPublicKey, "ssh-ed25519 AAAA...")
            XCTAssertEqual(decodedRequest.sshUser, "omerta")
        } else {
            XCTFail("Expected requestVM action")
        }
    }

    func testVMCreatedResponseContainsRequiredFields() throws {
        let vmId = UUID()
        let response = VMCreatedResponse(
            vmId: vmId,
            vmIP: "10.0.0.2",
            sshPort: 22,
            providerPublicKey: "providerKey456=="
        )

        // Verify success response
        XCTAssertFalse(response.isError)
        XCTAssertEqual(response.vmIP, "10.0.0.2")
        XCTAssertEqual(response.sshPort, 22)
        XCTAssertEqual(response.providerPublicKey, "providerKey456==")
    }

    func testVMCreatedResponseErrorDetection() throws {
        // Empty vmIP is an error
        let emptyIP = VMCreatedResponse(
            vmId: UUID(),
            vmIP: "",
            providerPublicKey: "key"
        )
        XCTAssertTrue(emptyIP.isError)

        // Empty providerPublicKey is an error
        let emptyKey = VMCreatedResponse(
            vmId: UUID(),
            vmIP: "10.0.0.2",
            providerPublicKey: ""
        )
        XCTAssertTrue(emptyKey.isError)

        // Explicit error message
        let explicitError = VMCreatedResponse(
            vmId: UUID(),
            vmIP: "10.0.0.2",
            providerPublicKey: "key",
            error: "Something went wrong"
        )
        XCTAssertTrue(explicitError.isError)
    }

    // MARK: - Timestamp/Replay Tests

    func testControlMessageHasRecentTimestamp() {
        let message = ControlMessage(action: .queryVMStatus(VMStatusRequest()))

        let now = UInt64(Date().timeIntervalSince1970)
        let diff = abs(Int64(message.timestamp) - Int64(now))

        XCTAssertLessThan(diff, 5, "Timestamp should be within 5 seconds of now")
    }

    func testOldTimestampDetection() {
        // A message with a very old timestamp should be considered stale
        let oldTimestamp = UInt64(Date().timeIntervalSince1970) - 120 // 2 minutes ago
        let message = ControlMessage(
            messageId: UUID(),
            timestamp: oldTimestamp,
            action: .queryVMStatus(VMStatusRequest())
        )

        let now = UInt64(Date().timeIntervalSince1970)
        let diff = abs(Int64(message.timestamp) - Int64(now))

        XCTAssertGreaterThan(diff, 60, "Old message should be detected as stale")
    }

    // MARK: - All Action Types Tests

    func testAllActionTypesSerialize() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let actions: [ControlAction] = [
            .requestVM(RequestVMMessage(
                requirements: ResourceRequirements(),
                vpnConfig: VPNConfiguration(
                    consumerPublicKey: "k",
                    consumerEndpoint: "1.2.3.4:51820",
                    consumerVPNIP: "10.0.0.1",
                    vmVPNIP: "10.0.0.2",
                    vpnSubnet: "10.0.0.0/24"
                ),
                consumerEndpoint: "1.2.3.4:51821",
                sshPublicKey: "ssh-ed25519 AAA..."
            )),
            .releaseVM(ReleaseVMMessage(vmId: UUID())),
            .queryVMStatus(VMStatusRequest(vmId: UUID())),
            .queryVMStatus(VMStatusRequest(vmId: nil)), // Query all
            .vmCreated(VMCreatedResponse(vmId: UUID(), vmIP: "10.0.0.2", providerPublicKey: "k")),
            .vmReleased(VMReleasedResponse(vmId: UUID())),
            .vmStatus(VMStatusResponse(vms: []))
        ]

        for (index, action) in actions.enumerated() {
            let message = ControlMessage(action: action)
            let data = try encoder.encode(message)
            let decoded = try decoder.decode(ControlMessage.self, from: data)

            // Verify action type is preserved
            let originalType = String(describing: type(of: action))
            let decodedType = String(describing: type(of: decoded.action))

            // Check that the enum case matches
            switch (action, decoded.action) {
            case (.requestVM, .requestVM),
                 (.releaseVM, .releaseVM),
                 (.queryVMStatus, .queryVMStatus),
                 (.vmCreated, .vmCreated),
                 (.vmReleased, .vmReleased),
                 (.vmStatus, .vmStatus):
                break // Match
            default:
                XCTFail("Action type mismatch at index \(index): \(originalType) vs \(decodedType)")
            }
        }
    }

    // MARK: - VPN Configuration Tests

    func testVPNConfigurationValidation() {
        // Valid config
        let validConfig = VPNConfiguration(
            consumerPublicKey: "base64Key==",
            consumerEndpoint: "192.168.1.100:51820",
            consumerVPNIP: "10.0.0.1",
            vmVPNIP: "10.0.0.2",
            vpnSubnet: "10.0.0.0/24"
        )

        XCTAssertEqual(validConfig.consumerPublicKey, "base64Key==")
        XCTAssertEqual(validConfig.consumerEndpoint, "192.168.1.100:51820")
        XCTAssertEqual(validConfig.consumerVPNIP, "10.0.0.1")
        XCTAssertEqual(validConfig.vmVPNIP, "10.0.0.2")
        XCTAssertEqual(validConfig.vpnSubnet, "10.0.0.0/24")
    }

    // MARK: - Resource Requirements Tests

    func testResourceRequirementsDefaults() {
        let defaults = ResourceRequirements()

        // All should be nil (use provider defaults)
        XCTAssertNil(defaults.cpuCores)
        XCTAssertNil(defaults.memoryMB)
        XCTAssertNil(defaults.storageMB)
    }

    func testResourceRequirementsCustomValues() {
        let custom = ResourceRequirements(
            cpuCores: 8,
            memoryMB: 16384,
            storageMB: 102400
        )

        XCTAssertEqual(custom.cpuCores, 8)
        XCTAssertEqual(custom.memoryMB, 16384)
        XCTAssertEqual(custom.storageMB, 102400)
    }

    // MARK: - VM Status Tests

    func testVMStatusEnumValues() {
        // Verify all status values
        let statuses: [VMStatus] = [.starting, .running, .stopping, .stopped, .error]

        for status in statuses {
            // Verify raw value
            XCTAssertFalse(status.rawValue.isEmpty)

            // Verify serialization
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try! encoder.encode(status)
            let decoded = try! decoder.decode(VMStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testVMInfoContainsAllFields() throws {
        let vmId = UUID()
        let createdAt = Date()

        let info = VMInfo(
            vmId: vmId,
            status: .running,
            vmIP: "10.0.0.2",
            createdAt: createdAt,
            uptimeSeconds: 3600,
            consoleOutput: "Boot complete"
        )

        XCTAssertEqual(info.vmId, vmId)
        XCTAssertEqual(info.status, .running)
        XCTAssertEqual(info.vmIP, "10.0.0.2")
        XCTAssertEqual(info.uptimeSeconds, 3600)
        XCTAssertEqual(info.consoleOutput, "Boot complete")

        // Verify serialization
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(info)
        let decoded = try decoder.decode(VMInfo.self, from: data)

        XCTAssertEqual(decoded.vmId, vmId)
        XCTAssertEqual(decoded.status, .running)
    }
}

// MARK: - Localhost UDP Tests (requires NIO)

#if canImport(NIOCore)
extension UDPControlProtocolTests {

    /// Test that we can send/receive messages over localhost UDP
    /// This is a simplified test that doesn't use the full UDPControlServer
    func testLocalhostUDPMessageExchange() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        // Create a simple echo server
        let serverPort = 51900 + Int.random(in: 0..<100)
        var receivedData: Data?
        let receivedExpectation = XCTestExpectation(description: "Received message")

        class EchoHandler: ChannelInboundHandler {
            typealias InboundIn = AddressedEnvelope<ByteBuffer>
            typealias OutboundOut = AddressedEnvelope<ByteBuffer>

            var receivedData: Data?
            let expectation: XCTestExpectation

            init(expectation: XCTestExpectation) {
                self.expectation = expectation
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let envelope = unwrapInboundIn(data)
                var buffer = envelope.data
                if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    receivedData = Data(bytes)
                    expectation.fulfill()

                    // Echo back
                    var response = context.channel.allocator.buffer(capacity: bytes.count)
                    response.writeBytes(bytes)
                    let responseEnvelope = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: response)
                    context.writeAndFlush(wrapOutboundOut(responseEnvelope), promise: nil)
                }
            }
        }

        let handler = EchoHandler(expectation: receivedExpectation)

        let serverBootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let serverChannel = try await serverBootstrap.bind(host: "127.0.0.1", port: serverPort).get()
        defer { try? serverChannel.close().wait() }

        // Create client and send message
        let clientBootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let clientChannel = try await clientBootstrap.bind(host: "127.0.0.1", port: 0).get()
        defer { try? clientChannel.close().wait() }

        // Send test message
        let testMessage = "Hello, UDP!"
        var buffer = clientChannel.allocator.buffer(capacity: testMessage.utf8.count)
        buffer.writeString(testMessage)

        let serverAddress = try SocketAddress(ipAddress: "127.0.0.1", port: serverPort)
        let envelope = AddressedEnvelope(remoteAddress: serverAddress, data: buffer)
        try await clientChannel.writeAndFlush(envelope).get()

        // Wait for response
        await fulfillment(of: [receivedExpectation], timeout: 5.0)

        XCTAssertNotNil(handler.receivedData)
        XCTAssertEqual(String(data: handler.receivedData!, encoding: .utf8), testMessage)
    }
}
#endif
