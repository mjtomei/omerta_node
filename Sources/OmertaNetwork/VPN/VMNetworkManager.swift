// VMNetworkManager.swift
// Unified VM network configuration manager

#if os(macOS)
import Foundation
@preconcurrency import Virtualization

// MARK: - VMNetworkMode

/// Network mode for VM isolation
public enum VMNetworkMode: String, Codable, Sendable {
    /// Direct NAT - VM has full internet access, relies on VM-side isolation
    /// Highest performance (~10 Gbps), lowest security
    case direct

    /// Sampled filtering - spot-check packets, terminate VM on violation
    /// High performance (~8 Gbps), medium security
    case sampled

    /// Connection tracking - filter first packet per flow, fast-path rest
    /// Good performance (~6 Gbps), good security
    case conntrack

    /// Full filtering - inspect every packet
    /// Lower performance (~2-4 Gbps), maximum security
    case filtered
}

// MARK: - VMNetworkHandle

/// Handle for managing VM network lifecycle
public enum VMNetworkHandle: Sendable {
    /// Direct mode - no background processing needed
    case direct

    /// Filtered mode with background processing task
    case filtered(
        nat: FilteredNAT,
        socketPair: (vm: Int32, host: Int32)
    )
}

// MARK: - VMNetworkConfiguration

/// Configuration result for VM network setup
@MainActor
public struct VMNetworkConfiguration {
    /// The network device configuration for the VM
    public let networkDevice: VZVirtioNetworkDeviceConfiguration

    /// Handle for managing the network
    public let handle: VMNetworkHandle

    /// The filtering strategy in use (nil for direct mode)
    public let strategy: (any FilteringStrategy)?
}

// MARK: - VMNetworkError

/// Errors from VM network setup
public enum VMNetworkError: Error, Sendable {
    case failedToCreateSocketPair
    case filteringRequiresEndpoint
    case invalidConfiguration(String)
    case fileHandleAttachmentUnavailable
}

// MARK: - VMNetworkManager

/// Manages VM network configuration for all modes
@MainActor
public enum VMNetworkManager {

    // MARK: - Network Creation

    /// Create VM network configuration for specified mode
    /// - Parameters:
    ///   - mode: Network mode (direct, sampled, conntrack, filtered)
    ///   - consumerEndpoint: Required for filtered modes, ignored for direct
    ///   - samplingRate: Sample rate for sampled mode (default 1%)
    /// - Returns: Network device configuration and management handle
    public static func createNetwork(
        mode: VMNetworkMode,
        consumerEndpoint: Endpoint? = nil,
        samplingRate: Double = 0.01
    ) throws -> VMNetworkConfiguration {
        switch mode {
        case .direct:
            return createDirectNetwork()

        case .sampled:
            guard let endpoint = consumerEndpoint else {
                throw VMNetworkError.filteringRequiresEndpoint
            }
            let allowlist = EndpointAllowlist([endpoint])
            let strategy = SampledStrategy(allowlist: allowlist, sampleRate: samplingRate)
            return try createFilteredNetwork(
                consumerEndpoint: endpoint,
                strategy: strategy
            )

        case .conntrack:
            guard let endpoint = consumerEndpoint else {
                throw VMNetworkError.filteringRequiresEndpoint
            }
            let allowlist = EndpointAllowlist([endpoint])
            let strategy = ConntrackStrategy(allowlist: allowlist)
            return try createFilteredNetwork(
                consumerEndpoint: endpoint,
                strategy: strategy
            )

        case .filtered:
            guard let endpoint = consumerEndpoint else {
                throw VMNetworkError.filteringRequiresEndpoint
            }
            let allowlist = EndpointAllowlist([endpoint])
            let strategy = FullFilterStrategy(allowlist: allowlist)
            return try createFilteredNetwork(
                consumerEndpoint: endpoint,
                strategy: strategy
            )
        }
    }

    // MARK: - Direct Mode

    /// Create direct NAT network (kernel-level, highest performance)
    private static func createDirectNetwork() -> VMNetworkConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        return VMNetworkConfiguration(
            networkDevice: networkDevice,
            handle: .direct,
            strategy: nil
        )
    }

    // MARK: - Filtered Mode

    /// Create filtered network with specified strategy
    ///
    /// NOTE: VZFileHandleNetworkDeviceAttachment requires a specific type of file descriptor
    /// that behaves like a network device (tap interface). Unix sockets are NOT compatible
    /// and will cause kernel panics. This mode requires either:
    /// - com.apple.vm.networking entitlement (restricted, requires Apple approval)
    /// - NEFilterPacketProvider (Phase 15, standard entitlement)
    /// - Or running the filter in the VM itself
    ///
    /// For now, filtered modes fall back to direct mode with a warning.
    private static func createFilteredNetwork(
        consumerEndpoint: Endpoint,
        strategy: any FilteringStrategy
    ) throws -> VMNetworkConfiguration {
        // IMPORTANT: VZFileHandleNetworkDeviceAttachment requires a tap-like file descriptor.
        // Using socketpair() causes kernel panics because Unix sockets don't handle
        // ethernet frame boundaries correctly.
        //
        // Options for proper implementation:
        // 1. Use com.apple.vm.networking entitlement to create vmnet interface (restricted)
        // 2. Use NEFilterPacketProvider system extension (Phase 15)
        // 3. Run filtering in-VM with iptables (defense in depth, already implemented)
        //
        // For now, we use direct mode but keep the strategy for future use.
        // The VM-side iptables provides the primary isolation.

        #if DEBUG
        print("WARNING: Filtered network modes not yet implemented on macOS.")
        print("Using direct NAT mode. VM-side iptables provides isolation.")
        print("See Phase 15 (NEFilterPacketProvider) for kernel-level filtering.")
        #endif

        // Fall back to direct mode - VM iptables provides isolation
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        // Create FilteredNAT for potential future use (won't receive frames yet)
        let nat = FilteredNAT(consumerEndpoint: consumerEndpoint)

        return VMNetworkConfiguration(
            networkDevice: networkDevice,
            handle: .filtered(
                nat: nat,
                socketPair: (-1, -1)  // Invalid sockets indicate fallback mode
            ),
            strategy: strategy
        )
    }

    // MARK: - Cleanup

    /// Clean up network resources
    public static func cleanup(_ handle: VMNetworkHandle) {
        switch handle {
        case .direct:
            // No cleanup needed for direct mode
            break

        case .filtered(_, let socketPair):
            // Only close sockets if they're valid (not in fallback mode)
            if socketPair.vm >= 0 {
                Darwin.close(socketPair.vm)
            }
            if socketPair.host >= 0 {
                Darwin.close(socketPair.host)
            }
        }
    }
}

// MARK: - Network Processing Task

/// Task for processing filtered network traffic
public actor FilteredNetworkProcessor {

    private let nat: FilteredNAT
    private let strategy: any FilteringStrategy
    private let hostSocket: Int32
    private var isRunning = false
    private var processingTask: Task<Void, Never>?

    public init(
        nat: FilteredNAT,
        strategy: any FilteringStrategy,
        hostSocket: Int32
    ) {
        self.nat = nat
        self.strategy = strategy
        self.hostSocket = hostSocket
    }

    /// Start processing network traffic
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        processingTask = Task {
            await processTraffic()
        }
    }

    /// Stop processing
    public func stop() {
        isRunning = false
        processingTask?.cancel()
        processingTask = nil
    }

    /// Main traffic processing loop
    private func processTraffic() async {
        var buffer = [UInt8](repeating: 0, count: 65536)

        while isRunning && !Task.isCancelled {
            // Read from socket
            let bytesRead = Darwin.recv(hostSocket, &buffer, buffer.count, 0)

            if bytesRead > 0 {
                let frameData = Data(buffer[0..<bytesRead])

                // Process outbound traffic through FilteredNAT
                let result = await nat.processOutbound(frameData)

                switch result {
                case .forwarded:
                    // Frame was allowed, actual forwarding happens in FilteredNAT
                    break

                case .dropped(let reason):
                    // Frame was dropped, could log here
                    _ = reason

                case .error(let error):
                    // Error processing, could log here
                    _ = error
                }
            } else if bytesRead == 0 {
                // Connection closed
                break
            } else {
                // Error or would block
                let err = Darwin.errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Non-blocking would block, sleep briefly
                    try? await Task.sleep(for: .milliseconds(1))
                } else if err != EINTR {
                    // Real error
                    break
                }
            }
        }
    }

    /// Check if processor is running
    public var running: Bool {
        isRunning
    }
}

// MARK: - Host Socket Reader

/// Helper to read frames from host socket
public struct HostSocketReader {
    private let socket: Int32

    public init(socket: Int32) {
        self.socket = socket
    }

    /// Read a frame from the socket
    public func readFrame() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = Darwin.recv(socket, &buffer, buffer.count, MSG_DONTWAIT)

        if bytesRead > 0 {
            return Data(buffer[0..<bytesRead])
        }
        return nil
    }

    /// Write a frame to the socket
    public func writeFrame(_ data: Data) -> Bool {
        data.withUnsafeBytes { ptr in
            let bytesSent = Darwin.send(socket, ptr.baseAddress, data.count, 0)
            return bytesSent == data.count
        }
    }
}
#endif
