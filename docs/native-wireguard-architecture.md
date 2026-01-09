# VM Network Architecture: Filtered NAT with In-VM WireGuard

## Overview

This document describes the network architecture for Omerta VMs on macOS providers. The design achieves:

- **No root privileges** on provider
- **No restricted entitlements** (works without Apple approval)
- **Strong isolation** - VM can only reach consumer
- **High performance** - kernel WireGuard in VM
- **Defense in depth** - multiple isolation layers

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Consumer (Linux)                             │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  WireGuard Server (kernel)                                    │  │
│  │  - Interface: wg0                                             │  │
│  │  - Listens: UDP port 51900                                    │  │
│  │  - Peer: Provider's NAT IP                                    │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                                 ▲
                                 │ WireGuard UDP (encrypted)
                                 │ ONLY allowed traffic
                                 │
┌────────────────────────────────┼────────────────────────────────────┐
│                                │                                     │
│  ┌─────────────────────────────┼─────────────────────────────────┐  │
│  │           FilteredNAT (userspace, NO ROOT)                    │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  Allowlist: [(consumer_ip, 51900)]                      │ │  │
│  │  │  Default: DROP                                          │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  • Reads ethernet frames from VM via file handle              │  │
│  │  • Inspects IP headers (destination check)                    │  │
│  │  • Forwards allowed packets via regular UDP socket            │  │
│  │  • Drops everything else (never reaches network)              │  │
│  │                                                               │  │
│  └─────────────────────────────────────────────────────────────────┘│
│                                ▲                                     │
│                                │ VZFileHandleNetworkDeviceAttachment │
│                                │ (Provider controls ALL frames)      │
│                                ▼                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                           VM                                  │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  WireGuard Client (kernel) - FAST                       │ │  │
│  │  │  - Interface: wg0                                       │ │  │
│  │  │  - Endpoint: consumer:51900                             │ │  │
│  │  │  - AllowedIPs: 0.0.0.0/0 (default route)               │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  iptables (defense in depth)                            │ │  │
│  │  │  -P OUTPUT DROP                                         │ │  │
│  │  │  -A OUTPUT -o wg0 -j ACCEPT                             │ │  │
│  │  │  -A OUTPUT -o lo -j ACCEPT                              │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                      │
│                      Provider (macOS) - NO ROOT                      │
└──────────────────────────────────────────────────────────────────────┘
```

## Security Model

### Three Layers of Isolation

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: Provider FilteredNAT (STRONGEST)                       │
│ ─────────────────────────────────────────                       │
│ • Provider-side, cannot be bypassed by VM                       │
│ • Inspects every ethernet frame from VM                         │
│ • Only forwards packets to consumer endpoint                    │
│ • Everything else dropped before reaching network               │
│                                                                 │
│ Even if VM has root and disables all internal protections,      │
│ it still cannot reach anything except the consumer.             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Layer 2: VM iptables                                            │
│ ────────────────────                                            │
│ • Kernel-enforced inside VM                                     │
│ • Blocks non-WireGuard traffic at source                        │
│ • Could be bypassed by root workload                            │
│ • But Layer 1 catches any bypass attempt                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3: WireGuard Routing                                      │
│ ──────────────────────────                                      │
│ • Default route via wg0                                         │
│ • Traffic naturally flows through tunnel                        │
│ • Provides encryption for all workload traffic                  │
└─────────────────────────────────────────────────────────────────┘
```

### What VM Can Access

| Destination | Allowed | Enforced By |
|-------------|---------|-------------|
| Consumer WireGuard (UDP 51900) | ✅ | FilteredNAT allowlist |
| Consumer other ports | ❌ | FilteredNAT drops |
| Internet | ❌ | FilteredNAT drops |
| Provider LAN | ❌ | FilteredNAT drops |
| Provider host | ❌ | FilteredNAT drops |
| Other VMs | ❌ | FilteredNAT drops |

### Attack Scenarios

| Attack | Result |
|--------|--------|
| VM disables iptables | FilteredNAT still blocks |
| VM spoofs source IP | FilteredNAT checks dest, still blocks |
| VM sends to random IP | FilteredNAT drops (not in allowlist) |
| VM scans provider LAN | All packets dropped |
| VM tries DNS lookup | Dropped (unless consumer provides DNS) |
| Malicious inbound traffic | FilteredNAT only accepts from consumer |

## Implementation

### Provider Components

#### 1. VZFileHandleNetworkDeviceAttachment Setup

```swift
import Virtualization

func createFilteredNetwork() -> (VZNetworkDeviceConfiguration, FilteredNAT) {
    // Create pipe for VM network
    let (vmHandle, hostHandle) = createSocketPair()

    // Create network attachment using file handles
    let attachment = VZFileHandleNetworkDeviceAttachment(
        fileHandleForReading: vmHandle,
        fileHandleForWriting: vmHandle
    )

    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    networkDevice.attachment = attachment

    // Create filtered NAT that uses the host handle
    let filteredNAT = FilteredNAT(
        vmHandle: hostHandle,
        allowedEndpoints: []  // Set when consumer connects
    )

    return (networkDevice, filteredNAT)
}
```

#### 2. FilteredNAT Implementation

```swift
import Foundation
import Network

/// Userspace NAT with strict destination filtering
/// No root required - uses regular UDP sockets
public actor FilteredNAT {

    /// Allowed destinations (IP, port) - only consumer endpoint
    private var allowlist: Set<Endpoint> = []

    /// File handle to VM's network device
    private let vmHandle: FileHandle

    /// UDP socket for forwarding to consumer
    private let udpSocket: NWConnection

    /// VM's virtual MAC and IP (for response routing)
    private var vmMAC: Data?
    private var vmIP: IPv4Address?

    public struct Endpoint: Hashable {
        let address: IPv4Address
        let port: UInt16
    }

    public init(vmHandle: FileHandle) {
        self.vmHandle = vmHandle
        self.udpSocket = // ... create UDP socket
    }

    /// Set the allowed consumer endpoint
    public func setAllowedEndpoint(_ endpoint: Endpoint) {
        allowlist = [endpoint]
    }

    /// Main processing loop - runs in background
    public func start() async {
        // Read from VM
        Task { await processVMFrames() }

        // Read from network (consumer responses)
        Task { await processNetworkPackets() }
    }

    /// Process frames from VM
    private func processVMFrames() async {
        while true {
            guard let frame = try? await readFrame(from: vmHandle) else {
                continue
            }

            // Parse ethernet frame
            guard let ethernet = EthernetFrame(frame) else {
                continue
            }

            // Remember VM's MAC for responses
            if vmMAC == nil {
                vmMAC = ethernet.sourceMAC
            }

            // Only handle IPv4
            guard ethernet.etherType == .ipv4,
                  let ipPacket = IPv4Packet(ethernet.payload) else {
                continue
            }

            // Remember VM's IP for responses
            if vmIP == nil {
                vmIP = ipPacket.sourceAddress
            }

            // SECURITY CHECK: Only allow traffic to consumer
            let destination = Endpoint(
                address: ipPacket.destinationAddress,
                port: ipPacket.destinationPort
            )

            if allowlist.contains(destination) {
                // Forward to consumer
                await forwardToNetwork(ipPacket)
            } else {
                // DROP - log for debugging
                logger.warning("Blocked VM traffic", metadata: [
                    "destination": "\(ipPacket.destinationAddress):\(ipPacket.destinationPort)"
                ])
            }
        }
    }

    /// Process packets from network (consumer responses)
    private func processNetworkPackets() async {
        while true {
            guard let (data, source) = try? await udpSocket.receive() else {
                continue
            }

            // SECURITY CHECK: Only accept from consumer
            let sourceEndpoint = Endpoint(address: source.address, port: source.port)
            guard allowlist.contains(sourceEndpoint) else {
                logger.warning("Blocked inbound from \(source)")
                continue
            }

            // Wrap in IP and ethernet, send to VM
            guard let vmIP = vmIP, let vmMAC = vmMAC else {
                continue
            }

            let response = createResponseFrame(
                payload: data,
                destIP: vmIP,
                destMAC: vmMAC,
                sourceIP: sourceEndpoint.address,
                sourcePort: sourceEndpoint.port
            )

            try? vmHandle.write(contentsOf: response)
        }
    }

    /// Forward packet to consumer
    private func forwardToNetwork(_ packet: IPv4Packet) async {
        // Extract UDP payload (WireGuard packet)
        guard let udpPayload = packet.udpPayload else { return }

        // Send via our UDP socket (NAT - consumer sees provider's IP)
        try? await udpSocket.send(content: udpPayload)
    }
}
```

#### 3. Ethernet Frame Handling

```swift
/// Ethernet frame parser/builder
struct EthernetFrame {
    let destinationMAC: Data  // 6 bytes
    let sourceMAC: Data       // 6 bytes
    let etherType: EtherType  // 2 bytes
    let payload: Data         // Variable

    enum EtherType: UInt16 {
        case ipv4 = 0x0800
        case arp = 0x0806
        case ipv6 = 0x86DD
    }

    init?(_ data: Data) {
        guard data.count >= 14 else { return nil }
        destinationMAC = data[0..<6]
        sourceMAC = data[6..<12]
        etherType = EtherType(rawValue: UInt16(data[12]) << 8 | UInt16(data[13]))
        payload = data[14...]
    }

    func toData() -> Data {
        var frame = Data()
        frame.append(destinationMAC)
        frame.append(sourceMAC)
        frame.append(UInt8(etherType.rawValue >> 8))
        frame.append(UInt8(etherType.rawValue & 0xFF))
        frame.append(payload)
        return frame
    }
}

/// IPv4 packet parser
struct IPv4Packet {
    let sourceAddress: IPv4Address
    let destinationAddress: IPv4Address
    let proto: UInt8
    let payload: Data

    var destinationPort: UInt16 {
        guard proto == 17, payload.count >= 4 else { return 0 }  // UDP
        return UInt16(payload[2]) << 8 | UInt16(payload[3])
    }

    var udpPayload: Data? {
        guard proto == 17, payload.count >= 8 else { return nil }
        return payload[8...]
    }

    init?(_ data: Data) {
        guard data.count >= 20 else { return nil }
        let headerLength = Int(data[0] & 0x0F) * 4
        guard data.count >= headerLength else { return nil }

        sourceAddress = IPv4Address(data[12..<16])
        destinationAddress = IPv4Address(data[16..<20])
        proto = data[9]
        payload = data[headerLength...]
    }
}
```

### VM Configuration

#### WireGuard Setup (cloud-init or boot script)

```bash
#!/bin/bash
# /etc/wireguard/wg0.conf is provided by provider

# Bring up WireGuard
wg-quick up wg0

# Verify interface is up
ip link show wg0 || exit 1

# Set up iptables (defense in depth)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow WireGuard interface only
iptables -A INPUT -i wg0 -j ACCEPT
iptables -A OUTPUT -o wg0 -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow WireGuard UDP to consumer (needed for handshake)
# This is the ONLY exception - allows initial connection
iptables -A OUTPUT -p udp --dport 51900 -d $CONSUMER_IP -j ACCEPT

echo "=== VPN ROUTING ACTIVE ==="
```

## Performance

### Throughput Analysis

| Component | Throughput | Notes |
|-----------|------------|-------|
| VM WireGuard (kernel) | 10+ Gbps | Linux kernel, SIMD crypto |
| Provider frame filtering | 5-10 Gbps | Simple header check |
| Provider userspace NAT | 2-4 Gbps | UDP socket send/recv |
| **End-to-end** | **2-4 Gbps** | Limited by userspace NAT |

### Latency Analysis

| Component | Latency Added |
|-----------|---------------|
| Frame read from VM | ~10-50 μs |
| IP header parsing | ~1 μs |
| Allowlist check | ~0.1 μs |
| UDP socket send | ~10-50 μs |
| **Total provider overhead** | **~50-150 μs** |
| WireGuard encryption (VM) | ~10-20 μs |

### Optimization Opportunities

See "Performance Acceleration" section below.

## Performance Acceleration

### macOS Options

#### 1. Dispatch I/O (Built-in)

```swift
// Use GCD for concurrent frame processing
let queue = DispatchQueue(label: "filtered-nat", qos: .userInteractive, attributes: .concurrent)

dispatchIO = DispatchIO(type: .stream, fileDescriptor: vmHandle.fileDescriptor, queue: queue) { error in
    // Handle cleanup
}

dispatchIO.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
    // Process frame - runs concurrently
}
```

#### 2. Batch Processing

```swift
// Process multiple frames per syscall
func processBatch() async {
    var frames: [Data] = []

    // Collect frames for batch
    while let frame = try? readFrameNonBlocking() {
        frames.append(frame)
        if frames.count >= 64 { break }
    }

    // Process batch
    let results = frames.compactMap { frame -> (Data, Endpoint)? in
        guard let ethernet = EthernetFrame(frame),
              let ip = IPv4Packet(ethernet.payload),
              allowlist.contains(Endpoint(ip.destinationAddress, ip.destinationPort)) else {
            return nil
        }
        return (ip.udpPayload!, Endpoint(ip.destinationAddress, ip.destinationPort))
    }

    // Send batch via vectored I/O
    try? await udpSocket.sendBatch(results)
}
```

#### 3. Network.framework with Better Buffering

```swift
let parameters = NWParameters.udp
parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: 0)

// Enable larger buffers
if let opts = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
    // Optimize for throughput
}

let connection = NWConnection(to: consumerEndpoint, using: parameters)
```

### Linux Options

#### 1. io_uring (Kernel 5.1+)

```c
// Asynchronous I/O with minimal syscalls
struct io_uring ring;
io_uring_queue_init(256, &ring, 0);

// Submit multiple reads/writes in one syscall
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_read(sqe, vm_fd, buffer, size, 0);

// Batch submit
io_uring_submit(&ring);

// Batch completion
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
```

With io_uring, can achieve **5-8 Gbps** in userspace.

#### 2. AF_XDP (Kernel 4.18+)

```c
// Zero-copy packet processing
// Bypasses most of kernel network stack

struct xsk_socket *xsk;
xsk_socket__create(&xsk, ifname, queue_id, umem, &rx, &tx, &cfg);

// Frames delivered directly to userspace memory
// No copies between kernel and userspace
```

With AF_XDP, can achieve **10+ Gbps** approaching line rate.

#### 3. DPDK (Data Plane Development Kit)

For extreme performance (25+ Gbps), but requires:
- Dedicated NIC
- Hugepages
- More complex setup

Probably overkill for Omerta's use case.

### Recommended Approach

| Platform | Method | Expected Throughput |
|----------|--------|-------------------|
| macOS | Dispatch I/O + batching | 3-5 Gbps |
| Linux | io_uring | 5-8 Gbps |
| Linux (advanced) | AF_XDP | 10+ Gbps |

For initial implementation, start with basic async I/O. Optimize later if needed.

## Comparison with Alternatives

| Approach | Privileges | Performance | Security | Complexity |
|----------|-----------|-------------|----------|------------|
| **Filtered NAT (this doc)** | None | 2-4 Gbps | Excellent | Medium |
| VZNATNetworkDeviceAttachment | None | 5-10 Gbps | Poor (open NAT) | Low |
| WireGuard on provider (GotaTun) | Root | 3-5 Gbps | Good | Medium |
| Network Extension | Restricted entitlement | 5-10 Gbps | Good | High |

## Implementation Phases

Each phase produces a testable artifact. Unit tests are written alongside implementation.

### Phase 1: Ethernet Frame Parser

**File:** `Sources/OmertaNetwork/VPN/EthernetFrame.swift`

**Deliverable:** Standalone struct that parses and builds ethernet frames.

```swift
public struct EthernetFrame {
    public let destinationMAC: Data
    public let sourceMAC: Data
    public let etherType: EtherType
    public let payload: Data

    public init?(_ data: Data)
    public func toData() -> Data
}
```

**Unit Tests:** `EthernetFrameTests.swift`
- Parse valid IPv4/ARP/IPv6 frames
- Handle truncated frames (return nil)
- Round-trip serialization
- Edge cases (empty payload, max size)

**Dependencies:** None (pure data parsing)

**Verification:** `swift test --filter EthernetFrame`

---

### Phase 2: IPv4 Packet Parser

**File:** `Sources/OmertaNetwork/VPN/IPv4Packet.swift`

**Deliverable:** Standalone struct that parses IPv4 headers and extracts UDP/TCP ports.

```swift
public struct IPv4Packet {
    public let sourceAddress: IPv4Address
    public let destinationAddress: IPv4Address
    public let proto: IPProtocol
    public let payload: Data

    public var destinationPort: UInt16?
    public var udpPayload: Data?

    public init?(_ data: Data)
}
```

**Unit Tests:** `IPv4PacketTests.swift`
- Parse UDP/TCP/ICMP packets
- Extract destination ports correctly
- Handle IP options (variable header length)
- Handle truncated/malformed headers

**Dependencies:** None (pure data parsing)

**Verification:** `swift test --filter IPv4Packet`

---

### Phase 3: Endpoint Allowlist

**File:** `Sources/OmertaNetwork/VPN/EndpointAllowlist.swift`

**Deliverable:** Thread-safe allowlist that checks if an endpoint is permitted.

```swift
public struct Endpoint: Hashable, Sendable {
    public let address: IPv4Address
    public let port: UInt16
}

public actor EndpointAllowlist {
    public func setAllowed(_ endpoints: Set<Endpoint>)
    public func isAllowed(_ endpoint: Endpoint) -> Bool
    public func isAllowed(address: IPv4Address, port: UInt16) -> Bool
}
```

**Unit Tests:** `EndpointAllowlistTests.swift`
- Empty allowlist blocks all
- Single endpoint allowed, others blocked
- Multiple endpoints
- Port mismatch blocked
- IP mismatch blocked
- Thread safety (concurrent access)

**Dependencies:** `IPv4Packet` (for `IPv4Address` type, or define separately)

**Verification:** `swift test --filter EndpointAllowlist`

---

### Phase 4: UDP Forwarder

**File:** `Sources/OmertaNetwork/VPN/UDPForwarder.swift`

**Deliverable:** Sends UDP packets to consumer and receives responses.

```swift
public actor UDPForwarder {
    public init(localPort: UInt16 = 0)

    public func send(_ data: Data, to endpoint: Endpoint) async throws
    public func receive() async throws -> (data: Data, from: Endpoint)
    public func close()
}
```

**Unit Tests:** `UDPForwarderTests.swift`
- Send to localhost echo server
- Receive response
- Handle connection errors
- Multiple sequential sends

**Dependencies:** `Endpoint` type

**Verification:** `swift test --filter UDPForwarder`

---

### Phase 5: Frame-to-Packet Bridge

**File:** `Sources/OmertaNetwork/VPN/FramePacketBridge.swift`

**Deliverable:** Converts between ethernet frames and IP packets, handles response wrapping.

```swift
public struct FramePacketBridge {
    public mutating func processFrame(_ frame: EthernetFrame) -> IPv4Packet?
    public func wrapResponse(
        payload: Data,
        from source: Endpoint,
        to vmIP: IPv4Address,
        vmMAC: Data
    ) -> EthernetFrame
}
```

**Unit Tests:** `FramePacketBridgeTests.swift`
- Extract IPv4 packet from ethernet frame
- Ignore non-IPv4 frames (ARP, IPv6)
- Build response frame with correct headers
- MAC/IP address tracking

**Dependencies:** `EthernetFrame`, `IPv4Packet`, `Endpoint`

**Verification:** `swift test --filter FramePacketBridge`

---

### Phase 6: FilteredNAT Core

**File:** `Sources/OmertaNetwork/VPN/FilteredNAT.swift`

**Deliverable:** Combines all components into the filtering NAT logic.

```swift
public actor FilteredNAT {
    private let allowlist: EndpointAllowlist
    private let forwarder: UDPForwarder
    private let bridge: FramePacketBridge

    public init(consumerEndpoint: Endpoint)

    /// Process a frame from VM, return response frame if any
    public func processOutbound(_ frame: Data) async -> FilterResult

    /// Process inbound packet from network
    public func processInbound(_ data: Data, from: Endpoint) async -> Data?

    public enum FilterResult {
        case forwarded
        case dropped(reason: String)
        case error(Error)
    }
}
```

**Unit Tests:** `FilteredNATTests.swift`
- Allowed traffic forwarded
- Blocked traffic dropped with reason
- Inbound from allowed source accepted
- Inbound from unknown source dropped
- Malformed frames handled gracefully

**Dependencies:** All previous phases

**Verification:** `swift test --filter FilteredNAT`

---

### Phase 7: File Handle Network Attachment

**File:** `Sources/OmertaNetwork/VPN/FileHandleNetwork.swift`

**Deliverable:** Creates `VZFileHandleNetworkDeviceAttachment` and connects to FilteredNAT.

```swift
#if os(macOS)
import Virtualization

public struct FileHandleNetwork {
    public let attachment: VZFileHandleNetworkDeviceAttachment
    public let filteredNAT: FilteredNAT

    public static func create(consumerEndpoint: Endpoint) throws -> FileHandleNetwork

    /// Start processing loop
    public func start() async

    /// Stop and cleanup
    public func stop()
}
#endif
```

**Integration Tests:** `FileHandleNetworkTests.swift`
- Attachment creation succeeds
- File handles are readable/writable
- Write to host handle, read appears (mock VM side)
- Cleanup releases resources

**Dependencies:** `FilteredNAT`, Virtualization.framework

**Verification:** `swift test --filter FileHandleNetwork` (macOS only)

---

### Phase 8: VM WireGuard Setup

**Files:** `Resources/cloud-init/wireguard-setup.sh`, `Resources/cloud-init/iptables-setup.sh`

**Deliverable:** Scripts that configure WireGuard and iptables inside VM.

```bash
# wireguard-setup.sh
#!/bin/bash
wg-quick up /etc/wireguard/wg0.conf
ip link show wg0 || exit 1

# iptables-setup.sh
#!/bin/bash
iptables -P OUTPUT DROP
iptables -A OUTPUT -o wg0 -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
# ... etc
```

**Integration Tests:** `VMWireGuardTests.swift`
- VM boots with WireGuard configured
- `wg show` returns expected peer
- iptables rules match expected
- Outbound non-wg0 traffic blocked

**Dependencies:** VM image with WireGuard tools

**Verification:** Boot test VM, run verification script

---

### Phase 9: Provider Integration

**File:** Modify `Sources/OmertaProvider/ProviderVPNManager.swift`

**Deliverable:** Replace current VPN setup with FileHandleNetwork.

```swift
public actor ProviderVPNManager {
    // Replace WireGuard setup with:
    public func setupFilteredNAT(
        consumerEndpoint: Endpoint,
        vmConfig: inout VZVirtualMachineConfiguration
    ) async throws -> FileHandleNetwork
}
```

**Integration Tests:** `ProviderVPNIntegrationTests.swift`
- Full VM boot with filtered network
- Traffic to consumer works
- Traffic to internet blocked
- VM termination cleans up

**Dependencies:** All previous phases

**Verification:** `swift test --filter ProviderVPNIntegration`

---

### Phase 10: End-to-End Testing

**Deliverable:** Full consumer-to-VM connectivity test.

**Tests:** `E2EConnectivityTests.swift`
- Consumer WireGuard server running
- Provider starts VM with filtered NAT
- VM establishes WireGuard tunnel
- Bidirectional data transfer works
- Isolation verified (VM cannot reach internet)

**Dependencies:** All previous phases, test infrastructure

**Verification:** `swift test --filter E2E`

---

### Phase 11: Performance Optimization

**Files:** Modify `FilteredNAT.swift`, `FileHandleNetwork.swift`

**Deliverable:** Batch processing and Dispatch I/O optimizations.

```swift
extension FilteredNAT {
    /// Process multiple frames in batch
    public func processBatch(_ frames: [Data]) async -> [FilterResult]
}

extension FileHandleNetwork {
    /// Use Dispatch I/O for better throughput
    func startWithDispatchIO() async
}
```

**Performance Tests:** `ThroughputBenchmarkTests.swift`, `LatencyBenchmarkTests.swift`
- Measure baseline throughput
- Measure with batching
- Compare Dispatch I/O vs Foundation
- Verify targets met (2 Gbps, <100μs p50)

**Dependencies:** Phase 10 complete

**Verification:** `swift test --filter Benchmark`

---

### Phase 12: Hardening

**Deliverable:** Error handling, edge cases, security hardening.

**Tasks:**
- Handle VM handle EOF/errors gracefully
- Handle UDP socket errors with retry
- Add metrics/logging for dropped packets
- Fuzz testing with malformed frames
- Memory leak verification (Instruments)

**Tests:** `ErrorHandlingTests.swift`, `StressTests.swift`, `SecurityBypassTests.swift`

**Verification:** `swift test --filter Stress && swift test --filter Security`

---

## Phase Summary

| Phase | Deliverable | Tests | Dependencies |
|-------|-------------|-------|--------------|
| 1 | EthernetFrame parser | Unit | None |
| 2 | IPv4Packet parser | Unit | None |
| 3 | EndpointAllowlist | Unit | Phase 2 |
| 4 | UDPForwarder | Unit | Phase 3 |
| 5 | FramePacketBridge | Unit | Phase 1, 2, 3 |
| 6 | FilteredNAT core | Unit | Phase 3, 4, 5 |
| 7 | FileHandleNetwork | Integration | Phase 6 |
| 8 | VM WireGuard scripts | Integration | None |
| 9 | Provider integration | Integration | Phase 7, 8 |
| 10 | E2E testing | E2E | Phase 9 |
| 11 | Performance optimization | Performance | Phase 10 |
| 12 | Hardening | Stress/Security | Phase 11 |

## Files to Create/Modify

### New Files

| File | Phase | Purpose |
|------|-------|---------|
| `Sources/OmertaNetwork/VPN/EthernetFrame.swift` | 1 | Frame parsing/building |
| `Sources/OmertaNetwork/VPN/IPv4Packet.swift` | 2 | IP packet parsing |
| `Sources/OmertaNetwork/VPN/EndpointAllowlist.swift` | 3 | Allowlist logic |
| `Sources/OmertaNetwork/VPN/UDPForwarder.swift` | 4 | UDP socket wrapper |
| `Sources/OmertaNetwork/VPN/FramePacketBridge.swift` | 5 | Frame/packet conversion |
| `Sources/OmertaNetwork/VPN/FilteredNAT.swift` | 6 | Main NAT implementation |
| `Sources/OmertaNetwork/VPN/FileHandleNetwork.swift` | 7 | VZ attachment setup |
| `Resources/cloud-init/wireguard-setup.sh` | 8 | VM WireGuard config |
| `Resources/cloud-init/iptables-setup.sh` | 8 | VM firewall config |
| `Tests/OmertaNetworkTests/EthernetFrameTests.swift` | 1 | Unit tests |
| `Tests/OmertaNetworkTests/IPv4PacketTests.swift` | 2 | Unit tests |
| `Tests/OmertaNetworkTests/EndpointAllowlistTests.swift` | 3 | Unit tests |
| `Tests/OmertaNetworkTests/UDPForwarderTests.swift` | 4 | Unit tests |
| `Tests/OmertaNetworkTests/FramePacketBridgeTests.swift` | 5 | Unit tests |
| `Tests/OmertaNetworkTests/FilteredNATTests.swift` | 6 | Unit tests |
| `Tests/OmertaNetworkTests/FileHandleNetworkTests.swift` | 7 | Integration tests |
| `Tests/OmertaNetworkTests/E2EConnectivityTests.swift` | 10 | E2E tests |
| `Tests/OmertaNetworkTests/ThroughputBenchmarkTests.swift` | 11 | Performance tests |
| `Tests/OmertaNetworkTests/LatencyBenchmarkTests.swift` | 11 | Performance tests |

### Modified Files

| File | Phase | Changes |
|------|-------|---------|
| `Sources/OmertaProvider/ProviderVPNManager.swift` | 9 | Use FilteredNAT instead of WireGuard |
| `Sources/OmertaVM/VirtualizationManager.swift` | 9 | Use VZFileHandleNetworkDeviceAttachment |
| `Resources/cloud-init/*` | 8 | WireGuard + iptables setup |

## Security Checklist

- [ ] FilteredNAT only allows consumer endpoint
- [ ] Inbound packets only accepted from consumer
- [ ] No path for VM to reach internet
- [ ] No path for VM to reach provider LAN
- [ ] No path for VM to reach provider host
- [ ] VM iptables configured as defense in depth
- [ ] Logging of blocked traffic for debugging
- [ ] No sensitive data in logs

## Test Plan

### Unit Tests

#### EthernetFrame Parser (`EthernetFrameTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testParseValidIPv4Frame` | Parse well-formed IPv4 ethernet frame | Correct MAC addresses, etherType=0x0800, payload extracted |
| `testParseValidARPFrame` | Parse ARP frame | etherType=0x0806, payload extracted |
| `testParseIPv6Frame` | Parse IPv6 frame | etherType=0x86DD |
| `testParseTruncatedFrame` | Frame < 14 bytes | Returns nil |
| `testParseEmptyPayload` | Valid header, no payload | Valid frame with empty payload |
| `testRoundTrip` | Parse then serialize | Identical bytes |
| `testMACAddressExtraction` | Various MAC addresses | Correct 6-byte extraction |

#### IPv4Packet Parser (`IPv4PacketTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testParseValidUDPPacket` | Standard UDP packet | Correct src/dst IP, proto=17, port extraction |
| `testParseValidTCPPacket` | Standard TCP packet | Correct src/dst IP, proto=6 |
| `testParseICMPPacket` | ICMP echo request | proto=1, payload extracted |
| `testParseWithIPOptions` | IP header with options | Correct header length, payload offset |
| `testParseTruncatedHeader` | Packet < 20 bytes | Returns nil |
| `testParseInvalidHeaderLength` | IHL field too small | Returns nil |
| `testDestinationPortUDP` | UDP destination port | Correct port extraction |
| `testDestinationPortTCP` | TCP destination port | Correct port extraction |
| `testUDPPayloadExtraction` | Extract UDP payload | Correct offset (skip 8-byte UDP header) |

#### FilteredNAT Allowlist (`FilteredNATTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testAllowedEndpointPasses` | Packet to allowed endpoint | Forwarded |
| `testBlockedEndpointDropped` | Packet to non-allowed endpoint | Dropped, logged |
| `testEmptyAllowlistBlocksAll` | No endpoints configured | All packets dropped |
| `testMultipleAllowedEndpoints` | Two allowed endpoints | Both pass, others blocked |
| `testPortMismatchBlocked` | Correct IP, wrong port | Dropped |
| `testIPMismatchBlocked` | Wrong IP, correct port | Dropped |
| `testInboundFromAllowed` | Response from consumer | Accepted |
| `testInboundFromUnknown` | Packet from random IP | Dropped |
| `testSetAllowedEndpoint` | Update allowlist | New endpoint allowed, old blocked |

### Integration Tests

#### VM Network Setup (`VMNetworkIntegrationTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testFileHandleAttachmentCreation` | Create VZFileHandleNetworkDeviceAttachment | Valid attachment, handles readable/writable |
| `testVMReceivesFrames` | Send frame to VM handle | VM sees frame on eth0 |
| `testVMSendsFrames` | VM sends packet | Frame readable from host handle |
| `testARPResolution` | VM ARP request | FilteredNAT responds or forwards |
| `testDHCPOptional` | VM boots without DHCP | Static IP configuration works |

#### End-to-End Connectivity (`E2EConnectivityTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMToConsumerPing` | Ping consumer from VM | ICMP reaches consumer (if allowed) |
| `testVMToConsumerUDP` | UDP packet to consumer WireGuard port | Packet delivered |
| `testWireGuardHandshake` | Full WireGuard handshake | Tunnel established |
| `testEncryptedDataTransfer` | Send data through tunnel | Data received at consumer |
| `testBidirectionalTraffic` | Consumer sends to VM | Response received |

### Security Tests

#### Isolation Verification (`SecurityIsolationTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMCannotReachInternet` | VM tries to reach 8.8.8.8 | Packet dropped by FilteredNAT |
| `testVMCannotReachProviderLAN` | VM tries 192.168.1.1 | Dropped |
| `testVMCannotReachProviderHost` | VM tries provider's IP | Dropped |
| `testVMCannotReachOtherVMs` | VM tries other VM's IP | Dropped |
| `testVMCannotScanPorts` | Port scan attempt | All packets dropped |
| `testDNSBlocked` | VM tries DNS lookup (53/udp) | Dropped (unless consumer provides) |
| `testHTTPBlocked` | VM tries HTTP to internet | Dropped |
| `testHTTPSBlocked` | VM tries HTTPS to internet | Dropped |

#### Bypass Attempts (`SecurityBypassTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testSpoofedSourceIP` | VM spoofs source IP | Still blocked (dest check) |
| `testSpoofedSourceMAC` | VM spoofs MAC address | No effect on filtering |
| `testFragmentedPacket` | Fragmented IP packet | Reassembled and checked, or dropped |
| `testOversizedPacket` | Jumbo frame | Handled or dropped gracefully |
| `testMalformedIPHeader` | Invalid IP header | Dropped, no crash |
| `testMalformedEthernetFrame` | Truncated/corrupt frame | Dropped, no crash |
| `testRapidEndpointChanges` | Attacker tries to race allowlist | Only configured endpoint allowed |
| `testIPv6Blocked` | VM sends IPv6 | Dropped (IPv4 only allowlist) |
| `testNonIPProtocol` | Raw ethernet frames | Dropped or handled |

#### Defense in Depth Verification (`DefenseInDepthTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMIptablesActive` | Check VM firewall rules | OUTPUT policy DROP, wg0 allowed |
| `testVMIptablesSurvivesReboot` | Reboot VM | Rules persist |
| `testVMWithoutIptables` | Disable VM iptables | FilteredNAT still blocks |
| `testLayeredBlocking` | Both layers see blocked packet | Logged at both layers |

### Performance Tests

#### Throughput Benchmarks (`ThroughputBenchmarkTests.swift`)

| Test Case | Target | Measurement Method |
|-----------|--------|-------------------|
| `testSmallPacketThroughput` | >100K pps | 64-byte UDP packets for 10s, count delivered |
| `testLargePacketThroughput` | >2 Gbps | 1400-byte UDP packets for 10s, measure bandwidth |
| `testMixedSizeThroughput` | >1.5 Gbps | Realistic packet size distribution |
| `testSustainedThroughput` | Stable | 60-second continuous transfer, check for degradation |
| `testBurstThroughput` | No drops | 1000 packets in <10ms bursts |
| `testBidirectionalThroughput` | >1 Gbps each | Simultaneous upload/download |

**Throughput Test Methodology:**

```swift
func measureThroughput(packetSize: Int, duration: TimeInterval) async -> ThroughputResult {
    let startTime = ContinuousClock.now
    var bytesSent: UInt64 = 0
    var packetsSent: UInt64 = 0

    while ContinuousClock.now - startTime < .seconds(duration) {
        let packet = generateTestPacket(size: packetSize)
        try await filteredNAT.forward(packet)
        bytesSent += UInt64(packetSize)
        packetsSent += 1
    }

    let elapsed = ContinuousClock.now - startTime
    return ThroughputResult(
        bytesPerSecond: Double(bytesSent) / elapsed.seconds,
        packetsPerSecond: Double(packetsSent) / elapsed.seconds
    )
}
```

#### Latency Benchmarks (`LatencyBenchmarkTests.swift`)

| Test Case | Target | Measurement Method |
|-----------|--------|-------------------|
| `testFrameProcessingLatency` | <100 μs p50 | Timestamp at ingress/egress, measure delta |
| `testAllowlistCheckLatency` | <1 μs | Microbenchmark allowlist lookup |
| `testE2ELatency` | <500 μs p50 | Round-trip ping through full stack |
| `testLatencyUnderLoad` | <200 μs p50 | Measure latency at 50% throughput |
| `testLatencyPercentiles` | p99 <1ms | Collect 10K samples, compute percentiles |
| `testJitter` | <100 μs stddev | Measure latency variance |

**Latency Test Methodology:**

```swift
func measureLatency(samples: Int) async -> LatencyResult {
    var latencies: [Duration] = []

    for _ in 0..<samples {
        let packet = generateTestPacket()
        let start = ContinuousClock.now
        try await filteredNAT.forward(packet)
        let end = ContinuousClock.now
        latencies.append(end - start)
    }

    latencies.sort()
    return LatencyResult(
        p50: latencies[samples / 2],
        p95: latencies[samples * 95 / 100],
        p99: latencies[samples * 99 / 100],
        mean: latencies.reduce(.zero, +) / samples,
        stddev: calculateStdDev(latencies)
    )
}
```

#### Stress Tests (`StressTests.swift`)

| Test Case | Description | Success Criteria |
|-----------|-------------|------------------|
| `testHighPacketRate` | 500K pps for 60s | No crashes, <1% packet loss |
| `testMemoryStability` | 1M packets | Memory usage stable (no leaks) |
| `testCPUUtilization` | Max throughput | CPU usage reasonable (<80% one core) |
| `testLongRunning` | 1 hour continuous | No degradation, no memory growth |
| `testConnectionChurn` | Rapid VM start/stop | Clean resource cleanup |
| `testConcurrentVMs` | 4 VMs simultaneously | Fair bandwidth sharing |

**Stress Test Methodology:**

```swift
func stressTest(duration: TimeInterval, targetPPS: Int) async -> StressResult {
    let monitor = ResourceMonitor()
    monitor.start()

    let startMemory = monitor.currentMemory
    var totalPackets: UInt64 = 0
    var droppedPackets: UInt64 = 0

    let startTime = ContinuousClock.now
    while ContinuousClock.now - startTime < .seconds(duration) {
        for _ in 0..<targetPPS / 100 {  // 10ms batches
            let result = try? await filteredNAT.forward(generateTestPacket())
            totalPackets += 1
            if result == nil { droppedPackets += 1 }
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    monitor.stop()
    return StressResult(
        totalPackets: totalPackets,
        droppedPackets: droppedPackets,
        dropRate: Double(droppedPackets) / Double(totalPackets),
        peakMemory: monitor.peakMemory,
        memoryGrowth: monitor.peakMemory - startMemory,
        peakCPU: monitor.peakCPUPercent
    )
}
```

#### Baseline Comparisons (`BaselineComparisonTests.swift`)

| Comparison | Method |
|------------|--------|
| FilteredNAT vs VZNATNetworkDeviceAttachment | Same workload, measure throughput delta |
| FilteredNAT vs raw socket forwarding | Measure filtering overhead |
| With batching vs without batching | Measure batch optimization gains |
| Dispatch I/O vs Foundation FileHandle | Compare I/O strategies |

### Reliability Tests

#### Error Handling (`ErrorHandlingTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMHandleClose` | VM terminates unexpectedly | Clean shutdown, no crash |
| `testNetworkSocketError` | UDP socket error | Reconnect or graceful failure |
| `testResourceExhaustion` | Out of file descriptors | Graceful error, cleanup |
| `testInvalidFrameRecovery` | Stream of invalid frames | Continue processing valid frames |
| `testPartialRead` | Incomplete frame read | Buffer and wait for rest |

#### Recovery (`RecoveryTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMRestart` | Stop and start VM | New FilteredNAT instance works |
| `testConsumerReconnect` | Consumer IP changes | Allowlist update, traffic flows |
| `testProviderNetworkFlap` | Provider loses network briefly | Recovers when network returns |

### Test Infrastructure

#### Test Utilities

```swift
// Mock VM handle for unit tests
class MockVMHandle: FileHandle {
    var sentFrames: [Data] = []
    var framesToReceive: [Data] = []

    func simulateVMSends(_ frame: Data) {
        framesToReceive.append(frame)
    }
}

// Packet generators
func generateTestPacket(
    destIP: IPv4Address = .consumer,
    destPort: UInt16 = 51900,
    size: Int = 100
) -> Data

// Traffic generators for load testing
actor TrafficGenerator {
    func generateLoad(pps: Int, duration: TimeInterval) async
    func generateBurst(packets: Int) async
}

// Metrics collectors
class PerformanceMetrics {
    func recordLatency(_ duration: Duration)
    func recordThroughput(bytes: Int, duration: Duration)
    func generateReport() -> PerformanceReport
}
```

#### CI Integration

```yaml
# .github/workflows/test.yml
performance-tests:
  runs-on: macos-14  # Apple Silicon
  steps:
    - name: Run throughput benchmarks
      run: swift test --filter ThroughputBenchmark

    - name: Run latency benchmarks
      run: swift test --filter LatencyBenchmark

    - name: Compare against baseline
      run: |
        swift test --filter BaselineComparison
        # Fail if >10% regression

    - name: Upload performance results
      uses: actions/upload-artifact@v3
      with:
        name: perf-results
        path: .build/perf-*.json
```

### Performance Targets Summary

| Metric | Target | Stretch Goal |
|--------|--------|--------------|
| Throughput (large packets) | 2 Gbps | 4 Gbps |
| Throughput (small packets) | 100K pps | 200K pps |
| Latency (p50) | 100 μs | 50 μs |
| Latency (p99) | 500 μs | 200 μs |
| Memory per VM | <10 MB | <5 MB |
| CPU at max throughput | <80% | <50% |
| Packet loss under load | <0.1% | 0% |

## References

- [VZFileHandleNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment)
- [Virtualization.framework](https://developer.apple.com/documentation/virtualization)
- [WireGuard Protocol](https://www.wireguard.com/protocol/)
- [io_uring](https://kernel.dk/io_uring.pdf)
- [AF_XDP](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
