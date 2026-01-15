import XCTest
@testable import OmertaVPN

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class UDPForwarderTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitializationWithDefaultPort() async throws {
        let forwarder = try await UDPForwarder()

        // Should have bound to an ephemeral port
        let localPort = await forwarder.localPort
        XCTAssertGreaterThan(localPort, 0, "Should bind to an ephemeral port")
    }

    func testInitializationWithSpecificPort() async throws {
        // Use a high port that's likely available
        let forwarder = try await UDPForwarder(localPort: 59123)

        let localPort = await forwarder.localPort
        XCTAssertEqual(localPort, 59123)

        await forwarder.close()
    }

    // MARK: - Echo Server Tests

    func testSendAndReceive() async throws {
        // Start echo server on a known port
        let echoPort: UInt16 = 59200
        let echoServer = try await UDPEchoServer(port: echoPort)
        await echoServer.start()
        defer { Task { await echoServer.stop() } }

        let forwarder = try await UDPForwarder()
        defer { Task { await forwarder.close() } }

        // Send data to echo server
        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let destination = Endpoint(
            address: IPv4Address(127, 0, 0, 1),
            port: echoPort
        )

        try await forwarder.send(testData, to: destination)

        // Receive echoed response
        let (receivedData, from) = try await forwarder.receive(timeout: 1.0)

        XCTAssertEqual(receivedData, testData, "Should receive same data back")
        XCTAssertEqual(from.address, IPv4Address(127, 0, 0, 1))
        XCTAssertEqual(from.port, echoPort)
    }

    func testMultipleSequentialSends() async throws {
        let echoPort: UInt16 = 59201
        let echoServer = try await UDPEchoServer(port: echoPort)
        await echoServer.start()
        defer { Task { await echoServer.stop() } }

        let forwarder = try await UDPForwarder()
        defer { Task { await forwarder.close() } }

        let destination = Endpoint(
            address: IPv4Address(127, 0, 0, 1),
            port: echoPort
        )

        // Send multiple packets
        for i in 0..<5 {
            let testData = Data([UInt8(i), 0xAA, 0xBB, 0xCC])
            try await forwarder.send(testData, to: destination)

            let (receivedData, _) = try await forwarder.receive(timeout: 1.0)
            XCTAssertEqual(receivedData, testData, "Packet \(i) should match")
        }
    }

    func testLargePacket() async throws {
        let echoPort: UInt16 = 59202
        let echoServer = try await UDPEchoServer(port: echoPort)
        await echoServer.start()
        defer { Task { await echoServer.stop() } }

        let forwarder = try await UDPForwarder()
        defer { Task { await forwarder.close() } }

        // Send a large packet (typical WireGuard packet size)
        let testData = Data(repeating: 0x42, count: 1400)
        let destination = Endpoint(
            address: IPv4Address(127, 0, 0, 1),
            port: echoPort
        )

        try await forwarder.send(testData, to: destination)

        let (receivedData, _) = try await forwarder.receive(timeout: 1.0)
        XCTAssertEqual(receivedData, testData)
    }

    // MARK: - Error Handling Tests

    func testReceiveTimeout() async throws {
        let forwarder = try await UDPForwarder()
        defer { Task { await forwarder.close() } }

        // Try to receive with no data coming - should timeout
        do {
            _ = try await forwarder.receive(timeout: 0.1)
            XCTFail("Should have thrown timeout error")
        } catch let error as UDPForwarderError {
            XCTAssertEqual(error, .receiveTimeout)
        }
    }

    func testSendToUnreachableHost() async throws {
        let forwarder = try await UDPForwarder()
        defer { Task { await forwarder.close() } }

        // Try to send to a non-routable address
        // UDP is connectionless, so this won't fail immediately
        // but we can verify the send completes without throwing
        let destination = Endpoint(
            address: IPv4Address(192, 0, 2, 1),  // TEST-NET-1, not routable
            port: 12345
        )

        // This should not throw - UDP is connectionless
        try await forwarder.send(Data([0x01, 0x02]), to: destination)
    }

    func testSendAfterClose() async throws {
        let forwarder = try await UDPForwarder()
        await forwarder.close()

        let destination = Endpoint(
            address: IPv4Address(127, 0, 0, 1),
            port: 12345
        )

        do {
            try await forwarder.send(Data([0x01]), to: destination)
            XCTFail("Should have thrown error")
        } catch let error as UDPForwarderError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testReceiveAfterClose() async throws {
        let forwarder = try await UDPForwarder()
        await forwarder.close()

        do {
            _ = try await forwarder.receive(timeout: 1.0)
            XCTFail("Should have thrown error")
        } catch let error as UDPForwarderError {
            XCTAssertEqual(error, .closed)
        }
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentSends() async throws {
        let echoPort: UInt16 = 59203
        let echoServer = try await UDPEchoServer(port: echoPort)
        await echoServer.start()
        defer { Task { await echoServer.stop() } }

        let forwarder = try await UDPForwarder()
        defer { Task { await forwarder.close() } }

        let destination = Endpoint(
            address: IPv4Address(127, 0, 0, 1),
            port: echoPort
        )

        // Send 10 packets concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let data = Data([UInt8(i)])
                    try? await forwarder.send(data, to: destination)
                }
            }
        }

        // Receive all responses (order may vary)
        var received = Set<UInt8>()
        for _ in 0..<10 {
            if let (data, _) = try? await forwarder.receive(timeout: 1.0),
               let byte = data.first {
                received.insert(byte)
            }
        }

        XCTAssertEqual(received.count, 10, "Should receive all 10 responses")
    }

    // MARK: - Endpoint Verification Tests

    func testReceiveFromEndpoint() async throws {
        let echoPort: UInt16 = 59204
        let echoServer = try await UDPEchoServer(port: echoPort)
        await echoServer.start()
        defer { Task { await echoServer.stop() } }

        let forwarder = try await UDPForwarder()
        defer { Task { await forwarder.close() } }

        let destination = Endpoint(
            address: IPv4Address(127, 0, 0, 1),
            port: echoPort
        )

        try await forwarder.send(Data([0xAB]), to: destination)

        let (_, from) = try await forwarder.receive(timeout: 1.0)

        // Verify we got response from the expected endpoint
        XCTAssertEqual(from.address, destination.address)
        XCTAssertEqual(from.port, destination.port)
    }
}

// MARK: - Test Helpers

/// Simple UDP echo server for testing
actor UDPEchoServer {
    private let port: UInt16
    private var socket: Int32 = -1
    private var running = false
    private var task: Task<Void, Never>?

    init(port: UInt16) {
        self.port = port
    }

    func start() async {
        #if canImport(Darwin)
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        #else
        socket = Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif
        guard socket >= 0 else { return }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            #if canImport(Darwin)
            Darwin.close(socket)
            #else
            Glibc.close(socket)
            #endif
            socket = -1
            return
        }

        running = true
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while running && socket >= 0 {
            let bytesRead = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    recvfrom(socket, &buffer, buffer.count, 0, sockaddrPtr, &clientLen)
                }
            }

            if bytesRead > 0 {
                // Echo back
                withUnsafePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        _ = sendto(socket, &buffer, bytesRead, 0, sockaddrPtr, clientLen)
                    }
                }
            }
        }
    }

    func stop() {
        running = false
        if socket >= 0 {
            #if canImport(Darwin)
            Darwin.close(socket)
            #else
            Glibc.close(socket)
            #endif
            socket = -1
        }
        task?.cancel()
    }
}
