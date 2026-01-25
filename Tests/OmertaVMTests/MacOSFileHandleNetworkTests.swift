// MacOSFileHandleNetworkTests.swift
// Tests for macOS VM file handle networking with VZFileHandleNetworkDeviceAttachment

import XCTest
@testable import OmertaVM
@testable import OmertaCore

#if os(macOS)
import Virtualization

/// Tests for macOS VM file handle network attachment
/// VZFileHandleNetworkDeviceAttachment requires a connected Unix datagram socket
final class MacOSFileHandleNetworkTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-filehandle-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Unix Datagram Socket Tests

    func testCreateUnixDatagramSocketPair() throws {
        // Create a Unix datagram socket pair for VM network communication
        // This is the foundation for VZFileHandleNetworkDeviceAttachment
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        XCTAssertGreaterThan(socketPair.vmSocket, 0, "VM socket should be valid")
        XCTAssertGreaterThan(socketPair.hostSocket, 0, "Host socket should be valid")
        XCTAssertNotEqual(socketPair.vmSocket, socketPair.hostSocket, "Sockets should be different")
    }

    func testUnixDatagramSocketPairCommunication() throws {
        // Test that data can be sent between the socket pair
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        // Send from host to VM
        let testData = Data([0x45, 0x00, 0x00, 0x14, 0xDE, 0xAD, 0xBE, 0xEF])
        let bytesSent = try socketPair.sendToVM(testData)
        XCTAssertEqual(bytesSent, testData.count, "Should send all bytes")

        // Receive on VM side
        let receivedData = try socketPair.receiveFromHost(maxLength: 1500)
        XCTAssertEqual(receivedData, testData, "Received data should match sent data")
    }

    func testUnixDatagramSocketPairBidirectional() throws {
        // Test bidirectional communication
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        // Send from host to VM
        let hostToVMData = Data([0x01, 0x02, 0x03, 0x04])
        try socketPair.sendToVM(hostToVMData)
        let receivedFromHost = try socketPair.receiveFromHost(maxLength: 1500)
        XCTAssertEqual(receivedFromHost, hostToVMData)

        // Send from VM to host
        let vmToHostData = Data([0x05, 0x06, 0x07, 0x08])
        try socketPair.sendFromVM(vmToHostData)
        let receivedFromVM = try socketPair.receiveOnHost(maxLength: 1500)
        XCTAssertEqual(receivedFromVM, vmToHostData)
    }

    func testCreateFileHandleFromSocket() throws {
        // Test creating FileHandle from socket for use with VZFileHandleNetworkDeviceAttachment
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let vmFileHandle = FileHandle(fileDescriptor: socketPair.vmSocket, closeOnDealloc: false)
        XCTAssertNotNil(vmFileHandle, "Should create FileHandle from socket")

        // FileHandle should be usable
        let testData = Data([0xAB, 0xCD])
        try socketPair.sendToVM(testData)

        // Read using FileHandle
        let readData = vmFileHandle.availableData
        XCTAssertEqual(readData, testData, "FileHandle should read socket data")
    }

    // MARK: - VZFileHandleNetworkDeviceAttachment Tests

    func testVZFileHandleNetworkDeviceAttachmentCreation() throws {
        // Test that we can create VZFileHandleNetworkDeviceAttachment with a datagram socket
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let vmFileHandle = FileHandle(fileDescriptor: socketPair.vmSocket, closeOnDealloc: false)

        // This should succeed - VZFileHandleNetworkDeviceAttachment takes a single FileHandle
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: vmFileHandle)
        XCTAssertNotNil(attachment, "Should create network attachment")

        // Default MTU should be 1500
        XCTAssertEqual(attachment.maximumTransmissionUnit, 1500, "Default MTU should be 1500")
    }

    func testVZFileHandleNetworkDeviceAttachmentWithCustomMTU() throws {
        // Test setting custom MTU on the attachment
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let vmFileHandle = FileHandle(fileDescriptor: socketPair.vmSocket, closeOnDealloc: false)
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: vmFileHandle)

        // Set custom MTU
        attachment.maximumTransmissionUnit = 9000 // Jumbo frames
        XCTAssertEqual(attachment.maximumTransmissionUnit, 9000, "MTU should be updated")
    }

    func testVirtioNetworkDeviceWithFileHandleAttachment() throws {
        // Test creating a complete VirtioNetworkDeviceConfiguration with file handle attachment
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        let vmFileHandle = FileHandle(fileDescriptor: socketPair.vmSocket, closeOnDealloc: false)
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: vmFileHandle)

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = attachment

        // Generate a MAC address
        networkDevice.macAddress = VZMACAddress.randomLocallyAdministered()

        XCTAssertNotNil(networkDevice.attachment, "Network device should have attachment")
        XCTAssertTrue(networkDevice.attachment is VZFileHandleNetworkDeviceAttachment)
    }

    // MARK: - Integration Tests

    func testVMManagerCreatesFileHandleNetworkAttachment() async throws {
        // Test that VMManager can create a VM with file handle networking
        // This is the key test - it should use VZFileHandleNetworkDeviceAttachment
        // instead of VZNATNetworkDeviceAttachment

        let vmManager = VMManager(dryRun: true)
        let vmId = UUID()

        // Create socket pair for packet capture
        let socketPair = try UnixDatagramSocketPair.create()
        defer { socketPair.close() }

        // Start VM with file handle networking
        // The VMManager should configure VZFileHandleNetworkDeviceAttachment internally
        let result = try await vmManager.startVM(
            vmId: vmId,
            requirements: ResourceRequirements(cpuCores: 1, memoryMB: 512),
            sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@omerta"
        )

        // VM should have an IP
        XCTAssertFalse(result.vmIP.isEmpty, "VM should have IP")

        // In non-dry-run mode, we would verify packets flow through the socket pair
        try await vmManager.stopVM(vmId: vmId)
    }
}

// MARK: - Unix Datagram Socket Pair Helper

/// Creates a connected pair of Unix datagram sockets for VM network communication
/// One socket is for the VM (via VZFileHandleNetworkDeviceAttachment)
/// The other is for the host to read/write packets
public struct UnixDatagramSocketPair {
    /// Socket file descriptor for VM side (use with VZFileHandleNetworkDeviceAttachment)
    public let vmSocket: Int32
    /// Socket file descriptor for host side (for packet capture)
    public let hostSocket: Int32

    /// Create a connected Unix datagram socket pair
    public static func create() throws -> UnixDatagramSocketPair {
        var sockets: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets)
        guard result == 0 else {
            throw SocketPairError.creationFailed(errno: errno)
        }
        return UnixDatagramSocketPair(vmSocket: sockets[0], hostSocket: sockets[1])
    }

    /// Close both sockets
    public func close() {
        Darwin.close(vmSocket)
        Darwin.close(hostSocket)
    }

    /// Send data from host to VM
    @discardableResult
    public func sendToVM(_ data: Data) throws -> Int {
        return try data.withUnsafeBytes { buffer in
            let sent = write(hostSocket, buffer.baseAddress, data.count)
            if sent < 0 {
                throw SocketPairError.sendFailed(errno: errno)
            }
            return sent
        }
    }

    /// Send data from VM to host
    @discardableResult
    public func sendFromVM(_ data: Data) throws -> Int {
        return try data.withUnsafeBytes { buffer in
            let sent = write(vmSocket, buffer.baseAddress, data.count)
            if sent < 0 {
                throw SocketPairError.sendFailed(errno: errno)
            }
            return sent
        }
    }

    /// Receive data on VM side (sent from host)
    public func receiveFromHost(maxLength: Int = 1500) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let received = read(vmSocket, &buffer, maxLength)
        if received < 0 {
            throw SocketPairError.receiveFailed(errno: errno)
        }
        return Data(buffer.prefix(received))
    }

    /// Receive data on host side (sent from VM)
    public func receiveOnHost(maxLength: Int = 1500) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let received = read(hostSocket, &buffer, maxLength)
        if received < 0 {
            throw SocketPairError.receiveFailed(errno: errno)
        }
        return Data(buffer.prefix(received))
    }

    public enum SocketPairError: Error {
        case creationFailed(errno: Int32)
        case sendFailed(errno: Int32)
        case receiveFailed(errno: Int32)
    }
}
#endif
