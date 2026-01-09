import XCTest
@testable import OmertaNetwork

final class IPv4PacketTests: XCTestCase {

    // MARK: - Test Data Builders

    /// Build a minimal IPv4 header (20 bytes, no options)
    /// Format: Version/IHL, DSCP/ECN, Total Length, ID, Flags/Fragment, TTL, Protocol, Checksum, Src IP, Dst IP
    static func makeIPv4Header(
        srcIP: (UInt8, UInt8, UInt8, UInt8) = (192, 168, 1, 100),
        dstIP: (UInt8, UInt8, UInt8, UInt8) = (10, 99, 0, 1),
        proto: UInt8 = 17,  // UDP
        totalLength: UInt16? = nil,
        headerLength: UInt8 = 5,  // 5 * 4 = 20 bytes
        payload: Data = Data()
    ) -> Data {
        let actualLength = totalLength ?? UInt16(headerLength * 4 + UInt8(payload.count))

        var header = Data(count: Int(headerLength) * 4)
        header[0] = 0x40 | (headerLength & 0x0F)  // Version 4, IHL
        header[1] = 0x00  // DSCP/ECN
        header[2] = UInt8(actualLength >> 8)
        header[3] = UInt8(actualLength & 0xFF)
        header[4] = 0x00  // ID high
        header[5] = 0x01  // ID low
        header[6] = 0x00  // Flags/Fragment high
        header[7] = 0x00  // Fragment low
        header[8] = 64    // TTL
        header[9] = proto
        header[10] = 0x00 // Checksum (not validated)
        header[11] = 0x00
        header[12] = srcIP.0
        header[13] = srcIP.1
        header[14] = srcIP.2
        header[15] = srcIP.3
        header[16] = dstIP.0
        header[17] = dstIP.1
        header[18] = dstIP.2
        header[19] = dstIP.3

        header.append(payload)
        return header
    }

    /// Build UDP header (8 bytes) + payload
    static func makeUDPPayload(
        srcPort: UInt16 = 12345,
        dstPort: UInt16 = 51900,
        payload: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])
    ) -> Data {
        let length = UInt16(8 + payload.count)
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8)
        udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8)
        udp[3] = UInt8(dstPort & 0xFF)
        udp[4] = UInt8(length >> 8)
        udp[5] = UInt8(length & 0xFF)
        udp[6] = 0x00  // Checksum
        udp[7] = 0x00
        udp.append(payload)
        return udp
    }

    /// Build TCP header (20 bytes minimum) + payload
    static func makeTCPPayload(
        srcPort: UInt16 = 54321,
        dstPort: UInt16 = 443,
        payload: Data = Data()
    ) -> Data {
        var tcp = Data(count: 20)
        tcp[0] = UInt8(srcPort >> 8)
        tcp[1] = UInt8(srcPort & 0xFF)
        tcp[2] = UInt8(dstPort >> 8)
        tcp[3] = UInt8(dstPort & 0xFF)
        // Sequence number (4 bytes)
        tcp[4] = 0; tcp[5] = 0; tcp[6] = 0; tcp[7] = 1
        // Ack number (4 bytes)
        tcp[8] = 0; tcp[9] = 0; tcp[10] = 0; tcp[11] = 0
        // Data offset (5 = 20 bytes), flags
        tcp[12] = 0x50  // 5 << 4
        tcp[13] = 0x02  // SYN flag
        // Window
        tcp[14] = 0xFF; tcp[15] = 0xFF
        // Checksum
        tcp[16] = 0; tcp[17] = 0
        // Urgent pointer
        tcp[18] = 0; tcp[19] = 0
        tcp.append(payload)
        return tcp
    }

    // MARK: - Basic Parsing Tests

    func testParseValidUDPPacket() {
        let udpPayload = Self.makeUDPPayload(srcPort: 12345, dstPort: 51900)
        let packet = Self.makeIPv4Header(
            srcIP: (192, 168, 1, 100),
            dstIP: (10, 99, 0, 1),
            proto: 17,  // UDP
            payload: udpPayload
        )

        let parsed = IPv4Packet(packet)

        XCTAssertNotNil(parsed, "Should parse valid UDP packet")
        XCTAssertEqual(parsed?.version, 4)
        XCTAssertEqual(parsed?.protocol, .udp)
        XCTAssertEqual(parsed?.sourceAddress, IPv4Address(192, 168, 1, 100))
        XCTAssertEqual(parsed?.destinationAddress, IPv4Address(10, 99, 0, 1))
        XCTAssertEqual(parsed?.sourcePort, 12345)
        XCTAssertEqual(parsed?.destinationPort, 51900)
    }

    func testParseValidTCPPacket() {
        let tcpPayload = Self.makeTCPPayload(srcPort: 54321, dstPort: 443)
        let packet = Self.makeIPv4Header(
            srcIP: (10, 0, 0, 5),
            dstIP: (93, 184, 216, 34),
            proto: 6,  // TCP
            payload: tcpPayload
        )

        let parsed = IPv4Packet(packet)

        XCTAssertNotNil(parsed, "Should parse valid TCP packet")
        XCTAssertEqual(parsed?.protocol, .tcp)
        XCTAssertEqual(parsed?.sourcePort, 54321)
        XCTAssertEqual(parsed?.destinationPort, 443)
    }

    func testParseICMPPacket() {
        // ICMP echo request
        let icmpPayload = Data([0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01])
        let packet = Self.makeIPv4Header(
            proto: 1,  // ICMP
            payload: icmpPayload
        )

        let parsed = IPv4Packet(packet)

        XCTAssertNotNil(parsed, "Should parse ICMP packet")
        XCTAssertEqual(parsed?.protocol, .icmp)
        XCTAssertNil(parsed?.sourcePort, "ICMP has no ports")
        XCTAssertNil(parsed?.destinationPort, "ICMP has no ports")
    }

    func testParseUnknownProtocol() {
        let packet = Self.makeIPv4Header(
            proto: 99,  // Unknown
            payload: Data([0x01, 0x02, 0x03, 0x04])
        )

        let parsed = IPv4Packet(packet)

        XCTAssertNotNil(parsed, "Should parse packet with unknown protocol")
        XCTAssertEqual(parsed?.protocol, .other(99))
    }

    // MARK: - IP Header Options

    func testParseWithIPOptions() {
        // IP header with options (IHL = 6, so 24 bytes header)
        let udpPayload = Self.makeUDPPayload(dstPort: 8080)
        var packet = Self.makeIPv4Header(
            proto: 17,
            headerLength: 6,  // 24 bytes
            payload: udpPayload
        )
        // Fill option bytes (bytes 20-23)
        packet[20] = 0x01  // NOP
        packet[21] = 0x01  // NOP
        packet[22] = 0x01  // NOP
        packet[23] = 0x00  // End of options

        let parsed = IPv4Packet(packet)

        XCTAssertNotNil(parsed, "Should parse packet with IP options")
        XCTAssertEqual(parsed?.headerLength, 24)
        XCTAssertEqual(parsed?.destinationPort, 8080, "Should correctly offset to UDP header")
    }

    // MARK: - Error Cases

    func testParseTruncatedHeader() {
        // Only 19 bytes (need at least 20)
        let truncated = Data(repeating: 0x45, count: 19)

        let parsed = IPv4Packet(truncated)

        XCTAssertNil(parsed, "Should return nil for truncated header")
    }

    func testParseEmptyData() {
        let parsed = IPv4Packet(Data())

        XCTAssertNil(parsed, "Should return nil for empty data")
    }

    func testParseInvalidVersion() {
        var packet = Self.makeIPv4Header()
        packet[0] = 0x60  // Version 6 (IPv6)

        let parsed = IPv4Packet(packet)

        XCTAssertNil(parsed, "Should return nil for non-IPv4 packet")
    }

    func testParseInvalidHeaderLength() {
        var packet = Self.makeIPv4Header()
        packet[0] = 0x43  // IHL = 3 (invalid, minimum is 5)

        let parsed = IPv4Packet(packet)

        XCTAssertNil(parsed, "Should return nil for invalid IHL")
    }

    func testParseTruncatedUDPHeader() {
        // Valid IP header but truncated UDP (only 4 bytes instead of 8)
        let truncatedUDP = Data([0x30, 0x39, 0xCA, 0x6C])  // Ports only, no length/checksum
        let packet = Self.makeIPv4Header(proto: 17, payload: truncatedUDP)

        let parsed = IPv4Packet(packet)

        XCTAssertNotNil(parsed, "Should parse IP header")
        // Port extraction should still work with 4+ bytes
        XCTAssertEqual(parsed?.destinationPort, 51820)
    }

    // MARK: - Port Extraction

    func testDestinationPortUDP() {
        let udpPayload = Self.makeUDPPayload(dstPort: 51900)
        let packet = Self.makeIPv4Header(proto: 17, payload: udpPayload)

        let parsed = IPv4Packet(packet)

        XCTAssertEqual(parsed?.destinationPort, 51900)
    }

    func testDestinationPortTCP() {
        let tcpPayload = Self.makeTCPPayload(dstPort: 22)
        let packet = Self.makeIPv4Header(proto: 6, payload: tcpPayload)

        let parsed = IPv4Packet(packet)

        XCTAssertEqual(parsed?.destinationPort, 22)
    }

    func testSourcePortExtraction() {
        let udpPayload = Self.makeUDPPayload(srcPort: 44444, dstPort: 53)
        let packet = Self.makeIPv4Header(proto: 17, payload: udpPayload)

        let parsed = IPv4Packet(packet)

        XCTAssertEqual(parsed?.sourcePort, 44444)
        XCTAssertEqual(parsed?.destinationPort, 53)
    }

    // MARK: - UDP Payload Extraction

    func testUDPPayloadExtraction() {
        let innerPayload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
        let udpPayload = Self.makeUDPPayload(payload: innerPayload)
        let packet = Self.makeIPv4Header(proto: 17, payload: udpPayload)

        let parsed = IPv4Packet(packet)

        XCTAssertEqual(parsed?.udpPayload, innerPayload, "Should extract UDP payload after 8-byte header")
    }

    func testUDPPayloadEmpty() {
        let udpPayload = Self.makeUDPPayload(payload: Data())
        let packet = Self.makeIPv4Header(proto: 17, payload: udpPayload)

        let parsed = IPv4Packet(packet)

        XCTAssertEqual(parsed?.udpPayload, Data())
    }

    func testUDPPayloadNilForTCP() {
        let tcpPayload = Self.makeTCPPayload()
        let packet = Self.makeIPv4Header(proto: 6, payload: tcpPayload)

        let parsed = IPv4Packet(packet)

        XCTAssertNil(parsed?.udpPayload, "UDP payload should be nil for TCP packets")
    }

    // MARK: - IPv4Address Tests

    func testIPv4AddressCreation() {
        let addr = IPv4Address(192, 168, 1, 1)

        XCTAssertEqual(addr.octets.0, 192)
        XCTAssertEqual(addr.octets.1, 168)
        XCTAssertEqual(addr.octets.2, 1)
        XCTAssertEqual(addr.octets.3, 1)
        XCTAssertEqual(addr.description, "192.168.1.1")
    }

    func testIPv4AddressFromData() {
        let data = Data([10, 99, 0, 2])
        let addr = IPv4Address(data)

        XCTAssertNotNil(addr)
        XCTAssertEqual(addr?.octets.0, 10)
        XCTAssertEqual(addr?.octets.1, 99)
        XCTAssertEqual(addr?.octets.2, 0)
        XCTAssertEqual(addr?.octets.3, 2)
    }

    func testIPv4AddressFromDataTooShort() {
        let data = Data([10, 99, 0])  // Only 3 bytes
        let addr = IPv4Address(data)

        XCTAssertNil(addr)
    }

    func testIPv4AddressEquality() {
        let a = IPv4Address(192, 168, 1, 1)
        let b = IPv4Address(192, 168, 1, 1)
        let c = IPv4Address(192, 168, 1, 2)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testIPv4AddressHashable() {
        let a = IPv4Address(10, 0, 0, 1)
        let b = IPv4Address(10, 0, 0, 1)

        var set = Set<IPv4Address>()
        set.insert(a)
        set.insert(b)

        XCTAssertEqual(set.count, 1, "Same addresses should hash equally")
    }

    func testIPv4AddressToData() {
        let addr = IPv4Address(172, 16, 0, 1)
        let data = addr.toData()

        XCTAssertEqual(data, Data([172, 16, 0, 1]))
    }

    // MARK: - IPProtocol Tests

    func testIPProtocolRawValues() {
        XCTAssertEqual(IPProtocol.icmp.rawValue, 1)
        XCTAssertEqual(IPProtocol.tcp.rawValue, 6)
        XCTAssertEqual(IPProtocol.udp.rawValue, 17)
    }

    func testIPProtocolHasPort() {
        XCTAssertTrue(IPProtocol.tcp.hasPorts)
        XCTAssertTrue(IPProtocol.udp.hasPorts)
        XCTAssertFalse(IPProtocol.icmp.hasPorts)
        XCTAssertFalse(IPProtocol.other(47).hasPorts)  // GRE
    }
}
