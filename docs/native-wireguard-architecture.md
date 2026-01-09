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

### Phase 1: Basic Filtered NAT (1-2 days)

1. Implement VZFileHandleNetworkDeviceAttachment setup
2. Implement basic ethernet frame parsing
3. Implement FilteredNAT actor with allowlist
4. Basic UDP forwarding to consumer
5. Integration with ProviderVPNManager

### Phase 2: VM WireGuard Setup (1 day)

1. Update cloud-init/boot scripts for WireGuard
2. iptables rules for defense in depth
3. VPN verification on boot
4. Integration testing

### Phase 3: Performance Optimization (1-2 days)

1. Batch frame processing
2. Dispatch I/O / async optimizations
3. Throughput benchmarking
4. Latency profiling

### Phase 4: Testing & Hardening (1-2 days)

1. Security testing (bypass attempts)
2. Stress testing (high packet rates)
3. Error handling and recovery
4. Documentation

## Files to Create/Modify

### New Files

| File | Purpose |
|------|---------|
| `Sources/OmertaNetwork/VPN/FilteredNAT.swift` | Main filtered NAT implementation |
| `Sources/OmertaNetwork/VPN/EthernetFrame.swift` | Frame parsing/building |
| `Sources/OmertaNetwork/VPN/IPv4Packet.swift` | IP packet parsing |
| `Sources/OmertaNetwork/VPN/FileHandleNetwork.swift` | VZ file handle setup |
| `Tests/OmertaNetworkTests/FilteredNATTests.swift` | Unit tests |

### Modified Files

| File | Changes |
|------|---------|
| `Sources/OmertaProvider/ProviderVPNManager.swift` | Use FilteredNAT instead of WireGuard |
| `Sources/OmertaVM/VirtualizationManager.swift` | Use VZFileHandleNetworkDeviceAttachment |
| `Resources/cloud-init/*` | WireGuard + iptables setup |

## Security Checklist

- [ ] FilteredNAT only allows consumer endpoint
- [ ] Inbound packets only accepted from consumer
- [ ] No path for VM to reach internet
- [ ] No path for VM to reach provider LAN
- [ ] No path for VM to reach provider host
- [ ] VM iptables configured as defense in depth
- [ ] Logging of blocked traffic for debugging
- [ ] No sensitive data in logs

## References

- [VZFileHandleNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment)
- [Virtualization.framework](https://developer.apple.com/documentation/virtualization)
- [WireGuard Protocol](https://www.wireguard.com/protocol/)
- [io_uring](https://kernel.dk/io_uring.pdf)
- [AF_XDP](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
