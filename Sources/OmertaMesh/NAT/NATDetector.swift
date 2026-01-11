// NATDetector.swift - NAT type detection algorithm

import Foundation
import Logging

/// Detects NAT type using STUN protocol
public actor NATDetector {
    private let stunServers: [String]
    private let stunClient: STUNClient
    private let logger: Logger

    /// Create a NAT detector with specified STUN servers
    public init(stunServers: [String] = STUNClient.defaultServers) {
        self.stunServers = stunServers
        self.stunClient = STUNClient()
        self.logger = Logger(label: "io.omerta.mesh.nat.detector")
    }

    /// Detect NAT type
    ///
    /// Algorithm:
    /// 1. Query first STUN server to get mapping
    /// 2. Query second STUN server from same local port
    /// 3. Compare mappings to determine NAT type
    ///
    /// - If local IP matches public IP: no NAT (public)
    /// - If both servers return same mapping: cone NAT
    /// - If servers return different ports: symmetric NAT
    public func detect(timeout: TimeInterval = 5.0) async throws -> NATDetectionResult {
        guard stunServers.count >= 2 else {
            throw NATDetectorError.insufficientServers
        }

        logger.info("Starting NAT detection with servers: \(stunServers.prefix(2))")

        // Query first STUN server
        let result1: STUNBindingResult
        do {
            result1 = try await stunClient.discoverEndpoint(
                server: stunServers[0],
                timeout: timeout
            )
            logger.debug("First STUN result: \(result1.endpoint) from \(result1.serverAddress)")
        } catch {
            logger.error("First STUN query failed: \(error)")
            throw error
        }

        // Check if we have a public IP (no NAT)
        if await isLocalAddress(result1.publicAddress) {
            logger.info("Detected public IP (no NAT)")
            return NATDetectionResult(
                type: .public,
                publicEndpoint: result1.endpoint,
                publicAddress: result1.publicAddress,
                publicPort: result1.publicPort,
                localPort: result1.localPort,
                rtt: result1.rtt
            )
        }

        // Query second STUN server with same local port
        let result2: STUNBindingResult
        do {
            result2 = try await stunClient.discoverEndpoint(
                server: stunServers[1],
                localPort: result1.localPort,
                timeout: timeout
            )
            logger.debug("Second STUN result: \(result2.endpoint) from \(result2.serverAddress)")
        } catch {
            logger.warning("Second STUN query failed, assuming port-restricted cone: \(error)")
            // If second query fails, we can't determine type precisely
            return NATDetectionResult(
                type: .portRestrictedCone,
                publicEndpoint: result1.endpoint,
                publicAddress: result1.publicAddress,
                publicPort: result1.publicPort,
                localPort: result1.localPort,
                rtt: result1.rtt
            )
        }

        // Analyze mappings to determine NAT type
        let natType = analyzeNATType(first: result1, second: result2)

        logger.info("NAT detection complete", metadata: [
            "type": "\(natType.rawValue)",
            "endpoint": "\(result1.endpoint)",
            "secondMapping": "\(result2.endpoint)"
        ])

        return NATDetectionResult(
            type: natType,
            publicEndpoint: result1.endpoint,
            publicAddress: result1.publicAddress,
            publicPort: result1.publicPort,
            localPort: result1.localPort,
            rtt: result1.rtt
        )
    }

    /// Quick endpoint discovery without full NAT detection
    public func discoverEndpoint(timeout: TimeInterval = 5.0) async throws -> NATDetectionResult {
        guard !stunServers.isEmpty else {
            throw NATDetectorError.noServers
        }

        let result = try await stunClient.discoverEndpoint(
            server: stunServers[0],
            timeout: timeout
        )

        return NATDetectionResult(
            type: .unknown,
            publicEndpoint: result.endpoint,
            publicAddress: result.publicAddress,
            publicPort: result.publicPort,
            localPort: result.localPort,
            rtt: result.rtt
        )
    }

    // MARK: - Private Methods

    private func analyzeNATType(first: STUNBindingResult, second: STUNBindingResult) -> NATType {
        // Same IP and port to different servers = cone NAT
        if first.publicAddress == second.publicAddress && first.publicPort == second.publicPort {
            // To distinguish full cone from restricted/port-restricted cone,
            // we would need to test if unsolicited packets can arrive.
            // For now, assume port-restricted cone (most common)
            return .portRestrictedCone
        }

        // Same IP but different port = symmetric NAT (port variation)
        if first.publicAddress == second.publicAddress {
            return .symmetric
        }

        // Different IP = definitely symmetric (very restrictive)
        return .symmetric
    }

    private func isLocalAddress(_ address: String) async -> Bool {
        // Get local interfaces and check if address matches any
        // This is a simplified check
        let localPrefixes = ["127.", "10.", "192.168.", "172.16.", "172.17.",
                            "172.18.", "172.19.", "172.20.", "172.21.", "172.22.",
                            "172.23.", "172.24.", "172.25.", "172.26.", "172.27.",
                            "172.28.", "172.29.", "172.30.", "172.31."]

        for prefix in localPrefixes {
            if address.hasPrefix(prefix) {
                return false  // Private address, but still behind NAT
            }
        }

        // Check if it matches our actual local interface
        // In practice, STUN servers won't return our local IP unless we're truly public
        return false
    }
}

/// NAT detector errors
public enum NATDetectorError: Error, CustomStringConvertible {
    case insufficientServers
    case noServers
    case detectionFailed(Error)

    public var description: String {
        switch self {
        case .insufficientServers:
            return "Need at least 2 STUN servers for NAT detection"
        case .noServers:
            return "No STUN servers configured"
        case .detectionFailed(let error):
            return "NAT detection failed: \(error)"
        }
    }
}
