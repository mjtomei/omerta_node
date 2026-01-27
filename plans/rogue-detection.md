# Rogue Connection Detection

This document describes the RogueConnectionDetector system that monitors for unauthorized network traffic.

**Related Documents:**
- [Architecture Overview](vm-network-architecture.md) - VM isolation design
- [Implementation Details](vm-network-implementation.md) - FilteredNAT and network modes
- [Enhancements](enhancements.md) - Future improvements

## Purpose

The RogueConnectionDetector is a **defense-in-depth** mechanism that watches for any attempt by the VM to bypass the VPN. Even though iptables rules inside the VM should block rogue traffic, we actively monitor to detect and respond immediately.

**Security Model: Default Deny**

There is **no distinction** between "malicious" and "legitimate" non-VPN traffic. ALL workload traffic must go through the VPN:

- Traffic through VPN → Allowed
- Any other traffic → Rogue (terminate VM)

There is no such thing as "legitimate non-VPN traffic" from the workload's perspective.

## How It Works

### Automatic Activation

The detector starts automatically with every VM:

```swift
// VirtualizationManager.swift
let rogueDetectionState = RogueDetectionState()
try await rogueDetector.startMonitoring(
    jobId: job.id,
    vpnConfig: job.vpnConfig
) { [rogueDetectionState] event in
    self.logger.error("ROGUE CONNECTION DETECTED - Terminating VM immediately!")
    rogueDetectionState.detected = true
}
```

### Monitoring Loop

The detector polls every 5 seconds (configurable):

```swift
// RogueConnectionDetector.swift
private func monitorTrafficLoop(...) async {
    while monitors[jobId] != nil {
        let rogueConnections = try await detectRogueConnections(...)

        if !rogueConnections.isEmpty {
            onRogueDetected(event)
            break  // Stop monitoring, VM will be terminated
        }

        try await Task.sleep(for: .seconds(monitoringInterval))
    }
}
```

### Connection Detection

Uses `netstat` to get active network connections:

```swift
private func getCurrentConnections() async throws -> [ActiveConnection] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-n", "-a", "-p", "tcp"]
    // Parse output to get ESTABLISHED connections
}
```

### Route Verification

For each connection, checks if it routes through the VPN interface:

```swift
private func isConnectionThroughVPN(_ connection: ActiveConnection) async throws -> Bool {
    // macOS: /sbin/route get <destination-ip>
    // Linux: /sbin/ip route get <destination-ip>

    // Check if route goes through wg* or utun* interface
    return output.contains("dev wg") || output.contains("interface: utun")
}
```

**Example routing outputs:**

Good (through VPN):
```
10.0.0.5 via 10.99.0.1 dev wg0 src 10.99.0.2
```

Rogue (not through VPN):
```
8.8.8.8 via 192.168.64.1 dev eth0 src 192.168.64.2
```

### VPN Tunnel Health

The detector can also verify VPN health:

```swift
public func checkVPNTunnelHealth(...) async throws -> VPNTunnelHealth {
    // 1. Ping VPN server
    let isReachable = ping(vpnConfig.consumerVPNIP)

    // 2. Check WireGuard interface status
    let hasActiveInterface = wgShow().contains("interface:")

    return VPNTunnelHealth(
        isVPNReachable: isReachable,
        hasActiveInterface: hasActiveInterface
    )
}
```

## What Gets Flagged

### Allowed (Not Rogue)
- Connections to `127.0.0.1` / `::1` (localhost)
- Connections to consumer's VPN IP (the tunnel endpoint itself)
- Any connection that routes through `wg*` or `utun*` interface

### Rogue (Detected and Blocked)
- Direct connection to external IPs via `eth0`
- Connection to provider's local network (192.168.x.x, 10.x.x.x)
- Any external IP not routed through VPN

## Current Status and Limitations

### What the Detector Currently Monitors

The detector runs **on the host machine**, not inside the VM:

| Capability | Status |
|------------|--------|
| VPN tunnel health | Implemented |
| Host's own traffic | Monitored |
| VM-internal connections | **Not visible** |

### Why VM Traffic Is Not Directly Visible

With `VZNATNetworkDeviceAttachment`:
1. VM has its own network stack (separate from host)
2. VM traffic is NAT'd before reaching host network
3. Host's `netstat` shows NAT'd traffic, not VM-internal connections
4. Encrypted VPN traffic appears as single UDP flow

**Visual:**
```
┌─────────────────────────────────────────────────┐
│ Host netstat sees:                              │
│   192.168.1.100:45678 → vpn.example.com:51820   │
│   (Single encrypted tunnel)                     │
│                                                 │
│ Host CANNOT see inside tunnel:                  │
│   - VM's curl to api.example.com                │
│   - VM's connection to database                 │
│   - Any VM-internal traffic                     │
└─────────────────────────────────────────────────┘
```

### The Real Security Enforcement Point

The detector is **secondary defense**. Primary isolation is enforced by:

1. **iptables inside VM** (kernel-level, cannot be bypassed by userspace)
2. **WireGuard routing** (default route through VPN)
3. **Fail-safe termination** (VM shuts down if VPN setup fails)

```
┌─────────────────────────────────────────────────┐
│ Security Layers (effectiveness)                 │
├─────────────────────────────────────────────────┤
│ 1. iptables firewall          ★★★★★            │
│    - Kernel-level enforcement                   │
│    - Cannot be bypassed by userspace            │
│                                                 │
│ 2. WireGuard routing          ★★★★             │
│    - Changes default route                      │
│    - Could be overridden if iptables fails      │
│                                                 │
│ 3. VPN verification           ★★★              │
│    - Checks console for VPN active              │
│    - Prevents VM start if setup fails           │
│                                                 │
│ 4. RogueConnectionDetector    ★★               │
│    - Host-level monitoring                      │
│    - Limited visibility into VM                 │
│    - Best for VPN health checks                 │
└─────────────────────────────────────────────────┘
```

## Attack Scenarios

### Scenario 1: Malicious Workload Tries Direct Internet

**Attack:**
```python
import socket
s = socket.socket()
s.connect(("8.8.8.8", 443))
```

**Defense:**
1. iptables blocks at VM level (packet never leaves VM)
2. If iptables somehow fails, detector sees connection on host
3. VM terminated within 5 seconds

**Result:** Attack fails

### Scenario 2: VPN Tunnel Dies Mid-Job

**Attack:** VPN server crashes, VM tries to fail open

**Defense:**
1. WireGuard tunnel status checked by detector
2. Detector notices VPN server unreachable
3. VM terminated immediately

**Result:** Attack fails

### Scenario 3: Workload Scans Local Network

**Attack:**
```bash
nmap -p 22 192.168.1.0/24
```

**Defense:**
1. iptables blocks 192.168.1.x destinations (not through wg0)
2. Even if packets escape, detector sees them
3. VM terminated

**Result:** Attack fails

### Scenario 4: VPN Misconfiguration

**Attack:** Broken VPN config, VM might have open internet

**Defense:**
1. VPN setup script fails (can't bring up wg0)
2. VM immediately shuts down (fail-safe)
3. Workload never runs

**Result:** Attack fails

## Performance Impact

### Detector Overhead

| Operation | Time |
|-----------|------|
| Run `netstat` | ~5-10ms |
| Parse output | ~1-2ms |
| Run `ip route get` per connection | ~5ms each |
| **Total per check** | ~10-20ms |

**Polling interval:** 5 seconds (configurable)
**CPU impact:** Negligible (<0.01%)

### VPN Overhead

| Metric | Impact |
|--------|--------|
| Latency | +5-10ms per request |
| Bandwidth | ~5-10% overhead |
| CPU | Minimal (WireGuard is efficient) |

## Logging

### Normal Operation

```
2026-01-01 14:26:28 info: Starting rogue connection monitoring [job_id=abc-123]
2026-01-01 14:26:28 info: Monitoring started [job_id=abc-123]
```

### On Rogue Detection

```
2026-01-01 14:26:33 warning: Suspicious non-VPN connection detected
    destination: 8.8.8.8:443
    protocol: tcp
2026-01-01 14:26:33 error: ROGUE CONNECTION DETECTED - Terminating VM immediately!
    job_id: abc-123
```

## Code Reference

**Main implementation:** `Sources/OmertaVM/RogueConnectionDetector.swift`

| Component | Lines | Purpose |
|-----------|-------|---------|
| `startMonitoring()` | 22-50 | Begin monitoring a VM |
| `monitorTrafficLoop()` | 65-108 | Main polling loop |
| `detectRogueConnections()` | 110-151 | Check for non-VPN traffic |
| `getCurrentConnections()` | 153-174 | Run netstat |
| `isConnectionThroughVPN()` | 218-251 | Check routing table |
| `checkVPNTunnelHealth()` | 254-293 | Verify VPN status |

---

**See Also:** [Enhancements](enhancements.md) for planned improvements to rogue detection.
