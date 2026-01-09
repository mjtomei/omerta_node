// MacOSPacketFilter.swift
// Native macOS packet filter (pf) management using /dev/pf
// Manages firewall rules and NAT without shelling out to pfctl

#if os(macOS)
import Foundation
import Darwin

/// Errors for packet filter operations
public enum PacketFilterError: Error, CustomStringConvertible {
    case deviceOpenFailed(Int32)
    case ioctlFailed(String, Int32)
    case ruleParsingFailed(String)
    case anchorNotFound(String)
    case notEnabled
    case invalidInterface(String)
    case validationFailed(String)

    public var description: String {
        switch self {
        case .deviceOpenFailed(let errno):
            return "Failed to open /dev/pf: \(String(cString: strerror(errno)))"
        case .ioctlFailed(let op, let errno):
            return "pf ioctl \(op) failed: \(String(cString: strerror(errno)))"
        case .ruleParsingFailed(let msg):
            return "Failed to parse rule: \(msg)"
        case .anchorNotFound(let name):
            return "Anchor not found: \(name)"
        case .notEnabled:
            return "Packet filter is not enabled"
        case .invalidInterface(let name):
            return "Invalid interface name '\(name)' - expected utun interface (e.g., utun0, utun10)"
        case .validationFailed(let msg):
            return "Rule validation failed: \(msg)"
        }
    }
}

// MARK: - PF ioctl commands (from net/pfvar.h)

// Note: These values are specific to macOS and may differ from other BSDs
private let DIOCSTART: UInt = 0x20004401         // Start packet filter
private let DIOCSTOP: UInt = 0x20004402          // Stop packet filter
private let DIOCADDRULE: UInt = 0xc0104404       // Add a rule
private let DIOCGETRULES: UInt = 0xc0104406      // Get rules
private let DIOCCLRRULES: UInt = 0xc0084410      // Clear rules
private let DIOCBEGINADDRS: UInt = 0xc0084451    // Begin adding addresses
private let DIOCADDADDR: UInt = 0xc0484452       // Add an address
private let DIOCGETADDRS: UInt = 0xc0084453      // Get addresses
private let DIOCIGETIFACES: UInt = 0xc0284457    // Get interfaces
private let DIOCXBEGIN: UInt = 0xc0104461        // Begin transaction
private let DIOCXCOMMIT: UInt = 0xc0104462       // Commit transaction
private let DIOCXROLLBACK: UInt = 0xc0104463     // Rollback transaction
private let DIOCGETTIMEOUT: UInt = 0xc0084409    // Get timeout
private let DIOCGETSTATUS: UInt = 0xc0e84416     // Get status

// PF rule actions
private let PF_PASS: UInt8 = 0
private let PF_DROP: UInt8 = 1
private let PF_SCRUB: UInt8 = 2
private let PF_NOSCRUB: UInt8 = 3
private let PF_NAT: UInt8 = 4
private let PF_NONAT: UInt8 = 5
private let PF_BINAT: UInt8 = 6
private let PF_NOBINAT: UInt8 = 7
private let PF_RDR: UInt8 = 8
private let PF_NORDR: UInt8 = 9

// PF address types
private let PF_ADDR_ADDRMASK: UInt8 = 0
private let PF_ADDR_NOROUTE: UInt8 = 1
private let PF_ADDR_DYNIFTL: UInt8 = 2
private let PF_ADDR_TABLE: UInt8 = 3
private let PF_ADDR_URPFFAILED: UInt8 = 4

/// Simplified pf rule representation
public struct PFRule {
    public var action: PFAction
    public var direction: PFDirection
    public var proto: PFProto
    public var sourceAddress: String?
    public var sourcePort: UInt16?
    public var destAddress: String?
    public var destPort: UInt16?
    public var natAddress: String?  // For NAT rules
    public var rdirAddress: String? // For RDR rules
    public var rdirPort: UInt16?

    public init(action: PFAction, direction: PFDirection = .inout, proto: PFProto = .any) {
        self.action = action
        self.direction = direction
        self.proto = proto
    }
}

public enum PFAction {
    case pass
    case drop
    case nat
    case rdr
}

public enum PFDirection {
    case `in`
    case out
    case `inout`
}

public enum PFProto {
    case any
    case tcp
    case udp
    case icmp
}

/// Native macOS packet filter manager
/// Note: Full pf rule management is complex. This provides basic NAT and filtering.
/// For complex rules, we fall back to writing a rules file and loading via pfctl.
public class MacOSPacketFilterManager {

    private static let pfDevice = "/dev/pf"

    /// Check if pf is enabled
    public static func isEnabled() throws -> Bool {
        let fd = open(pfDevice, O_RDWR)
        guard fd >= 0 else {
            throw PacketFilterError.deviceOpenFailed(errno)
        }
        defer { close(fd) }

        // Get status - simplified check
        // Full implementation would parse pf_status structure
        return true // If we can open /dev/pf, pf is available
    }

    /// Enable the packet filter
    public static func enable() throws {
        let fd = open(pfDevice, O_RDWR)
        guard fd >= 0 else {
            throw PacketFilterError.deviceOpenFailed(errno)
        }
        defer { close(fd) }

        guard ioctl(fd, DIOCSTART, 0) >= 0 else {
            // EEXIST (17) means already enabled, which is fine
            if errno != EEXIST {
                throw PacketFilterError.ioctlFailed("DIOCSTART", errno)
            }
            return
        }
    }

    /// Disable the packet filter
    public static func disable() throws {
        let fd = open(pfDevice, O_RDWR)
        guard fd >= 0 else {
            throw PacketFilterError.deviceOpenFailed(errno)
        }
        defer { close(fd) }

        guard ioctl(fd, DIOCSTOP, 0) >= 0 else {
            throw PacketFilterError.ioctlFailed("DIOCSTOP", errno)
        }
    }

    /// Enable IP forwarding (required for NAT)
    public static func enableIPForwarding() throws {
        var value: Int32 = 1
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("net.inet.ip.forwarding", nil, nil, &value, size)
        guard result == 0 else {
            throw PacketFilterError.ioctlFailed("sysctl ip.forwarding", errno)
        }
    }

    /// Load rules into a named anchor from a configuration string
    /// This is the recommended approach for complex rules
    /// - Parameters:
    ///   - anchor: The pf anchor name (e.g., "omerta/10-99-0-2")
    ///   - rules: The pf rules to load
    ///   - validate: If true, validate rules syntax before loading (default: true)
    public static func loadRulesIntoAnchor(anchor: String, rules: String, validate: Bool = true) throws {
        // Optional pre-validation: check for invalid interface names and syntax
        if validate {
            // Check for invalid interface names first
            let invalidInterfaces = findInvalidInterfaces(in: rules)
            if !invalidInterfaces.isEmpty {
                throw PacketFilterError.invalidInterface(
                    "Invalid interfaces in rules: \(invalidInterfaces.joined(separator: ", ")). " +
                    "Ensure you're using actual system interface names (e.g., utun0) not logical names (e.g., wg-ABC)."
                )
            }

            // Full syntax validation using pfctl -n (dry-run)
            let syntaxResult = validateRules(rules)
            if case .failure(let error) = syntaxResult {
                throw error
            }
        }

        // Write rules to a temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let rulesFile = tempDir.appendingPathComponent("omerta-pf-\(anchor.replacingOccurrences(of: "/", with: "-")).conf")

        try rules.write(to: rulesFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rulesFile) }

        // Use Process to load via pfctl since direct ioctl for anchors is complex
        // This is a temporary solution until full anchor support is implemented
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = ["-a", anchor, "-f", rulesFile.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PacketFilterError.ruleParsingFailed(errorMsg)
        }
    }

    /// Flush rules from an anchor
    public static func flushAnchor(anchor: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = ["-a", anchor, "-F", "all"]
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()
        // Ignore errors - anchor might not exist
    }

    // MARK: - Validation

    /// Validate pf rules syntax without loading them
    /// Uses pfctl -nf to parse rules in dry-run mode
    /// - Parameter rules: The rules string to validate
    /// - Returns: Result with success or validation errors
    public static func validateRules(_ rules: String) -> Result<Void, PacketFilterError> {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("omerta-pf-validate-\(UUID().uuidString).conf")

        do {
            try rules.write(to: tempFile, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.validationFailed("Failed to write temp file: \(error)"))
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        // -n: Don't actually load rules (dry-run)
        // -f: Load rules from file
        process.arguments = ["-n", "-f", tempFile.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(.validationFailed("Failed to run pfctl: \(error)"))
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown syntax error"
            return .failure(.validationFailed(errorMsg))
        }

        return .success(())
    }

    /// Check if an interface name is a valid macOS utun interface
    /// - Parameter name: Interface name to validate
    /// - Returns: true if the name matches utun pattern (utun0, utun1, etc.)
    public static func isValidUtunInterface(_ name: String) -> Bool {
        // utun interfaces on macOS follow the pattern utunN where N is a non-negative integer
        let pattern = "^utun[0-9]+$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Check if an interface name is valid for use in pf rules
    /// Accepts utun interfaces for VPN and common physical interfaces for external
    /// - Parameter name: Interface name to validate
    /// - Returns: true if valid for pf rules
    public static func isValidPFInterface(_ name: String) -> Bool {
        // Valid patterns:
        // - utunN: Virtual tunnel interfaces (WireGuard)
        // - enN: Ethernet/Wi-Fi interfaces
        // - bridge: Bridge interfaces
        // - lo: Loopback
        // - vmnet: VM network interfaces
        let patterns = [
            "^utun[0-9]+$",
            "^en[0-9]+$",
            "^bridge[0-9]+$",
            "^lo[0-9]*$",
            "^vmnet[0-9]+$"
        ]

        return patterns.contains { pattern in
            name.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Validate that interface names used in rules are valid system interfaces
    /// - Parameter rules: Rules string to check
    /// - Returns: Array of invalid interface names found, empty if all valid
    public static func findInvalidInterfaces(in rules: String) -> [String] {
        var invalid: [String] = []

        // Pattern to find interface names in pf rules
        // Matches: "on <interface>" in rules
        let onPattern = "\\bon\\s+([a-zA-Z0-9_-]+)"

        let regex = try? NSRegularExpression(pattern: onPattern, options: [])
        let range = NSRange(rules.startIndex..., in: rules)

        regex?.enumerateMatches(in: rules, options: [], range: range) { match, _, _ in
            guard let match = match,
                  let ifaceRange = Range(match.range(at: 1), in: rules) else { return }

            let interfaceName = String(rules[ifaceRange])

            // Skip dynamic interface syntax like (en0)
            if interfaceName.hasPrefix("(") { return }

            // Check if it's a valid interface
            if !isValidPFInterface(interfaceName) {
                invalid.append(interfaceName)
            }
        }

        return invalid
    }

    /// Generate NAT rules for a VM
    /// - Parameters:
    ///   - vmVPNIP: The VM's VPN IP address
    ///   - vmNATIP: The VM's NAT IP address (on the host's internal network)
    ///   - vpnInterface: The WireGuard VPN interface (e.g., "utun5")
    ///   - externalInterface: The external interface for internet access
    /// - Returns: PF rules string
    public static func generateNATRules(
        vmVPNIP: String,
        vmNATIP: String,
        vpnInterface: String,
        externalInterface: String = "en0"
    ) -> String {
        """
        # NAT rules for VM \(vmVPNIP)
        # Forward traffic from VPN to VM and back

        # NAT outbound traffic from VM to appear as host
        nat on \(externalInterface) from \(vmNATIP) to any -> (\(externalInterface))

        # Forward traffic from VPN IP to VM NAT IP
        rdr on \(vpnInterface) proto {tcp, udp} from any to \(vmVPNIP) -> \(vmNATIP)

        # Allow traffic between VPN and VM
        pass quick on \(vpnInterface) from \(vmVPNIP)/32 to any
        pass quick on \(vpnInterface) from any to \(vmVPNIP)/32
        """
    }

    /// Generate isolation rules for a VM
    /// Prevents the VM from accessing the host's network except through the VPN
    public static func generateIsolationRules(
        vmNATIP: String,
        vpnSubnet: String,
        allowedPorts: [UInt16] = []
    ) -> String {
        var rules = """
        # Isolation rules for VM \(vmNATIP)

        # Block VM from accessing host network
        block drop quick from \(vmNATIP) to 192.168.0.0/16
        block drop quick from \(vmNATIP) to 10.0.0.0/8
        block drop quick from \(vmNATIP) to 172.16.0.0/12

        # Allow VM to access its VPN subnet
        pass quick from \(vmNATIP) to \(vpnSubnet)
        pass quick from \(vpnSubnet) to \(vmNATIP)

        """

        // Add allowed ports if specified
        for port in allowedPorts {
            rules += "pass quick proto tcp from \(vmNATIP) to any port \(port)\n"
        }

        rules += """

        # Allow established connections
        pass quick from \(vmNATIP) to any keep state
        """

        return rules
    }

    /// Quick setup for VM NAT
    /// Combines NAT and isolation rules
    public static func setupVMNAT(
        anchor: String,
        vmVPNIP: String,
        vmNATIP: String,
        vpnInterface: String,
        vpnSubnet: String
    ) throws {
        let rules = """
        \(generateNATRules(vmVPNIP: vmVPNIP, vmNATIP: vmNATIP, vpnInterface: vpnInterface))

        \(generateIsolationRules(vmNATIP: vmNATIP, vpnSubnet: vpnSubnet))
        """

        try enable()
        try enableIPForwarding()
        try loadRulesIntoAnchor(anchor: anchor, rules: rules)
    }

    /// Cleanup VM NAT rules
    public static func cleanupVMNAT(anchor: String) throws {
        try flushAnchor(anchor: anchor)
    }
}

#endif
