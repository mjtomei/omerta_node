# Future Enhancements

This document tracks planned improvements and future platform support for Omerta.

**Related Documents:**
- [Architecture Overview](vm-network-architecture.md) - Current VM network design
- [Rogue Detection](rogue-detection.md) - Current detection implementation

## Rogue Detection Improvements

The current RogueConnectionDetector has limited visibility into VM traffic (see [rogue-detection.md](rogue-detection.md#current-status-and-limitations)). These enhancements would improve detection capability.

### Console Output Monitoring

Parse VM console output for iptables block messages:

```bash
# Inside VM: Log all blocked packets
iptables -A OUTPUT -o eth0 -j LOG --log-prefix "ROGUE-ATTEMPT: "
```

```swift
// Host: Monitor console for blocked attempts
func parseConsoleForIPTablesDrops(_ output: String) -> [BlockedAttempt] {
    // Look for "ROGUE-ATTEMPT:" prefix in console output
}
```

**Status:** Partially implemented (VPN verification uses console parsing)

### Host-Level Packet Capture

Use `tcpdump` or BPF on host's NAT interface to monitor VM traffic:

```swift
func captureVMTraffic(vmIP: String) async throws -> [PacketInfo] {
    // tcpdump -i bridge100 host 192.168.64.x
    // Look for non-encrypted (non-WireGuard) traffic
}
```

**Advantages:**
- Can see actual packets from VM's IP
- Detect traffic that bypasses VPN encryption markers

**Considerations:**
- Requires CAP_NET_RAW or root
- Performance overhead for high-throughput scenarios

### Inside-VM Monitoring Agent

Run a monitoring process inside the VM that reports to host:

```bash
# Inside VM: Background monitor
while true; do
    # Check iptables rules haven't changed
    iptables -L OUTPUT | grep "eth0.*DROP" || {
        echo "SECURITY: iptables rules compromised!"
        poweroff -f
    }
    sleep 10
done
```

**Advantages:**
- Most accurate visibility
- Can detect iptables modifications

**Considerations:**
- Adds complexity to VM image
- Workload could potentially kill monitor (if root)

### Periodic iptables Verification

Verify VM firewall rules haven't been modified:

```swift
func verifyVMFirewallIntact(vmConsole: String) -> Bool {
    // Parse console for unexpected iptables modifications
    // Or run periodic verification command in VM
}
```

## Platform Support

### Current: macOS Provider (Virtualization.framework)

Full VM isolation using Apple's Virtualization.framework:
- Hardware-level isolation
- Kernel WireGuard in VM
- iptables firewall
- No root required

### Planned: Linux Provider (QEMU/KVM)

Linux servers as providers using QEMU with KVM acceleration:

| Component | macOS | Linux |
|-----------|-------|-------|
| Hypervisor | Virtualization.framework | QEMU/KVM |
| Network isolation | VZNATNetworkDeviceAttachment | tap + iptables/nftables |
| Packet filtering | FilteredNAT (userspace) | eBPF/TC (kernel) |
| Performance | ~2-10 Gbps | ~10+ Gbps with eBPF |

**Implementation approach:**
- More userspace implementation (no Apple frameworks)
- Native eBPF for kernel-level filtering
- tap interfaces instead of VZ* attachments

**Status:** Phase 11.5 in [implementation plan](vm-network-implementation.md)

### Planned: Windows Provider

Windows machines as providers:

| Component | Approach |
|-----------|----------|
| Hypervisor | Hyper-V or WSL2 |
| Network isolation | Hyper-V virtual switch + Windows Firewall |
| Packet filtering | WFP (Windows Filtering Platform) |

**Considerations:**
- Hyper-V requires Windows Pro/Enterprise
- WSL2 has networking limitations
- WFP for kernel-level filtering

### Planned: Mobile Providers

Mobile devices running interpreted workloads (no full VM):

#### iOS Provider App

| Component | Approach |
|-----------|----------|
| Isolation | App sandbox (no VM) |
| Runtime | JavaScriptCore, WebAssembly, or embedded Python |
| Network | URLSession with strict allowlist |
| Workloads | JavaScript, WASM, Python scripts |

**Architecture:**
```
┌─────────────────────────────────────────┐
│ iOS App (Provider)                      │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ Interpreter Sandbox              │   │
│  │ - JavaScriptCore / Pyodide      │   │
│  │ - No filesystem access          │   │
│  │ - No direct network access      │   │
│  └──────────────┬──────────────────┘   │
│                 │                       │
│                 │ Controlled API        │
│                 ▼                       │
│  ┌─────────────────────────────────┐   │
│  │ Network Proxy Layer              │   │
│  │ - Allowlist: consumer VPN only  │   │
│  │ - All requests go through VPN   │   │
│  └──────────────┬──────────────────┘   │
│                 │                       │
└─────────────────┼───────────────────────┘
                  │ WireGuard tunnel
                  ▼
            [Consumer]
```

**Supported workload types:**
- JavaScript (via JavaScriptCore)
- WebAssembly (via WKWebView or standalone runtime)
- Python (via Pyodide/WebAssembly or PythonKit)
- Limited native code (pre-approved, sandboxed)

**Limitations:**
- No arbitrary binary execution
- Memory/CPU constrained
- Battery considerations
- App Store restrictions on code execution

#### Android Provider App

| Component | Approach |
|-----------|----------|
| Isolation | App sandbox + optional Work Profile |
| Runtime | V8, WebAssembly, Chaquopy (Python) |
| Network | OkHttp with certificate pinning |
| Workloads | JavaScript, WASM, Python scripts |

**Architecture similar to iOS** with platform-specific runtimes.

**Android advantages:**
- More permissive runtime environment
- Termux-style environments possible
- Work Profile for additional isolation

### Workload Type Support by Platform

| Workload Type | macOS VM | Linux VM | Windows VM | iOS App | Android App |
|---------------|----------|----------|------------|---------|-------------|
| Native binaries | Full | Full | Full | Limited | Limited |
| Docker containers | Yes | Yes | Yes (WSL) | No | No |
| Python scripts | Yes | Yes | Yes | WASM/Pyodide | Chaquopy |
| JavaScript | Yes | Yes | Yes | JavaScriptCore | V8 |
| WebAssembly | Yes | Yes | Yes | Yes | Yes |
| ML inference | GPU | GPU | GPU | CoreML | NNAPI |

## Network Improvements

### NEFilterPacketProvider (macOS)

Kernel-assisted packet filtering for 5-10 Gbps on macOS:

```swift
class PacketFilterProvider: NEFilterPacketProvider {
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // Check against allowlist
        if isAllowed(flow) { return .allow() }
        return .drop()
    }
}
```

**Status:** Phase 15 in [implementation plan](vm-network-implementation.md)
**Entitlement:** Standard (no special Apple approval needed)

### eBPF Kernel Filtering (Linux)

Kernel-level filtering for 10+ Gbps on Linux:

```c
SEC("tc")
int filter_vm_egress(struct __sk_buff *skb) {
    // Parse headers, check allowlist map
    if (bpf_map_lookup_elem(&allowlist_map, &key))
        return TC_ACT_OK;
    return TC_ACT_SHOT;
}
```

**Status:** Phase 14 in [implementation plan](vm-network-implementation.md)
**Requirements:** Linux kernel 4.18+, CAP_BPF

### Connection Tracking Optimization

For typical workloads with few unique destinations:

```swift
public actor ConntrackStrategy: FilteringStrategy {
    private var seenFlows: Set<FlowKey> = []

    public func shouldForward(packet: IPv4Packet) async -> FilterDecision {
        let flow = FlowKey(dest: packet.destinationAddress, port: packet.destinationPort)

        // Fast path: already validated
        if seenFlows.contains(flow) {
            return .forward
        }

        // Slow path: check allowlist
        if await allowlist.isAllowed(flow) {
            seenFlows.insert(flow)
            return .forward
        }

        return .terminate(reason: "Connection to non-allowed endpoint")
    }
}
```

**Status:** Implemented in Phase 7

## Security Enhancements

### VM Attestation

Verify VM hasn't been tampered with:

- Boot measurement (TPM-style)
- Runtime integrity checking
- Signed VM images

### Encrypted Job Submission

End-to-end encryption for job payloads:

- Consumer encrypts job with provider's public key
- Provider decrypts only inside VM
- Results encrypted back to consumer

### Reputation System

Track provider reliability:

- Job completion rate
- Performance metrics
- Security incident history

## Performance Enhancements

### Batch Processing

Process multiple packets per syscall:

```swift
func processBatch() async {
    var frames: [Data] = []
    while let frame = try? readFrameNonBlocking() {
        frames.append(frame)
        if frames.count >= 64 { break }
    }
    // Process and send batch
}
```

### Zero-Copy Networking

Reduce memory copies in hot path:

- `AF_XDP` on Linux (kernel 4.18+)
- `Dispatch I/O` on macOS
- Memory-mapped buffers

### GPU Passthrough

For ML workloads:

- macOS: Metal via Virtualization.framework (limited)
- Linux: VFIO GPU passthrough
- Cloud: NVIDIA vGPU

## Implementation Priority

| Enhancement | Priority | Complexity | Impact |
|-------------|----------|------------|--------|
| Console output monitoring | High | Low | Medium |
| Linux provider (QEMU) | High | Medium | High |
| eBPF filtering (Linux) | Medium | Medium | High |
| iOS provider app | Medium | High | High |
| Android provider app | Medium | High | High |
| Windows provider | Low | High | Medium |
| NEFilterPacketProvider | Low | Medium | Medium |
| GPU passthrough | Low | High | Medium |

---

**Note:** This document captures future directions. See [implementation plan](vm-network-implementation.md) for currently in-progress work.
