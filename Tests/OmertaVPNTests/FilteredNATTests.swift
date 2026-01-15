import XCTest
@testable import OmertaVPN

final class FilteredNATTests: XCTestCase {

    // MARK: - Test Data

    static let vmMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
    static let gatewayMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0xFF])
    static let vmIP = IPv4Address(192, 168, 64, 2)
    static let consumerIP = IPv4Address(203, 0, 113, 50)
    static let consumerPort: UInt16 = 51900
    static let blockedIP = IPv4Address(8, 8, 8, 8)

    /// Build a test ethernet frame with IPv4/UDP packet
    static func makeFrame(
        srcIP: IPv4Address = vmIP,
        dstIP: IPv4Address = consumerIP,
        srcPort: UInt16 = 12345,
        dstPort: UInt16 = consumerPort,
        payload: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])
    ) -> Data {
        // Build UDP header + payload
        let udpLength = UInt16(8 + payload.count)
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8)
        udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8)
        udp[3] = UInt8(dstPort & 0xFF)
        udp[4] = UInt8(udpLength >> 8)
        udp[5] = UInt8(udpLength & 0xFF)
        udp[6] = 0x00
        udp[7] = 0x00
        udp.append(payload)

        // Build IPv4 header
        let totalLength = UInt16(20 + udp.count)
        var ip = Data(count: 20)
        ip[0] = 0x45
        ip[1] = 0x00
        ip[2] = UInt8(totalLength >> 8)
        ip[3] = UInt8(totalLength & 0xFF)
        ip[4] = 0x00; ip[5] = 0x01
        ip[6] = 0x00; ip[7] = 0x00
        ip[8] = 64
        ip[9] = 17  // UDP
        ip[10] = 0x00; ip[11] = 0x00
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
        frame.append(gatewayMAC)
        frame.append(vmMAC)
        frame.append(0x08)
        frame.append(0x00)
        frame.append(ip)

        return frame
    }

    // MARK: - Outbound Filtering Tests

    func testAllowedTrafficForwarded() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        let frame = Self.makeFrame(dstIP: Self.consumerIP, dstPort: Self.consumerPort)
        let result = await nat.processOutbound(frame)

        switch result {
        case .forwarded:
            break  // Expected
        case .dropped(let reason):
            XCTFail("Should forward allowed traffic, got dropped: \(reason)")
        case .error(let error):
            XCTFail("Should forward allowed traffic, got error: \(error)")
        }
    }

    func testBlockedIPDropped() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        // Try to send to blocked IP
        let frame = Self.makeFrame(dstIP: Self.blockedIP, dstPort: 53)
        let result = await nat.processOutbound(frame)

        switch result {
        case .dropped(let reason):
            XCTAssertTrue(reason.contains("allowlist") || reason.contains("blocked"),
                         "Should indicate why traffic was blocked")
        case .forwarded:
            XCTFail("Should block traffic to non-allowed IP")
        case .error:
            XCTFail("Should return dropped, not error")
        }
    }

    func testBlockedPortDropped() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        // Correct IP but wrong port
        let frame = Self.makeFrame(dstIP: Self.consumerIP, dstPort: 443)
        let result = await nat.processOutbound(frame)

        switch result {
        case .dropped:
            break  // Expected
        case .forwarded:
            XCTFail("Should block traffic to non-allowed port")
        case .error:
            XCTFail("Should return dropped, not error")
        }
    }

    func testMalformedFrameHandled() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        // Truncated frame
        let malformed = Data([0x01, 0x02, 0x03])
        let result = await nat.processOutbound(malformed)

        switch result {
        case .dropped(let reason):
            XCTAssertTrue(reason.contains("malformed") || reason.contains("parse"),
                         "Should indicate malformed frame")
        case .forwarded:
            XCTFail("Should not forward malformed frame")
        case .error:
            break  // Also acceptable
        }
    }

    func testNonIPv4FrameDropped() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        // ARP frame
        var arpFrame = Data()
        arpFrame.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))  // Broadcast
        arpFrame.append(Self.vmMAC)
        arpFrame.append(0x08)  // ARP
        arpFrame.append(0x06)
        arpFrame.append(Data(repeating: 0x00, count: 28))

        let result = await nat.processOutbound(arpFrame)

        switch result {
        case .dropped:
            break  // Expected - we only handle IPv4
        case .forwarded:
            XCTFail("Should not forward ARP frames")
        case .error:
            break  // Also acceptable
        }
    }

    // MARK: - Inbound Filtering Tests

    func testInboundFromAllowedSource() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        // First send outbound to establish VM addresses
        let outFrame = Self.makeFrame()
        _ = await nat.processOutbound(outFrame)

        // Now receive inbound from consumer
        let inboundData = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let responseFrame = await nat.processInbound(inboundData, from: consumerEndpoint)

        XCTAssertNotNil(responseFrame, "Should accept inbound from allowed source")
    }

    func testInboundFromUnknownSourceBlocked() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        // First send outbound to establish VM addresses
        let outFrame = Self.makeFrame()
        _ = await nat.processOutbound(outFrame)

        // Try to receive from unknown source
        let unknownSource = Endpoint(address: Self.blockedIP, port: 53)
        let inboundData = Data([0x01, 0x02])
        let responseFrame = await nat.processInbound(inboundData, from: unknownSource)

        XCTAssertNil(responseFrame, "Should block inbound from unknown source")
    }

    func testInboundBeforeOutbound() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        // Try to receive inbound without any outbound (no VM address known)
        let inboundData = Data([0x01, 0x02])
        let responseFrame = await nat.processInbound(inboundData, from: consumerEndpoint)

        XCTAssertNil(responseFrame, "Should return nil when VM address unknown")
    }

    // MARK: - Multiple Endpoints Tests

    func testMultipleAllowedEndpoints() async {
        let endpoint1 = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let endpoint2 = Endpoint(address: Self.consumerIP, port: 53)  // DNS on same host

        let nat = FilteredNAT(allowedEndpoints: [endpoint1, endpoint2])

        // Traffic to endpoint1
        let frame1 = Self.makeFrame(dstIP: Self.consumerIP, dstPort: Self.consumerPort)
        let result1 = await nat.processOutbound(frame1)

        // Traffic to endpoint2
        let frame2 = Self.makeFrame(dstIP: Self.consumerIP, dstPort: 53)
        let result2 = await nat.processOutbound(frame2)

        if case .dropped = result1 {
            XCTFail("Should allow traffic to endpoint1")
        }
        if case .dropped = result2 {
            XCTFail("Should allow traffic to endpoint2")
        }
    }

    // MARK: - Endpoint Update Tests

    func testUpdateAllowedEndpoint() async {
        let oldEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let newEndpoint = Endpoint(address: IPv4Address(10, 0, 0, 1), port: 51900)

        let nat = FilteredNAT(consumerEndpoint: oldEndpoint)

        // Initially, traffic to old endpoint works
        let frame1 = Self.makeFrame(dstIP: Self.consumerIP, dstPort: Self.consumerPort)
        let result1 = await nat.processOutbound(frame1)
        if case .dropped = result1 {
            XCTFail("Should allow traffic to initial endpoint")
        }

        // Update allowed endpoint
        await nat.setAllowedEndpoints([newEndpoint])

        // Traffic to old endpoint should now be blocked
        let result2 = await nat.processOutbound(frame1)
        if case .forwarded = result2 {
            XCTFail("Should block traffic to old endpoint after update")
        }

        // Traffic to new endpoint should work
        let frame2 = Self.makeFrame(dstIP: IPv4Address(10, 0, 0, 1), dstPort: 51900)
        let result3 = await nat.processOutbound(frame2)
        if case .dropped = result3 {
            XCTFail("Should allow traffic to new endpoint")
        }
    }

    // MARK: - Statistics Tests

    func testStatisticsTracking() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        // Send some allowed traffic
        for _ in 0..<5 {
            let frame = Self.makeFrame()
            _ = await nat.processOutbound(frame)
        }

        // Send some blocked traffic
        for _ in 0..<3 {
            let frame = Self.makeFrame(dstIP: Self.blockedIP, dstPort: 53)
            _ = await nat.processOutbound(frame)
        }

        let stats = await nat.statistics
        XCTAssertEqual(stats.framesProcessed, 8)
        XCTAssertEqual(stats.framesForwarded, 5)
        XCTAssertEqual(stats.framesDropped, 3)
    }

    // MARK: - Payload Preservation Tests

    func testOutboundPayloadExtracted() async {
        let consumerEndpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let frame = Self.makeFrame(payload: payload)

        let result = await nat.processOutbound(frame)

        if case .forwarded = result {
            // The payload should have been forwarded
            // In real implementation, we'd verify via mock forwarder
        } else {
            XCTFail("Should forward valid frame")
        }
    }
}
