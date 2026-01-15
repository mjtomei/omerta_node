// MacOSWireGuard.swift
// Native macOS WireGuard implementation using utun interfaces
// Implements WireGuard protocol in userspace without external binaries

#if os(macOS)
import Foundation
import Crypto
import Logging

/// WireGuard peer configuration
public struct WireGuardPeer {
    public let publicKey: Data          // 32 bytes
    public var endpoint: (host: String, port: UInt16)?
    public var allowedIPs: [(ip: String, cidr: UInt8)]
    public var persistentKeepalive: UInt16?
    public var presharedKey: Data?      // Optional 32 bytes

    // Runtime state
    var lastHandshake: Date?
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0

    public init(
        publicKey: Data,
        endpoint: (host: String, port: UInt16)? = nil,
        allowedIPs: [(ip: String, cidr: UInt8)] = [],
        persistentKeepalive: UInt16? = nil,
        presharedKey: Data? = nil
    ) {
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
        self.presharedKey = presharedKey
    }

    /// Create from base64-encoded public key
    public init?(
        publicKeyBase64: String,
        endpoint: (host: String, port: UInt16)? = nil,
        allowedIPs: [(ip: String, cidr: UInt8)] = [],
        persistentKeepalive: UInt16? = nil
    ) {
        guard let keyData = Data(base64Encoded: publicKeyBase64), keyData.count == 32 else {
            return nil
        }
        self.init(publicKey: keyData, endpoint: endpoint, allowedIPs: allowedIPs, persistentKeepalive: persistentKeepalive)
    }
}

/// WireGuard interface configuration
public struct WireGuardConfig {
    public var privateKey: Data         // 32 bytes
    public var listenPort: UInt16
    public var address: String          // Interface IP
    public var prefixLength: UInt8
    public var peers: [WireGuardPeer]
    public var mtu: Int32

    public init(
        privateKey: Data,
        listenPort: UInt16 = 0,
        address: String,
        prefixLength: UInt8 = 24,
        peers: [WireGuardPeer] = [],
        mtu: Int32 = 1420
    ) {
        self.privateKey = privateKey
        self.listenPort = listenPort
        self.address = address
        self.prefixLength = prefixLength
        self.peers = peers
        self.mtu = mtu
    }

    /// Create from base64-encoded private key
    public init?(
        privateKeyBase64: String,
        listenPort: UInt16 = 0,
        address: String,
        prefixLength: UInt8 = 24,
        peers: [WireGuardPeer] = [],
        mtu: Int32 = 1420
    ) {
        guard let keyData = Data(base64Encoded: privateKeyBase64), keyData.count == 32 else {
            return nil
        }
        self.init(privateKey: keyData, listenPort: listenPort, address: address, prefixLength: prefixLength, peers: peers, mtu: mtu)
    }

    /// Derive public key from private key
    public func publicKey() throws -> Data {
        let privateKeyObj = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        return privateKeyObj.publicKey.rawRepresentation
    }
}

/// Errors for WireGuard operations
public enum WireGuardError: Error, CustomStringConvertible {
    case invalidKey(String)
    case interfaceCreationFailed(String)
    case socketError(String)
    case handshakeFailed(String)
    case encryptionFailed(String)
    case notRunning

    public var description: String {
        switch self {
        case .invalidKey(let msg): return "Invalid key: \(msg)"
        case .interfaceCreationFailed(let msg): return "Interface creation failed: \(msg)"
        case .socketError(let msg): return "Socket error: \(msg)"
        case .handshakeFailed(let msg): return "Handshake failed: \(msg)"
        case .encryptionFailed(let msg): return "Encryption failed: \(msg)"
        case .notRunning: return "WireGuard interface not running"
        }
    }
}

/// Native macOS WireGuard manager
/// Creates and manages WireGuard tunnels using utun interfaces
public actor MacOSWireGuardManager {
    private let logger = Logger(label: "com.omerta.macos-wireguard")

    private var utunFd: Int32 = -1
    private var interfaceName: String = ""
    private var udpSocket: Int32 = -1
    private var config: WireGuardConfig?
    private var isRunning = false
    private var packetTask: Task<Void, Never>?

    // Noise protocol state for each peer
    private var peerStates: [Data: PeerState] = [:]  // keyed by public key

    public init() {}

    /// Create and start a WireGuard interface
    public func start(name: String? = nil, config: WireGuardConfig) async throws {
        guard !isRunning else { return }

        self.config = config

        // Create utun interface
        let (fd, ifName) = try MacOSUtunManager.createInterface()
        self.utunFd = fd
        self.interfaceName = ifName

        logger.info("Created utun interface", metadata: ["interface": "\(ifName)"])

        // Configure interface
        try MacOSUtunManager.setMTU(interface: ifName, mtu: config.mtu)
        try MacOSUtunManager.addIPv4Address(interface: ifName, address: config.address, prefixLength: config.prefixLength)
        try MacOSUtunManager.setInterfaceUp(interface: ifName, up: true)

        logger.info("Configured interface", metadata: [
            "interface": "\(ifName)",
            "address": "\(config.address)/\(config.prefixLength)"
        ])

        // Create UDP socket for WireGuard protocol
        udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
        guard udpSocket >= 0 else {
            throw WireGuardError.socketError("Failed to create UDP socket")
        }

        // Bind to listen port if specified
        if config.listenPort > 0 {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = config.listenPort.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY

            let bindResult = withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(udpSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bindResult >= 0 else {
                throw WireGuardError.socketError("Failed to bind UDP socket: \(String(cString: strerror(errno)))")
            }

            logger.info("Bound UDP socket", metadata: ["port": "\(config.listenPort)"])
        }

        // Add routes for peer allowed IPs
        for peer in config.peers {
            for (ip, cidr) in peer.allowedIPs {
                do {
                    try MacOSRoutingManager.addRoute(destination: ip, prefixLength: cidr, interface: ifName)
                    logger.info("Added route", metadata: ["destination": "\(ip)/\(cidr)", "interface": "\(ifName)"])
                } catch {
                    logger.warning("Failed to add route", metadata: ["error": "\(error)"])
                }
            }

            // Initialize peer state
            peerStates[peer.publicKey] = PeerState(peer: peer)
        }

        isRunning = true

        // Start packet processing
        packetTask = Task { [weak self] in
            await self?.processPackets()
        }

        logger.info("WireGuard interface started", metadata: ["interface": "\(ifName)"])
    }

    /// Stop the WireGuard interface
    public func stop() async {
        guard isRunning else { return }

        packetTask?.cancel()
        packetTask = nil

        // Remove routes
        if let config = config {
            for peer in config.peers {
                for (ip, cidr) in peer.allowedIPs {
                    try? MacOSRoutingManager.deleteRoute(destination: ip, prefixLength: cidr)
                }
            }
        }

        // Close sockets
        if udpSocket >= 0 {
            close(udpSocket)
            udpSocket = -1
        }

        // Close utun
        if utunFd >= 0 {
            MacOSUtunManager.closeInterface(fd: utunFd)
            utunFd = -1
        }

        isRunning = false
        config = nil
        peerStates.removeAll()

        logger.info("WireGuard interface stopped", metadata: ["interface": "\(interfaceName)"])
    }

    /// Get the interface name
    public func getInterfaceName() -> String {
        return interfaceName
    }

    /// Get public key derived from private key
    public func getPublicKey() throws -> String {
        guard let config = config else {
            throw WireGuardError.notRunning
        }
        return try config.publicKey().base64EncodedString()
    }

    /// Add a peer dynamically
    public func addPeer(_ peer: WireGuardPeer) async throws {
        guard isRunning else {
            throw WireGuardError.notRunning
        }

        logger.info("addPeer: starting", metadata: ["interface": "\(interfaceName)"])

        // Add routes for peer
        for (ip, cidr) in peer.allowedIPs {
            logger.info("addPeer: adding route", metadata: ["ip": "\(ip)", "cidr": "\(cidr)"])
            try MacOSRoutingManager.addRoute(destination: ip, prefixLength: cidr, interface: interfaceName)
            logger.info("addPeer: route added")
        }

        logger.info("addPeer: updating peer state")

        // Initialize peer state
        peerStates[peer.publicKey] = PeerState(peer: peer)

        // Update config
        config?.peers.append(peer)

        logger.info("Added peer", metadata: [
            "public_key": "\(peer.publicKey.base64EncodedString().prefix(20))..."
        ])
    }

    /// Get peer statistics
    public func getPeerStats() -> [(publicKey: String, rxBytes: UInt64, txBytes: UInt64, lastHandshake: Date?)] {
        return peerStates.map { (key, state) in
            (key.base64EncodedString(), state.rxBytes, state.txBytes, state.lastHandshake)
        }
    }

    // MARK: - Packet Processing

    private func processPackets() async {
        // Use non-blocking I/O with select/poll for both utun and UDP socket
        guard utunFd >= 0 && udpSocket >= 0 else { return }

        // Set non-blocking
        var flags = fcntl(utunFd, F_GETFL, 0)
        fcntl(utunFd, F_SETFL, flags | O_NONBLOCK)
        flags = fcntl(udpSocket, F_GETFL, 0)
        fcntl(udpSocket, F_SETFL, flags | O_NONBLOCK)

        var utunBuffer = [UInt8](repeating: 0, count: 2048)
        var udpBuffer = [UInt8](repeating: 0, count: 2048)

        while !Task.isCancelled && isRunning {
            // Yield to allow other actor operations to proceed
            await Task.yield()

            // Use select to wait for activity on either socket
            var readfds = fd_set()
            __darwin_fd_zero(&readfds)

            let maxFd = max(utunFd, udpSocket)
            withUnsafeMutablePointer(to: &readfds) { ptr in
                __darwin_fd_set(utunFd, ptr)
                __darwin_fd_set(udpSocket, ptr)
            }

            var timeout = timeval(tv_sec: 0, tv_usec: 100_000) // 100ms timeout
            let selectResult = select(maxFd + 1, &readfds, nil, nil, &timeout)

            if selectResult < 0 {
                if errno == EINTR { continue }
                break
            }

            // Check for packets from utun (outbound)
            if __darwin_fd_isset(utunFd, &readfds) != 0 {
                let bytesRead = read(utunFd, &utunBuffer, utunBuffer.count)
                if bytesRead > 4 {
                    // Process outbound packet
                    await handleOutboundPacket(Data(utunBuffer[4..<bytesRead]))
                }
            }

            // Check for packets from UDP (inbound WireGuard)
            if __darwin_fd_isset(udpSocket, &readfds) != 0 {
                var srcAddr = sockaddr_in()
                var srcAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

                let bytesRead = withUnsafeMutablePointer(to: &srcAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        recvfrom(udpSocket, &udpBuffer, udpBuffer.count, 0, sockaddrPtr, &srcAddrLen)
                    }
                }

                if bytesRead > 0 {
                    let sourceIP = String(cString: inet_ntoa(srcAddr.sin_addr))
                    let sourcePort = UInt16(bigEndian: srcAddr.sin_port)
                    await handleInboundPacket(Data(udpBuffer[0..<bytesRead]), from: (sourceIP, sourcePort))
                }
            }
        }
    }

    private func handleOutboundPacket(_ packet: Data) async {
        // Determine which peer should receive this packet based on destination IP
        guard packet.count >= 20 else { return }

        // Parse destination IP from IP header (bytes 16-19 for IPv4)
        let destIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"

        // Find matching peer
        guard let peer = findPeerForDestination(destIP),
              let state = peerStates[peer.publicKey],
              let endpoint = peer.endpoint else {
            logger.debug("No peer found for destination", metadata: ["dest": "\(destIP)"])
            return
        }

        // Encrypt and send via WireGuard protocol
        do {
            let encrypted = try await encryptPacket(packet, for: peer, state: state)
            try sendUDPPacket(encrypted, to: endpoint)
            peerStates[peer.publicKey]?.txBytes += UInt64(packet.count)
        } catch {
            logger.warning("Failed to encrypt/send packet", metadata: ["error": "\(error)"])
        }
    }

    private func handleInboundPacket(_ packet: Data, from source: (ip: String, port: UInt16)) async {
        // Decrypt WireGuard packet and write to utun
        guard packet.count >= 4 else { return }

        // Parse WireGuard message type
        let messageType = packet[0]

        switch messageType {
        case 1: // Handshake initiation
            await handleHandshakeInit(packet, from: source)
        case 2: // Handshake response
            await handleHandshakeResponse(packet, from: source)
        case 3: // Cookie reply
            break // TODO
        case 4: // Data
            await handleDataPacket(packet, from: source)
        default:
            logger.warning("Unknown WireGuard message type", metadata: ["type": "\(messageType)"])
        }
    }

    private func findPeerForDestination(_ destIP: String) -> WireGuardPeer? {
        guard let config = config else { return nil }

        for peer in config.peers {
            for (network, cidr) in peer.allowedIPs {
                if ipMatchesNetwork(destIP, network: network, cidr: cidr) {
                    return peer
                }
            }
        }
        return nil
    }

    private func ipMatchesNetwork(_ ip: String, network: String, cidr: UInt8) -> Bool {
        // Simple matching - convert to integers and compare with mask
        guard let ipInt = ipToInt(ip), let netInt = ipToInt(network) else {
            return false
        }
        let mask = cidr >= 32 ? UInt32.max : (UInt32.max << (32 - cidr))
        return (ipInt & mask) == (netInt & mask)
    }

    private func ipToInt(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    // MARK: - WireGuard Protocol

    private func encryptPacket(_ packet: Data, for peer: WireGuardPeer, state: PeerState) async throws -> Data {
        // Simplified - in production, use proper Noise protocol handshake
        // This is a placeholder for the full ChaCha20-Poly1305 encryption

        guard let sharedSecret = state.sharedSecret else {
            // Need to initiate handshake first
            try await initiateHandshake(with: peer)
            throw WireGuardError.handshakeFailed("Handshake in progress")
        }

        // WireGuard data message format:
        // Type (1) | Reserved (3) | Receiver Index (4) | Counter (8) | Encrypted Data + Tag (16)
        var message = Data()
        message.append(4) // Type: Data
        message.append(contentsOf: [0, 0, 0]) // Reserved
        message.append(contentsOf: withUnsafeBytes(of: state.receiverIndex.littleEndian) { Array($0) })
        message.append(contentsOf: withUnsafeBytes(of: state.sendCounter.littleEndian) { Array($0) })

        // Encrypt with ChaCha20-Poly1305
        let nonce = try ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: state.sendCounter.littleEndian) { Data($0) })
        let sealedBox = try ChaChaPoly.seal(packet, using: sharedSecret, nonce: nonce)
        message.append(sealedBox.ciphertext)
        message.append(sealedBox.tag)

        peerStates[peer.publicKey]?.sendCounter += 1

        return message
    }

    private func initiateHandshake(with peer: WireGuardPeer) async throws {
        guard let config = config else { throw WireGuardError.notRunning }

        // Generate ephemeral keypair
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()

        // Build handshake initiation message
        // This is a simplified version - full implementation needs Noise IK pattern
        var message = Data()
        message.append(1) // Type: Handshake initiation
        message.append(contentsOf: [0, 0, 0]) // Reserved

        // Sender index (random 4 bytes)
        var senderIndex = UInt32.random(in: 0...UInt32.max)
        message.append(contentsOf: withUnsafeBytes(of: senderIndex.littleEndian) { Array($0) })

        // Encrypted ephemeral public key (using peer's public key)
        message.append(ephemeralKey.publicKey.rawRepresentation)

        // In full implementation: encrypt static public key and timestamp

        if let endpoint = peer.endpoint {
            try sendUDPPacket(message, to: endpoint)
            logger.info("Sent handshake initiation", metadata: [
                "peer": "\(peer.publicKey.base64EncodedString().prefix(20))..."
            ])
        }
    }

    private func handleHandshakeInit(_ packet: Data, from source: (ip: String, port: UInt16)) async {
        // Handle incoming handshake initiation
        logger.info("Received handshake initiation", metadata: ["from": "\(source.ip):\(source.port)"])
        // TODO: Implement full Noise IK handshake response
    }

    private func handleHandshakeResponse(_ packet: Data, from source: (ip: String, port: UInt16)) async {
        // Handle handshake response, derive session keys
        logger.info("Received handshake response", metadata: ["from": "\(source.ip):\(source.port)"])
        // TODO: Complete handshake, derive transport keys
    }

    private func handleDataPacket(_ packet: Data, from source: (ip: String, port: UInt16)) async {
        guard packet.count > 16 else { return }

        // Find peer by receiver index
        let receiverIndex = packet[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

        guard let (publicKey, state) = peerStates.first(where: { $0.value.senderIndex == receiverIndex }),
              let sharedSecret = state.sharedSecret else {
            logger.warning("Unknown receiver index", metadata: ["index": "\(receiverIndex)"])
            return
        }

        // Decrypt
        let counter = packet[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let ciphertext = packet[16..<(packet.count - 16)]
        let tag = packet[(packet.count - 16)...]

        do {
            let nonce = try ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: counter.littleEndian) { Data($0) })
            let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let decrypted = try ChaChaPoly.open(sealedBox, using: sharedSecret)

            // Write decrypted packet to utun
            try writeToUtun(decrypted)
            peerStates[publicKey]?.rxBytes += UInt64(decrypted.count)
            peerStates[publicKey]?.lastHandshake = Date()
        } catch {
            logger.warning("Failed to decrypt packet", metadata: ["error": "\(error)"])
        }
    }

    private func sendUDPPacket(_ data: Data, to endpoint: (host: String, port: UInt16)) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        inet_pton(AF_INET, endpoint.host, &addr.sin_addr)

        let result = data.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(udpSocket, dataPtr.baseAddress, data.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard result >= 0 else {
            throw WireGuardError.socketError("sendto failed: \(String(cString: strerror(errno)))")
        }
    }

    private func writeToUtun(_ packet: Data) throws {
        // Prepend 4-byte protocol header (AF_INET or AF_INET6)
        let isIPv6 = packet.count > 0 && (packet[0] >> 4) == 6
        let proto: UInt32 = isIPv6 ? UInt32(AF_INET6) : UInt32(AF_INET)

        var fullPacket = Data()
        fullPacket.append(contentsOf: withUnsafeBytes(of: proto.bigEndian) { Array($0) })
        fullPacket.append(packet)

        let result = fullPacket.withUnsafeBytes { ptr in
            write(utunFd, ptr.baseAddress, fullPacket.count)
        }

        guard result == fullPacket.count else {
            throw WireGuardError.socketError("write to utun failed")
        }
    }
}

// MARK: - Peer State

private class PeerState {
    let peer: WireGuardPeer
    var senderIndex: UInt32 = 0
    var receiverIndex: UInt32 = 0
    var sendCounter: UInt64 = 0
    var receiveCounter: UInt64 = 0
    var sharedSecret: SymmetricKey?
    var lastHandshake: Date?
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0

    init(peer: WireGuardPeer) {
        self.peer = peer
        self.senderIndex = UInt32.random(in: 0...UInt32.max)
    }
}

// Helper for fd_set operations - macOS uses fds_bits (not __fds_bits)
private func __darwin_fd_zero(_ set: UnsafeMutablePointer<fd_set>) {
    // Zero all bits - macOS fd_set is 32 x 32-bit words = 1024 bits
    withUnsafeMutablePointer(to: &set.pointee.fds_bits) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: 128) { bytes in
            for i in 0..<128 {
                bytes[i] = 0
            }
        }
    }
}

private func __darwin_fd_set(_ fd: Int32, _ set: UnsafeMutablePointer<fd_set>) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutablePointer(to: &set.pointee.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= Int32(1 << bitOffset)
        }
    }
}

private func __darwin_fd_isset(_ fd: Int32, _ set: UnsafeMutablePointer<fd_set>) -> Int32 {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    return withUnsafePointer(to: &set.pointee.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            (bits[intOffset] & Int32(1 << bitOffset)) != 0 ? 1 : 0
        }
    }
}

#endif
