// MacOSPacketCaptureIntegrationTests.swift
// Integration tests for macOS VM packet capture via file handle networking

import XCTest
@testable import OmertaVM
@testable import OmertaCore

#if os(macOS)
import Virtualization

/// Integration tests for packet capture with VZFileHandleNetworkDeviceAttachment
/// These tests verify that packets flow correctly through the file handle socket pair
final class MacOSPacketCaptureIntegrationTests: XCTestCase {

    // MARK: - Ethernet Frame Tests

    func testEthernetFrameConstruction() {
        // Test constructing a minimal Ethernet frame (for testing packet flow)
        let destMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x01]) // locally administered
        let srcMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x02])
        let etherType = Data([0x08, 0x00]) // IPv4

        // Minimal IP header (20 bytes)
        let ipHeader = Data([
            0x45, 0x00, 0x00, 0x14, // Version, IHL, TOS, Total Length
            0x00, 0x01, 0x00, 0x00, // ID, Flags, Fragment Offset
            0x40, 0x06, 0x00, 0x00, // TTL, Protocol (TCP), Checksum
            0x0A, 0x00, 0x00, 0x01, // Source IP: 10.0.0.1
            0x0A, 0x00, 0x00, 0x02  // Dest IP: 10.0.0.2
        ])

        let frame = destMAC + srcMAC + etherType + ipHeader

        XCTAssertEqual(frame.count, 34, "Minimal Ethernet frame should be 34 bytes")
        XCTAssertEqual(frame[12], 0x08, "EtherType should indicate IPv4")
        XCTAssertEqual(frame[13], 0x00)
    }

    func testSocketPairWithEthernetFrames() throws {
        // Test sending Ethernet frames through socket pair
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        // Construct a test Ethernet frame
        let destMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
        let srcMAC = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x02])
        let etherType = Data([0x08, 0x00]) // IPv4
        let payload = Data([0x45, 0x00, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00])

        let frame = destMAC + srcMAC + etherType + payload

        // Send frame from host to VM
        try socketPair.sendToVM(frame)

        // Receive on VM side
        let receivedFrame = try socketPair.receiveFromHost(maxLength: 1500)
        XCTAssertEqual(receivedFrame, frame, "Frame should be received intact")
    }

    func testMultipleFramesThroughSocketPair() throws {
        // Test sending multiple frames sequentially
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let frames: [Data] = (0..<10).map { i in
            Data([0x02, 0x00, 0x00, 0x00, 0x00, UInt8(i)]) +
            Data([0x02, 0x00, 0x00, 0x00, 0x00, 0xFF]) +
            Data([0x08, 0x00]) +
            Data(repeating: UInt8(i), count: 20)
        }

        // Send all frames
        for frame in frames {
            try socketPair.sendToVM(frame)
        }

        // Receive all frames
        for (index, expectedFrame) in frames.enumerated() {
            let receivedFrame = try socketPair.receiveFromHost(maxLength: 1500)
            XCTAssertEqual(receivedFrame, expectedFrame, "Frame \(index) should match")
        }
    }

    // MARK: - FileHandle Integration Tests

    func testFileHandleReadWrite() throws {
        // Test using FileHandle for reading/writing (as VZ framework does)
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let vmFileHandle = FileHandle(fileDescriptor: socketPair.vmSocket, closeOnDealloc: false)
        let hostFileHandle = FileHandle(fileDescriptor: socketPair.hostSocket, closeOnDealloc: false)

        // Write from host to VM
        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
        try hostFileHandle.write(contentsOf: testData)

        // Read on VM side
        let receivedData = vmFileHandle.availableData
        XCTAssertEqual(receivedData, testData, "FileHandle should transfer data correctly")
    }

    func testAsyncFileHandleReading() async throws {
        // Test async reading with FileHandle (simulating VZ's async packet delivery)
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let vmFileHandle = FileHandle(fileDescriptor: socketPair.vmSocket, closeOnDealloc: false)

        // Send data in background
        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        Task {
            try await Task.sleep(for: .milliseconds(50))
            try socketPair.sendToVM(testData)
        }

        // Read with timeout
        let receivedData: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                return nil // Timeout
            }
            group.addTask {
                return vmFileHandle.availableData
            }
            for await result in group {
                if let data = result, !data.isEmpty {
                    group.cancelAll()
                    return data
                }
            }
            return nil
        }

        XCTAssertNotNil(receivedData, "Should receive data")
        XCTAssertEqual(receivedData, testData, "Async read should receive data")
    }

    // MARK: - Packet Capture Bridge Tests

    func testPacketCaptureBridgeWithSocketPair() async throws {
        // Test the packet capture bridge concept
        // This simulates how VMPacketCapture should work with file handle networking

        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        // Simulate VM sending packets first so data is available before reading
        let packets: [Data] = [
            Data([0x45, 0x00, 0x00, 0x14]), // Packet 1
            Data([0x45, 0x00, 0x00, 0x28]), // Packet 2
            Data([0x45, 0x00, 0x00, 0x3C])  // Packet 3
        ]

        for packet in packets {
            try socketPair.sendFromVM(packet)
        }

        // Brief delay to ensure socket buffers are populated
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Read packets from host side
        let hostFileHandle = FileHandle(fileDescriptor: socketPair.hostSocket, closeOnDealloc: false)
        var capturedPackets: [Data] = []
        for _ in 0..<3 {
            let data = hostFileHandle.availableData
            if !data.isEmpty {
                capturedPackets.append(data)
            }
        }

        XCTAssertEqual(capturedPackets.count, 3, "Should capture all packets")
        for (index, packet) in packets.enumerated() {
            XCTAssertEqual(capturedPackets[index], packet, "Packet \(index) should match")
        }
    }

    // MARK: - VZ Network Attachment Validation

    func testVZNetworkAttachmentValidation() throws {
        // Test that VZFileHandleNetworkDeviceAttachment can be used in a VM configuration
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let vmFileHandle = FileHandle(fileDescriptor: socketPair.vmSocket, closeOnDealloc: false)
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: vmFileHandle)

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = attachment
        networkDevice.macAddress = VZMACAddress.randomLocallyAdministered()

        // Create minimal VM configuration to validate
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 1
        config.memorySize = 1024 * 1024 * 1024 // 1GB

        // Add required devices
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.networkDevices = [networkDevice]

        // Note: Full validation requires boot loader and storage
        // This test just verifies network device configuration is valid
        XCTAssertEqual(config.networkDevices.count, 1, "Should have 1 network device")
        XCTAssertTrue(config.networkDevices[0].attachment is VZFileHandleNetworkDeviceAttachment)
    }

    // MARK: - MTU Tests

    func testLargePacketsThroughSocketPair() throws {
        // Test sending MTU-sized packets
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        // Standard MTU (1500 bytes)
        let mtuPacket = Data(repeating: 0x42, count: 1500)
        try socketPair.sendToVM(mtuPacket)
        let received = try socketPair.receiveFromHost(maxLength: 2000)
        XCTAssertEqual(received.count, 1500, "Should handle MTU-sized packets")
    }

    func testJumboFramesThroughSocketPair() throws {
        // Test sending jumbo frames (9000 bytes)
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let jumboPacket = Data(repeating: 0x43, count: 9000)
        try socketPair.sendToVM(jumboPacket)
        let received = try socketPair.receiveFromHost(maxLength: 10000)
        XCTAssertEqual(received.count, 9000, "Should handle jumbo frames")
    }
}
#endif
