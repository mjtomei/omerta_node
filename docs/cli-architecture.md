# Omerta CLI Architecture Overview

## Architecture Decisions

| Question | Decision |
|----------|----------|
| P2P discovery? | Yes, but implement later. Direct connection for MVP. |
| Multiple VPN backends? | No. Single backend, prioritize no-sudo where possible. |
| Host-side filtering? | Yes - monitor ALL VMs (provider VMs + consumer VM) uniformly. |
| Use case? | P2P network with minimal friction to join/participate. |
| App model? | **Unified app** - every participant is both provider AND consumer. |

---

## Target Architecture

### Unified P2P Model

Every Omerta participant runs the same app and can:
1. **Provide** VMs to others (provider role)
2. **Consume** VMs from others (consumer role)

The consumer runs inside a VM too, so the host can monitor all VM traffic uniformly.

```
┌─────────────────────────────────────────────────────────────────────┐
│ Omerta.app (macOS) - Unified Provider + Consumer                    │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ Host Process (Virtualization.framework - no sudo)               │ │
│ │ ├─ VM Manager (boots all VMs)                                   │ │
│ │ ├─ UDP Control Server (accepts incoming VM requests)            │ │
│ │ ├─ Host Monitor (optional: PF rules, traffic logging)           │ │
│ │ └─ Port Forwarder (SSH access to consumer VM)                   │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                              │                                      │
│    ┌─────────────────────────┼─────────────────────────┐            │
│    ▼                         ▼                         ▼            │
│ ┌──────────────┐      ┌──────────────┐          ┌──────────────┐    │
│ │ Consumer VM  │      │ Provider VM  │          │ Provider VM  │    │
│ │ (YOUR node)  │      │ (for peer A) │          │ (for peer B) │    │
│ │              │      │              │          │              │    │
│ │ ├─ WG server │      │ ├─ WG client │          │ ├─ WG client │    │
│ │ ├─ Control   │      │ ├─ iptables  │          │ ├─ iptables  │    │
│ │ └─ SSH jump  │      │ └─ SSH       │          │ └─ SSH       │    │
│ └──────────────┘      └──────────────┘          └──────────────┘    │
│        │                     │                         │            │
│        │ WireGuard tunnels (VM-to-VM, never touches host network)   │
│        ▼                     ▼                         ▼            │
└─────────────────────────────────────────────────────────────────────┘
         │
         │ To other peers' provider VMs
         ▼
```

### Why Consumer in a VM?

1. **Uniform monitoring** - Host can monitor/filter all VM traffic the same way
2. **Isolation** - Consumer network activity is isolated from host
3. **No sudo** - WireGuard runs inside VM, no host network changes needed
4. **Symmetry** - Same isolation model whether you're providing or consuming

### User Experience

```
1. User launches Omerta.app

2. App boots Consumer VM automatically
   - Consumer VM has WireGuard server ready
   - SSH accessible via port forward (localhost:2222)

3. App shows status:
   ┌─────────────────────────────────────────┐
   │ Omerta                           [■ ▼]  │
   ├─────────────────────────────────────────┤
   │ Your Node: Ready                        │
   │   SSH: ssh -p 2222 localhost            │
   │                                         │
   │ Providing: 2 VMs running                │
   │   • peer-abc (10.0.1.2) - 2h uptime     │
   │   • peer-xyz (10.0.2.2) - 45m uptime    │
   │                                         │
   │ Consuming: 1 VM                         │
   │   • from 192.168.1.50 (10.0.0.2)        │
   │     ssh -J localhost:2222 10.0.0.2      │
   └─────────────────────────────────────────┘

4. To request a VM from another peer:
   $ ssh -p 2222 localhost
   consumer$ omerta vm request --provider 192.168.1.50

   Or via app UI: Click "Request VM" → Enter peer IP

5. To SSH to remote VM:
   $ ssh -J localhost:2222 10.0.0.2
```

---

## Identity and Security

### omerta init

The `omerta init` command sets up:

1. **SSH Keypair** (Ed25519)
   - Stored at `~/.omerta/ssh/id_ed25519`
   - Used for SSH access to VMs
   - Public key is injected into VMs via cloud-init

2. **Local Encryption Key** (32 bytes)
   - Stored in `~/.omerta/config.json` as `localKey`
   - Used for ChaCha20-Poly1305 encryption of UDP control plane
   - Shared between consumer and provider for direct connections

3. **Network Keys** (for P2P, future)
   - Named networks with their own keys
   - Stored in `networks` config section
   - NetworkId in message envelope lets provider use correct key

### Control Plane Encryption

```
Consumer                                Provider
   │                                       │
   │ ┌─────────────────────────────────┐   │
   │ │ MessageEnvelope:                │   │
   │ │ [1 byte: networkId length]      │   │
   │ │ [N bytes: networkId (UTF-8)]    │──►│ Provider looks up key by networkId
   │ │ [rest: encrypted payload]       │   │
   │ └─────────────────────────────────┘   │
   │                                       │
   │ Payload encrypted with:               │
   │ - ChaCha20-Poly1305                   │
   │ - Network key (or localKey for direct)│
   │                                       │
```

### Key Sharing Model

| Mode | Key Source | How Shared |
|------|------------|------------|
| Direct (MVP) | `localKey` | Manual exchange (copy-paste, QR code, etc.) |
| P2P Network | Network key | Via P2P discovery / network join |

For MVP, two users who want to connect directly:
1. Both run `omerta init`
2. One user shares their `localKey` with the other
3. Other user adds it to their config
4. They can now exchange encrypted VM requests

For future P2P:
1. User joins a network (receives network key)
2. All peers on that network use the same key
3. P2P discovery announces available providers
4. Anyone on the network can request VMs

---

## CLI Tools (Power Users / Development)

For development and power users, CLI tools also available:

**omerta** (consumer CLI)
```bash
omerta init                      # Initialize config, SSH keys, and encryption key
omerta status                    # Show current status
omerta check-deps                # Verify dependencies installed
omerta vm request --provider IP  # Request VM (needs sudo for wg-quick)
omerta vm list                   # List active VMs
omerta vm release                # Release VM
```

**omertad** (provider daemon)
```bash
omertad start    # Start provider daemon
omertad stop     # Stop daemon
omertad status   # Show status
```

These work standalone without the app, but require sudo for WireGuard.

---

## Privilege Model

### Goal: Zero Sudo for App Users

| Component | Needs Sudo? | Notes |
|-----------|-------------|-------|
| **Omerta.app** | No | All VMs via Virtualization.framework |
| **Host monitoring** | Optional | PF rules if desired, VM iptables as default |
| **omerta CLI** | Yes | wg-quick needs root (power users only) |
| **omertad CLI** | No | Virtualization.framework |

### All Network Activity in VMs

```
Host (unprivileged)
├─ Omerta.app process
│  └─ Virtualization.framework (no sudo needed)
│
└─ VMs (all network activity here)
   ├─ Consumer VM: WireGuard server, outbound connections
   └─ Provider VMs: WireGuard clients, isolated workloads
```

The host never creates network interfaces or modifies routing. All WireGuard tunnels exist between VMs.

---

## Network Isolation Model

### VM-to-VM Only

```
Consumer VM (yours)          Provider VM (on peer's machine)
┌─────────────────┐          ┌─────────────────┐
│ WireGuard server│◄────────►│ WireGuard client│
│ 10.0.0.1        │  tunnel  │ 10.0.0.2        │
│                 │          │                 │
│ iptables:       │          │ iptables:       │
│ - Allow WG peer │          │ - Allow WG peer │
│ - DROP else     │          │ - DROP else     │
└─────────────────┘          └─────────────────┘
```

### Host Monitoring (Optional)

The host can optionally monitor/filter VM traffic:

1. **Passive monitoring** - Log traffic for debugging
2. **Active filtering** - Block certain destinations (via VMNetworkManager sampled/conntrack modes)
3. **Rate limiting** - Prevent abuse

This is the same for consumer VM and provider VMs - uniform policy.

---

## Simplified Code Structure

### Current Modules (Keep)

| Module | Purpose | Changes |
|--------|---------|---------|
| OmertaCore | Config, types, crypto | Keep as-is |
| OmertaVM | VM management, cloud-init | Keep SimpleVMManager + CloudInitGenerator |
| OmertaProvider | Provider daemon logic | Simplify, remove unused code |
| OmertaConsumer | Consumer client logic | Simplify to wg-quick for CLI |
| OmertaCLI | CLI binary | Refactor from monolith |
| OmertaDaemon | Provider binary | Keep as-is |

### New Module: OmertaApp

```
OmertaApp/
├─ AppDelegate.swift       # Menu bar app lifecycle
├─ StatusMenuController.swift  # UI for status menu
├─ UnifiedNode.swift       # Combined provider + consumer
├─ ConsumerVM.swift        # Boot/manage consumer VM
├─ PortForwarder.swift     # Forward SSH to consumer VM
└─ PeerManager.swift       # Track active peers (providing/consuming)
```

### Remove/Deprecate

| Code | Reason |
|------|--------|
| MacOSWireGuard | Not needed (WG in VM) |
| LinuxWireGuardNetlink | Not needed (WG in VM) |
| NetworkExtensionVPN | Not needed |
| PeerDiscovery/PeerRegistry | Implement later |
| EphemeralVPN complexity | Simplify to VM-based |

---

## E2E Flow

### App User Flow

```
1. Launch Omerta.app
   - Boots Consumer VM (your node)
   - Starts UDP control server (accept VM requests)
   - Shows "Ready" in menu bar

2. Request VM from peer:
   - Enter peer IP in app (or ssh to consumer VM and run omerta CLI)
   - Consumer VM creates WireGuard server
   - Sends request to peer's control server
   - Peer boots provider VM with WireGuard client
   - Provider VM connects back to your consumer VM

3. SSH to remote VM:
   ssh -J localhost:2222 10.0.0.2

   This goes: Host → Consumer VM (jump) → WireGuard tunnel → Provider VM

4. Peer requests VM from you:
   - Your control server receives request
   - Your app boots provider VM
   - Provider VM connects to peer's consumer VM
   - Peer can SSH to your provider VM
```

### CLI Flow (Power Users)

```
# Terminal 1: Start provider
$ omertad start
Provider listening on :51820

# Terminal 2: Request VM (needs sudo for wg-quick)
$ sudo omerta vm request --provider 192.168.1.100
Creating WireGuard interface...
Requesting VM from 192.168.1.100...
VM ready: ssh omerta@10.0.0.2

$ ssh omerta@10.0.0.2
```

---

## Test Plan

### Unit Tests (Keep/Expand)

| Test | Status | Notes |
|------|--------|-------|
| CloudInitTests | ✅ Working | 28 tests, Phase 9 |
| IPv4PacketTests | ✅ Working | Packet parsing |
| EthernetFrameTests | ✅ Working | Frame parsing |
| ProviderVPNIntegrationTests | ✅ Working | 15 tests, mocked |

### Integration Tests (Add)

| Test | Priority | Description |
|------|----------|-------------|
| ConsumerProviderHandshake | High | Full UDP message exchange |
| VMBootMacOS | High | Virtualization.framework boot with cloud-init |
| VMBootLinux | High | QEMU/KVM boot with cloud-init |
| WireGuardVMConnection | High | VM-to-VM WireGuard tunnel |
| SSHOverWireGuard | High | SSH through WireGuard tunnel |
| ConsumerVMBoot | High | Consumer VM boots and accepts connections |

### E2E Tests (Add)

| Test | Priority | Description |
|------|----------|-------------|
| AppFullFlow | Critical | App boots, request VM, SSH works |
| CLIFullFlow | Critical | omerta + omertad CLI flow |
| BidirectionalPeering | High | Both peers provide VMs to each other |
| MultipleVMs | Medium | Multiple provider VMs simultaneously |
| VMCleanup | Medium | VM release cleans up properly |
| HostMonitoring | Medium | Host can see/filter VM traffic |

### Manual Test Script

```bash
#!/bin/bash
# test-e2e.sh

# Machine A (192.168.1.100):
omertad start

# Machine B:
ssh -p 2222 localhost  # Into consumer VM
omerta vm request --provider 192.168.1.100
ssh omerta@10.0.0.2 "echo 'E2E test passed'"
```

---

## Implementation Phases

### Phase 1: CLI Integration

**Goal:** Wire up existing components so CLI E2E flow works.

**Files to Modify:**
| File | Changes |
|------|---------|
| `Sources/OmertaVM/SimpleVMManager.swift` | Accept consumer endpoint, use Phase 9 cloud-init |
| `Sources/OmertaProvider/UDPControlServer.swift` | Pass consumer endpoint to VM creation |
| `Sources/OmertaConsumer/ConsumerClient.swift` | Ensure WireGuard server starts before request |

**Deliverable:** Working CLI flow:
```bash
# Machine A (provider):
omerta init
omertad start

# Machine B (consumer):
omerta init
# Share localKey with provider
omerta vm request --provider 192.168.1.100
ssh omerta@10.0.0.2
```

**Unit Tests:** `CLIIntegrationTests.swift`
- Config initialization creates valid config
- SSH key generation works
- Local key is valid 32-byte hex

**Integration Tests:** `ConsumerProviderHandshakeTests.swift`
- UDP message encryption/decryption works
- VM request message format correct
- VM response contains all required fields

**Dependencies:** VM Network Architecture Phases 9-10 (cloud-init integration)

**Verification:**
```bash
swift test --filter CLIIntegration
swift test --filter ConsumerProviderHandshake
```

---

### Phase 2: Provider VM Boot

**Goal:** Provider can boot VMs with WireGuard + SSH configured via cloud-init.

**Files to Modify:**
| File | Changes |
|------|---------|
| `Sources/OmertaVM/SimpleVMManager.swift` | Use VMNetworkConfig for cloud-init |
| `Sources/OmertaVM/CloudInitGenerator.swift` | Ensure WireGuard + iptables scripts work |
| `Sources/OmertaProvider/ProviderVPNManager.swift` | Generate WireGuard keys for VM |

**Deliverable:** VM boots and:
- WireGuard interface comes up automatically
- Connects to consumer's WireGuard server
- SSH accessible over WireGuard tunnel
- iptables blocks non-WireGuard traffic

**Unit Tests:** `VMBootTests.swift`
- Cloud-init ISO generated correctly
- WireGuard config valid format
- iptables rules valid format

**Integration Tests:** `VMBootIntegrationTests.swift`
- VM boots on macOS (Virtualization.framework)
- VM boots on Linux (QEMU/KVM)
- Cloud-init runs successfully
- WireGuard interface created

**Dependencies:** Phase 1

**Verification:**
```bash
swift test --filter VMBoot
# Manual: Boot VM and verify wg show works
```

---

### Phase 3: Consumer WireGuard Server

**Goal:** Consumer creates WireGuard server that VMs connect to.

**Files to Modify:**
| File | Changes |
|------|---------|
| `Sources/OmertaConsumer/ConsumerClient.swift` | Create WG server before request |
| `Sources/OmertaNetwork/VPN/EphemeralVPN.swift` | Simplify to wg-quick only |

**Deliverable:** Consumer can:
- Generate WireGuard keypair
- Create wg-quick config file
- Start WireGuard interface (sudo wg-quick up)
- Add VM as peer when it connects
- Clean up interface on release

**Unit Tests:** `ConsumerWireGuardTests.swift`
- WireGuard config generation valid
- Key pair generation works
- Peer config format correct

**Integration Tests:** `ConsumerWireGuardIntegrationTests.swift`
- wg-quick up creates interface
- Interface has correct IP
- Peer can be added dynamically
- wg-quick down cleans up

**Dependencies:** Phase 2

**Verification:**
```bash
swift test --filter ConsumerWireGuard
# Manual: sudo wg-quick up and verify wg show
```

---

### Phase 4: E2E CLI Flow

**Goal:** Full CLI flow works end-to-end.

**Files:** No new files - integration of Phases 1-3

**Deliverable:** Complete flow:
```
Consumer                          Provider
   │                                 │
   │ omerta init                     │ omerta init
   │ (generates keys)                │ (generates keys)
   │                                 │
   │                                 │ omertad start
   │                                 │ (listening)
   │                                 │
   │ omerta vm request ────────────► │
   │ (starts WG server)              │ (boots VM with cloud-init)
   │                                 │
   │ ◄─────────────────────────────  │ (VM connects to consumer WG)
   │ (adds VM as peer)               │
   │                                 │
   │ ssh omerta@10.0.0.2 ──────────► │ (through WG tunnel)
   │                                 │
```

**E2E Tests:** `FullE2ETests.swift`
- Consumer requests VM, gets SSH access
- SSH commands work over WireGuard
- VM release cleans up properly
- Multiple VMs work simultaneously

**Test Script:** `scripts/test-e2e.sh`
```bash
#!/bin/bash
set -e

# Start provider in background
omertad start &
PROVIDER_PID=$!
sleep 2

# Request VM
omerta vm request --provider localhost --timeout 60

# Test SSH
ssh -o StrictHostKeyChecking=no omerta@10.0.0.2 "echo 'E2E test passed'"

# Cleanup
omerta vm release --all
kill $PROVIDER_PID
```

**Dependencies:** Phases 1-3

**Verification:**
```bash
./scripts/test-e2e.sh
```

---

### Phase 5: Consumer VM Image

**Goal:** Pre-built VM image with consumer tools for "easy mode".

**New Files:**
| File | Purpose |
|------|---------|
| `Resources/consumer-vm/cloud-init/user-data` | Consumer VM configuration |
| `Resources/consumer-vm/cloud-init/meta-data` | VM metadata |
| `Sources/OmertaVM/ConsumerVMManager.swift` | Boot/manage consumer VM |
| `scripts/build-consumer-vm.sh` | Build consumer VM image |

**Deliverable:** Consumer VM image that includes:
- WireGuard tools installed
- omerta CLI installed
- SSH server running
- Ready to accept WireGuard peer connections

**Cloud-init config:**
```yaml
#cloud-config
packages:
  - wireguard-tools
  - openssh-server

write_files:
  - path: /usr/local/bin/omerta
    permissions: '0755'
    content: |
      # omerta CLI binary (embedded or downloaded)

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
```

**Unit Tests:** `ConsumerVMImageTests.swift`
- Cloud-init config valid YAML
- Required packages listed
- SSH configured correctly

**Integration Tests:** `ConsumerVMBootTests.swift`
- Consumer VM boots successfully
- SSH accessible on port 22
- WireGuard tools available
- omerta CLI works

**Dependencies:** Phase 4

**Verification:**
```bash
swift test --filter ConsumerVM
./scripts/build-consumer-vm.sh
```

---

### Phase 6: Port Forwarding

**Goal:** Forward SSH from host to consumer VM.

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaApp/PortForwarder.swift` | TCP port forwarding |

**Deliverable:** Host can forward ports to consumer VM:
```
localhost:2222 → Consumer VM:22
```

User can then:
```bash
ssh -p 2222 localhost              # Gets to consumer VM
ssh -J localhost:2222 10.0.0.2     # Jumps to provider VM
```

**Implementation:**
```swift
public actor PortForwarder {
    public init(localPort: UInt16, vmIP: String, vmPort: UInt16)
    public func start() async throws
    public func stop() async
}
```

**Unit Tests:** `PortForwarderTests.swift`
- TCP connection forwarded correctly
- Multiple connections handled
- Clean shutdown

**Integration Tests:** `PortForwardingIntegrationTests.swift`
- SSH through forwarded port works
- Jump host (-J) works
- Connection survives VM operations

**Dependencies:** Phase 5

**Verification:**
```bash
swift test --filter PortForward
ssh -p 2222 localhost
```

---

### Phase 7: Unified Node

**Goal:** Single process manages both provider and consumer roles.

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaApp/UnifiedNode.swift` | Combined provider + consumer |
| `Sources/OmertaApp/PeerManager.swift` | Track peers (providing to / consuming from) |

**Deliverable:** `UnifiedNode` that:
- Boots consumer VM on start
- Listens for incoming VM requests (provider role)
- Can request VMs from other peers (via consumer VM)
- Tracks all active peer connections

**Implementation:**
```swift
public actor UnifiedNode {
    public init(config: OmertaConfig)

    // Lifecycle
    public func start() async throws
    public func stop() async

    // Provider role
    public var providingVMs: [VMInfo] { get }

    // Consumer role (runs in consumer VM)
    public func requestVM(from peer: String) async throws -> VMInfo
    public var consumingVMs: [VMInfo] { get }
}
```

**Unit Tests:** `UnifiedNodeTests.swift`
- Node starts and stops cleanly
- Consumer VM boots on start
- Provider accepts connections

**Integration Tests:** `UnifiedNodeIntegrationTests.swift`
- Full bidirectional flow (A provides to B, B provides to A)
- Multiple VMs in both directions
- Clean shutdown of all VMs

**Dependencies:** Phase 6

**Verification:**
```bash
swift test --filter UnifiedNode
```

---

### Phase 8: Menu Bar App

**Goal:** macOS menu bar app wrapping UnifiedNode.

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaApp/AppDelegate.swift` | App lifecycle |
| `Sources/OmertaApp/StatusMenuController.swift` | Menu bar UI |
| `Sources/OmertaApp/Omerta.entitlements` | App entitlements |
| `Sources/OmertaApp/Info.plist` | App metadata |

**Deliverable:** macOS app that:
- Lives in menu bar
- Shows status (Ready / X VMs providing / Y VMs consuming)
- Allows requesting VMs via UI
- Shows SSH commands for each VM
- Starts on login (optional)

**UI Mockup:**
```
┌─────────────────────────────────────────┐
│ Omerta                           [■ ▼]  │
├─────────────────────────────────────────┤
│ Your Node: Ready                        │
│   SSH: ssh -p 2222 localhost            │
│                                         │
│ Providing: 2 VMs                        │
│   • peer-abc (10.0.1.2)  [Copy SSH]     │
│   • peer-xyz (10.0.2.2)  [Copy SSH]     │
│                                         │
│ Consuming: 1 VM                         │
│   • from 192.168.1.50    [Copy SSH]     │
│     ssh -J localhost:2222 10.0.0.2      │
├─────────────────────────────────────────┤
│ [Request VM...]  [Settings]  [Quit]     │
└─────────────────────────────────────────┘
```

**Tests:** Manual UI testing + `OmertaAppUITests.swift`
- App launches without crashing
- Menu shows correct status
- Request VM dialog works
- SSH commands copyable

**Dependencies:** Phase 7

**Verification:**
```bash
open Omerta.app
# Manual UI testing
```

---

### Phase 9: Key Exchange UX

**Goal:** Easy way to share localKey between peers.

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaApp/KeyExchange.swift` | Key sharing utilities |
| `Sources/OmertaApp/QRCodeGenerator.swift` | Generate QR codes |

**Deliverable:** Multiple key sharing methods:
1. **Copy/Paste** - Copy key as hex string
2. **QR Code** - Display QR code for mobile scanning
3. **Link** - `omerta://connect?key=...&host=...`
4. **File** - Export/import key file

**Implementation:**
```swift
public struct KeyExchange {
    public static func generateQRCode(for config: PeerConfig) -> NSImage
    public static func generateLink(for config: PeerConfig) -> URL
    public static func parseLink(_ url: URL) -> PeerConfig?
    public static func exportToFile(_ config: PeerConfig, path: URL) throws
    public static func importFromFile(_ path: URL) throws -> PeerConfig
}

public struct PeerConfig: Codable {
    public let localKey: String
    public let host: String
    public let port: UInt16
}
```

**Unit Tests:** `KeyExchangeTests.swift`
- QR code generates valid image
- Link format correct
- Link parsing works
- File export/import round-trips

**Dependencies:** Phase 8

**Verification:**
```bash
swift test --filter KeyExchange
# Manual: Scan QR code, click link
```

---

### Phase 10: P2P Discovery (Future)

**Goal:** Automatic peer discovery without manual key exchange.

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaNetwork/Discovery/DHTClient.swift` | DHT client |
| `Sources/OmertaNetwork/Discovery/PeerAnnouncer.swift` | Announce availability |
| `Sources/OmertaNetwork/Discovery/PeerFinder.swift` | Find available peers |

**Deliverable:** P2P network where:
- Providers announce their availability
- Consumers discover available providers
- Network key shared via network join
- No manual IP/key exchange needed

**Unit Tests:** `DHTTests.swift`
- DHT put/get works
- Peer announcement format correct
- Peer discovery finds announced peers

**Integration Tests:** `P2PDiscoveryIntegrationTests.swift`
- Multiple nodes discover each other
- Provider announcement propagates
- Consumer finds available providers

**Dependencies:** Phase 9

**Verification:**
```bash
swift test --filter DHT
swift test --filter P2PDiscovery
```

---

## Cross-Platform Support

Both **provider** and **consumer** are designed to work on macOS and Linux.

| Role | macOS | Linux | Notes |
|------|-------|-------|-------|
| **Provider** | Virtualization.framework | QEMU/KVM | Both boot VMs with cloud-init |
| **Consumer** | wg-quick (sudo) | wg-quick (sudo) | Same WireGuard setup |
| **App** | Menu bar app | CLI only | macOS app in Phases 8-9 |

### VM Network Isolation

VM network isolation (WireGuard + iptables via cloud-init) is documented in `docs/vm-network-architecture.md`:

- **Phase 9**: Cloud-init WireGuard + firewall setup (works on both platforms)
- **Phase 10**: Provider integration (macOS Virtualization.framework)
- **Phase 11.5**: Linux QEMU VM network parity (brings Linux to same level)

See `vm-network-architecture.md` for detailed implementation of VM-side isolation.

---

## Phase Summary

| Phase | Deliverable | Tests | Dependencies | Platform |
|-------|-------------|-------|--------------|----------|
| 1 | CLI integration | Unit, Integration | VM Network Phases 9-11.5 | All |
| 2 | Provider VM boot | Unit, Integration | Phase 1 | macOS, Linux |
| 3 | Consumer WireGuard server | Unit, Integration | Phase 2 | All (needs sudo) |
| 4 | E2E CLI flow | E2E | Phases 1-3 | All |
| 5 | Consumer VM image | Unit, Integration | Phase 4 | All |
| 6 | Port forwarding | Unit, Integration | Phase 5 | All |
| 7 | Unified node | Unit, Integration | Phase 6 | All |
| 8 | Menu bar app | UI | Phase 7 | **macOS only** |
| 9 | Key exchange UX | Unit | Phase 8 | **macOS only** |
| 10 | P2P discovery | Unit, Integration | Phase 9 | All |

**Notes:**
- VM network isolation for Linux is in `vm-network-architecture.md` Phase 11.5
- Phases 1-4 enable full CLI E2E flow on both platforms
- Phases 5-7 enable "easy mode" with consumer VM
- Phases 8-9 add macOS app UI
- Phase 10 adds automatic peer discovery (future)

---

## Files to Create/Modify

### New Files

| File | Phase | Purpose |
|------|-------|---------|
| `Tests/OmertaCLITests/CLIIntegrationTests.swift` | 1 | CLI integration tests |
| `Tests/OmertaConsumerTests/ConsumerProviderHandshakeTests.swift` | 1 | Handshake tests |
| `Tests/OmertaVMTests/VMBootTests.swift` | 2 | VM boot tests |
| `Tests/OmertaVMTests/VMBootIntegrationTests.swift` | 2 | VM boot integration |
| `Tests/OmertaConsumerTests/ConsumerWireGuardTests.swift` | 3 | Consumer WG tests |
| `Tests/OmertaNetworkTests/FullE2ETests.swift` | 4 | Full E2E tests |
| `scripts/test-e2e.sh` | 4 | E2E test script |
| `Resources/consumer-vm/cloud-init/user-data` | 5 | Consumer VM config |
| `Resources/consumer-vm/cloud-init/meta-data` | 5 | Consumer VM metadata |
| `Sources/OmertaVM/ConsumerVMManager.swift` | 5 | Consumer VM manager |
| `scripts/build-consumer-vm.sh` | 5 | Build consumer VM |
| `Tests/OmertaVMTests/ConsumerVMImageTests.swift` | 5 | Consumer VM tests |
| `Sources/OmertaApp/PortForwarder.swift` | 6 | Port forwarding |
| `Tests/OmertaAppTests/PortForwarderTests.swift` | 6 | Port forward tests |
| `Sources/OmertaApp/UnifiedNode.swift` | 7 | Unified node |
| `Sources/OmertaApp/PeerManager.swift` | 7 | Peer tracking |
| `Tests/OmertaAppTests/UnifiedNodeTests.swift` | 7 | Unified node tests |
| `Sources/OmertaApp/AppDelegate.swift` | 8 | App lifecycle |
| `Sources/OmertaApp/StatusMenuController.swift` | 8 | Menu bar UI |
| `Sources/OmertaApp/Omerta.entitlements` | 8 | Entitlements |
| `Sources/OmertaApp/Info.plist` | 8 | App metadata |
| `Sources/OmertaApp/KeyExchange.swift` | 9 | Key sharing |
| `Sources/OmertaApp/QRCodeGenerator.swift` | 9 | QR generation |
| `Tests/OmertaAppTests/KeyExchangeTests.swift` | 9 | Key exchange tests |
| `Sources/OmertaNetwork/Discovery/DHTClient.swift` | 10 | DHT client |
| `Sources/OmertaNetwork/Discovery/PeerAnnouncer.swift` | 10 | Peer announcer |
| `Sources/OmertaNetwork/Discovery/PeerFinder.swift` | 10 | Peer finder |
| `Tests/OmertaNetworkTests/DHTTests.swift` | 10 | DHT tests |
| `Tests/OmertaNetworkTests/P2PDiscoveryIntegrationTests.swift` | 10 | P2P tests |

### Modified Files

| File | Phase | Changes |
|------|-------|---------|
| `Sources/OmertaVM/SimpleVMManager.swift` | 1, 2 | Accept consumer endpoint, use Phase 9 cloud-init |
| `Sources/OmertaProvider/UDPControlServer.swift` | 1 | Pass consumer endpoint to VM creation |
| `Sources/OmertaConsumer/ConsumerClient.swift` | 1, 3 | Start WG server before request |
| `Sources/OmertaVM/CloudInitGenerator.swift` | 2 | Ensure WG + iptables work |
| `Sources/OmertaProvider/ProviderVPNManager.swift` | 2 | Generate WG keys for VM |
| `Sources/OmertaNetwork/VPN/EphemeralVPN.swift` | 3 | Simplify to wg-quick only |
| `Package.swift` | 8 | Add OmertaApp target |

---

## Detailed Test Plan

### Unit Tests

#### CLI Integration (`CLIIntegrationTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testInitCreatesConfig` | Run omerta init | Config file created at ~/.omerta/config.json |
| `testInitCreatesSSHKey` | Run omerta init | SSH key at ~/.omerta/ssh/id_ed25519 |
| `testInitGeneratesLocalKey` | Run omerta init | localKey is 64-char hex string |
| `testInitIdempotent` | Run omerta init twice | Second run succeeds, warns about existing |
| `testInitForceOverwrites` | Run omerta init --force | Overwrites existing config |
| `testConfigLoadAfterInit` | Load config after init | All fields populated correctly |

#### Consumer WireGuard (`ConsumerWireGuardTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testKeyPairGeneration` | Generate WG keypair | Valid base64 public and private keys |
| `testServerConfigGeneration` | Generate server config | Valid wg-quick format |
| `testPeerConfigFormat` | Generate peer config | Contains PublicKey, AllowedIPs, Endpoint |
| `testConfigFileWritable` | Write config to temp file | File created with correct content |
| `testMultiplePeersConfig` | Config with multiple peers | All peers in config |

#### Cloud-Init (`CloudInitTests.swift` - existing, expand)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testWireGuardClientConfig` | Generate WG client config | Valid wg-quick format for client |
| `testIptablesRules` | Generate iptables rules | DROP default, allow WG + SSH |
| `testPackageInstallation` | Generate package install | wireguard-tools in packages |
| `testSSHAuthorizedKeys` | Include SSH key | authorized_keys has correct key |
| `testFullUserData` | Generate complete user-data | Valid YAML, all sections present |

#### Port Forwarding (`PortForwarderTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testTCPForward` | Forward localhost:2222 → VM:22 | Connection forwarded |
| `testMultipleConnections` | Multiple SSH sessions | All connections work |
| `testConnectionClose` | Close one connection | Other connections unaffected |
| `testForwarderStop` | Stop forwarder | All connections closed gracefully |
| `testReconnect` | Connect after disconnect | New connection works |

#### Key Exchange (`KeyExchangeTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testQRCodeGeneration` | Generate QR code | Valid NSImage, scannable |
| `testLinkGeneration` | Generate omerta:// link | Valid URL with key and host |
| `testLinkParsing` | Parse omerta:// link | Extracts key, host, port |
| `testFileExport` | Export config to file | JSON file with all fields |
| `testFileImport` | Import config from file | PeerConfig matches exported |
| `testFileRoundTrip` | Export then import | Identical config |

### Integration Tests

#### Consumer-Provider Handshake (`ConsumerProviderHandshakeTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testMessageEncryption` | Encrypt control message | Decryptable with same key |
| `testMessageDecryption` | Decrypt control message | Original message recovered |
| `testEnvelopeFormat` | Create message envelope | NetworkId prefix, encrypted payload |
| `testEnvelopeParsing` | Parse message envelope | NetworkId and payload extracted |
| `testVMRequestFormat` | Create VM request | All required fields present |
| `testVMResponseFormat` | Parse VM response | Contains vmId, vmIP, vmPublicKey |
| `testWrongKeyFails` | Decrypt with wrong key | Throws decryption error |

#### VM Boot (`VMBootIntegrationTests.swift`)

**Note:** Linux VM network isolation tests are in `vm-network-architecture.md` Phase 11.5.

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMBootMacOS` | Boot VM on macOS | VM runs, responds to ping |
| `testVMBootLinux` | Boot VM on Linux (QEMU) | VM runs, responds to ping |
| `testCloudInitRuns` | Boot with cloud-init | User created, packages installed |
| `testWireGuardInterface` | Boot with WG config | wg0 interface exists |
| `testIptablesApplied` | Boot with iptables | Rules visible in iptables -L |
| `testSSHAccessible` | Boot with SSH key | SSH login works |

#### Unified Node (`UnifiedNodeIntegrationTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testNodeStartStop` | Start and stop node | Clean startup and shutdown |
| `testConsumerVMBoots` | Node starts | Consumer VM running |
| `testProviderAccepts` | Remote VM request | VM booted for requester |
| `testBidirectional` | Both nodes provide/consume | VMs in both directions |
| `testMultipleVMs` | Request multiple VMs | All VMs accessible |
| `testCleanShutdown` | Stop with active VMs | All VMs terminated |

### E2E Tests

#### Full E2E Flow (`FullE2ETests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testCLIE2E` | omerta init → omertad → vm request → ssh | SSH command works |
| `testSSHCommand` | SSH to provider VM | Shell prompt, commands work |
| `testFileTransfer` | SCP file to/from VM | File transferred correctly |
| `testVMRelease` | Release VM | VM terminated, WG peer removed |
| `testMultipleVMsE2E` | Request 2 VMs | Both accessible via different IPs |
| `testReconnect` | Disconnect and reconnect | Connection restored |
| `testProviderRestart` | Restart omertad | Existing VMs preserved (or clean shutdown) |

#### App E2E (`AppE2ETests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testAppLaunch` | Launch Omerta.app | Menu bar icon appears |
| `testConsumerVMReady` | App running | ssh -p 2222 localhost works |
| `testRequestVMViaApp` | Use app UI to request VM | VM accessible |
| `testCopySSHCommand` | Click copy SSH | Correct command in clipboard |
| `testAppQuit` | Quit app | Consumer VM stopped, cleanup |

---

## Codebase Size

### Current

| Module | Lines |
|--------|-------|
| OmertaCLI | 2,583 |
| OmertaDaemon | 297 |
| OmertaNetwork | 8,008 |
| OmertaProvider | 3,261 |
| OmertaVM | 2,609 |
| OmertaConsumer | 1,713 |
| OmertaCore | 1,439 |
| **Total** | ~21,000 |

### Target After Simplification

| Module | Estimated |
|--------|-----------|
| OmertaCore | ~1,400 |
| OmertaVM | ~2,500 |
| OmertaProvider | ~1,000 |
| OmertaConsumer | ~500 |
| OmertaNetwork | ~1,500 |
| OmertaCLI | ~400 |
| OmertaDaemon | ~300 |
| OmertaApp | ~1,500 |
| **Total** | ~9,100 |

---

## Security Checklist

- [ ] UDP control messages encrypted with ChaCha20-Poly1305
- [ ] WireGuard keys generated securely (32 random bytes)
- [ ] SSH keys generated with ed25519
- [ ] VM iptables blocks non-WireGuard traffic
- [ ] Provider host filtering (optional) limits VM network access
- [ ] localKey stored securely (file permissions 600)
- [ ] No secrets in logs
- [ ] VM cannot access provider host
- [ ] VM cannot access provider LAN
- [ ] Consumer cannot access provider LAN

---

## Next Steps

1. **Phase 1: CLI Integration** - Wire existing components together
2. **Phase 2: Provider VM Boot** - Verify VM boots with WireGuard
3. **Phase 3: Consumer WireGuard** - Consumer creates WG server
4. **Phase 4: E2E CLI Flow** - Test full flow works
5. **Phase 5+**: Consumer VM, App, P2P discovery
