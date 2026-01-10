import XCTest
@testable import OmertaNetwork

final class FilteringStrategyTests: XCTestCase {

    // MARK: - Test Data

    static let consumerIP = IPv4Address(203, 0, 113, 50)
    static let consumerPort: UInt16 = 51900
    static let blockedIP = IPv4Address(8, 8, 8, 8)

    /// Build a minimal IPv4 packet for testing
    static func makePacket(
        srcIP: IPv4Address = IPv4Address(192, 168, 64, 2),
        dstIP: IPv4Address = consumerIP,
        srcPort: UInt16 = 12345,
        dstPort: UInt16 = consumerPort
    ) -> IPv4Packet {
        // Build UDP payload
        var udp = Data(count: 8)
        udp[0] = UInt8(srcPort >> 8)
        udp[1] = UInt8(srcPort & 0xFF)
        udp[2] = UInt8(dstPort >> 8)
        udp[3] = UInt8(dstPort & 0xFF)
        udp[4] = 0x00; udp[5] = 0x08  // Length
        udp[6] = 0x00; udp[7] = 0x00  // Checksum

        // Build IP header
        var ip = Data(count: 20)
        ip[0] = 0x45  // Version 4, IHL 5
        ip[1] = 0x00
        ip[2] = 0x00; ip[3] = 0x1C  // Total length 28
        ip[4] = 0x00; ip[5] = 0x01
        ip[6] = 0x00; ip[7] = 0x00
        ip[8] = 64    // TTL
        ip[9] = 17    // UDP
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

        return IPv4Packet(ip)!
    }

    // MARK: - FilterDecision Tests

    func testFilterDecisionEquality() {
        XCTAssertEqual(FilterDecision.forward, FilterDecision.forward)
        XCTAssertNotEqual(FilterDecision.forward, FilterDecision.drop(reason: "test"))
        XCTAssertNotEqual(FilterDecision.drop(reason: "a"), FilterDecision.drop(reason: "b"))
        XCTAssertNotEqual(FilterDecision.forward, FilterDecision.terminate(reason: "test"))
    }

    // MARK: - FullFilterStrategy Tests

    func testFullFilterAllowsValidTraffic() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = FullFilterStrategy(allowlist: allowlist)

        let packet = Self.makePacket(dstIP: Self.consumerIP, dstPort: Self.consumerPort)
        let decision = await strategy.shouldForward(packet: packet)

        XCTAssertEqual(decision, .forward, "Should forward allowed traffic")
    }

    func testFullFilterDropsInvalidTraffic() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = FullFilterStrategy(allowlist: allowlist)

        let packet = Self.makePacket(dstIP: Self.blockedIP, dstPort: 53)
        let decision = await strategy.shouldForward(packet: packet)

        if case .drop = decision {
            // Expected
        } else {
            XCTFail("Should drop invalid traffic")
        }
    }

    func testFullFilterChecksEveryPacket() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = FullFilterStrategy(allowlist: allowlist)

        // Send multiple packets
        for _ in 0..<100 {
            let packet = Self.makePacket()
            let decision = await strategy.shouldForward(packet: packet)
            XCTAssertEqual(decision, .forward)
        }

        // Each packet should have been checked
        let stats = await strategy.statistics
        XCTAssertEqual(stats.packetsChecked, 100)
    }

    // MARK: - ConntrackStrategy Tests

    func testConntrackFirstPacketChecked() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = ConntrackStrategy(allowlist: allowlist)

        let packet = Self.makePacket()
        let decision = await strategy.shouldForward(packet: packet)

        XCTAssertEqual(decision, .forward)

        let stats = await strategy.statistics
        XCTAssertEqual(stats.allowlistChecks, 1, "First packet should check allowlist")
    }

    func testConntrackRepeatPacketFastPath() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = ConntrackStrategy(allowlist: allowlist)

        // First packet establishes flow
        let packet1 = Self.makePacket()
        _ = await strategy.shouldForward(packet: packet1)

        // Subsequent packets to same destination should use fast path
        for _ in 0..<99 {
            let packet = Self.makePacket()
            let decision = await strategy.shouldForward(packet: packet)
            XCTAssertEqual(decision, .forward)
        }

        let stats = await strategy.statistics
        XCTAssertEqual(stats.allowlistChecks, 1, "Repeat packets should not recheck allowlist")
        XCTAssertEqual(stats.fastPathHits, 99, "Repeat packets should hit fast path")
    }

    func testConntrackBadFlowTerminates() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = ConntrackStrategy(allowlist: allowlist)

        // Try to access non-allowed destination
        let packet = Self.makePacket(dstIP: Self.blockedIP, dstPort: 53)
        let decision = await strategy.shouldForward(packet: packet)

        if case .terminate(let reason) = decision {
            XCTAssertTrue(reason.contains("non-allowed") || reason.contains("blocked"),
                         "Should indicate violation reason")
        } else {
            XCTFail("Should terminate on bad flow, got: \(decision)")
        }
    }

    func testConntrackMultipleFlows() async {
        let endpoint1 = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let endpoint2 = Endpoint(address: Self.consumerIP, port: 53)
        let allowlist = EndpointAllowlist([endpoint1, endpoint2])
        let strategy = ConntrackStrategy(allowlist: allowlist)

        // Establish two different flows
        let packet1 = Self.makePacket(dstPort: Self.consumerPort)
        let packet2 = Self.makePacket(dstPort: 53)

        _ = await strategy.shouldForward(packet: packet1)
        _ = await strategy.shouldForward(packet: packet2)

        let stats = await strategy.statistics
        XCTAssertEqual(stats.allowlistChecks, 2, "Each unique flow should be checked once")
        XCTAssertEqual(stats.trackedFlows, 2, "Should track two flows")
    }

    func testConntrackFlowTimeout() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        // Very short timeout for testing
        let strategy = ConntrackStrategy(allowlist: allowlist, flowTimeoutSeconds: 0.1)

        // Establish flow
        let packet = Self.makePacket()
        _ = await strategy.shouldForward(packet: packet)

        // Wait for timeout
        try? await Task.sleep(for: .milliseconds(150))

        // Should need to recheck
        _ = await strategy.shouldForward(packet: packet)

        let stats = await strategy.statistics
        XCTAssertEqual(stats.allowlistChecks, 2, "Should recheck after timeout")
    }

    // MARK: - SampledStrategy Tests

    func testSampledSkipsMostPackets() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        // 1% sample rate
        let strategy = SampledStrategy(allowlist: allowlist, sampleRate: 0.01)

        // Send 1000 good packets
        for _ in 0..<1000 {
            let packet = Self.makePacket()
            _ = await strategy.shouldForward(packet: packet)
        }

        let stats = await strategy.statistics
        // With 1% rate, expect roughly 10 checks (within statistical bounds)
        XCTAssertLessThan(stats.packetsChecked, 50, "Should skip most packets with 1% rate")
        XCTAssertGreaterThan(stats.packetsChecked, 0, "Should check some packets")
    }

    func testSampledAllowsGoodTraffic() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = SampledStrategy(allowlist: allowlist, sampleRate: 1.0)  // Check all

        let packet = Self.makePacket()
        let decision = await strategy.shouldForward(packet: packet)

        XCTAssertEqual(decision, .forward, "Should forward good traffic")
    }

    func testSampledCatchesViolation() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = SampledStrategy(allowlist: allowlist, sampleRate: 1.0)  // Check all

        let packet = Self.makePacket(dstIP: Self.blockedIP, dstPort: 53)
        let decision = await strategy.shouldForward(packet: packet)

        if case .terminate = decision {
            // Expected - sampled strategies terminate on violation
        } else {
            XCTFail("Should terminate on sampled violation")
        }
    }

    func testSampledEventuallyDetectsAbuse() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        // 10% sample rate
        let strategy = SampledStrategy(allowlist: allowlist, sampleRate: 0.10)

        var terminated = false
        // Send bad packets until detected
        for _ in 0..<1000 {
            let packet = Self.makePacket(dstIP: Self.blockedIP, dstPort: 53)
            let decision = await strategy.shouldForward(packet: packet)
            if case .terminate = decision {
                terminated = true
                break
            }
        }

        XCTAssertTrue(terminated, "Should eventually detect abuse with sampling")
    }

    func testSampledHighRateDetectsQuickly() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        // 50% sample rate - should detect quickly
        let strategy = SampledStrategy(allowlist: allowlist, sampleRate: 0.50)

        var detectionCount = 0
        for i in 0..<20 {
            let packet = Self.makePacket(dstIP: Self.blockedIP, dstPort: 53)
            let decision = await strategy.shouldForward(packet: packet)
            if case .terminate = decision {
                detectionCount = i + 1
                break
            }
        }

        XCTAssertLessThan(detectionCount, 10, "High sample rate should detect within few packets")
    }

    // MARK: - Statistics Tests

    func testFullFilterStatistics() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = FullFilterStrategy(allowlist: allowlist)

        // Good packets
        for _ in 0..<5 {
            let packet = Self.makePacket()
            _ = await strategy.shouldForward(packet: packet)
        }

        // Bad packets
        for _ in 0..<3 {
            let packet = Self.makePacket(dstIP: Self.blockedIP, dstPort: 53)
            _ = await strategy.shouldForward(packet: packet)
        }

        let stats = await strategy.statistics
        XCTAssertEqual(stats.packetsChecked, 8)
        XCTAssertEqual(stats.packetsForwarded, 5)
        XCTAssertEqual(stats.packetsDropped, 3)
    }

    func testConntrackStatistics() async {
        let endpoint = Endpoint(address: Self.consumerIP, port: Self.consumerPort)
        let allowlist = EndpointAllowlist([endpoint])
        let strategy = ConntrackStrategy(allowlist: allowlist)

        // Multiple packets to same destination
        for _ in 0..<10 {
            let packet = Self.makePacket()
            _ = await strategy.shouldForward(packet: packet)
        }

        let stats = await strategy.statistics
        XCTAssertEqual(stats.packetsProcessed, 10)
        XCTAssertEqual(stats.allowlistChecks, 1)  // Only first packet
        XCTAssertEqual(stats.fastPathHits, 9)
        XCTAssertEqual(stats.trackedFlows, 1)
    }
}
