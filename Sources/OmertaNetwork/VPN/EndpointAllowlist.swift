// EndpointAllowlist.swift
// Thread-safe allowlist for VM network filtering

import Foundation

// MARK: - Endpoint

/// A network endpoint (IP address + port)
public struct Endpoint: Equatable, Hashable, Sendable, CustomStringConvertible {

    /// The IP address
    public let address: IPv4Address

    /// The port number
    public let port: UInt16

    /// Create an endpoint
    public init(address: IPv4Address, port: UInt16) {
        self.address = address
        self.port = port
    }

    public var description: String {
        "\(address):\(port)"
    }
}

// MARK: - EndpointAllowlist

/// Thread-safe allowlist of permitted endpoints
///
/// Uses Swift actor for thread safety. An empty allowlist blocks all traffic.
/// Only explicitly allowed endpoints can pass.
public actor EndpointAllowlist {

    /// The set of allowed endpoints
    private var allowed: Set<Endpoint>

    /// Create an empty allowlist (blocks all traffic)
    public init() {
        self.allowed = []
    }

    /// Create an allowlist with initial endpoints
    public init(_ endpoints: [Endpoint]) {
        self.allowed = Set(endpoints)
    }

    // MARK: - Checking

    /// Check if an endpoint is allowed
    public func isAllowed(_ endpoint: Endpoint) -> Bool {
        allowed.contains(endpoint)
    }

    /// Check if an address/port combination is allowed
    public func isAllowed(address: IPv4Address, port: UInt16) -> Bool {
        allowed.contains(Endpoint(address: address, port: port))
    }

    // MARK: - Mutation

    /// Replace the entire allowlist
    public func setAllowed(_ endpoints: [Endpoint]) {
        allowed = Set(endpoints)
    }

    /// Add an endpoint to the allowlist
    public func add(_ endpoint: Endpoint) {
        allowed.insert(endpoint)
    }

    /// Remove an endpoint from the allowlist
    public func remove(_ endpoint: Endpoint) {
        allowed.remove(endpoint)
    }

    /// Clear all allowed endpoints
    public func clear() {
        allowed.removeAll()
    }

    // MARK: - Queries

    /// Number of allowed endpoints
    public var count: Int {
        allowed.count
    }

    /// Whether the allowlist is empty
    public var isEmpty: Bool {
        allowed.isEmpty
    }

    /// Check if an endpoint is in the allowlist
    public func contains(_ endpoint: Endpoint) -> Bool {
        allowed.contains(endpoint)
    }
}
