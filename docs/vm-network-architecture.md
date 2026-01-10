# VM Network Architecture: In-VM WireGuard with Optional Filtering

## Overview

This document describes the network architecture for Omerta VMs on macOS providers. Two networking modes are available:

| Mode | Throughput | Isolation | Provider Overhead | Use Case |
|------|------------|-----------|-------------------|----------|
| **Direct** | ~10 Gbps | VM-side only | None | Trusted workloads, performance-critical |
| **Filtered** | ~2-4 Gbps | Provider-enforced | Userspace NAT | Untrusted workloads, maximum security |

Both modes share:
- **No root privileges** on provider
- **No restricted entitlements** (works without Apple approval)
- **In-VM kernel WireGuard** for encryption
- **VM iptables** for defense in depth

## Network Mode Configuration

```swift
public enum VMNetworkMode: String, Codable {
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
```

Provider configuration:
```json
{
  "network": {
    "mode": "conntrack",
    "samplingRate": 0.01,  // for sampled mode: check 1% of packets
    "allowModeOverride": false
  }
}
```

### Mode Comparison

| Mode | Throughput | Security | CPU Overhead | Detection |
|------|------------|----------|--------------|-----------|
| `direct` | ~10 Gbps | VM-only | None | None |
| `sampled` | ~8 Gbps | Probabilistic | ~5% | Eventual (may miss) |
| `conntrack` | ~6 Gbps | Per-flow | ~15% | First packet |
| `filtered` | ~2-4 Gbps | Per-packet | ~50% | Immediate |

### Mode Details

**`sampled` - Statistical Sampling:**
- Check random subset of packets (e.g., 1%)
- If violation detected → terminate VM immediately
- Attacker could get lucky, but sustained abuse will be caught
- Best for: trusted networks where you want a safety net

**`conntrack` - Connection Tracking:**
- Maintain hash table of seen (destIP, destPort) pairs
- First packet to new destination → full allowlist check
- Subsequent packets to same destination → hash lookup only
- Best for: typical workloads with few unique destinations

**`filtered` - Full Inspection:**
- Every packet checked against allowlist
- Guaranteed isolation
- Best for: untrusted workloads, maximum security

## Architecture: Direct Mode (Default)

Uses `VZNATNetworkDeviceAttachment` - Apple's built-in NAT with kernel-level performance.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Consumer (Linux)                             │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  WireGuard Server (kernel)                                    │  │
│  │  - Listens: UDP port 51900                                    │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                                 ▲
                                 │ WireGuard UDP (encrypted)
                                 │
┌────────────────────────────────┼────────────────────────────────────┐
│                                │                                     │
│  ┌─────────────────────────────┼─────────────────────────────────┐  │
│  │      VZNATNetworkDeviceAttachment (kernel, ~10 Gbps)          │  │
│  │      • Zero provider code in data path                        │  │
│  │      • VM gets 192.168.64.x address                           │  │
│  │      • Full internet access (filtered by VM only)             │  │
│  └─────────────────────────────┼─────────────────────────────────┘  │
│                                │                                     │
│  ┌─────────────────────────────┼─────────────────────────────────┐  │
│  │                           VM                                  │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  WireGuard Client (kernel) - FAST                       │ │  │
│  │  │  - Endpoint: consumer:51900                             │ │  │
│  │  │  - AllowedIPs: 0.0.0.0/0 (default route)               │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  iptables (PRIMARY isolation in direct mode)            │ │  │
│  │  │  -P OUTPUT DROP                                         │ │  │
│  │  │  -A OUTPUT -o wg0 -j ACCEPT                             │ │  │
│  │  │  -A OUTPUT -o lo -j ACCEPT                              │ │  │
│  │  │  -A OUTPUT -p udp --dport 51900 -d $CONSUMER -j ACCEPT  │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                      │
│                      Provider (macOS) - NO ROOT                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Direct Mode Security:**
- Isolation enforced by VM iptables only
- A root workload inside VM could bypass iptables
- Suitable for trusted workloads or when performance is critical
- VM still cannot access provider's localhost (macOS NAT isolation)

## Architecture: Filtered Mode

Uses `VZFileHandleNetworkDeviceAttachment` - provider inspects every packet.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Consumer (Linux)                             │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  WireGuard Server (kernel)                                    │  │
│  │  - Listens: UDP port 51900                                    │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                                 ▲
                                 │ WireGuard UDP (encrypted)
                                 │ ONLY allowed traffic
                                 │
┌────────────────────────────────┼────────────────────────────────────┐
│                                │                                     │
│  ┌─────────────────────────────┼─────────────────────────────────┐  │
│  │           FilteredNAT (userspace, ~2-4 Gbps)                  │  │
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

### Isolation Layers by Mode

| Layer | Direct Mode | Filtered Mode |
|-------|-------------|---------------|
| Provider FilteredNAT | ❌ Not present | ✅ Primary isolation |
| VM iptables | ⚠️ Primary (bypassable) | ✅ Defense in depth |
| WireGuard routing | ✅ Encryption | ✅ Encryption |

### What VM Can Access

**Direct Mode:**

| Destination | Allowed | Enforced By |
|-------------|---------|-------------|
| Consumer WireGuard | ✅ | VM iptables |
| Internet | ⚠️ Blocked by VM iptables | VM only (bypassable) |
| Provider LAN | ⚠️ Blocked by VM iptables | VM only (bypassable) |
| Provider localhost | ❌ | macOS NAT isolation |

**Filtered Mode:**

| Destination | Allowed | Enforced By |
|-------------|---------|-------------|
| Consumer WireGuard | ✅ | FilteredNAT allowlist |
| Consumer other ports | ❌ | FilteredNAT drops |
| Internet | ❌ | FilteredNAT drops |
| Provider LAN | ❌ | FilteredNAT drops |
| Provider host | ❌ | FilteredNAT drops |
| Other VMs | ❌ | FilteredNAT drops |

### Attack Scenarios

**Filtered Mode:**

| Attack | Result |
|--------|--------|
| VM disables iptables | FilteredNAT still blocks |
| VM spoofs source IP | FilteredNAT checks dest, still blocks |
| VM sends to random IP | FilteredNAT drops (not in allowlist) |
| VM scans provider LAN | All packets dropped |
| VM tries DNS lookup | Dropped (unless consumer provides DNS) |
| Malicious inbound traffic | FilteredNAT only accepts from consumer |

**Direct Mode:**

| Attack | Result |
|--------|--------|
| VM disables iptables | ⚠️ VM can reach internet |
| VM spoofs source IP | Traffic may leak |
| VM sends to random IP | ⚠️ Traffic reaches internet |
| VM scans provider LAN | ⚠️ Possible (macOS NAT may limit) |
| VM tries DNS lookup | ⚠️ Succeeds if iptables bypassed |
| Malicious inbound traffic | Blocked by NAT (no port forwarding) |

### Boot-Time Network Isolation

**Critical Security Consideration:** The VM must be network-isolated from the provider's network until the WireGuard tunnel is established. This prevents the VM from:
- Accessing the provider's LAN during the boot window
- Reaching the internet before firewall rules are applied
- Communicating with any endpoint other than the consumer

**The Problem: Package Installation**

If the VM image doesn't have WireGuard pre-installed, cloud-init must download packages during boot. This creates a security window where the VM needs network access before isolation is enforced:

| Approach | Boot-time Isolation | Complexity | Recommended |
|----------|---------------------|------------|-------------|
| **Pre-built image** | ✅ Full isolation | Image maintenance | ✅ Production |
| **Offline packages** | ✅ Full isolation | Seed ISO packaging | ✅ Alternative |
| **Online install** | ❌ Network exposed | Minimal | ⚠️ Development only |

**Recommended: Pre-built VM Image**

For production deployments, use VM images with WireGuard and iptables pre-installed:

```bash
# Ubuntu/Debian base image
apt-get install -y wireguard iptables cloud-init

# Alpine base image
apk add wireguard-tools iptables cloud-init
```

With packages pre-installed:
1. Firewall rules can be applied immediately in `bootcmd` (before networking starts)
2. WireGuard can start before any outbound connections are possible
3. The VM never has unrestricted network access

**Alternative: Offline Package Installation**

Include `.deb` or `.apk` packages in the cloud-init seed ISO:

```yaml
write_files:
  - path: /var/cache/apt/archives/wireguard.deb
    encoding: base64
    content: <base64-encoded-deb>

bootcmd:
  - dpkg -i /var/cache/apt/archives/wireguard.deb
  - /etc/omerta/firewall.sh  # Apply isolation immediately
```

**Development Mode: Online Installation (Not Recommended)**

For development/testing only, packages can be installed at boot with temporary network access:

```yaml
# WARNING: Opens network access before WireGuard is configured
packages:
  - wireguard-tools
  - iptables

runcmd:
  - wg-quick up wg0
  - /etc/omerta/firewall.sh  # Isolation only after packages installed
```

**Security implications of online installation:**
- VM has ~30-60 seconds of unrestricted network access during boot
- Provider LAN is exposed during this window
- Acceptable only for trusted development environments

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

#### 3. eBPF/TC - Kernel-Level Filtering (Linux Only, Recommended)

eBPF (extended Berkeley Packet Filter) allows running sandboxed programs directly in the Linux kernel. For VM traffic filtering, **TC (Traffic Control) eBPF** is ideal because it works on both ingress and egress.

**Performance:** 10-24 Mpps per core (near line-rate)

**How it works:**
1. Attach eBPF program to VM's tap/virtio-net interface
2. Store allowlist in eBPF map (kernel hash table)
3. Kernel filters packets - they never reach userspace unless allowed
4. Swift manages loading/configuration via libbpf FFI

```c
// eBPF program for VM egress filtering (compiled with clang)
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

struct flow_key {
    __be32 dest_ip;
    __be16 dest_port;
};

// Allowlist stored in kernel - populated from userspace
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, struct flow_key);
    __type(value, __u8);
} allowlist_map SEC(".maps");

SEC("tc")
int filter_vm_egress(struct __sk_buff *skb) {
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    // Parse ethernet header
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_SHOT;

    // Only filter IPv4
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return TC_ACT_OK;

    // Parse IP header
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return TC_ACT_SHOT;

    // Only filter UDP (WireGuard)
    if (ip->protocol != IPPROTO_UDP)
        return TC_ACT_SHOT;

    // Parse UDP header
    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end)
        return TC_ACT_SHOT;

    // Build lookup key
    struct flow_key key = {
        .dest_ip = ip->daddr,
        .dest_port = udp->dest,
    };

    // O(1) kernel hash table lookup
    if (bpf_map_lookup_elem(&allowlist_map, &key))
        return TC_ACT_OK;   // Allowed - forward packet

    return TC_ACT_SHOT;     // Not allowed - drop packet
}

char LICENSE[] SEC("license") = "GPL";
```

**Swift integration via libbpf:**

```swift
// Load and attach eBPF program
import CLibbpf  // FFI wrapper

public class EBPFFilter {
    private var obj: OpaquePointer?
    private var prog: OpaquePointer?
    private var mapFd: Int32 = -1

    public func load(interfaceName: String) throws {
        // Load compiled eBPF object
        obj = bpf_object__open("vm_filter.bpf.o")
        guard obj != nil else { throw EBPFError.loadFailed }

        bpf_object__load(obj)

        // Get program and map
        prog = bpf_object__find_program_by_name(obj, "filter_vm_egress")
        mapFd = bpf_object__find_map_fd_by_name(obj, "allowlist_map")

        // Attach to TC on interface
        let ifindex = if_nametoindex(interfaceName)
        // ... tc qdisc and filter setup via netlink
    }

    public func setAllowedEndpoint(_ endpoint: Endpoint) throws {
        var key = FlowKey(
            destIP: endpoint.address.networkOrder,
            destPort: endpoint.port.bigEndian
        )
        var value: UInt8 = 1

        bpf_map_update_elem(mapFd, &key, &value, BPF_ANY)
    }

    public func removeEndpoint(_ endpoint: Endpoint) throws {
        var key = FlowKey(
            destIP: endpoint.address.networkOrder,
            destPort: endpoint.port.bigEndian
        )
        bpf_map_delete_elem(mapFd, &key)
    }
}
```

**Advantages:**
- Filtering happens at kernel level - no syscall overhead per packet
- Packets are dropped before reaching userspace (zero copy for blocked traffic)
- Allowlist updates are instant (eBPF map operations are atomic)
- Works with existing VM tap interfaces

**Requirements:**
- Linux kernel 4.18+ (for TC eBPF)
- CAP_BPF capability (or root) to load programs
- libbpf library
- clang/llvm for compiling eBPF programs

#### 4. Network Extension / NEFilterPacketProvider (macOS)

macOS provides `NEFilterPacketProvider` for kernel-assisted packet filtering with 5-10 Gbps performance.

**Entitlement Clarification (as of January 2026):**

Contrary to some outdated sources, `com.apple.developer.networking.networkextension` is **NOT a restricted entitlement** requiring special pre-approval:

- **No approval form needed**: Any paid Apple Developer Program member can enable it directly
- **Enable in Xcode**: Add "Network Extensions" capability, check "packet-filter-provider"
- **Enable in Developer Portal**: Check "Network Extensions" when creating/editing App ID
- **Standard App Review**: Apple reviews apps with this entitlement closely (due to network interception power), but no pre-entitlement approval is needed

**Common points of confusion:**
- `com.apple.vm.networking` (for Virtualization.framework network access) **IS restricted** and requires a request form - this is separate from NetworkExtension
- Early NetworkExtension (2015-2016) required requests, but this is long obsolete
- New features like "url-filter-provider" (2025) require capability requests, but packet-filter does not

**Implementation approach:**

```swift
import NetworkExtension

class PacketFilterProvider: NEFilterPacketProvider {
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        // Configure packet filtering rules
        completionHandler(nil)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // Check against allowlist
        guard let socketFlow = flow as? NEFilterSocketFlow,
              let remoteEndpoint = socketFlow.remoteEndpoint as? NWHostEndpoint else {
            return .drop()
        }

        if isAllowed(host: remoteEndpoint.hostname, port: remoteEndpoint.port) {
            return .allow()
        }
        return .drop()
    }
}
```

**Advantages:**
- Kernel-level filtering (5-10 Gbps)
- Standard entitlement (no special approval)
- Works with system extension model
- User-visible consent for transparency

**Considerations:**
- Requires system extension (user must approve in System Settings)
- More complex deployment than userspace
- App Store review scrutiny (but not blocked)
- Consider for future version after userspace approach is proven

#### 5. DPDK (Data Plane Development Kit)

For extreme performance (25+ Gbps), but requires:
- Dedicated NIC
- Hugepages
- More complex setup

Probably overkill for Omerta's use case.

### Recommended Approach

| Platform | Method | Expected Throughput | Complexity |
|----------|--------|-------------------|------------|
| macOS | Dispatch I/O + batching | 3-5 Gbps | Low |
| macOS | **NEFilterPacketProvider** | **5-10 Gbps** | Medium |
| Linux | Userspace (io_uring) | 5-8 Gbps | Low |
| Linux | **eBPF/TC (recommended)** | **10+ Gbps** | Medium |
| Linux (advanced) | AF_XDP | 10+ Gbps | High |

**Recommended path:**
1. Start with userspace filtering (Phases 1-7, already implemented)
2. Add eBPF acceleration for Linux (Phase 14)
3. Add NEFilterPacketProvider for macOS (Phase 15) - standard entitlement, no special approval

## Comparison with Alternatives

| Approach | Privileges | Performance | Security | Complexity | Platform |
|----------|-----------|-------------|----------|------------|----------|
| **Direct mode** | None | ~10 Gbps | VM-only | Low | All |
| **Sampled mode** | None | ~8 Gbps | Probabilistic | Low | All |
| **Conntrack mode** | None | ~6 Gbps | Good | Medium | All |
| **Filtered mode** | None | ~2-4 Gbps | Excellent | Medium | All |
| **eBPF/TC filtered** | CAP_BPF | **~10+ Gbps** | Excellent | Medium | Linux |
| **NEFilterPacketProvider** | Standard entitlement | **5-10 Gbps** | Excellent | Medium | macOS |
| WireGuard on provider (GotaTun) | Root | 3-5 Gbps | Good | Medium | All |

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

### Phase 7: Filtering Strategies

**File:** `Sources/OmertaNetwork/VPN/FilteringStrategy.swift`

**Deliverable:** Protocol and implementations for different filtering strategies.

```swift
/// Protocol for packet filtering strategies
public protocol FilteringStrategy: Sendable {
    /// Check if a packet should be forwarded
    func shouldForward(packet: IPv4Packet) async -> FilterDecision

    /// Called when violation detected (for logging/metrics)
    func recordViolation(packet: IPv4Packet, reason: String) async
}

public enum FilterDecision {
    case forward
    case drop(reason: String)
    case terminate(reason: String)  // Kill VM immediately
}

/// Full filtering - check every packet
public actor FullFilterStrategy: FilteringStrategy {
    private let allowlist: EndpointAllowlist

    public func shouldForward(packet: IPv4Packet) async -> FilterDecision {
        if await allowlist.isAllowed(address: packet.destinationAddress,
                                      port: packet.destinationPort ?? 0) {
            return .forward
        }
        return .drop(reason: "Not in allowlist")
    }
}

/// Connection tracking - check first packet per flow
public actor ConntrackStrategy: FilteringStrategy {
    private let allowlist: EndpointAllowlist
    private var seenFlows: Set<FlowKey> = []

    public func shouldForward(packet: IPv4Packet) async -> FilterDecision {
        let flow = FlowKey(dest: packet.destinationAddress,
                          port: packet.destinationPort ?? 0)

        // Fast path: already validated this flow
        if seenFlows.contains(flow) {
            return .forward
        }

        // Slow path: validate against allowlist
        if await allowlist.isAllowed(address: flow.dest, port: flow.port) {
            seenFlows.insert(flow)
            return .forward
        }

        return .terminate(reason: "Connection to non-allowed endpoint")
    }
}

/// Sampled filtering - check random subset
public actor SampledStrategy: FilteringStrategy {
    private let allowlist: EndpointAllowlist
    private let sampleRate: Double  // 0.01 = 1%

    public func shouldForward(packet: IPv4Packet) async -> FilterDecision {
        // Only check sampled packets
        guard Double.random(in: 0...1) < sampleRate else {
            return .forward  // Skip check
        }

        if await allowlist.isAllowed(address: packet.destinationAddress,
                                      port: packet.destinationPort ?? 0) {
            return .forward
        }

        // Violation detected in sample - terminate
        return .terminate(reason: "Sampled packet violated allowlist")
    }
}
```

**Unit Tests:** `FilteringStrategyTests.swift`
- FullFilterStrategy blocks non-allowed traffic
- ConntrackStrategy allows repeat flows without recheck
- ConntrackStrategy terminates on new bad flow
- SampledStrategy sometimes allows, sometimes checks
- SampledStrategy terminates on sampled violation

**Dependencies:** `EndpointAllowlist`, `IPv4Packet`

**Verification:** `swift test --filter FilteringStrategy`

---

### Phase 8: VM Network Manager

**File:** `Sources/OmertaNetwork/VPN/VMNetworkManager.swift`

**Deliverable:** Unified manager that creates network for any mode.

```swift
#if os(macOS)
import Virtualization

public actor VMNetworkManager {

    public enum NetworkHandle {
        case direct  // No cleanup needed
        case filtered(task: Task<Void, Never>)  // Background processing task
    }

    /// Create VM network configuration for specified mode
    public static func createNetwork(
        mode: VMNetworkMode,
        consumerEndpoint: Endpoint,
        samplingRate: Double = 0.01
    ) throws -> (VZNetworkDeviceConfiguration, NetworkHandle) {

        switch mode {
        case .direct:
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            return (device, .direct)

        case .sampled:
            let strategy = SampledStrategy(
                allowlist: EndpointAllowlist([consumerEndpoint]),
                sampleRate: samplingRate
            )
            return try createFilteredNetwork(strategy: strategy)

        case .conntrack:
            let strategy = ConntrackStrategy(
                allowlist: EndpointAllowlist([consumerEndpoint])
            )
            return try createFilteredNetwork(strategy: strategy)

        case .filtered:
            let strategy = FullFilterStrategy(
                allowlist: EndpointAllowlist([consumerEndpoint])
            )
            return try createFilteredNetwork(strategy: strategy)
        }
    }

    private static func createFilteredNetwork(
        strategy: FilteringStrategy
    ) throws -> (VZNetworkDeviceConfiguration, NetworkHandle) {
        // ... VZFileHandleNetworkDeviceAttachment setup
    }
}
#endif
```

**Integration Tests:** `VMNetworkManagerTests.swift`
- Direct mode creates VZNATNetworkDeviceAttachment
- Filtered mode creates VZFileHandleNetworkDeviceAttachment
- Conntrack mode creates file handle with conntrack strategy
- Sampled mode respects sample rate configuration
- Cleanup stops background tasks

**Dependencies:** Phases 1-7, Virtualization.framework

**Verification:** `swift test --filter VMNetworkManager` (macOS only)

---

### Phase 9: VM WireGuard Setup (Cloud-Init)

**Goal:** Portable WireGuard and firewall configuration using cloud-init, works across:
- Different Linux distributions (Ubuntu, Alpine, Debian)
- Different VM platforms (macOS Virtualization.framework, QEMU)
- Dynamic per-session configuration (keys, endpoints)

#### Files

| File | Purpose |
|------|---------|
| `Sources/OmertaVM/CloudInit/CloudInitConfig.swift` | Configuration model |
| `Sources/OmertaVM/CloudInit/CloudInitGenerator.swift` | Generates cloud-init userdata |
| `Sources/OmertaVM/CloudInit/CloudInitISO.swift` | Creates NoCloud ISO for VM |
| `Resources/cloud-init/meta-data.template` | Instance metadata template |
| `Resources/cloud-init/user-data.template` | Cloud-config YAML template |
| `Tests/OmertaVMTests/CloudInitTests.swift` | Unit tests |

#### Cloud-Init Configuration Model

```swift
/// Configuration for VM network isolation via WireGuard
public struct VMNetworkConfig: Codable, Sendable {
    /// WireGuard interface configuration
    public struct WireGuard: Codable, Sendable {
        public let privateKey: String      // Base64 WG private key
        public let address: String         // e.g., "10.200.200.2/24"
        public let listenPort: UInt16?     // Optional, usually not needed for client

        public struct Peer: Codable, Sendable {
            public let publicKey: String   // Consumer's public key
            public let endpoint: String    // e.g., "203.0.113.50:51820"
            public let allowedIPs: String  // e.g., "0.0.0.0/0, ::/0"
            public let persistentKeepalive: UInt16?  // e.g., 25
        }
        public let peer: Peer
    }
    public let wireGuard: WireGuard

    /// Firewall configuration
    public struct Firewall: Codable, Sendable {
        public let allowLoopback: Bool           // Always true
        public let allowWireGuardInterface: Bool // Always true
        public let allowDHCP: Bool               // For initial network setup
        public let allowDNS: Bool                // Usually false (use WG DNS)
        public let customRules: [String]?        // Additional iptables rules
    }
    public let firewall: Firewall

    /// VM metadata
    public let instanceId: String        // Unique per VM instance
    public let hostname: String          // e.g., "omerta-vm-abc123"
}
```

#### Cloud-Init Generator

```swift
public struct CloudInitGenerator {

    /// Generate cloud-init user-data YAML
    public static func generateUserData(config: VMNetworkConfig) -> String {
        """
        #cloud-config

        # Omerta VM Network Isolation Configuration
        # Generated: \(ISO8601DateFormatter().string(from: Date()))
        # Instance: \(config.instanceId)

        hostname: \(config.hostname)

        # Write WireGuard configuration
        write_files:
          - path: /etc/wireguard/wg0.conf
            permissions: '0600'
            content: |
              [Interface]
              PrivateKey = \(config.wireGuard.privateKey)
              Address = \(config.wireGuard.address)
              \(config.wireGuard.listenPort.map { "ListenPort = \($0)" } ?? "")

              [Peer]
              PublicKey = \(config.wireGuard.peer.publicKey)
              Endpoint = \(config.wireGuard.peer.endpoint)
              AllowedIPs = \(config.wireGuard.peer.allowedIPs)
              \(config.wireGuard.peer.persistentKeepalive.map { "PersistentKeepalive = \($0)" } ?? "")

          - path: /etc/omerta/firewall.sh
            permissions: '0755'
            content: |
              #!/bin/sh
              set -e

              # Flush existing rules
              iptables -F
              iptables -X
              ip6tables -F
              ip6tables -X

              # Default policies: DROP everything
              iptables -P INPUT DROP
              iptables -P FORWARD DROP
              iptables -P OUTPUT DROP
              ip6tables -P INPUT DROP
              ip6tables -P FORWARD DROP
              ip6tables -P OUTPUT DROP

              # Allow established connections
              iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
              iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

              \(config.firewall.allowLoopback ? """
              # Allow loopback
              iptables -A INPUT -i lo -j ACCEPT
              iptables -A OUTPUT -o lo -j ACCEPT
              ip6tables -A INPUT -i lo -j ACCEPT
              ip6tables -A OUTPUT -o lo -j ACCEPT
              """ : "")

              \(config.firewall.allowDHCP ? """
              # Allow DHCP (for initial network config)
              iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT
              iptables -A INPUT -p udp --sport 67:68 -j ACCEPT
              """ : "")

              \(config.firewall.allowWireGuardInterface ? """
              # Allow all traffic on WireGuard interface
              iptables -A INPUT -i wg0 -j ACCEPT
              iptables -A OUTPUT -o wg0 -j ACCEPT
              ip6tables -A INPUT -i wg0 -j ACCEPT
              ip6tables -A OUTPUT -o wg0 -j ACCEPT
              """ : "")

              # Allow WireGuard UDP to establish tunnel (before wg0 is up)
              # This allows the initial handshake through eth0/ens*
              iptables -A OUTPUT -p udp --dport \(config.wireGuard.peer.endpoint.split(separator: ":").last ?? "51820") -j ACCEPT

              \(config.firewall.customRules?.joined(separator: "\n") ?? "")

              echo "Firewall configured successfully"

          - path: /etc/omerta/setup-complete.sh
            permissions: '0755'
            content: |
              #!/bin/sh
              # Signal that setup is complete
              echo "OMERTA_SETUP_COMPLETE" > /run/omerta-ready
              echo "VM network isolation active"

        # Run commands on first boot
        runcmd:
          # Apply firewall rules first (defense in depth)
          - /etc/omerta/firewall.sh

          # Start WireGuard
          - wg-quick up wg0

          # Verify WireGuard is running
          - wg show wg0

          # Signal completion
          - /etc/omerta/setup-complete.sh

        # Ensure WireGuard starts on reboot
        bootcmd:
          - /etc/omerta/firewall.sh
        """
    }

    /// Generate cloud-init meta-data
    public static func generateMetaData(config: VMNetworkConfig) -> String {
        """
        instance-id: \(config.instanceId)
        local-hostname: \(config.hostname)
        """
    }
}
```

#### Cloud-Init ISO Generator

For VMs that use NoCloud datasource (most common):

```swift
public struct CloudInitISO {

    /// Create a cloud-init ISO image (NoCloud datasource)
    /// Returns path to the generated ISO file
    public static func create(
        config: VMNetworkConfig,
        outputPath: URL
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-init-\(config.instanceId)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write meta-data
        let metaData = CloudInitGenerator.generateMetaData(config: config)
        try metaData.write(to: tempDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)

        // Write user-data
        let userData = CloudInitGenerator.generateUserData(config: config)
        try userData.write(to: tempDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)

        // Create ISO using platform-specific tool
        let isoPath = outputPath.appendingPathComponent("cidata-\(config.instanceId).iso")

        #if os(macOS)
        // Use hdiutil on macOS
        try createISOmacOS(sourceDir: tempDir, outputPath: isoPath)
        #else
        // Use genisoimage/mkisofs on Linux
        try createISOLinux(sourceDir: tempDir, outputPath: isoPath)
        #endif

        // Cleanup temp directory
        try? FileManager.default.removeItem(at: tempDir)

        return isoPath
    }

    #if os(macOS)
    private static func createISOmacOS(sourceDir: URL, outputPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid",
            "-iso",
            "-joliet",
            "-o", outputPath.path,
            "-volname", "cidata",
            sourceDir.path
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CloudInitError.isoCreationFailed
        }
    }
    #else
    private static func createISOLinux(sourceDir: URL, outputPath: URL) throws {
        let process = Process()
        // Try genisoimage first, fall back to mkisofs
        process.executableURL = URL(fileURLWithPath: "/usr/bin/genisoimage")
        process.arguments = [
            "-output", outputPath.path,
            "-volid", "cidata",
            "-joliet",
            "-rock",
            sourceDir.path
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CloudInitError.isoCreationFailed
        }
    }
    #endif
}

public enum CloudInitError: Error {
    case isoCreationFailed
    case invalidConfiguration(String)
}
```

#### Integration with VM Platforms

**macOS (Virtualization.framework):**
```swift
extension VZVirtualMachineConfiguration {
    /// Attach cloud-init ISO as secondary disk
    mutating func attachCloudInitISO(_ isoPath: URL) throws {
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: isoPath,
            readOnly: true
        )
        let disk = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        self.storageDevices.append(disk)
    }
}
```

**Linux (QEMU):**
```swift
extension QEMUVMConfiguration {
    /// Add cloud-init ISO to QEMU command line
    func cloudInitArguments(isoPath: URL) -> [String] {
        ["-drive", "file=\(isoPath.path),if=virtio,format=raw,readonly=on"]
    }
}
```

#### Convenience Factory

```swift
public struct VMNetworkConfigFactory {

    /// Create a standard VM network config for consumer connection
    public static func createForConsumer(
        consumerPublicKey: String,
        consumerEndpoint: String,  // "ip:port"
        vmPrivateKey: String? = nil  // Auto-generate if nil
    ) -> VMNetworkConfig {
        let privateKey = vmPrivateKey ?? generateWireGuardPrivateKey()
        let instanceId = UUID().uuidString.prefix(8).lowercased()

        return VMNetworkConfig(
            wireGuard: .init(
                privateKey: privateKey,
                address: "10.200.200.2/24",
                listenPort: nil,
                peer: .init(
                    publicKey: consumerPublicKey,
                    endpoint: consumerEndpoint,
                    allowedIPs: "0.0.0.0/0, ::/0",
                    persistentKeepalive: 25
                )
            ),
            firewall: .init(
                allowLoopback: true,
                allowWireGuardInterface: true,
                allowDHCP: true,
                allowDNS: false,  // Use WireGuard DNS
                customRules: nil
            ),
            instanceId: "omerta-\(instanceId)",
            hostname: "omerta-vm-\(instanceId)"
        )
    }

    /// Generate WireGuard keypair
    public static func generateWireGuardKeyPair() -> (privateKey: String, publicKey: String) {
        // Use wg genkey | wg pubkey or native Curve25519
        // Implementation depends on available crypto libraries
        fatalError("TODO: Implement using Crypto framework or shell out to wg")
    }
}
```

#### Unit Tests

```swift
// CloudInitTests.swift
import XCTest
@testable import OmertaVM

final class CloudInitTests: XCTestCase {

    func testGenerateUserData() {
        let config = VMNetworkConfig(
            wireGuard: .init(
                privateKey: "test-private-key-base64==",
                address: "10.200.200.2/24",
                listenPort: nil,
                peer: .init(
                    publicKey: "consumer-public-key-base64==",
                    endpoint: "203.0.113.50:51820",
                    allowedIPs: "0.0.0.0/0",
                    persistentKeepalive: 25
                )
            ),
            firewall: .init(
                allowLoopback: true,
                allowWireGuardInterface: true,
                allowDHCP: true,
                allowDNS: false,
                customRules: nil
            ),
            instanceId: "test-instance-123",
            hostname: "omerta-vm-test"
        )

        let userData = CloudInitGenerator.generateUserData(config: config)

        // Verify cloud-config header
        XCTAssertTrue(userData.hasPrefix("#cloud-config"))

        // Verify WireGuard config is present
        XCTAssertTrue(userData.contains("PrivateKey = test-private-key-base64=="))
        XCTAssertTrue(userData.contains("PublicKey = consumer-public-key-base64=="))
        XCTAssertTrue(userData.contains("Endpoint = 203.0.113.50:51820"))
        XCTAssertTrue(userData.contains("AllowedIPs = 0.0.0.0/0"))

        // Verify firewall rules
        XCTAssertTrue(userData.contains("iptables -P OUTPUT DROP"))
        XCTAssertTrue(userData.contains("-o wg0 -j ACCEPT"))
        XCTAssertTrue(userData.contains("-i lo -j ACCEPT"))
    }

    func testGenerateMetaData() {
        let config = VMNetworkConfig(/* ... */)
        let metaData = CloudInitGenerator.generateMetaData(config: config)

        XCTAssertTrue(metaData.contains("instance-id: test-instance-123"))
        XCTAssertTrue(metaData.contains("local-hostname: omerta-vm-test"))
    }

    func testFirewallRulesBlockNonWireGuard() {
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "test-key",
            consumerEndpoint: "1.2.3.4:51820"
        )
        let userData = CloudInitGenerator.generateUserData(config: config)

        // Default policy should be DROP
        XCTAssertTrue(userData.contains("iptables -P OUTPUT DROP"))
        XCTAssertTrue(userData.contains("iptables -P INPUT DROP"))
        XCTAssertTrue(userData.contains("ip6tables -P OUTPUT DROP"))

        // Only wg0 and lo should be allowed
        XCTAssertTrue(userData.contains("-o wg0 -j ACCEPT"))
        XCTAssertTrue(userData.contains("-o lo -j ACCEPT"))

        // No general internet access rules
        XCTAssertFalse(userData.contains("-o eth0 -j ACCEPT"))
    }

    func testCreateISO() throws {
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: "test-key",
            consumerEndpoint: "1.2.3.4:51820"
        )

        let tempDir = FileManager.default.temporaryDirectory
        let isoPath = try CloudInitISO.create(config: config, outputPath: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: isoPath.path))

        // Cleanup
        try? FileManager.default.removeItem(at: isoPath)
    }
}
```

#### Integration Tests (require VM)

```swift
// VMWireGuardIntegrationTests.swift
final class VMWireGuardIntegrationTests: XCTestCase {

    func testVMBootsWithWireGuardConfigured() async throws {
        // Create cloud-init config
        let config = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: testConsumerPublicKey,
            consumerEndpoint: "\(testConsumerIP):51820"
        )

        // Create ISO
        let isoPath = try CloudInitISO.create(config: config, outputPath: tempDir)

        // Boot VM with cloud-init ISO attached
        let vm = try await bootTestVM(cloudInitISO: isoPath)
        defer { vm.stop() }

        // Wait for cloud-init to complete
        try await vm.waitForFile("/run/omerta-ready", timeout: 60)

        // Verify WireGuard is running
        let wgOutput = try await vm.execute("wg show wg0")
        XCTAssertTrue(wgOutput.contains("peer:"))
        XCTAssertTrue(wgOutput.contains(testConsumerPublicKey))
    }

    func testOutboundNonWireGuardBlocked() async throws {
        let vm = try await bootTestVMWithNetworkIsolation()
        defer { vm.stop() }

        // Try to ping external IP (should fail)
        let pingResult = try? await vm.execute("ping -c 1 -W 2 8.8.8.8")
        XCTAssertNil(pingResult, "Direct internet access should be blocked")

        // Try to reach via WireGuard (should work if consumer is running)
        // This would require a test consumer endpoint
    }

    func testIptablesRulesApplied() async throws {
        let vm = try await bootTestVMWithNetworkIsolation()
        defer { vm.stop() }

        let iptables = try await vm.execute("iptables -L -n")

        // Verify default DROP policies
        XCTAssertTrue(iptables.contains("Chain OUTPUT (policy DROP)"))
        XCTAssertTrue(iptables.contains("Chain INPUT (policy DROP)"))

        // Verify wg0 is allowed
        XCTAssertTrue(iptables.contains("ACCEPT") && iptables.contains("wg0"))
    }
}
```

#### Package Installation via Cloud-Init

> ⚠️ **Security Warning:** Online package installation requires network access before WireGuard isolation is active. See [Boot-Time Network Isolation](#boot-time-network-isolation) for security implications. **Use pre-built images for production.**

Cloud-init can automatically install required packages on first boot. The configuration model includes an optional packages list:

```swift
public struct VMNetworkConfig: Codable, Sendable {
    // ... existing fields ...

    /// Packages to install (distribution-specific)
    public struct PackageConfig: Codable, Sendable {
        public let packages: [String]      // Package names to install
        public let updateFirst: Bool       // apt-get update / apk update first
    }
    public let packageConfig: PackageConfig?
}
```

The generated cloud-config includes:

```yaml
# Package installation (DEVELOPMENT ONLY - see security warning above)
package_update: true
package_upgrade: false
packages:
  - wireguard-tools
  - iptables
```

For Alpine (where package names differ):
- `wireguard-tools` → same
- `iptables` → same

For Ubuntu/Debian:
- `wireguard-tools` → `wireguard`
- `iptables` → `iptables`

#### VM Image Requirements

**Production (Recommended):** Pre-install WireGuard and iptables for full boot-time isolation:

```bash
# Alpine
apk add wireguard-tools iptables cloud-init

# Ubuntu/Debian
apt-get install wireguard iptables cloud-init
```

With packages pre-installed, cloud-init can apply firewall rules in `bootcmd` before any network access occurs.

**Development Only:** Minimal image with just `cloud-init` pre-installed. Packages download during boot, creating a ~30-60 second window of unrestricted network access.

#### Verification

```bash
# Unit tests (no VM required)
swift test --filter CloudInit

# Integration tests (requires VM image)
swift test --filter VMWireGuardIntegration
```

---

### Phase 10: Provider Integration

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

### Phase 11: End-to-End Testing

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

### Phase 11.5: Linux QEMU VM Network Parity

**Goal:** Linux QEMU VMs use Phase 9 cloud-init network isolation (same as macOS).

**Current Gap:**
- macOS `startVMMacOS()` uses `VMNetworkConfigFactory.createForConsumer()` with WireGuard + iptables
- Linux `startVMQEMU()` accepts `consumerPublicKey`/`consumerEndpoint` but doesn't use them

**File:** `Sources/OmertaVM/SimpleVMManager.swift`

**Deliverable:** Linux QEMU VMs boot with:
- WireGuard client configured via cloud-init
- iptables rules blocking non-WireGuard traffic
- Same network isolation as macOS VMs

```swift
#if os(Linux)
private func startVMQEMU(...) async throws -> String {
    // Check if we should use VM-side WireGuard network isolation (Phase 9)
    let useNetworkIsolation = consumerPublicKey != nil && consumerEndpoint != nil

    if useNetworkIsolation, let consumerPubKey = consumerPublicKey,
       let consumerEP = consumerEndpoint {
        // Phase 9: Use network isolation cloud-init with WireGuard + firewall
        let vmPrivateKeyBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let vmPrivateKey = Data(vmPrivateKeyBytes).base64EncodedString()

        let vmAddress = vpnIP.map { "\($0)/24" } ?? "10.200.200.2/24"
        let vmNetConfig = VMNetworkConfigFactory.createForConsumer(
            consumerPublicKey: consumerPubKey,
            consumerEndpoint: consumerEP,
            vmPrivateKey: vmPrivateKey,
            vmAddress: vmAddress,
            packageConfig: .debian
        )

        try createCombinedCloudInitISO(
            at: seedISOPath,
            vmNetConfig: vmNetConfig,
            sshPublicKey: sshPublicKey,
            sshUser: sshUser,
            instanceId: vmId
        )
    } else {
        // Basic cloud-init without network isolation
        try CloudInitGenerator.createSeedISO(...)
    }
    // ... rest of QEMU boot
}
#endif
```

**Unit Tests:** Existing `CloudInitTests.swift` covers config generation (cross-platform)

**Integration Tests:** `Tests/OmertaVMTests/LinuxVMNetworkTests.swift`

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testLinuxVMWithNetworkIsolation` | Boot QEMU VM with consumer params | VM boots with WireGuard configured |
| `testLinuxVMWireGuardInterface` | Check wg0 interface in VM | Interface exists with correct config |
| `testLinuxVMIptables` | Check iptables rules in VM | DROP default, WireGuard traffic allowed |
| `testLinuxVMConnectsToConsumer` | VM connects to consumer WG | Handshake successful |
| `testLinuxVMFallbackWithoutParams` | Boot without consumer params | Basic cloud-init, no WireGuard |

**Dependencies:** Phase 9 (Cloud-Init), Phase 10 (Provider Integration concepts)

**Verification:**
```bash
# On Linux:
swift test --filter LinuxVMNetwork
# Manual: Boot VM and verify
ssh omerta@<vm-ip> "ip link show wg0 && sudo iptables -L"
```

**Platform:** Linux only (macOS already has this via `startVMMacOS`)

---

### Phase 12: Performance Optimization

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

### Phase 13: Hardening

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

### Phase 14: eBPF Kernel Filtering (Linux Only)

**Files:**
- `Sources/OmertaNetwork/VPN/EBPFFilter.swift` - Swift wrapper for libbpf
- `Sources/OmertaNetwork/VPN/ebpf/vm_filter.bpf.c` - eBPF program source
- `Sources/CLibbpf/` - C shim for libbpf FFI

**Deliverable:** Kernel-level packet filtering using eBPF/TC for 10+ Gbps performance on Linux.

```swift
#if os(Linux)
/// eBPF-accelerated packet filter for Linux
public actor EBPFFilter {
    /// Load eBPF program and attach to interface
    public func attach(to interfaceName: String) throws

    /// Update allowlist in eBPF map (instant, no reload)
    public func setAllowedEndpoints(_ endpoints: [Endpoint]) throws

    /// Detach and cleanup
    public func detach()

    /// Get filtering statistics from eBPF map
    public var statistics: EBPFFilterStatistics { get async }
}

/// Integration with existing FilteredNAT
extension FilteredNAT {
    /// Use eBPF for filtering instead of userspace
    public func enableEBPFAcceleration(interface: String) async throws
}
#endif
```

**eBPF Program Features:**
- TC egress filter on VM tap interface
- Allowlist stored in BPF_MAP_TYPE_HASH
- Statistics in BPF_MAP_TYPE_PERCPU_ARRAY
- Atomic allowlist updates via map operations

**Unit Tests:** `EBPFFilterTests.swift` (Linux only)
- Load/attach eBPF program
- Allowlist map operations
- Verify packets filtered correctly
- Statistics collection
- Cleanup on detach

**Integration Tests:**
- Compare filtering results: eBPF vs userspace
- Throughput benchmark: expect 10+ Gbps
- Latency benchmark: expect <10μs

**Build Requirements:**
- Linux kernel 4.18+ with BTF support
- libbpf-dev package
- clang/llvm for compiling eBPF
- CAP_BPF or root for loading programs

**Build Integration:**
```swift
// Package.swift
#if os(Linux)
targets: [
    .systemLibrary(
        name: "CLibbpf",
        pkgConfig: "libbpf",
        providers: [.apt(["libbpf-dev"])]
    ),
    .executableTarget(
        name: "omertad",
        dependencies: ["OmertaNetwork", "CLibbpf"],
        linkerSettings: [.linkedLibrary("bpf")]
    )
]
#endif
```

**Verification:** `swift test --filter EBPF` (Linux with CAP_BPF)

---

## Phase Summary

| Phase | Deliverable | Tests | Dependencies | Platform |
|-------|-------------|-------|--------------|----------|
| 1 | EthernetFrame parser | Unit | None | All |
| 2 | IPv4Packet parser | Unit | None | All |
| 3 | EndpointAllowlist | Unit | Phase 2 | All |
| 4 | UDPForwarder | Unit | Phase 3 | All |
| 5 | FramePacketBridge | Unit | Phase 1, 2, 3 | All |
| 6 | FilteredNAT core | Unit | Phase 3, 4, 5 | All |
| 7 | Filtering strategies | Unit | Phase 3, 2 | All |
| 8 | VM Network Manager | Integration | Phase 6, 7 | macOS |
| 9 | VM WireGuard scripts | Integration | None | All |
| 10 | Provider integration | Integration | Phase 8, 9 | macOS |
| 11 | E2E testing | E2E | Phase 10 | macOS |
| **11.5** | **Linux QEMU VM network parity** | Integration | Phase 9 | **Linux only** |
| 12 | Performance optimization | Performance | Phase 11 | All |
| 13 | Hardening | Stress/Security | Phase 12 | All |
| 14 | eBPF kernel filtering | Performance | Phase 6 | **Linux only** |
| 15 | NEFilterPacketProvider | Performance | Phase 6 | **macOS only** |

**Notes:**
- Direct mode (Phase 8) can be tested independently after Phase 9, without phases 1-7.
- **Phase 11.5** brings Linux QEMU VMs to parity with macOS for cloud-init network isolation.
- Phase 14 (eBPF) is optional - provides 10+ Gbps on Linux but requires CAP_BPF.
- Phase 15 (NEFilterPacketProvider) is optional - provides 5-10 Gbps on macOS with standard entitlement (no special approval needed).

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
| `Sources/OmertaNetwork/VPN/FilteringStrategy.swift` | 7 | Full/Conntrack/Sampled strategies |
| `Sources/OmertaNetwork/VPN/VMNetworkManager.swift` | 8 | Unified network mode manager |
| `Resources/cloud-init/wireguard-setup.sh` | 9 | VM WireGuard config |
| `Resources/cloud-init/iptables-setup.sh` | 9 | VM firewall config |
| `Tests/OmertaNetworkTests/EthernetFrameTests.swift` | 1 | Unit tests |
| `Tests/OmertaNetworkTests/IPv4PacketTests.swift` | 2 | Unit tests |
| `Tests/OmertaNetworkTests/EndpointAllowlistTests.swift` | 3 | Unit tests |
| `Tests/OmertaNetworkTests/UDPForwarderTests.swift` | 4 | Unit tests |
| `Tests/OmertaNetworkTests/FramePacketBridgeTests.swift` | 5 | Unit tests |
| `Tests/OmertaNetworkTests/FilteredNATTests.swift` | 6 | Unit tests |
| `Tests/OmertaNetworkTests/FilteringStrategyTests.swift` | 7 | Unit tests |
| `Tests/OmertaNetworkTests/VMNetworkManagerTests.swift` | 8 | Integration tests |
| `Tests/OmertaNetworkTests/E2EConnectivityTests.swift` | 11 | E2E tests |
| `Tests/OmertaVMTests/LinuxVMNetworkTests.swift` | 11.5 | Linux VM network isolation tests |
| `Tests/OmertaNetworkTests/ThroughputBenchmarkTests.swift` | 12 | Performance tests |
| `Tests/OmertaNetworkTests/LatencyBenchmarkTests.swift` | 12 | Performance tests |
| `Sources/OmertaNetwork/VPN/EBPFFilter.swift` | 14 | eBPF Swift wrapper (Linux) |
| `Sources/OmertaNetwork/VPN/ebpf/vm_filter.bpf.c` | 14 | eBPF program source |
| `Sources/CLibbpf/module.modulemap` | 14 | libbpf FFI module |
| `Sources/CLibbpf/shim.h` | 14 | libbpf header shim |
| `Tests/OmertaNetworkTests/EBPFFilterTests.swift` | 14 | eBPF unit tests (Linux) |
| `Sources/OmertaNetwork/VPN/NEPacketFilter.swift` | 15 | NEFilterPacketProvider wrapper (macOS) |
| `Sources/OmertaNetworkExtension/PacketFilterProvider.swift` | 15 | System extension provider |
| `Sources/OmertaNetworkExtension/Info.plist` | 15 | Extension configuration |
| `Tests/OmertaNetworkTests/NEPacketFilterTests.swift` | 15 | Network Extension tests (macOS) |

### Modified Files

| File | Phase | Changes |
|------|-------|---------|
| `Sources/OmertaProvider/ProviderVPNManager.swift` | 10 | Use VMNetworkManager |
| `Sources/OmertaVM/VirtualizationManager.swift` | 10 | Support all network modes |
| `Sources/OmertaVM/SimpleVMManager.swift` | 11.5 | Use VMNetworkConfig in Linux QEMU path |
| `Resources/cloud-init/*` | 9 | WireGuard + iptables setup |

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

#### Filtering Strategies (`FilteringStrategyTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testFullFilterAllowsValidTraffic` | Packet to consumer endpoint | `.forward` |
| `testFullFilterDropsInvalidTraffic` | Packet to random IP | `.drop` |
| `testConntrackFirstPacketChecked` | First packet to endpoint | Allowlist consulted, `.forward` |
| `testConntrackRepeatPacketFastPath` | Second packet to same endpoint | No allowlist check, `.forward` |
| `testConntrackBadFlowTerminates` | Packet to non-allowed endpoint | `.terminate` |
| `testConntrackMultipleFlows` | Traffic to multiple allowed endpoints | All tracked separately |
| `testSampledSkipsMostPackets` | 1000 packets at 1% rate | ~990 not checked |
| `testSampledCatchesViolation` | Bad packet in sample | `.terminate` |
| `testSampledAllowsGoodTraffic` | Good packets sampled | `.forward` |

#### Network Mode Selection (`VMNetworkManagerTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testDirectModeCreatesNATAttachment` | Create with `.direct` | `VZNATNetworkDeviceAttachment` |
| `testFilteredModeCreatesFileHandle` | Create with `.filtered` | `VZFileHandleNetworkDeviceAttachment` |
| `testConntrackModeUsesConntrackStrategy` | Create with `.conntrack` | ConntrackStrategy instance |
| `testSampledModeUsesSampledStrategy` | Create with `.sampled` | SampledStrategy instance |
| `testSamplingRateConfigurable` | Set sampling rate to 5% | Strategy uses 0.05 rate |
| `testCleanupStopsBackgroundTasks` | Stop network handle | Background task cancelled |

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

#### Mode-Specific E2E Tests (`E2EModeTests.swift`)

| Test Case | Mode | Description | Expected Result |
|-----------|------|-------------|-----------------|
| `testDirectModeConnectivity` | direct | Full E2E in direct mode | WireGuard tunnel works |
| `testDirectModePerformance` | direct | Throughput benchmark | ~10 Gbps |
| `testFilteredModeConnectivity` | filtered | Full E2E in filtered mode | WireGuard tunnel works |
| `testFilteredModeBlocking` | filtered | VM tries internet | Blocked |
| `testConntrackModeConnectivity` | conntrack | Full E2E in conntrack mode | WireGuard tunnel works |
| `testConntrackModeTerminatesOnBadFlow` | conntrack | VM tries internet | VM terminated |
| `testSampledModeConnectivity` | sampled | Full E2E in sampled mode | WireGuard tunnel works |
| `testSampledModeEventualDetection` | sampled | Sustained bad traffic | Eventually detected |
| `testModeSwitchingAtRuntime` | all | Change mode while VM running | Not supported (clean restart) |

### Security Tests

#### Isolation Verification by Mode (`SecurityIsolationTests.swift`)

**Filtered Mode (guaranteed isolation):**

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testFilteredVMCannotReachInternet` | VM tries to reach 8.8.8.8 | Packet dropped |
| `testFilteredVMCannotReachProviderLAN` | VM tries 192.168.1.1 | Dropped |
| `testFilteredVMCannotReachProviderHost` | VM tries provider's IP | Dropped |
| `testFilteredVMCannotReachOtherVMs` | VM tries other VM's IP | Dropped |
| `testFilteredVMCannotScanPorts` | Port scan attempt | All packets dropped |
| `testFilteredDNSBlocked` | VM tries DNS lookup (53/udp) | Dropped |

**Conntrack Mode (terminates on violation):**

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testConntrackTerminatesOnInternetAccess` | VM tries 8.8.8.8 | VM terminated |
| `testConntrackTerminatesOnLANAccess` | VM tries 192.168.1.1 | VM terminated |
| `testConntrackAllowsRepeatedGoodTraffic` | Repeated consumer traffic | All forwarded |

**Sampled Mode (probabilistic detection):**

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testSampledEventuallyDetectsAbuse` | 1000 bad packets | Detected within ~100 packets |
| `testSampledMayMissSinglePacket` | Single bad packet | May or may not detect |
| `testSampledHighRateDetectsQuickly` | 10% sample rate | Faster detection |

**Direct Mode (VM-side only):**

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testDirectModeIptablesBlocks` | VM with iptables tries internet | Blocked by VM |
| `testDirectModeBypassable` | VM disables iptables, tries internet | ⚠️ Traffic leaks |
| `testDirectModeLocalhostBlocked` | VM tries provider localhost | Blocked by macOS NAT |

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

#### Dual-Platform Testing

All unit tests for phases 1-7 must pass on both platforms:

| Platform | Test Environment | Notes |
|----------|-----------------|-------|
| **macOS** | `user@mac.local` | Apple Silicon, Virtualization.framework available |
| **Linux** | Local development machine | aarch64, no Virtualization.framework |

**Platform-specific code:**
- Phases 1-7 (parsers, allowlist, forwarder, strategies): Must work on both platforms
- Phase 8+ (VMNetworkManager): macOS only (uses Virtualization.framework)

**Testing procedure for each phase:**
```bash
# On Linux (local)
swift test --filter <TestName>

# On macOS (remote)
ssh user@mac.local "cd /path/to/omerta && swift test --filter <TestName>"
```

**Verification checklist:**
- [x] Phase 1: EthernetFrameTests - Linux ✓ (16 tests) macOS ✓ (16 tests)
- [x] Phase 2: IPv4PacketTests - Linux ✓ (24 tests) macOS ✓ (24 tests)
- [x] Phase 3: EndpointAllowlistTests - Linux ✓ (22 tests) macOS ✓ (22 tests)
- [x] Phase 4: UDPForwarderTests - Linux ✓ (11 tests) macOS ✓ (11 tests)
- [x] Phase 5: FramePacketBridgeTests - Linux ✓ (15 tests) macOS ✓ (15 tests)
- [x] Phase 6: FilteredNATTests - Linux ✓ (12 tests) macOS ✓ (12 tests)
- [x] Phase 7: FilteringStrategyTests - Linux ✓ (16 tests) macOS ✓ (16 tests)

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
