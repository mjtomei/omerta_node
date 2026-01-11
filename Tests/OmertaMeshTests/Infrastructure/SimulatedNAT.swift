// SimulatedNAT.swift - Simulates NAT behavior for testing

import Foundation
@testable import OmertaMesh

/// Simulates NAT behavior for testing hole punching and relay scenarios
public actor SimulatedNAT {
    /// The type of NAT being simulated
    public let type: NATType

    /// The public IP address of this NAT
    public let publicIP: String

    /// Port allocation strategy for symmetric NAT
    public let portAllocation: PortAllocationStrategy

    /// Active mappings from internal to external endpoints
    private var mappings: [String: NATMapping] = [:]

    /// Next external port to allocate
    private var nextExternalPort: UInt16 = 10000

    /// Mapping timeout in seconds
    private let mappingTimeout: TimeInterval = 120

    /// Port allocation strategies for symmetric NAT
    public enum PortAllocationStrategy: Sendable {
        case sequential      // Ports increase by 1 each time
        case random          // Random port each time
        case preserving      // Try to use same port as internal
    }

    /// A NAT mapping entry
    public struct NATMapping: Sendable {
        public let internalEndpoint: String
        public let externalEndpoint: String
        public let createdAt: Date
        public var lastUsed: Date

        /// For restricted NATs: which destinations we've sent to
        public var allowedDestinations: Set<String>

        /// For port-restricted: exact IP:port pairs
        public var allowedDestinationPorts: Set<String>

        public var isExpired: Bool {
            Date().timeIntervalSince(lastUsed) > 120
        }
    }

    public init(
        type: NATType,
        publicIP: String = "10.0.0.1",
        portAllocation: PortAllocationStrategy = .sequential
    ) {
        self.type = type
        self.publicIP = publicIP
        self.portAllocation = portAllocation
    }

    // MARK: - Outbound Translation

    /// Translate an outbound packet (internal -> external)
    /// Returns the external source endpoint to use, or nil if blocked
    public func translateOutbound(
        from internalEndpoint: String,
        to destination: String
    ) -> String? {
        // Public NAT doesn't translate
        if type == .public {
            return internalEndpoint
        }

        // Get or create mapping
        let mapping = getOrCreateMapping(for: internalEndpoint, destination: destination)

        // Update allowed destinations for restricted NATs
        var updatedMapping = mapping
        updatedMapping.lastUsed = Date()

        switch type {
        case .restrictedCone:
            // Track IP only
            let destIP = destination.split(separator: ":").first.map(String.init) ?? destination
            updatedMapping.allowedDestinations.insert(destIP)

        case .portRestrictedCone:
            // Track IP:port
            updatedMapping.allowedDestinationPorts.insert(destination)

        case .symmetric:
            // Track exact destination
            updatedMapping.allowedDestinationPorts.insert(destination)

        default:
            break
        }

        // Store updated mapping
        let key = mappingKey(internalEndpoint, destination: destination)
        mappings[key] = updatedMapping

        return mapping.externalEndpoint
    }

    /// Get or create a NAT mapping
    private func getOrCreateMapping(for internalEndpoint: String, destination: String) -> NATMapping {
        let key = mappingKey(internalEndpoint, destination: destination)

        // Check for existing mapping
        if let existing = mappings[key], !existing.isExpired {
            return existing
        }

        // Create new mapping
        let externalPort = allocatePort(for: internalEndpoint, destination: destination)
        let externalEndpoint = "\(publicIP):\(externalPort)"

        let mapping = NATMapping(
            internalEndpoint: internalEndpoint,
            externalEndpoint: externalEndpoint,
            createdAt: Date(),
            lastUsed: Date(),
            allowedDestinations: [],
            allowedDestinationPorts: []
        )

        mappings[key] = mapping
        return mapping
    }

    /// Generate mapping key based on NAT type
    private func mappingKey(_ internalEndpoint: String, destination: String) -> String {
        switch type {
        case .symmetric:
            // Different mapping per destination
            return "\(internalEndpoint)->\(destination)"
        default:
            // Same mapping for all destinations
            return internalEndpoint
        }
    }

    /// Allocate an external port
    private func allocatePort(for internalEndpoint: String, destination: String) -> UInt16 {
        // For non-symmetric NAT, try to reuse existing port
        if type != .symmetric {
            for (_, mapping) in mappings {
                if mapping.internalEndpoint == internalEndpoint && !mapping.isExpired {
                    let port = mapping.externalEndpoint.split(separator: ":").last
                        .flatMap { UInt16($0) }
                    if let port = port {
                        return port
                    }
                }
            }
        }

        // Allocate new port based on strategy
        let port: UInt16
        switch portAllocation {
        case .sequential:
            port = nextExternalPort
            nextExternalPort += 1

        case .random:
            port = UInt16.random(in: 10000..<60000)

        case .preserving:
            // Try to use internal port
            if let internalPort = internalEndpoint.split(separator: ":").last.flatMap({ UInt16($0) }) {
                port = internalPort
            } else {
                port = nextExternalPort
                nextExternalPort += 1
            }
        }

        return port
    }

    // MARK: - Inbound Filtering

    /// Check if an inbound packet should be allowed
    /// Returns the internal destination if allowed, nil if blocked
    public func filterInbound(
        from sourceEndpoint: String,
        to externalEndpoint: String
    ) -> String? {
        // Public NAT allows everything
        if type == .public {
            return externalEndpoint // No translation needed
        }

        // Find mapping for this external endpoint
        guard let mapping = findMappingByExternal(externalEndpoint) else {
            return nil // No mapping, packet dropped
        }

        // Check if source is allowed based on NAT type
        switch type {
        case .fullCone:
            // Anyone can send to mapped port
            return mapping.internalEndpoint

        case .restrictedCone:
            // Source IP must be in allowed list
            let sourceIP = sourceEndpoint.split(separator: ":").first.map(String.init) ?? sourceEndpoint
            if mapping.allowedDestinations.contains(sourceIP) {
                return mapping.internalEndpoint
            }
            return nil

        case .portRestrictedCone, .symmetric:
            // Source IP:port must be in allowed list
            if mapping.allowedDestinationPorts.contains(sourceEndpoint) {
                return mapping.internalEndpoint
            }
            return nil

        default:
            return nil
        }
    }

    /// Find a mapping by its external endpoint
    private func findMappingByExternal(_ externalEndpoint: String) -> NATMapping? {
        for (_, mapping) in mappings {
            if mapping.externalEndpoint == externalEndpoint && !mapping.isExpired {
                return mapping
            }
        }
        return nil
    }

    // MARK: - Management

    /// Get the external endpoint for an internal endpoint (if mapped)
    public func getExternalEndpoint(for internalEndpoint: String) -> String? {
        for (_, mapping) in mappings {
            if mapping.internalEndpoint == internalEndpoint && !mapping.isExpired {
                return mapping.externalEndpoint
            }
        }
        return nil
    }

    /// Get all active mappings
    public func getMappings() -> [NATMapping] {
        Array(mappings.values.filter { !$0.isExpired })
    }

    /// Expire all mappings (simulates NAT timeout)
    public func expireAllMappings() {
        mappings.removeAll()
    }

    /// Clean up expired mappings
    public func cleanupExpired() {
        mappings = mappings.filter { !$0.value.isExpired }
    }
}
