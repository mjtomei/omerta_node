import XCTest
@testable import OmertaNetwork

final class FramePacketBridgeTests: XCTestCase {

    // MARK: - Test Data

    static let vmMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
    static let gatewayMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0xFF])
    static let vmIP = IPv4Address(192, 168, 64, 2)
    static let consumerIP = IPv4Address(203, 0, 113, 50)

    /// Build a test ethernet frame with IPv4 packet inside
    static func makeIPv4Frame(
        srcMAC: Data = vmMAC,
        dstMAC: Data = gatewayMAC,
        srcIP: IPv4Address = vmIP,
        dstIP: IPv4Address = consumerIP,
        srcPort: UInt16 = 12345,
        dstPort: UInt16 = 51900,
        udpPayload: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])
    ) -> Data {
        // Build UDP header + payload
        let udpLength = UInt16(8 + udpPayload.count)
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8)
        udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8)
        udp[3] = UInt8(dstPort & 0xFF)
        udp[4] = UInt8(udpLength >> 8)
        udp[5] = UInt8(udpLength & 0xFF)
        udp[6] = 0x00  // Checksum
        udp[7] = 0x00
        udp.append(udpPayload)

        // Build IPv4 header (20 bytes, no options)
        let totalLength = UInt16(20 + udp.count)
        var ip = Data(count: 20)
        ip[0] = 0x45  // Version 4, IHL 5
        ip[1] = 0x00  // DSCP/ECN
        ip[2] = UInt8(totalLength >> 8)
        ip[3] = UInt8(totalLength & 0xFF)
        ip[4] = 0x00; ip[5] = 0x01  // ID
        ip[6] = 0x00; ip[7] = 0x00  // Flags/Fragment
        ip[8] = 64    // TTL
        ip[9] = 17    // UDP
        ip[10] = 0x00; ip[11] = 0x00  // Checksum
        ip[12] = srcIP.octets.0
        ip[13] = srcIP.octets.1
        ip[14] = srcIP.octets.2
        ip[15] = srcIP.octets.3
        ip[16] = dstIP.octets.0
        ip[17] = dstIP.octets.1
        ip[18] = dstIP.octets.2
        ip[19] = dstIP.octets.3
        ip.append(udp)

        // Build ethernet frame
        var frame = Data()
        frame.append(dstMAC)
        frame.append(srcMAC)
        frame.append(0x08)  // EtherType IPv4
        frame.append(0x00)
        frame.append(ip)

        return frame
    }

    /// Build a test ARP frame
    static func makeARPFrame(
        srcMAC: Data = vmMAC,
        dstMAC: Data = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    ) -> Data {
        var frame = Data()
        frame.append(dstMAC)
        frame.append(srcMAC)
        frame.append(0x08)  // EtherType ARP
        frame.append(0x06)
        // Minimal ARP payload
        frame.append(Data(repeating: 0x00, count: 28))
        return frame
    }

    /// Build a test IPv6 frame
    static func makeIPv6Frame(srcMAC: Data = vmMAC) -> Data {
        var frame = Data()
        frame.append(Data([0x33, 0x33, 0x00, 0x00, 0x00, 0x01]))  // IPv6 multicast
        frame.append(srcMAC)
        frame.append(0x86)  // EtherType IPv6
        frame.append(0xDD)
        // Minimal IPv6 payload
        frame.append(Data(repeating: 0x00, count: 40))
        return frame
    }

    // MARK: - Frame Processing Tests

    func testExtractIPv4PacketFromFrame() {
        let frameData = Self.makeIPv4Frame()
        var bridge = FramePacketBridge()

        guard let frame = EthernetFrame(frameData) else {
            XCTFail("Should parse ethernet frame")
            return
        }

        let packet = bridge.processFrame(frame)

        XCTAssertNotNil(packet, "Should extract IPv4 packet from frame")
        XCTAssertEqual(packet?.sourceAddress, Self.vmIP)
        XCTAssertEqual(packet?.destinationAddress, Self.consumerIP)
        XCTAssertEqual(packet?.destinationPort, 51900)
    }

    func testIgnoreARPFrame() {
        let frameData = Self.makeARPFrame()
        var bridge = FramePacketBridge()

        guard let frame = EthernetFrame(frameData) else {
            XCTFail("Should parse ARP frame")
            return
        }

        let packet = bridge.processFrame(frame)

        XCTAssertNil(packet, "Should ignore ARP frames")
    }

    func testIgnoreIPv6Frame() {
        let frameData = Self.makeIPv6Frame()
        var bridge = FramePacketBridge()

        guard let frame = EthernetFrame(frameData) else {
            XCTFail("Should parse IPv6 frame")
            return
        }

        let packet = bridge.processFrame(frame)

        XCTAssertNil(packet, "Should ignore IPv6 frames")
    }

    func testTrackVMMAC() {
        let frameData = Self.makeIPv4Frame(srcMAC: Self.vmMAC)
        var bridge = FramePacketBridge()

        guard let frame = EthernetFrame(frameData) else {
            XCTFail("Should parse frame")
            return
        }

        _ = bridge.processFrame(frame)

        XCTAssertEqual(bridge.vmMAC, Self.vmMAC, "Should track VM's MAC address")
    }

    func testTrackVMIP() {
        let frameData = Self.makeIPv4Frame(srcIP: Self.vmIP)
        var bridge = FramePacketBridge()

        guard let frame = EthernetFrame(frameData) else {
            XCTFail("Should parse frame")
            return
        }

        _ = bridge.processFrame(frame)

        XCTAssertEqual(bridge.vmIP, Self.vmIP, "Should track VM's IP address")
    }

    func testUpdateVMAddressesOnSubsequentFrames() {
        var bridge = FramePacketBridge()

        // First frame with one IP
        let frame1Data = Self.makeIPv4Frame(srcIP: IPv4Address(192, 168, 64, 2))
        if let frame1 = EthernetFrame(frame1Data) {
            _ = bridge.processFrame(frame1)
        }
        XCTAssertEqual(bridge.vmIP, IPv4Address(192, 168, 64, 2))

        // Second frame with different IP (VM got new address)
        let frame2Data = Self.makeIPv4Frame(srcIP: IPv4Address(192, 168, 64, 5))
        if let frame2 = EthernetFrame(frame2Data) {
            _ = bridge.processFrame(frame2)
        }
        XCTAssertEqual(bridge.vmIP, IPv4Address(192, 168, 64, 5), "Should update VM IP")
    }

    // MARK: - Response Wrapping Tests

    func testWrapResponseFrame() {
        var bridge = FramePacketBridge()

        // Process outgoing frame first to learn VM addresses
        let outFrame = Self.makeIPv4Frame()
        if let frame = EthernetFrame(outFrame) {
            _ = bridge.processFrame(frame)
        }

        // Wrap a response
        let responsePayload = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let sourceEndpoint = Endpoint(address: Self.consumerIP, port: 51900)

        let responseFrame = bridge.wrapResponse(
            udpPayload: responsePayload,
            from: sourceEndpoint,
            vmPort: 12345
        )

        XCTAssertNotNil(responseFrame, "Should create response frame")

        // Verify ethernet header
        XCTAssertEqual(responseFrame?.destinationMAC, Self.vmMAC)
        XCTAssertEqual(responseFrame?.etherType, .ipv4)

        // Verify IP addresses in payload
        if let frame = responseFrame, let packet = IPv4Packet(frame.payload) {
            XCTAssertEqual(packet.sourceAddress, Self.consumerIP)
            XCTAssertEqual(packet.destinationAddress, Self.vmIP)
            XCTAssertEqual(packet.sourcePort, 51900)
            XCTAssertEqual(packet.destinationPort, 12345)
        } else {
            XCTFail("Should parse response IP packet")
        }
    }

    func testWrapResponseWithoutKnownVMAddress() {
        let bridge = FramePacketBridge()

        let responsePayload = Data([0x01, 0x02])
        let sourceEndpoint = Endpoint(address: Self.consumerIP, port: 51900)

        let responseFrame = bridge.wrapResponse(
            udpPayload: responsePayload,
            from: sourceEndpoint,
            vmPort: 12345
        )

        XCTAssertNil(responseFrame, "Should return nil without known VM address")
    }

    func testWrapResponsePreservesPayload() {
        var bridge = FramePacketBridge()

        // Learn VM addresses
        let outFrame = Self.makeIPv4Frame()
        if let frame = EthernetFrame(outFrame) {
            _ = bridge.processFrame(frame)
        }

        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let sourceEndpoint = Endpoint(address: Self.consumerIP, port: 51900)

        let responseFrame = bridge.wrapResponse(
            udpPayload: payload,
            from: sourceEndpoint,
            vmPort: 12345
        )

        // Extract UDP payload from response
        if let frame = responseFrame,
           let packet = IPv4Packet(frame.payload),
           let udpPayload = packet.udpPayload {
            XCTAssertEqual(udpPayload, payload, "Response should preserve payload")
        } else {
            XCTFail("Should extract UDP payload from response")
        }
    }

    // MARK: - Gateway MAC Tests

    func testDefaultGatewayMAC() {
        let bridge = FramePacketBridge()

        // Default gateway MAC should be set
        XCTAssertNotNil(bridge.gatewayMAC)
        XCTAssertEqual(bridge.gatewayMAC.count, 6)
    }

    func testCustomGatewayMAC() {
        let customMAC = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        let bridge = FramePacketBridge(gatewayMAC: customMAC)

        XCTAssertEqual(bridge.gatewayMAC, customMAC)
    }

    func testResponseUsesGatewayMACAsSource() {
        let customMAC = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        var bridge = FramePacketBridge(gatewayMAC: customMAC)

        // Learn VM addresses
        let outFrame = Self.makeIPv4Frame()
        if let frame = EthernetFrame(outFrame) {
            _ = bridge.processFrame(frame)
        }

        let responseFrame = bridge.wrapResponse(
            udpPayload: Data([0x01]),
            from: Endpoint(address: Self.consumerIP, port: 51900),
            vmPort: 12345
        )

        XCTAssertEqual(responseFrame?.sourceMAC, customMAC, "Response source MAC should be gateway MAC")
    }

    // MARK: - Edge Cases

    func testMalformedIPv4InFrame() {
        // Valid ethernet frame but truncated IP header
        var frameData = Data()
        frameData.append(Self.gatewayMAC)
        frameData.append(Self.vmMAC)
        frameData.append(0x08)  // IPv4
        frameData.append(0x00)
        frameData.append(Data(repeating: 0x45, count: 10))  // Truncated IP

        var bridge = FramePacketBridge()
        if let frame = EthernetFrame(frameData) {
            let packet = bridge.processFrame(frame)
            XCTAssertNil(packet, "Should return nil for malformed IP")
        }
    }

    func testEmptyPayloadFrame() {
        var frameData = Data()
        frameData.append(Self.gatewayMAC)
        frameData.append(Self.vmMAC)
        frameData.append(0x08)
        frameData.append(0x00)
        // No IP payload

        var bridge = FramePacketBridge()
        if let frame = EthernetFrame(frameData) {
            let packet = bridge.processFrame(frame)
            XCTAssertNil(packet, "Should return nil for empty payload")
        }
    }

    func testLargeUDPPayload() {
        // 1400 byte payload (typical WireGuard packet)
        let largePayload = Data(repeating: 0x42, count: 1400)
        let frameData = Self.makeIPv4Frame(udpPayload: largePayload)

        var bridge = FramePacketBridge()
        if let frame = EthernetFrame(frameData) {
            let packet = bridge.processFrame(frame)
            XCTAssertNotNil(packet)
            XCTAssertEqual(packet?.udpPayload, largePayload)
        }
    }
}
