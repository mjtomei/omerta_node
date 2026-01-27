// DaemonConfigTests.swift - Tests for DaemonConfig parsing

import XCTest
@testable import OmertaDaemon

final class DaemonConfigTests: XCTestCase {

    // MARK: - Parser Coverage Test

    /// This test ensures all DaemonConfig properties have corresponding parser cases.
    /// If you add a new property to DaemonConfig, this test will fail until you add
    /// the parser case in DaemonConfig.parse().
    func testAllPropertiesHaveParserCases() throws {
        // List all properties that should be parseable from config file
        // Update this list when adding new properties to DaemonConfig
        let expectedProperties: Set<String> = [
            "network",
            "port",
            "noProvider",
            "dryRun",
            "timeout",
            "canRelay",
            "canCoordinateHolePunch",
            "enableEventLogging",
            "forceRelayOnly"
        ]

        // Use Mirror to get actual properties of DaemonConfig
        let config = DaemonConfig()
        let mirror = Mirror(reflecting: config)
        let actualProperties = Set(mirror.children.compactMap { $0.label })

        // Check for properties in struct but not in expected list (missing parser)
        let missingFromExpected = actualProperties.subtracting(expectedProperties)
        XCTAssertTrue(
            missingFromExpected.isEmpty,
            "DaemonConfig has properties without parser cases: \(missingFromExpected.sorted()). " +
            "Add parser cases in DaemonConfig.parse() and update this test."
        )

        // Check for expected properties not in struct (stale test)
        let missingFromStruct = expectedProperties.subtracting(actualProperties)
        XCTAssertTrue(
            missingFromStruct.isEmpty,
            "Test expects properties that don't exist in DaemonConfig: \(missingFromStruct.sorted()). " +
            "Update the expectedProperties list."
        )
    }

    // MARK: - Basic Parsing Tests

    func testParseEmptyConfig() throws {
        let config = try DaemonConfig.parse("")
        XCTAssertNil(config.network)
        XCTAssertEqual(config.port, 9999)
        XCTAssertFalse(config.noProvider)
        XCTAssertFalse(config.dryRun)
        XCTAssertNil(config.timeout)
        XCTAssertTrue(config.canRelay)
        XCTAssertTrue(config.canCoordinateHolePunch)
        XCTAssertFalse(config.enableEventLogging)
    }

    func testParseNetwork() throws {
        let config = try DaemonConfig.parse("network=my-network-id")
        XCTAssertEqual(config.network, "my-network-id")
    }

    func testParsePort() throws {
        let config = try DaemonConfig.parse("port=8888")
        XCTAssertEqual(config.port, 8888)
    }

    func testParseNoProvider() throws {
        let config = try DaemonConfig.parse("no-provider=true")
        XCTAssertTrue(config.noProvider)
    }

    func testParseDryRun() throws {
        let config = try DaemonConfig.parse("dry-run=true")
        XCTAssertTrue(config.dryRun)
    }

    func testParseTimeout() throws {
        let config = try DaemonConfig.parse("timeout=3600")
        XCTAssertEqual(config.timeout, 3600)
    }

    func testParseCanRelay() throws {
        let config = try DaemonConfig.parse("can-relay=false")
        XCTAssertFalse(config.canRelay)
    }

    func testParseCanCoordinateHolePunch() throws {
        let config = try DaemonConfig.parse("can-coordinate-hole-punch=false")
        XCTAssertFalse(config.canCoordinateHolePunch)
    }

    func testParseEnableEventLogging() throws {
        let config = try DaemonConfig.parse("enable-event-logging=true")
        XCTAssertTrue(config.enableEventLogging)
    }

    // MARK: - Key Variant Tests

    func testParseKeyVariants() throws {
        // Test different key formats are accepted
        XCTAssertTrue(try DaemonConfig.parse("noProvider=true").noProvider)
        XCTAssertTrue(try DaemonConfig.parse("noprovider=true").noProvider)
        XCTAssertTrue(try DaemonConfig.parse("no_provider=true").noProvider)

        XCTAssertTrue(try DaemonConfig.parse("dryRun=true").dryRun)
        XCTAssertTrue(try DaemonConfig.parse("dryrun=true").dryRun)
        XCTAssertTrue(try DaemonConfig.parse("dry_run=true").dryRun)

        XCTAssertFalse(try DaemonConfig.parse("canRelay=false").canRelay)
        XCTAssertFalse(try DaemonConfig.parse("canrelay=false").canRelay)
        XCTAssertFalse(try DaemonConfig.parse("can_relay=false").canRelay)
        XCTAssertFalse(try DaemonConfig.parse("relay=false").canRelay)

        XCTAssertFalse(try DaemonConfig.parse("canCoordinateHolePunch=false").canCoordinateHolePunch)
        XCTAssertFalse(try DaemonConfig.parse("hole-punch=false").canCoordinateHolePunch)
        XCTAssertFalse(try DaemonConfig.parse("holepunch=false").canCoordinateHolePunch)

        XCTAssertTrue(try DaemonConfig.parse("enableEventLogging=true").enableEventLogging)
        XCTAssertTrue(try DaemonConfig.parse("event-logging=true").enableEventLogging)
        XCTAssertTrue(try DaemonConfig.parse("eventlogging=true").enableEventLogging)
    }

    // MARK: - Value Format Tests

    func testParseBooleanValues() throws {
        // Test "true" and "1" are accepted as true
        XCTAssertTrue(try DaemonConfig.parse("dry-run=true").dryRun)
        XCTAssertTrue(try DaemonConfig.parse("dry-run=TRUE").dryRun)
        XCTAssertTrue(try DaemonConfig.parse("dry-run=True").dryRun)
        XCTAssertTrue(try DaemonConfig.parse("dry-run=1").dryRun)

        // Test other values are false
        XCTAssertFalse(try DaemonConfig.parse("dry-run=false").dryRun)
        XCTAssertFalse(try DaemonConfig.parse("dry-run=0").dryRun)
        XCTAssertFalse(try DaemonConfig.parse("dry-run=yes").dryRun)
    }

    func testParseQuotedValues() throws {
        let config = try DaemonConfig.parse("""
        network="my-network"
        """)
        XCTAssertEqual(config.network, "my-network")

        let config2 = try DaemonConfig.parse("""
        network='my-network'
        """)
        XCTAssertEqual(config2.network, "my-network")
    }

    // MARK: - Comment and Whitespace Tests

    func testParseIgnoresComments() throws {
        let config = try DaemonConfig.parse("""
        # This is a comment
        network=test-network
        # Another comment
        port=8888
        """)
        XCTAssertEqual(config.network, "test-network")
        XCTAssertEqual(config.port, 8888)
    }

    func testParseIgnoresEmptyLines() throws {
        let config = try DaemonConfig.parse("""

        network=test-network

        port=8888

        """)
        XCTAssertEqual(config.network, "test-network")
        XCTAssertEqual(config.port, 8888)
    }

    func testParseHandlesWhitespace() throws {
        let config = try DaemonConfig.parse("""
          network = test-network
          port=8888
        """)
        XCTAssertEqual(config.network, "test-network")
        XCTAssertEqual(config.port, 8888)
    }

    // MARK: - Full Config Test

    func testParseFullConfig() throws {
        let config = try DaemonConfig.parse("""
        # Omerta Daemon Configuration
        network=production-network
        port=9999
        no-provider=false
        dry-run=false
        can-relay=true
        can-coordinate-hole-punch=true
        enable-event-logging=true
        timeout=7200
        """)

        XCTAssertEqual(config.network, "production-network")
        XCTAssertEqual(config.port, 9999)
        XCTAssertFalse(config.noProvider)
        XCTAssertFalse(config.dryRun)
        XCTAssertTrue(config.canRelay)
        XCTAssertTrue(config.canCoordinateHolePunch)
        XCTAssertTrue(config.enableEventLogging)
        XCTAssertEqual(config.timeout, 7200)
    }

    // MARK: - Sample Config Test

    func testSampleConfigIsValid() throws {
        // The sample config should parse without errors
        let sampleConfig = DaemonConfig.sampleConfig()
        let config = try DaemonConfig.parse(sampleConfig)

        // Sample config should have reasonable defaults
        XCTAssertEqual(config.port, 9999)
        XCTAssertTrue(config.canRelay)
        XCTAssertTrue(config.canCoordinateHolePunch)
        XCTAssertFalse(config.enableEventLogging)
    }
}
