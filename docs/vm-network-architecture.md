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

**Related Documents:**
- [Implementation Details](vm-network-implementation.md) - Phased implementation plan and code
- [Test Plan](vm-network-tests.md) - Security, performance, and reliability tests
- [Rogue Detection](rogue-detection.md) - Traffic monitoring and violation detection
- [Enhancements](enhancements.md) - Future improvements and platform support

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
    "samplingRate": 0.01,
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

## Summary

### Security Guarantees by Mode

| Guarantee | Direct | Filtered |
|-----------|--------|----------|
| Provider IP hidden | ✅ | ✅ |
| Provider bandwidth protected | ✅ | ✅ |
| Provider LAN isolated | ⚠️ VM-enforced | ✅ Provider-enforced |
| Internet access blocked | ⚠️ VM-enforced | ✅ Provider-enforced |
| Bypass-resistant | ❌ Root can bypass | ✅ Cannot bypass |

### Trust Model

- **Provider trusts**: Virtualization.framework (Apple), iptables (Linux kernel), WireGuard
- **Requester trusts**: Provider won't modify VM or intercept VPN traffic
- **Neither needs to trust**: The workload code itself (isolation handles malicious code)

---

**Next:** See [Implementation Details](vm-network-implementation.md) for the phased implementation plan.
