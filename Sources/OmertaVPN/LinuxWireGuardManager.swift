// LinuxWireGuardManager.swift
// High-level WireGuard management using native Linux netlink APIs
// Replaces dependency on wg-quick and wg CLI tools

#if os(Linux)
import Foundation

/// Peer configuration for WireGuard
public struct WireGuardPeerConfig {
    public let publicKey: Data
    public let endpoint: (host: String, port: UInt16)?
    public let allowedIPs: [(ip: String, cidr: UInt8)]
    public let persistentKeepalive: UInt16?

    public init(
        publicKey: Data,
        endpoint: (host: String, port: UInt16)? = nil,
        allowedIPs: [(ip: String, cidr: UInt8)] = [],
        persistentKeepalive: UInt16? = nil
    ) {
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
    }

    /// Create from base64-encoded public key string
    public init?(
        publicKeyBase64: String,
        endpoint: (host: String, port: UInt16)? = nil,
        allowedIPs: [(ip: String, cidr: UInt8)] = [],
        persistentKeepalive: UInt16? = nil
    ) {
        guard let keyData = Data(base64Encoded: publicKeyBase64), keyData.count == 32 else {
            return nil
        }
        self.publicKey = keyData
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
    }
}

/// Native Linux WireGuard manager using netlink APIs
public class LinuxWireGuardManager {
    private var rtNetlink: RTNetlinkSocket?
    private var wgNetlink: WireGuardNetlinkSocket?

    public init() {}

    /// Create and configure a WireGuard interface
    /// - Parameters:
    ///   - name: Interface name (max 15 chars, e.g., "wg0")
    ///   - privateKey: 32-byte WireGuard private key
    ///   - listenPort: UDP port to listen on (0 for auto-assign)
    ///   - address: Interface IP address (e.g., "10.0.0.1")
    ///   - prefixLength: CIDR prefix length (e.g., 24)
    ///   - peers: List of peer configurations
    public func createInterface(
        name: String,
        privateKey: Data,
        listenPort: UInt16 = 0,
        address: String,
        prefixLength: UInt8,
        peers: [WireGuardPeerConfig] = []
    ) throws {
        // Initialize sockets lazily
        if rtNetlink == nil {
            rtNetlink = try RTNetlinkSocket()
        }
        if wgNetlink == nil {
            wgNetlink = try WireGuardNetlinkSocket()
        }

        guard let rt = rtNetlink, let wg = wgNetlink else {
            throw LinuxWireGuardError.socketInitFailed
        }

        // Step 1: Create WireGuard interface via RTNetlink
        try rt.createWireGuardInterface(name: name)

        // Step 2: Configure private key via WireGuard Generic Netlink
        try wg.setPrivateKey(interface: name, privateKey: privateKey)

        // Step 3: Set listen port if specified
        if listenPort > 0 {
            try wg.setListenPort(interface: name, port: listenPort)
        }

        // Step 4: Add peers
        for peer in peers {
            try wg.addPeer(
                interface: name,
                publicKey: peer.publicKey,
                endpoint: peer.endpoint,
                allowedIPs: peer.allowedIPs,
                persistentKeepalive: peer.persistentKeepalive
            )
        }

        // Step 5: Assign IP address
        try rt.addIPv4Address(interface: name, address: address, prefixLength: prefixLength)

        // Step 6: Bring interface up
        try rt.setInterfaceUp(name: name, up: true)
    }

    /// Create interface from base64-encoded private key
    public func createInterface(
        name: String,
        privateKeyBase64: String,
        listenPort: UInt16 = 0,
        address: String,
        prefixLength: UInt8,
        peers: [WireGuardPeerConfig] = []
    ) throws {
        guard let keyData = Data(base64Encoded: privateKeyBase64), keyData.count == 32 else {
            throw LinuxWireGuardError.invalidPrivateKey
        }
        try createInterface(
            name: name,
            privateKey: keyData,
            listenPort: listenPort,
            address: address,
            prefixLength: prefixLength,
            peers: peers
        )
    }

    /// Add a peer to an existing WireGuard interface
    public func addPeer(interface: String, peer: WireGuardPeerConfig) throws {
        if wgNetlink == nil {
            wgNetlink = try WireGuardNetlinkSocket()
        }
        guard let wg = wgNetlink else {
            throw LinuxWireGuardError.socketInitFailed
        }

        try wg.addPeer(
            interface: interface,
            publicKey: peer.publicKey,
            endpoint: peer.endpoint,
            allowedIPs: peer.allowedIPs,
            persistentKeepalive: peer.persistentKeepalive
        )
    }

    /// Delete a WireGuard interface
    public func deleteInterface(name: String) throws {
        if rtNetlink == nil {
            rtNetlink = try RTNetlinkSocket()
        }
        guard let rt = rtNetlink else {
            throw LinuxWireGuardError.socketInitFailed
        }

        try rt.deleteInterface(name: name)
    }

    /// Set interface up or down
    public func setInterfaceUp(name: String, up: Bool) throws {
        if rtNetlink == nil {
            rtNetlink = try RTNetlinkSocket()
        }
        guard let rt = rtNetlink else {
            throw LinuxWireGuardError.socketInitFailed
        }

        try rt.setInterfaceUp(name: name, up: up)
    }

    /// Check if an interface exists
    public func interfaceExists(name: String) -> Bool {
        do {
            if rtNetlink == nil {
                rtNetlink = try RTNetlinkSocket()
            }
            _ = try rtNetlink?.getInterfaceIndex(name: name)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Linux WireGuard Errors

public enum LinuxWireGuardError: Error, CustomStringConvertible {
    case socketInitFailed
    case invalidPrivateKey
    case invalidPublicKey

    public var description: String {
        switch self {
        case .socketInitFailed:
            return "Failed to initialize netlink sockets"
        case .invalidPrivateKey:
            return "Invalid WireGuard private key (must be 32 bytes base64-encoded)"
        case .invalidPublicKey:
            return "Invalid WireGuard public key (must be 32 bytes base64-encoded)"
        }
    }
}

#endif
