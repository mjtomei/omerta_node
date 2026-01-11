// STUNServerTests.swift
// Tests for STUN server implementation

import XCTest
@testable import OmertaRendezvousLib

final class STUNServerTests: XCTestCase {

    // MARK: - STUN Message Creation Tests

    func testCreateBindingRequest() {
        let request = STUNServer.createBindingRequest()

        // Should be 20 bytes (header only, no attributes)
        XCTAssertEqual(request.count, 20)

        // Message type: Binding Request (0x0001)
        XCTAssertEqual(request[0], 0x00)
        XCTAssertEqual(request[1], 0x01)

        // Message length: 0
        XCTAssertEqual(request[2], 0x00)
        XCTAssertEqual(request[3], 0x00)

        // Magic cookie: 0x2112A442
        XCTAssertEqual(request[4], 0x21)
        XCTAssertEqual(request[5], 0x12)
        XCTAssertEqual(request[6], 0xA4)
        XCTAssertEqual(request[7], 0x42)

        // Transaction ID should be 12 bytes
        let transactionId = request[8..<20]
        XCTAssertEqual(transactionId.count, 12)
    }

    func testBindingRequestsHaveUniqueTransactionIds() {
        let request1 = STUNServer.createBindingRequest()
        let request2 = STUNServer.createBindingRequest()

        let transactionId1 = Data(request1[8..<20])
        let transactionId2 = Data(request2[8..<20])

        XCTAssertNotEqual(transactionId1, transactionId2)
    }

    // MARK: - STUN Response Parsing Tests

    func testParseMappedAddressIPv4() {
        // Construct a valid STUN binding response with XOR-MAPPED-ADDRESS
        // IP: 192.168.1.100 (0xC0A80164)
        // Port: 12345
        var response = Data()

        // Message type: Binding Response (0x0101)
        response.append(contentsOf: [0x01, 0x01])

        // Message length: 12 bytes (one attribute)
        response.append(contentsOf: [0x00, 0x0C])

        // Magic cookie
        response.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])

        // Transaction ID (12 bytes)
        response.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C])

        // XOR-MAPPED-ADDRESS attribute
        // Type: 0x0020
        response.append(contentsOf: [0x00, 0x20])
        // Length: 8 bytes
        response.append(contentsOf: [0x00, 0x08])
        // Reserved
        response.append(0x00)
        // Family: IPv4
        response.append(0x01)

        // XOR'd port: 12345 XOR 0x2112 = 12345 XOR 8466 = 0x1133
        // 12345 = 0x3039
        // 0x3039 XOR 0x2112 = 0x112B
        let xorPort: UInt16 = 12345 ^ 0x2112
        response.append(UInt8(xorPort >> 8))
        response.append(UInt8(xorPort & 0xFF))

        // XOR'd address: 192.168.1.100 XOR 0x2112A442
        // 192.168.1.100 = 0xC0A80164
        // 0xC0A80164 XOR 0x2112A442 = 0xE1BAA526
        let ip: UInt32 = (192 << 24) | (168 << 16) | (1 << 8) | 100
        let magicCookie: UInt32 = 0x2112A442
        let xorAddr = ip ^ magicCookie
        response.append(UInt8(xorAddr >> 24))
        response.append(UInt8((xorAddr >> 16) & 0xFF))
        response.append(UInt8((xorAddr >> 8) & 0xFF))
        response.append(UInt8(xorAddr & 0xFF))

        // Parse the response
        let result = STUNServer.parseMappedAddress(from: response)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "192.168.1.100")
        XCTAssertEqual(result?.port, 12345)
    }

    func testParseMappedAddressInvalidMessageType() {
        var response = Data()

        // Message type: Not a binding response (0x0001 = request)
        response.append(contentsOf: [0x00, 0x01])
        response.append(contentsOf: [0x00, 0x00])
        response.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])
        response.append(contentsOf: [UInt8](repeating: 0, count: 12))

        let result = STUNServer.parseMappedAddress(from: response)
        XCTAssertNil(result)
    }

    func testParseMappedAddressTooShort() {
        let response = Data([0x01, 0x01, 0x00, 0x00]) // Only 4 bytes
        let result = STUNServer.parseMappedAddress(from: response)
        XCTAssertNil(result)
    }

    func testParseMappedAddressEmpty() {
        let response = Data()
        let result = STUNServer.parseMappedAddress(from: response)
        XCTAssertNil(result)
    }

    func testParseMappedAddressNoAttributes() {
        var response = Data()

        // Message type: Binding Response
        response.append(contentsOf: [0x01, 0x01])
        // Message length: 0
        response.append(contentsOf: [0x00, 0x00])
        // Magic cookie
        response.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])
        // Transaction ID
        response.append(contentsOf: [UInt8](repeating: 0, count: 12))

        let result = STUNServer.parseMappedAddress(from: response)
        XCTAssertNil(result) // No XOR-MAPPED-ADDRESS attribute
    }

    // MARK: - Edge Cases

    func testParseMappedAddressWithPadding() {
        // Response with SOFTWARE attribute before XOR-MAPPED-ADDRESS
        var response = Data()

        // Message type: Binding Response
        response.append(contentsOf: [0x01, 0x01])

        // Message length: will fill in later
        let lengthOffset = response.count
        response.append(contentsOf: [0x00, 0x00])

        // Magic cookie
        response.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])

        // Transaction ID
        response.append(contentsOf: [UInt8](repeating: 0x11, count: 12))

        // SOFTWARE attribute (type 0x8022)
        response.append(contentsOf: [0x80, 0x22])
        // Length: 4 bytes
        response.append(contentsOf: [0x00, 0x04])
        // Value: "Test"
        response.append(contentsOf: [0x54, 0x65, 0x73, 0x74])
        // No padding needed (4 bytes is already aligned)

        // XOR-MAPPED-ADDRESS attribute
        response.append(contentsOf: [0x00, 0x20])
        response.append(contentsOf: [0x00, 0x08])
        response.append(0x00) // Reserved
        response.append(0x01) // Family: IPv4

        // Port 8080 XOR'd
        let xorPort: UInt16 = 8080 ^ 0x2112
        response.append(UInt8(xorPort >> 8))
        response.append(UInt8(xorPort & 0xFF))

        // IP 10.0.0.1 XOR'd
        let ip: UInt32 = (10 << 24) | (0 << 16) | (0 << 8) | 1
        let xorAddr = ip ^ 0x2112A442
        response.append(UInt8(xorAddr >> 24))
        response.append(UInt8((xorAddr >> 16) & 0xFF))
        response.append(UInt8((xorAddr >> 8) & 0xFF))
        response.append(UInt8(xorAddr & 0xFF))

        // Update message length
        let messageLength = response.count - 20
        response[lengthOffset] = UInt8(messageLength >> 8)
        response[lengthOffset + 1] = UInt8(messageLength & 0xFF)

        let result = STUNServer.parseMappedAddress(from: response)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "10.0.0.1")
        XCTAssertEqual(result?.port, 8080)
    }

    // MARK: - XOR Encoding Verification

    func testXOREncodingConsistency() {
        // Verify that our XOR encoding matches the RFC 5389 spec
        let magicCookie: UInt32 = 0x2112A442

        // Test port XOR (upper 16 bits of magic cookie = 0x2112)
        let port: UInt16 = 54321
        let xorPort = port ^ 0x2112
        let decodedPort = xorPort ^ 0x2112
        XCTAssertEqual(port, decodedPort)

        // Test address XOR
        let ip: UInt32 = 0xC0A80164 // 192.168.1.100
        let xorAddr = ip ^ magicCookie
        let decodedAddr = xorAddr ^ magicCookie
        XCTAssertEqual(ip, decodedAddr)
    }
}
