// EndpointUtils.swift - Endpoint utilities for IPv4/IPv6 prioritization
//
// Endpoints are stored as-is (IPv4 or IPv6 format). When selecting which
// endpoint to use, IPv6 is preferred. The dual-stack socket handles both.

import Foundation

/// Utilities for working with endpoints and prioritizing IPv6
public enum EndpointUtils {

    // MARK: - Detection

    /// Check if an endpoint is IPv6
    /// Handles: [::1]:5000, ::1:5000 (if parseable)
    public static func isIPv6(_ endpoint: String) -> Bool {
        // Bracket notation is definitely IPv6
        if endpoint.hasPrefix("[") {
            return true
        }

        // Check if it's an IPv6 address (contains multiple colons)
        // IPv4 has format x.x.x.x:port (one colon)
        // IPv6 has format x:x:x:x:x:x:x:x:port (multiple colons)
        let colonCount = endpoint.filter { $0 == ":" }.count
        return colonCount > 1
    }

    /// Check if an endpoint is IPv4
    public static func isIPv4(_ endpoint: String) -> Bool {
        !isIPv6(endpoint)
    }

    // MARK: - Sorting

    /// Sort endpoints with IPv6 first
    public static func sortPreferringIPv6(_ endpoints: [String]) -> [String] {
        endpoints.sorted { a, b in
            let aIsIPv6 = isIPv6(a)
            let bIsIPv6 = isIPv6(b)
            if aIsIPv6 != bIsIPv6 {
                return aIsIPv6  // IPv6 comes first
            }
            return a < b  // Stable sort within same type
        }
    }

    /// Get the preferred endpoint (IPv6 if available)
    public static func preferredEndpoint(from endpoints: [String]) -> String? {
        // Return first IPv6, or first IPv4 if no IPv6
        endpoints.first { isIPv6($0) } ?? endpoints.first
    }

    // MARK: - Address Validation

    /// Check if a string is a valid IPv4 address (not endpoint)
    public static func isIPv4Address(_ string: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, string, &addr) == 1
    }

    /// Check if a string is a valid IPv6 address (not endpoint)
    public static func isIPv6Address(_ string: String) -> Bool {
        var addr = in6_addr()
        return inet_pton(AF_INET6, string, &addr) == 1
    }
}
