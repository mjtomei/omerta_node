# VM Network Implementation Details

This document covers the phased implementation plan for the VM network architecture.

**Related Documents:**
- [Architecture Overview](vm-network-architecture.md) - Design, security model, and mode comparison
- [Test Plan](vm-network-tests.md) - Security, performance, and reliability tests

## Implementation

### Network Mode Selection

```swift
import Virtualization

public func createVMNetwork(
    mode: VMNetworkMode,
    consumerEndpoint: Endpoint?
) -> VMNetworkResult {
    switch mode {
    case .direct:
        return createDirectNetwork()
    case .filtered:
        guard let endpoint = consumerEndpoint else {
            fatalError("Filtered mode requires consumer endpoint")
        }
        return createFilteredNetwork(consumerEndpoint: endpoint)
    }
}

public enum VMNetworkResult {
    case direct(VZNetworkDeviceConfiguration)
    case filtered(VZNetworkDeviceConfiguration, FilteredNAT)
}
```

### Direct Mode Setup

```swift
func createDirectNetwork() -> VMNetworkResult {
    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    networkDevice.attachment = VZNATNetworkDeviceAttachment()
    return .direct(networkDevice)
}
```

### Filtered Mode Setup

```swift
func createFilteredNetwork(consumerEndpoint: Endpoint) -> VMNetworkResult {
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
        consumerEndpoint: consumerEndpoint
    )

    return .filtered(networkDevice, filteredNAT)
}
```

### FilteredNAT Implementation

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

### Ethernet Frame Handling

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

### Linux Options

#### 1. eBPF/TC - Kernel-Level Filtering (Recommended)

eBPF allows running sandboxed programs directly in the Linux kernel. For VM traffic filtering, **TC (Traffic Control) eBPF** is ideal.

**Performance:** 10-24 Mpps per core (near line-rate)

```c
// eBPF program for VM egress filtering
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

struct flow_key {
    __be32 dest_ip;
    __be16 dest_port;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, struct flow_key);
    __type(value, __u8);
} allowlist_map SEC(".maps");

SEC("tc")
int filter_vm_egress(struct __sk_buff *skb) {
    // Parse headers, check allowlist, return TC_ACT_OK or TC_ACT_SHOT
}
```

#### 2. NEFilterPacketProvider (macOS)

macOS provides `NEFilterPacketProvider` for kernel-assisted packet filtering with 5-10 Gbps performance.

**Note:** `com.apple.developer.networking.networkextension` is a standard entitlement (no special approval needed).

### Recommended Approach

| Platform | Method | Expected Throughput | Complexity |
|----------|--------|-------------------|------------|
| macOS | Dispatch I/O + batching | 3-5 Gbps | Low |
| macOS | **NEFilterPacketProvider** | **5-10 Gbps** | Medium |
| Linux | Userspace (io_uring) | 5-8 Gbps | Low |
| Linux | **eBPF/TC (recommended)** | **10+ Gbps** | Medium |

## Comparison with Alternatives

| Approach | Privileges | Performance | Security | Complexity | Platform |
|----------|-----------|-------------|----------|------------|----------|
| **Direct mode** | None | ~10 Gbps | VM-only | Low | All |
| **Sampled mode** | None | ~8 Gbps | Probabilistic | Low | All |
| **Conntrack mode** | None | ~6 Gbps | Good | Medium | All |
| **Filtered mode** | None | ~2-4 Gbps | Excellent | Medium | All |
| **eBPF/TC filtered** | CAP_BPF | **~10+ Gbps** | Excellent | Medium | Linux |
| **NEFilterPacketProvider** | Standard entitlement | **5-10 Gbps** | Excellent | Medium | macOS |

## Implementation Phases

Each phase produces a testable artifact.

### Phase 1: Ethernet Frame Parser

**File:** `Sources/OmertaNetwork/VPN/EthernetFrame.swift`

**Deliverable:** Standalone struct that parses and builds ethernet frames.

**Unit Tests:** `EthernetFrameTests.swift`
- Parse valid IPv4/ARP/IPv6 frames
- Handle truncated frames (return nil)
- Round-trip serialization

**Dependencies:** None

---

### Phase 2: IPv4 Packet Parser

**File:** `Sources/OmertaNetwork/VPN/IPv4Packet.swift`

**Deliverable:** Standalone struct that parses IPv4 headers and extracts UDP/TCP ports.

**Unit Tests:** `IPv4PacketTests.swift`
- Parse UDP/TCP/ICMP packets
- Extract destination ports correctly
- Handle IP options

**Dependencies:** None

---

### Phase 3: Endpoint Allowlist

**File:** `Sources/OmertaNetwork/VPN/EndpointAllowlist.swift`

**Deliverable:** Thread-safe allowlist that checks if an endpoint is permitted.

**Unit Tests:** `EndpointAllowlistTests.swift`
- Empty allowlist blocks all
- Port/IP mismatch blocked
- Thread safety

**Dependencies:** Phase 2

---

### Phase 4: UDP Forwarder

**File:** `Sources/OmertaNetwork/VPN/UDPForwarder.swift`

**Deliverable:** Sends UDP packets to consumer and receives responses.

**Unit Tests:** `UDPForwarderTests.swift`
- Send to localhost echo server
- Receive response

**Dependencies:** Phase 3

---

### Phase 5: Frame-to-Packet Bridge

**File:** `Sources/OmertaNetwork/VPN/FramePacketBridge.swift`

**Deliverable:** Converts between ethernet frames and IP packets.

**Unit Tests:** `FramePacketBridgeTests.swift`
- Extract IPv4 packet from frame
- Build response frame

**Dependencies:** Phases 1, 2, 3

---

### Phase 6: FilteredNAT Core

**File:** `Sources/OmertaNetwork/VPN/FilteredNAT.swift`

**Deliverable:** Combines all components into the filtering NAT logic.

**Unit Tests:** `FilteredNATTests.swift`
- Allowed traffic forwarded
- Blocked traffic dropped

**Dependencies:** Phases 3, 4, 5

---

### Phase 7: Filtering Strategies

**File:** `Sources/OmertaNetwork/VPN/FilteringStrategy.swift`

**Deliverable:** Protocol and implementations for different filtering strategies (Full, Conntrack, Sampled).

**Unit Tests:** `FilteringStrategyTests.swift`
- Full filter blocks non-allowed
- Conntrack fast-paths repeat flows
- Sampled catches violations probabilistically

**Dependencies:** Phases 2, 3

---

### Phase 8: VM Network Manager

**File:** `Sources/OmertaNetwork/VPN/VMNetworkManager.swift`

**Deliverable:** Unified manager that creates network for any mode.

**Integration Tests:** `VMNetworkManagerTests.swift`
- Direct mode creates VZNATNetworkDeviceAttachment
- Filtered mode creates VZFileHandleNetworkDeviceAttachment

**Platform:** macOS only

**Dependencies:** Phases 6, 7

---

### Phase 9: VM WireGuard Setup (Cloud-Init)

**Goal:** Portable WireGuard and firewall configuration using cloud-init.

**Files:**
- `Sources/OmertaVM/CloudInit/CloudInitConfig.swift`
- `Sources/OmertaVM/CloudInit/CloudInitGenerator.swift`
- `Sources/OmertaVM/CloudInit/CloudInitISO.swift`

**Unit Tests:** `CloudInitTests.swift`
- Valid cloud-config YAML generated
- WireGuard config embedded correctly
- Firewall rules present

**Dependencies:** None (works on both platforms)

---

### Phase 10: Provider Integration

**File:** Modify `Sources/OmertaProvider/ProviderVPNManager.swift`

**Deliverable:** Replace current VPN setup with VMNetworkManager.

**Dependencies:** Phases 8, 9

---

### Phase 11: End-to-End Testing

**Tests:** `E2EConnectivityTests.swift`
- Consumer WireGuard server running
- Provider starts VM with filtered NAT
- VM establishes WireGuard tunnel
- Isolation verified

**Dependencies:** Phase 10

---

### Phase 11.5: Linux QEMU VM Network Parity

**Goal:** Linux QEMU VMs use Phase 9 cloud-init network isolation.

**File:** `Sources/OmertaVM/VMManager.swift`

**Deliverable:** Linux QEMU VMs boot with WireGuard + iptables configured via cloud-init.

**Platform:** Linux only

**Dependencies:** Phase 9

---

### Phase 12: Performance Optimization

**Deliverable:** Batch processing and Dispatch I/O optimizations.

**Performance Tests:** `ThroughputBenchmarkTests.swift`, `LatencyBenchmarkTests.swift`

**Dependencies:** Phase 11

---

### Phase 13: Hardening

**Deliverable:** Error handling, edge cases, security hardening.

**Tests:** `ErrorHandlingTests.swift`, `StressTests.swift`, `SecurityBypassTests.swift`

**Dependencies:** Phase 12

---

### Phase 14: eBPF Kernel Filtering (Linux Only)

**Files:**
- `Sources/OmertaNetwork/VPN/EBPFFilter.swift`
- `Sources/OmertaNetwork/VPN/ebpf/vm_filter.bpf.c`

**Deliverable:** Kernel-level packet filtering for 10+ Gbps on Linux.

**Requirements:** Linux kernel 4.18+, libbpf, CAP_BPF

**Dependencies:** Phase 6

---

### Phase 15: NEFilterPacketProvider (macOS Only)

**Files:**
- `Sources/OmertaNetwork/VPN/NEPacketFilter.swift`
- `Sources/OmertaNetworkExtension/PacketFilterProvider.swift`

**Deliverable:** Kernel-assisted filtering for 5-10 Gbps on macOS.

**Dependencies:** Phase 6

---

## Phase Summary

| Phase | Deliverable | Platform | Status |
|-------|-------------|----------|--------|
| 1 | EthernetFrame parser | All | Done |
| 2 | IPv4Packet parser | All | Done |
| 3 | EndpointAllowlist | All | Done |
| 4 | UDPForwarder | All | Done |
| 5 | FramePacketBridge | All | Done |
| 6 | FilteredNAT core | All | Done |
| 7 | Filtering strategies | All | Done |
| 8 | VM Network Manager | macOS | Done |
| 9 | VM WireGuard scripts | All | Done |
| 10 | Provider integration | macOS | Done |
| 11 | E2E testing | macOS | Done |
| 11.5 | Linux QEMU parity | Linux | Done |
| 12 | Performance optimization | All | Pending |
| 13 | Hardening | All | Pending |
| 14 | eBPF kernel filtering | Linux | Pending |
| 15 | NEFilterPacketProvider | macOS | Pending |

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
| `Sources/OmertaNetwork/VPN/FilteringStrategy.swift` | 7 | Filtering strategies |
| `Sources/OmertaNetwork/VPN/VMNetworkManager.swift` | 8 | Network mode manager |
| `Sources/OmertaNetwork/VPN/EBPFFilter.swift` | 14 | eBPF wrapper (Linux) |
| `Sources/OmertaNetwork/VPN/NEPacketFilter.swift` | 15 | NE wrapper (macOS) |

### Modified Files

| File | Phase | Changes |
|------|-------|---------|
| `Sources/OmertaProvider/ProviderVPNManager.swift` | 10 | Use VMNetworkManager |
| `Sources/OmertaVM/VirtualizationManager.swift` | 10 | Support all network modes |
| `Sources/OmertaVM/VMManager.swift` | 11.5 | Use VMNetworkConfig in Linux QEMU |

---

**Next:** See [Test Plan](vm-network-tests.md) for detailed test specifications.
