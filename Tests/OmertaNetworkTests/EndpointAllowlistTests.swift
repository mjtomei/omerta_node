import XCTest
@testable import OmertaNetwork

final class EndpointAllowlistTests: XCTestCase {

    // MARK: - Endpoint Tests

    func testEndpointCreation() {
        let endpoint = Endpoint(
            address: IPv4Address(10, 99, 0, 1),
            port: 51900
        )

        XCTAssertEqual(endpoint.address, IPv4Address(10, 99, 0, 1))
        XCTAssertEqual(endpoint.port, 51900)
    }

    func testEndpointEquality() {
        let a = Endpoint(address: IPv4Address(192, 168, 1, 1), port: 8080)
        let b = Endpoint(address: IPv4Address(192, 168, 1, 1), port: 8080)
        let c = Endpoint(address: IPv4Address(192, 168, 1, 1), port: 8081)
        let d = Endpoint(address: IPv4Address(192, 168, 1, 2), port: 8080)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "Different ports should not be equal")
        XCTAssertNotEqual(a, d, "Different addresses should not be equal")
    }

    func testEndpointHashable() {
        let a = Endpoint(address: IPv4Address(10, 0, 0, 1), port: 443)
        let b = Endpoint(address: IPv4Address(10, 0, 0, 1), port: 443)
        let c = Endpoint(address: IPv4Address(10, 0, 0, 1), port: 80)

        var set = Set<Endpoint>()
        set.insert(a)
        set.insert(b)
        set.insert(c)

        XCTAssertEqual(set.count, 2, "Same endpoints should hash equally")
    }

    func testEndpointDescription() {
        let endpoint = Endpoint(address: IPv4Address(203, 0, 113, 50), port: 51900)

        XCTAssertEqual(endpoint.description, "203.0.113.50:51900")
    }

    // MARK: - Empty Allowlist Tests

    func testEmptyAllowlistBlocksAll() async {
        let allowlist = EndpointAllowlist()

        let result = await allowlist.isAllowed(
            address: IPv4Address(8, 8, 8, 8),
            port: 53
        )

        XCTAssertFalse(result, "Empty allowlist should block all endpoints")
    }

    func testEmptyAllowlistBlocksEndpoint() async {
        let allowlist = EndpointAllowlist()
        let endpoint = Endpoint(address: IPv4Address(1, 1, 1, 1), port: 443)

        let result = await allowlist.isAllowed(endpoint)

        XCTAssertFalse(result)
    }

    // MARK: - Single Endpoint Tests

    func testSingleEndpointAllowed() async {
        let consumer = Endpoint(address: IPv4Address(203, 0, 113, 50), port: 51900)
        let allowlist = EndpointAllowlist([consumer])

        let result = await allowlist.isAllowed(consumer)

        XCTAssertTrue(result, "Allowed endpoint should pass")
    }

    func testSingleEndpointOthersBlocked() async {
        let consumer = Endpoint(address: IPv4Address(203, 0, 113, 50), port: 51900)
        let allowlist = EndpointAllowlist([consumer])

        let otherIP = await allowlist.isAllowed(
            address: IPv4Address(8, 8, 8, 8),
            port: 53
        )
        let otherPort = await allowlist.isAllowed(
            address: IPv4Address(203, 0, 113, 50),
            port: 443
        )

        XCTAssertFalse(otherIP, "Different IP should be blocked")
        XCTAssertFalse(otherPort, "Different port should be blocked")
    }

    func testPortMismatchBlocked() async {
        let consumer = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let allowlist = EndpointAllowlist([consumer])

        // Same IP, different port
        let result = await allowlist.isAllowed(
            address: IPv4Address(10, 99, 0, 1),
            port: 51901
        )

        XCTAssertFalse(result, "Port mismatch should be blocked")
    }

    func testIPMismatchBlocked() async {
        let consumer = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let allowlist = EndpointAllowlist([consumer])

        // Different IP, same port
        let result = await allowlist.isAllowed(
            address: IPv4Address(10, 99, 0, 2),
            port: 51900
        )

        XCTAssertFalse(result, "IP mismatch should be blocked")
    }

    // MARK: - Multiple Endpoints Tests

    func testMultipleEndpointsAllowed() async {
        let endpoint1 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let endpoint2 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 53)  // DNS on same host
        let allowlist = EndpointAllowlist([endpoint1, endpoint2])

        let result1 = await allowlist.isAllowed(endpoint1)
        let result2 = await allowlist.isAllowed(endpoint2)

        XCTAssertTrue(result1)
        XCTAssertTrue(result2)
    }

    func testMultipleEndpointsOthersBlocked() async {
        let endpoint1 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let endpoint2 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 53)
        let allowlist = EndpointAllowlist([endpoint1, endpoint2])

        let blocked = await allowlist.isAllowed(
            address: IPv4Address(8, 8, 8, 8),
            port: 443
        )

        XCTAssertFalse(blocked)
    }

    // MARK: - Mutation Tests

    func testSetAllowedEndpoints() async {
        let allowlist = EndpointAllowlist()

        let oldEndpoint = Endpoint(address: IPv4Address(1, 1, 1, 1), port: 443)
        let newEndpoint = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)

        // Initially empty
        var result = await allowlist.isAllowed(newEndpoint)
        XCTAssertFalse(result)

        // Add endpoint
        await allowlist.setAllowed([newEndpoint])
        result = await allowlist.isAllowed(newEndpoint)
        XCTAssertTrue(result, "Newly added endpoint should be allowed")

        // Old endpoint still blocked
        result = await allowlist.isAllowed(oldEndpoint)
        XCTAssertFalse(result)
    }

    func testSetAllowedReplacesOld() async {
        let endpoint1 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let endpoint2 = Endpoint(address: IPv4Address(10, 99, 0, 2), port: 51900)

        let allowlist = EndpointAllowlist([endpoint1])

        // endpoint1 allowed initially
        var result = await allowlist.isAllowed(endpoint1)
        XCTAssertTrue(result)

        // Replace with endpoint2
        await allowlist.setAllowed([endpoint2])

        // endpoint1 should now be blocked
        result = await allowlist.isAllowed(endpoint1)
        XCTAssertFalse(result, "Old endpoint should be blocked after replacement")

        // endpoint2 should be allowed
        result = await allowlist.isAllowed(endpoint2)
        XCTAssertTrue(result, "New endpoint should be allowed")
    }

    func testAddEndpoint() async {
        let endpoint1 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let endpoint2 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 53)

        let allowlist = EndpointAllowlist([endpoint1])

        // Add second endpoint
        await allowlist.add(endpoint2)

        // Both should be allowed
        let result1 = await allowlist.isAllowed(endpoint1)
        let result2 = await allowlist.isAllowed(endpoint2)

        XCTAssertTrue(result1)
        XCTAssertTrue(result2)
    }

    func testRemoveEndpoint() async {
        let endpoint1 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let endpoint2 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 53)

        let allowlist = EndpointAllowlist([endpoint1, endpoint2])

        // Remove endpoint1
        await allowlist.remove(endpoint1)

        // endpoint1 should be blocked
        let result1 = await allowlist.isAllowed(endpoint1)
        XCTAssertFalse(result1)

        // endpoint2 should still be allowed
        let result2 = await allowlist.isAllowed(endpoint2)
        XCTAssertTrue(result2)
    }

    func testClear() async {
        let endpoint = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let allowlist = EndpointAllowlist([endpoint])

        // Clear all
        await allowlist.clear()

        let result = await allowlist.isAllowed(endpoint)
        XCTAssertFalse(result, "All endpoints should be blocked after clear")
    }

    // MARK: - Query Tests

    func testCount() async {
        let allowlist = EndpointAllowlist()

        var count = await allowlist.count
        XCTAssertEqual(count, 0)

        let endpoint1 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let endpoint2 = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 53)

        await allowlist.add(endpoint1)
        count = await allowlist.count
        XCTAssertEqual(count, 1)

        await allowlist.add(endpoint2)
        count = await allowlist.count
        XCTAssertEqual(count, 2)

        // Adding same endpoint again shouldn't increase count
        await allowlist.add(endpoint1)
        count = await allowlist.count
        XCTAssertEqual(count, 2)
    }

    func testIsEmpty() async {
        let allowlist = EndpointAllowlist()

        var isEmpty = await allowlist.isEmpty
        XCTAssertTrue(isEmpty)

        let endpoint = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        await allowlist.add(endpoint)

        isEmpty = await allowlist.isEmpty
        XCTAssertFalse(isEmpty)

        await allowlist.clear()
        isEmpty = await allowlist.isEmpty
        XCTAssertTrue(isEmpty)
    }

    func testContains() async {
        let endpoint = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)
        let other = Endpoint(address: IPv4Address(8, 8, 8, 8), port: 53)

        let allowlist = EndpointAllowlist([endpoint])

        let contains1 = await allowlist.contains(endpoint)
        let contains2 = await allowlist.contains(other)

        XCTAssertTrue(contains1)
        XCTAssertFalse(contains2)
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAccess() async {
        let allowlist = EndpointAllowlist()
        let endpoint = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)

        await allowlist.add(endpoint)

        // Concurrent reads
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await allowlist.isAllowed(endpoint)
                }
            }

            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }

            XCTAssertEqual(results.count, 100)
            XCTAssertTrue(results.allSatisfy { $0 }, "All concurrent reads should return true")
        }
    }

    func testConcurrentReadWrite() async {
        let allowlist = EndpointAllowlist()
        let endpoint = Endpoint(address: IPv4Address(10, 99, 0, 1), port: 51900)

        // Mix of reads and writes
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<10 {
                group.addTask {
                    let ep = Endpoint(address: IPv4Address(10, 99, 0, UInt8(i)), port: 51900)
                    await allowlist.add(ep)
                }
            }

            // Readers
            for _ in 0..<50 {
                group.addTask {
                    _ = await allowlist.isAllowed(endpoint)
                }
            }

            await group.waitForAll()
        }

        // Should have 10 endpoints
        let count = await allowlist.count
        XCTAssertEqual(count, 10)
    }
}
