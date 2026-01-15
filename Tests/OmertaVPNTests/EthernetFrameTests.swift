import XCTest
@testable import OmertaVPN

final class EthernetFrameTests: XCTestCase {

    // MARK: - Test Data

    /// Standard ethernet frame: dst MAC + src MAC + etherType + payload
    /// 6 + 6 + 2 + N bytes
    static let dstMAC = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
    static let srcMAC = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])

    /// Build a test ethernet frame
    static func makeFrame(
        dst: Data = dstMAC,
        src: Data = srcMAC,
        etherType: UInt16,
        payload: Data = Data()
    ) -> Data {
        var frame = Data()
        frame.append(dst)
        frame.append(src)
        frame.append(UInt8(etherType >> 8))
        frame.append(UInt8(etherType & 0xFF))
        frame.append(payload)
        return frame
    }

    // MARK: - Parsing Tests

    func testParseValidIPv4Frame() {
        let payload = Data([0x45, 0x00, 0x00, 0x28])  // Minimal IPv4 header start
        let frameData = Self.makeFrame(etherType: 0x0800, payload: payload)

        let frame = EthernetFrame(frameData)

        XCTAssertNotNil(frame, "Should parse valid IPv4 frame")
        XCTAssertEqual(frame?.destinationMAC, Self.dstMAC)
        XCTAssertEqual(frame?.sourceMAC, Self.srcMAC)
        XCTAssertEqual(frame?.etherType, .ipv4)
        XCTAssertEqual(frame?.payload, payload)
    }

    func testParseValidARPFrame() {
        let payload = Data([0x00, 0x01, 0x08, 0x00])  // ARP for Ethernet/IPv4
        let frameData = Self.makeFrame(etherType: 0x0806, payload: payload)

        let frame = EthernetFrame(frameData)

        XCTAssertNotNil(frame, "Should parse valid ARP frame")
        XCTAssertEqual(frame?.etherType, .arp)
        XCTAssertEqual(frame?.payload, payload)
    }

    func testParseValidIPv6Frame() {
        let payload = Data([0x60, 0x00, 0x00, 0x00])  // IPv6 header start
        let frameData = Self.makeFrame(etherType: 0x86DD, payload: payload)

        let frame = EthernetFrame(frameData)

        XCTAssertNotNil(frame, "Should parse valid IPv6 frame")
        XCTAssertEqual(frame?.etherType, .ipv6)
    }

    func testParseUnknownEtherType() {
        let frameData = Self.makeFrame(etherType: 0x9999, payload: Data([0x01, 0x02]))

        let frame = EthernetFrame(frameData)

        XCTAssertNotNil(frame, "Should parse frame with unknown etherType")
        XCTAssertEqual(frame?.etherType, .other(0x9999))
    }

    func testParseTruncatedFrame() {
        // Frame with only 13 bytes (need at least 14 for header)
        let truncated = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
                              0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
                              0x08])  // Missing second byte of etherType

        let frame = EthernetFrame(truncated)

        XCTAssertNil(frame, "Should return nil for truncated frame")
    }

    func testParseEmptyData() {
        let frame = EthernetFrame(Data())

        XCTAssertNil(frame, "Should return nil for empty data")
    }

    func testParseEmptyPayload() {
        // Valid header but no payload (just the 14-byte header)
        let frameData = Self.makeFrame(etherType: 0x0800, payload: Data())

        let frame = EthernetFrame(frameData)

        XCTAssertNotNil(frame, "Should parse frame with empty payload")
        XCTAssertEqual(frame?.payload, Data())
    }

    func testParseLargePayload() {
        // Standard MTU is 1500 bytes for payload
        let largePayload = Data(repeating: 0xAB, count: 1500)
        let frameData = Self.makeFrame(etherType: 0x0800, payload: largePayload)

        let frame = EthernetFrame(frameData)

        XCTAssertNotNil(frame, "Should parse frame with large payload")
        XCTAssertEqual(frame?.payload.count, 1500)
    }

    // MARK: - MAC Address Tests

    func testMACAddressExtraction() {
        let customDst = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let customSrc = Data([0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54])
        let frameData = Self.makeFrame(dst: customDst, src: customSrc, etherType: 0x0800)

        let frame = EthernetFrame(frameData)

        XCTAssertEqual(frame?.destinationMAC, customDst)
        XCTAssertEqual(frame?.sourceMAC, customSrc)
    }

    func testBroadcastMAC() {
        let broadcast = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let frameData = Self.makeFrame(dst: broadcast, src: Self.srcMAC, etherType: 0x0806)

        let frame = EthernetFrame(frameData)

        XCTAssertEqual(frame?.destinationMAC, broadcast)
        XCTAssertTrue(frame?.isBroadcast ?? false, "Should detect broadcast address")
    }

    // MARK: - Serialization Tests

    func testRoundTrip() {
        let payload = Data([0x45, 0x00, 0x00, 0x28, 0x00, 0x01])
        let originalData = Self.makeFrame(etherType: 0x0800, payload: payload)

        let frame = EthernetFrame(originalData)
        let serialized = frame?.toData()

        XCTAssertEqual(serialized, originalData, "Round-trip should produce identical bytes")
    }

    func testRoundTripWithEmptyPayload() {
        let originalData = Self.makeFrame(etherType: 0x0800, payload: Data())

        let frame = EthernetFrame(originalData)
        let serialized = frame?.toData()

        XCTAssertEqual(serialized, originalData)
    }

    func testRoundTripPreservesUnknownEtherType() {
        let originalData = Self.makeFrame(etherType: 0x1234, payload: Data([0xAB, 0xCD]))

        let frame = EthernetFrame(originalData)
        let serialized = frame?.toData()

        XCTAssertEqual(serialized, originalData)
    }

    // MARK: - Builder Tests

    func testBuildFrame() {
        let frame = EthernetFrame(
            destinationMAC: Self.dstMAC,
            sourceMAC: Self.srcMAC,
            etherType: .ipv4,
            payload: Data([0x45, 0x00])
        )

        let data = frame.toData()

        XCTAssertEqual(data.count, 16)  // 14 header + 2 payload
        XCTAssertEqual(data[0..<6], Self.dstMAC)
        XCTAssertEqual(data[6..<12], Self.srcMAC)
        XCTAssertEqual(data[12], 0x08)
        XCTAssertEqual(data[13], 0x00)
        XCTAssertEqual(data[14..<16], Data([0x45, 0x00]))
    }

    // MARK: - EtherType Helper Tests

    func testEtherTypeRawValues() {
        XCTAssertEqual(EtherType.ipv4.rawValue, 0x0800)
        XCTAssertEqual(EtherType.arp.rawValue, 0x0806)
        XCTAssertEqual(EtherType.ipv6.rawValue, 0x86DD)
    }

    func testEtherTypeEquality() {
        XCTAssertEqual(EtherType.ipv4, EtherType.ipv4)
        XCTAssertNotEqual(EtherType.ipv4, EtherType.arp)
        XCTAssertEqual(EtherType.other(0x1234), EtherType.other(0x1234))
        XCTAssertNotEqual(EtherType.other(0x1234), EtherType.other(0x5678))
    }
}
