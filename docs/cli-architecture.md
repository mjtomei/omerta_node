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

### Test Pyramid Strategy

Tests are organized in layers, from fastest/simplest to slowest/most comprehensive:

```
                    ┌─────────────┐
                    │   E2E Tests │  Requires: 2 machines, sudo, VMs
                    │  (Manual)   │  Run: Before releases
                    └──────┬──────┘
                   ┌───────┴───────┐
                   │  Integration  │  Requires: Single machine, may need sudo
                   │    Tests      │  Run: CI on both Linux & macOS
                   └───────┬───────┘
              ┌────────────┴────────────┐
              │    Component Tests      │  Requires: No privileges
              │  (In-process mocking)   │  Run: Every commit
              └────────────┬────────────┘
         ┌─────────────────┴─────────────────┐
         │           Unit Tests              │  Requires: Nothing
         │  (Pure functions, serialization)  │  Run: Every commit
         └───────────────────────────────────┘
```

### Level 1: Unit Tests (No privileges, fast)

| Test File | Tests | Description |
|-----------|-------|-------------|
| `CLIIntegrationTests.swift` | ✅ 17 | Config, SSH keys, local key generation |
| `ConsumerProviderHandshakeTests.swift` | ✅ 21 | Message envelope, encryption, serialization |
| `CloudInitTests.swift` | ✅ 28 | Cloud-init file generation |
| `NetworkIsolationTests.swift` | ✅ 7 | VM network config generation |
| `FilteringStrategyTests.swift` | ✅ | Filtering mode selection |
| `EthernetFrameTests.swift` | ✅ | Frame parsing |
| `IPv4PacketTests.swift` | ✅ | Packet parsing |

**Run:** `swift test` (all platforms, no privileges)

### Level 2: Component Tests (No privileges, in-process)

| Test File | Description | What It Validates |
|-----------|-------------|-------------------|
| `UDPControlProtocolTests.swift` | In-process client/server | Message routing, encryption, response matching |
| `VMConfigurationTests.swift` | VM config validation | CPU/memory limits, disk paths, network config |
| `WireGuardConfigTests.swift` | WG config generation | Valid wg-quick format, key formats, peer config |
| `CloudInitISOTests.swift` | ISO generation | Valid ISO9660, correct file structure |

**Run:** `swift test --filter Component` (all platforms, no privileges)

### Level 3: Integration Tests (May need privileges)

#### 3a: Provider-side (needs entitlements on macOS, root on Linux for QEMU)

| Test File | Platform | Description |
|-----------|----------|-------------|
| `ProviderVMBootTests.swift` | macOS | VM boots via Virtualization.framework |
| `ProviderVMBootTests.swift` | Linux | VM boots via QEMU/KVM |
| `CloudInitExecutionTests.swift` | Both | Cloud-init runs, WG interface created |
| `VMNetworkIsolationTests.swift` | Both | iptables rules block non-WG traffic |

**Run:**
- macOS: `swift test --filter ProviderVMBoot` (needs signed binary with entitlements)
- Linux: `sudo swift test --filter ProviderVMBoot` (needs KVM access)

#### 3b: Consumer-side (needs sudo for WireGuard)

| Test File | Platform | Description |
|-----------|----------|-------------|
| `ConsumerWireGuardTests.swift` | Both | WG server starts, peer can be added |
| `EphemeralVPNTests.swift` | Both | VPN lifecycle (create, add peer, cleanup) |

**Run:** `sudo swift test --filter ConsumerWireGuard`

#### 3c: Protocol Tests (no privileges, localhost UDP)

| Test File | Description |
|-----------|-------------|
| `UDPControlServerTests.swift` | Server accepts connections, routes messages |
| `UDPControlClientTests.swift` | Client sends requests, receives responses |
| `ControlProtocolE2ETests.swift` | Full request/response cycle over localhost |

**Run:** `swift test --filter UDPControl`

### Level 4: E2E Tests (Manual, needs 2 machines)

| Test | Setup | Validates |
|------|-------|-----------|
| Local loopback | Single machine, provider + consumer | Protocol works over localhost |
| Cross-machine | 2 machines on same network | Full network path |
| Cross-network | 2 machines on different networks | NAT traversal (if applicable) |

**Scripts:**

```bash
# test-local-loopback.sh (single machine)
#!/bin/bash
set -e

# Start provider (no sudo needed)
omertad start --dry-run &
PROVIDER_PID=$!
sleep 2

# Request VM (consumer dry-run to test protocol)
omerta vm request --provider 127.0.0.1:51820 --dry-run

# Cleanup
kill $PROVIDER_PID
echo "Local loopback test passed!"
```

```bash
# test-provider-vm-boot.sh (tests actual VM boot)
#!/bin/bash
set -e

# macOS: Sign binary first
codesign --force --sign - --entitlements entitlements.plist .build/release/omertad

# Start provider (real mode)
omertad start &
PROVIDER_PID=$!
sleep 2

# Request VM (consumer dry-run, but provider creates real VM)
omerta vm request --provider 127.0.0.1:51820 --dry-run

# Check VM is running
omerta vm list

# Cleanup
omerta vm release --all
kill $PROVIDER_PID
```

```bash
# test-full-e2e.sh (needs 2 machines + sudo)
#!/bin/bash
# Run on consumer machine

PROVIDER_IP=${1:-192.168.1.100}

# This needs sudo for consumer WireGuard
sudo omerta vm request --provider $PROVIDER_IP

# Test SSH through WireGuard tunnel
ssh -o ConnectTimeout=30 omerta@10.0.0.2 "echo 'E2E test passed!'"

# Cleanup
sudo omerta vm release
```

### CI Configuration

```yaml
# .github/workflows/test.yml
jobs:
  unit-tests:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Run unit tests
        run: swift test

  integration-tests-linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run protocol tests
        run: swift test --filter UDPControl
      - name: Run provider VM tests (QEMU)
        run: |
          sudo apt-get install -y qemu-system-x86
          sudo swift test --filter ProviderVMBoot

  integration-tests-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build and sign
        run: |
          swift build -c release
          codesign --force --sign - --entitlements entitlements.plist .build/release/omertad
      - name: Run protocol tests
        run: swift test --filter UDPControl
      - name: Run provider VM tests (Virtualization.framework)
        run: swift test --filter ProviderVMBoot
```

### Test Files to Create

| File | Level | Priority | Description |
|------|-------|----------|-------------|
| `Tests/OmertaProviderTests/UDPControlProtocolTests.swift` | 2 | High | In-process client/server protocol |
| `Tests/OmertaVMTests/VMConfigurationTests.swift` | 2 | High | VM config validation |
| `Tests/OmertaVMTests/ProviderVMBootTests.swift` | 3a | High | Real VM boot (platform-specific) |
| `Tests/OmertaNetworkTests/ControlProtocolE2ETests.swift` | 3c | High | Localhost UDP roundtrip |
| `Tests/OmertaConsumerTests/ConsumerWireGuardTests.swift` | 3b | Medium | WireGuard server lifecycle |

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

### Phase 4.5: Standalone VM Tests

**Goal:** VM boot and connectivity tests that don't require the full consumer setup.

**Motivation:** The full E2E test (Phase 4) requires:
- Consumer WireGuard server running
- VM to establish WireGuard tunnel
- SSH via WireGuard

This makes debugging difficult. Standalone tests isolate each component.

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaCLI/Commands/VMBootTest.swift` | VM boot test command |
| `Tests/OmertaVMTests/StandaloneVMTests.swift` | Standalone VM test suite |

**New CLI Commands:**

```bash
# Test VM boots and TAP connectivity (no WireGuard required)
omerta vm boot-test --provider 127.0.0.1:51820 --timeout 120

# Test VM with direct SSH (bypasses WireGuard firewall for debugging)
omerta vm boot-test --provider 127.0.0.1:51820 --direct-ssh
```

**Test Modes:**

| Mode | What It Tests | Requirements |
|------|---------------|--------------|
| TAP ping | VM boots, gets TAP IP, responds to ping | Provider only (Linux) |
| Direct SSH | VM boots, SSH works over TAP | Provider only (Linux) |
| Console boot | VM boots, hostname visible in console log | Provider only (macOS) |
| Reverse SSH | VM boots, establishes reverse SSH tunnel to host | Provider + SSH server on host (macOS) |
| Full E2E | VM boots, WireGuard connects to consumer | Consumer + Provider |

**Implementation:**

1. **TAP Ping Test**
   - Provider boots VM with TAP networking
   - VM gets IP 192.168.100.2 via cloud-init
   - Host pings 192.168.100.2 via TAP interface
   - No WireGuard or firewall rules needed

2. **Direct SSH Test**
   - Same as TAP ping, but also:
   - Cloud-init allows SSH on TAP interface (no iptables DROP)
   - Host SSHs to 192.168.100.2:22
   - Validates cloud-init user creation, SSH key injection

3. **Console Boot Test (macOS)**
   - Provider boots VM with Virtualization.framework NAT networking
   - VM gets IP via DHCP from macOS (192.168.64.x range)
   - Test monitors VM console output for hostname pattern
   - Validates: VM boots, cloud-init runs, network initializes
   - No SSH required - useful when NAT prevents inbound connections

4. **Reverse SSH Test (macOS)**
   - Same as console boot, but also:
   - Cloud-init installs SSH private key for tunnel
   - VM establishes reverse SSH tunnel to host: `ssh -R 2222:localhost:22 user@192.168.64.1`
   - Host connects through tunnel: `ssh -p 2222 localhost`
   - Validates: VM has outbound connectivity (critical for WireGuard to consumer)
   - Requires SSH server running on macOS host

**Cloud-Init Test Modes:**

```yaml
# Direct SSH mode - no firewall, SSH on TAP interface
test_mode: direct_ssh
network_config:
  ethernets:
    id0:
      match: {driver: "virtio*"}
      addresses: ["192.168.100.2/24"]
      routes: [{to: default, via: "192.168.100.1"}]
```

**Platform Support:**

| Platform | TAP Ping | Direct SSH | Console Boot | Reverse SSH | Full E2E |
|----------|----------|------------|--------------|-------------|----------|
| Linux (QEMU) | ✅ | ✅ | N/A | N/A | ✅ |
| macOS (Virtualization.framework) | N/A* | N/A* | ✅ | ✅ | ✅ |

*macOS uses NAT networking (192.168.64.x) which doesn't allow inbound connections. Use `console-boot` to verify VM boots or `reverse-ssh` to verify SSH via reverse tunnel from VM to host.

**Unit Tests:** `StandaloneVMTests.swift`
- Cloud-init generates correct test mode config
- TAP network config valid
- Direct SSH config disables firewall
- Reverse tunnel cloud-init includes private key and SSH config

**Integration Tests:** `StandaloneVMIntegrationTests.swift`
- VM boots and responds to ping (Linux)
- Direct SSH works without WireGuard (Linux)
- Console boot shows hostname in console log (macOS)
- Reverse SSH tunnel establishes and allows SSH (macOS)

**Dependencies:** Phase 2 (Provider VM Boot)

**Verification:**
```bash
# Linux - direct SSH over TAP
sudo omerta vm boot-test --provider 127.0.0.1:51820 --mode direct-ssh

# macOS - console boot (verify VM boots via console log)
omerta vm boot-test --provider 127.0.0.1:51820 --mode console-boot

# macOS - reverse SSH (verify VM can make outbound connections)
# Requires SSH server running on host: sudo systemsetup -setremotelogin on
omerta vm boot-test --provider 127.0.0.1:51820 --mode reverse-ssh
```

---

### Phase 5: P2P Networking Foundation

**Goal:** Complete peer-to-peer networking stack: identity, discovery, NAT traversal, and relay.

**Motivation:**
- Peers need stable identities (can't use IPs - they change with NAT)
- Need decentralized peer discovery (no single point of failure)
- Need NAT traversal for direct connections (~90% of cases)
- Need relay fallback for symmetric NAT (~10% of cases)

**Sub-phases:**
| Sub-phase | Component | Purpose |
|-----------|-----------|---------|
| 5a | Identity System | Peer IDs from public keys |
| 5b | DHT Peer Discovery | Decentralized peer lookup |
| 5c | Signaling Server | Real-time coordination + STUN + relay |
| 5d | NAT Traversal Client | Hole punching logic |
| 5e | WireGuard Integration | Dynamic endpoint updates |
| 5f | CLI Integration | User-facing commands |

**Architecture Overview:**

```
                              ┌─────────────────────────────────────┐
                              │         DHT Network                 │
                              │   (Peer Discovery & Announcements)  │
                              │                                     │
                              │  Peers announce: peerId + publicKey │
                              │  + capabilities + signaling address │
                              └───────────────┬─────────────────────┘
                                              │
                    ┌─────────────────────────┴─────────────────────────┐
                    │                                                   │
                    ▼                                                   ▼
┌─────────────────────────────────┐                 ┌─────────────────────────────────┐
│           Consumer              │                 │           Provider              │
│  ┌───────────────────────────┐  │                 │  ┌───────────────────────────┐  │
│  │ Identity:                 │  │                 │  │ Identity:                 │  │
│  │   peerId: a1b2c3d4...     │  │                 │  │   peerId: f1e2d3c4...     │  │
│  │   publicKey: [32 bytes]   │  │                 │  │   publicKey: [32 bytes]   │  │
│  └───────────────────────────┘  │                 │  └───────────────────────────┘  │
│                                 │                 │                                 │
│  1. Lookup provider in DHT      │                 │  1. Announce in DHT             │
│  2. Connect to signaling        │                 │  2. Listen for connections      │
│  3. NAT traversal (below)       │                 │  3. NAT traversal (below)       │
└─────────────────────────────────┘                 └─────────────────────────────────┘
                    │                                                   │
                    │         ┌─────────────────────────────┐           │
                    │         │     Signaling Server        │           │
                    └────────►│  (Real-time coordination)   │◄──────────┘
                              │                             │
                              │  - Hole punch timing        │
                              │  - Endpoint exchange        │
                              │  - Connection state         │
                              │                             │
                              │  Also provides:             │
                              │  - STUN (NAT detection)     │
                              │  - Relay (symmetric NAT)    │
                              └──────────────┬──────────────┘
                                             │
              ┌──────────────────────────────┴──────────────────────────┐
              │                                                         │
              ▼                                                         ▼
┌─────────────────────────────────┐                 ┌─────────────────────────────────┐
│    Consumer (behind NAT)        │◄═══════════════►│    Provider VM (behind NAT)     │
│                                 │  Direct WireGuard│                                 │
│    After successful hole punch  │   (hole punched) │    After successful hole punch  │
└─────────────────────────────────┘  or via relay    └─────────────────────────────────┘
```

**Connection Modes:**

Signaling servers and DHT are **optional**. The connection mode depends on network topology:

| Mode | When to Use | DHT | Signaling | Relay |
|------|-------------|-----|-----------|-------|
| Direct | Provider has public IP or same LAN | Optional | No | No |
| DHT + Direct | Provider behind cone NAT, reachable endpoint in DHT | Yes | No | No |
| DHT + Signaling | Both behind NAT, hole punch needed | Yes | Yes | No |
| DHT + Relay | Both symmetric NAT | Yes | Yes | Yes |

**Connection Flow (Direct Mode - no signaling required):**

```
1. IDENTITY: Each peer has identity (generated on init)
   Consumer: peerId = "a1b2c3d4e5f67890"
   Provider: peerId = "f1e2d3c4b5a69078"

2. DISCOVER: Consumer knows provider's address (one of):
   a) Direct IP: omerta vm request --provider 192.168.1.50
   b) Known peer: omerta vm request --provider f1e2d3c4... (from knownPeers cache)
   c) DHT lookup: Provider announced with public endpoint in DHT

3. CONNECT: Consumer connects directly to provider
   Consumer → Provider: [WireGuard handshake to known endpoint]
   (Provider verifies consumer's identity via publicKey)

4. DONE: No signaling or relay needed
```

**Connection Flow (NAT Traversal Mode - signaling required):**

```
1. IDENTITY: Each peer generates identity on first run
   Consumer: peerId = SHA256(publicKey).prefix(8).hex → "a1b2c3d4e5f67890"
   Provider: peerId = SHA256(publicKey).prefix(8).hex → "f1e2d3c4b5a69078"

2. ANNOUNCE: Provider announces availability in DHT
   Provider → DHT: PUT(key=peerId, value={publicKey, capabilities, signalingAddr})
   (signalingAddr only needed if provider is behind NAT)

3. DISCOVER: Consumer looks up provider in DHT
   Consumer → DHT: GET(key="f1e2d3c4b5a69078")
   Consumer ← DHT: {publicKey, capabilities, signalingAddr, directEndpoint?}

4. TRY DIRECT: If directEndpoint present, try direct connection first
   Consumer → Provider: [UDP probe to directEndpoint]
   If response received → skip to step 9 (WIREGUARD)

5. SIGNAL: If direct failed, use signaling server
   Consumer → Signaling: "I'm a1b2c3d4..., want to connect to f1e2d3c4..."
   Provider → Signaling: "I'm f1e2d3c4..., accepting connection from a1b2c3d4..."
   (Both prove identity by signing a challenge with their private key)

6. STUN: Both peers discover their NAT type
   Consumer ←→ STUN: "Your public address is 203.0.113.50:40000, NAT type: cone"
   Provider ←→ STUN: "Your public address is 198.51.100.20:50000, NAT type: symmetric"

7. PUNCH: Signaling server coordinates based on NAT types
   (Asymmetric case: Provider is symmetric, Consumer is cone)
   Signaling → Provider: "Send to 203.0.113.50:40000 NOW"
   Provider → Consumer: [UDP punch packet, creates symmetric mapping Y]
   Provider → Signaling: "My new endpoint is 198.51.100.20:Y"
   Signaling → Consumer: "Provider is at 198.51.100.20:Y"
   Consumer → Provider: [UDP reply to port Y]

8. PROBE: Both sides verify connectivity
   Consumer ←→ Provider: [probe packets, verify RTT < threshold]

9. WIREGUARD: Configure WireGuard with discovered endpoints
   Consumer: Peer f1e2d3c4... Endpoint = 198.51.100.20:Y
   Provider: Peer a1b2c3d4... Endpoint = 203.0.113.50:40000

10. FALLBACK: If both symmetric NAT, use relay
    Signaling → Both: "Use relay at relay.example.com:3479"
    Consumer ←→ Relay ←→ Provider: [WireGuard UDP packets relayed]
```

**CLI Examples:**

```bash
# Direct connection (no DHT/signaling needed)
omerta vm request --provider 192.168.1.50       # By IP address
omerta vm request --provider matt-macbook       # By known peer name

# DHT-based discovery (signaling used if needed)
omerta vm request --provider f1e2d3c4b5a69078   # By peer ID

# Force direct (skip DHT/signaling even if peer ID given)
omerta vm request --provider f1e2d3c4... --direct 192.168.1.50
```

**NAT Type Detection:**

| Test | Result | NAT Type |
|------|--------|----------|
| Same port to different STUN servers | Yes | Cone (Full, Restricted, or Port-Restricted) |
| Same port to different STUN servers | No | Symmetric |
| Accepts unsolicited inbound | Yes | Full Cone |
| Accepts inbound from contacted IP | Yes | Restricted Cone |
| Accepts inbound from contacted IP:port | Yes | Port-Restricted Cone |

**Hole Punch Success Matrix:**

| Consumer NAT | Provider NAT | Direct Connection | Who Initiates |
|--------------|--------------|-------------------|---------------|
| Cone | Cone | ✅ Yes | Either |
| Cone | Symmetric | ✅ Yes | Provider (symmetric side) |
| Symmetric | Cone | ✅ Yes | Consumer (symmetric side) |
| Symmetric | Symmetric | ❌ No - use relay | N/A |

---

#### Phase 5a: Identity System

**Goal:** Cryptographic peer identities with zero-friction setup on Apple platforms and cross-platform portability.

**Design Principles:**
1. **Zero-friction onboarding** - macOS/iOS app users sign in and start immediately
2. **Recovery phrase exists but isn't required upfront** - Available in Settings
3. **BIP-39 compatible** - Same 12 words work as crypto wallet seed
4. **Multiple sync backends** - iCloud Keychain, 1Password, Bitwarden, etc.
5. **Cross-platform transfer** - 6-digit code for quick device-to-device transfer
6. **SSO integration** - Sign in with Apple/Google for account identity

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaCore/Identity/PeerIdentity.swift` | Identity types and verification |
| `Sources/OmertaCore/Identity/IdentityKeypair.swift` | Keypair generation and signing |
| `Sources/OmertaCore/Identity/IdentityStore.swift` | Multi-backend storage |
| `Sources/OmertaCore/Identity/BIP39.swift` | Mnemonic phrase support |
| `Sources/OmertaCore/Identity/KeychainProvider.swift` | Keychain/password manager integration |
| `Sources/OmertaCore/Identity/TransferSession.swift` | Device-to-device transfer |
| `Sources/OmertaCore/Identity/ControlPlaneClient.swift` | Cloud backup/sync |
| `Tests/OmertaCoreTests/IdentityTests.swift` | Identity unit tests |

---

**Architecture:**

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Identity Architecture                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   12-Word Recovery Phrase (BIP-39)                                       │
│   ════════════════════════════════                                       │
│   Source of truth. Always exists. Crypto-wallet compatible.              │
│                                                                          │
│                              │                                           │
│              ┌───────────────┼───────────────┐                           │
│              │               │               │                           │
│              ▼               ▼               ▼                           │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│   │   Automatic  │  │   Automatic  │  │   Transfer   │                  │
│   │    Sync      │  │    Sync      │  │    Code      │                  │
│   │              │  │              │  │              │                  │
│   │ iCloud       │  │ 1Password    │  │ 6-digit PIN  │                  │
│   │ Keychain     │  │ Bitwarden    │  │ (one-time)   │                  │
│   │              │  │ etc.         │  │              │                  │
│   └──────────────┘  └──────────────┘  └──────────────┘                  │
│                                                                          │
│   Apple → Apple     Any → Any          Any → Any                         │
│   (automatic)       (automatic)        (manual, quick)                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

**Core Implementation:**

```swift
import Crypto

/// A peer's cryptographic identity (public info, safe to share)
public struct PeerIdentity: Codable, Hashable {
    /// 16-character hex string derived from public key
    public let peerId: String

    /// Curve25519 public key (32 bytes, base64 encoded)
    public let publicKey: String

    /// Verify that peerId matches publicKey (prevents impersonation)
    public var isValid: Bool {
        guard let keyData = Data(base64Encoded: publicKey) else { return false }
        let hash = SHA256.hash(data: keyData)
        let expected = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return peerId == expected
    }
}

/// Full identity including private key (NEVER shared)
public struct IdentityKeypair: Codable {
    public let identity: PeerIdentity
    public let privateKey: Data  // 32 bytes

    /// BIP-39 entropy if created from mnemonic (enables recovery phrase export)
    public let bip39Entropy: Data?

    /// Generate new random identity with BIP-39 recovery phrase
    public static func generate() -> (keypair: IdentityKeypair, mnemonic: [String]) {
        // Generate 128 bits of entropy (12-word mnemonic)
        let entropy = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let mnemonic = BIP39.mnemonic(from: entropy)
        let keypair = try! derive(from: mnemonic)
        return (keypair, mnemonic)
    }

    /// Derive identity from BIP-39 mnemonic (for recovery or crypto wallet compatibility)
    public static func derive(from mnemonic: [String]) throws -> IdentityKeypair {
        let entropy = try BIP39.entropy(from: mnemonic)
        let seed = BIP39.seed(from: mnemonic)

        // Derive at Omerta's HD path: m/44'/omerta'/0'
        let derivedKey = BIP32.derive(seed: seed, path: "m/44'/0'/0'/0/0")
        let privateKey = Curve25519.Signing.PrivateKey(rawRepresentation: derivedKey)

        let publicKeyData = privateKey.publicKey.rawRepresentation
        let hash = SHA256.hash(data: publicKeyData)
        let peerId = hash.prefix(8).map { String(format: "%02x", $0) }.joined()

        return IdentityKeypair(
            identity: PeerIdentity(
                peerId: peerId,
                publicKey: publicKeyData.base64EncodedString()
            ),
            privateKey: privateKey.rawRepresentation,
            bip39Entropy: entropy
        )
    }

    /// Sign data to prove ownership of this identity
    public func sign(_ data: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return try key.signature(for: data)
    }

    /// Get recovery phrase (only if created from BIP-39)
    public func recoveryPhrase() -> [String]? {
        guard let entropy = bip39Entropy else { return nil }
        return BIP39.mnemonic(from: entropy)
    }
}
```

---

**Multi-Backend Storage:**

```swift
/// Where identity can be stored
public enum KeychainProvider: String, Codable {
    case system              // Local system keychain
    case iCloud              // iCloud Keychain (Apple, auto-sync)
    case onePassword         // 1Password (cross-platform)
    case bitwarden           // Bitwarden (cross-platform)
    case file                // Encrypted file
}

public actor IdentityStore {
    private var provider: KeychainProvider

    /// Initialize with preferred provider
    public init(provider: KeychainProvider = .system) {
        self.provider = provider
    }

    /// Load existing identity from any available source
    public func load() async throws -> IdentityKeypair? {
        // Try providers in order of preference
        for source in [provider, .iCloud, .system, .onePassword, .bitwarden] {
            if let identity = try? await loadFrom(source) {
                return identity
            }
        }
        return nil
    }

    /// Save identity to configured provider
    public func save(_ keypair: IdentityKeypair) async throws {
        switch provider {
        case .iCloud:
            try await saveToKeychain(keypair, synchronizable: true)
        case .system:
            try await saveToKeychain(keypair, synchronizable: false)
        case .onePassword:
            try await saveToOnePassword(keypair)
        case .bitwarden:
            try await saveToBitwarden(keypair)
        case .file:
            throw IdentityError.fileRequiresExplicitPath
        }
    }

    /// Export identity encrypted with password
    public func export(keypair: IdentityKeypair, password: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try Argon2id.deriveKey(password: password, salt: salt)
        let plaintext = try JSONEncoder().encode(keypair)
        let ciphertext = try ChaChaPoly.seal(plaintext, using: key)
        return salt + ciphertext.combined!
    }

    /// Import identity from encrypted file
    public func importFrom(data: Data, password: String) throws -> IdentityKeypair {
        let salt = data.prefix(16)
        let ciphertext = data.dropFirst(16)
        let key = try Argon2id.deriveKey(password: password, salt: Data(salt))
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        let plaintext = try ChaChaPoly.open(box, using: key)
        return try JSONDecoder().decode(IdentityKeypair.self, from: plaintext)
    }

    /// Detect available keychain providers
    public static func availableProviders() -> [KeychainProvider] {
        var available: [KeychainProvider] = [.system, .file]

        #if os(macOS) || os(iOS)
        if FileManager.default.ubiquityIdentityToken != nil {
            available.append(.iCloud)
        }
        #endif

        if shell("which", "op").exitCode == 0 {
            available.append(.onePassword)
        }
        if shell("which", "bw").exitCode == 0 {
            available.append(.bitwarden)
        }

        return available
    }
}
```

---

**SSO + Control Plane Integration:**

```swift
public enum SSOProvider: String, Codable {
    case apple
    case google
    case github
}

public actor ControlPlaneClient {
    let baseURL: URL

    /// Authenticate with SSO provider
    public func authenticate(_ provider: SSOProvider) async throws -> AuthSession {
        // OAuth flow, returns session token
    }

    /// Check if identity exists for this account
    public func hasIdentity(session: AuthSession) async throws -> Bool

    /// Upload encrypted identity for backup/sync
    public func uploadIdentity(
        _ encrypted: Data,
        session: AuthSession
    ) async throws

    /// Download encrypted identity
    public func downloadIdentity(
        session: AuthSession
    ) async throws -> Data?

    /// Create transfer session (new device calls this)
    public func createTransferSession(
        publicKey: Data,
        session: AuthSession
    ) async throws -> TransferSession

    /// Get pending transfer request (existing device calls this)
    public func getPendingTransfer(
        session: AuthSession
    ) async throws -> TransferSession?

    /// Complete transfer (existing device uploads encrypted identity)
    public func completeTransfer(
        sessionId: String,
        encryptedIdentity: Data
    ) async throws
}

public struct TransferSession {
    let id: String
    let code: String           // "847-293" (6 digits, displayed to user)
    let newDevicePublicKey: Data
    let expiresAt: Date        // 5 minutes
}
```

---

**Device Transfer Protocol:**

```swift
public actor DeviceTransfer {

    /// Request transfer on NEW device
    public func requestTransfer(
        session: AuthSession
    ) async throws -> (code: String, waitForIdentity: () async throws -> IdentityKeypair) {
        // Generate ephemeral keypair for this transfer
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        // Create transfer session on control plane
        let transfer = try await controlPlane.createTransferSession(
            publicKey: ephemeral.publicKey.rawRepresentation,
            session: session
        )

        return (
            code: transfer.code,
            waitForIdentity: {
                // Poll for encrypted identity
                while Date() < transfer.expiresAt {
                    if let encrypted = try? await controlPlane.getTransferResult(transfer.id) {
                        // Decrypt with ephemeral private key
                        let shared = try ephemeral.sharedSecretFromKeyAgreement(
                            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: encrypted.senderPublicKey)
                        )
                        let key = shared.hkdfDerivedSymmetricKey(...)
                        return try decrypt(encrypted.ciphertext, with: key)
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                throw TransferError.expired
            }
        )
    }

    /// Approve transfer on EXISTING device
    public func approveTransfer(
        code: String,
        identity: IdentityKeypair,
        session: AuthSession
    ) async throws {
        // Look up transfer session by code
        let transfer = try await controlPlane.getTransferSession(code: code)

        // Encrypt identity to new device's public key
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: transfer.newDevicePublicKey)
        )
        let key = shared.hkdfDerivedSymmetricKey(...)
        let encrypted = try encrypt(identity, with: key)

        // Upload encrypted identity
        try await controlPlane.completeTransfer(
            sessionId: transfer.id,
            encryptedIdentity: EncryptedTransfer(
                senderPublicKey: ephemeral.publicKey.rawRepresentation,
                ciphertext: encrypted
            )
        )
    }
}
```

---

**Platform-Specific Flows:**

**macOS/iOS App (Zero-Friction):**

```
┌─────────────────────────────────────────────────────────────────────────┐
│  First Launch                                                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│                       Welcome to Omerta                                  │
│                                                                          │
│          Share computing resources with your friends                     │
│                                                                          │
│         ┌─────────────────────────────────────┐                          │
│         │       Sign in with Apple            │                          │
│         └─────────────────────────────────────┘                          │
│                                                                          │
│         ┌─────────────────────────────────────┐                          │
│         │       Sign in with Google           │                          │
│         └─────────────────────────────────────┘                          │
│                                                                          │
│                    ─────── or ───────                                    │
│                                                                          │
│         ┌─────────────────────────────────────┐                          │
│         │     I have a recovery phrase        │                          │
│         └─────────────────────────────────────┘                          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

         User clicks "Sign in with Apple"
                        │
                        ▼ (5 seconds later)

┌─────────────────────────────────────────────────────────────────────────┐
│  Ready to Use - No recovery phrase prompt!                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   ✓ You're all set!                                                      │
│                                                                          │
│   Your Peer ID: a1b2c3d4e5f67890                   [Copy]                │
│                                                                          │
│   ────────────────────────────────────────────────────────────────────   │
│                                                                          │
│   Add a peer to get started:                                             │
│   ┌─────────────────────────────────────┐                                │
│   │ Enter peer ID or scan QR...        │  [Add Peer]                     │
│   └─────────────────────────────────────┘                                │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

   Behind the scenes:
   1. Identity generated with BIP-39 entropy
   2. Stored in iCloud Keychain (auto-syncs)
   3. Encrypted backup uploaded to control plane
   4. Recovery phrase available in Settings
```

**App Settings (Recovery Phrase Access):**

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Settings > Identity                                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Your Identity                                                          │
│   ────────────────────────────────────────────────────────────────────   │
│   Peer ID: a1b2c3d4e5f67890                                [Copy]        │
│   Signed in as: matt@icloud.com (Apple)                                  │
│   Synced via: iCloud Keychain ✓                                          │
│                                                                          │
│   ────────────────────────────────────────────────────────────────────   │
│                                                                          │
│   Recovery Options                                                       │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐    │
│   │  📝 View Recovery Phrase                                        │    │
│   │     12 words that restore your identity anywhere.               │    │
│   │     Also works as a cryptocurrency wallet seed.                 │    │
│   └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐    │
│   │  📱 Add Another Device                                          │    │
│   │     Transfer identity to a new device                           │    │
│   └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐    │
│   │  📤 Export to File                                              │    │
│   │     Save encrypted backup                                       │    │
│   └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│   ────────────────────────────────────────────────────────────────────   │
│                                                                          │
│   ⚠️  Your identity syncs via iCloud. If you lose access to your         │
│      Apple ID without a recovery phrase, your identity is lost.          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**Transfer to New Device (No Shared Keychain):**

```
┌─────────────────────────────────────────────────────────────────────────┐
│  New Device (e.g., Linux)                                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Signed in as: matt@gmail.com                                           │
│                                                                          │
│   Found existing identity. How would you like to restore?                │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐    │
│   │  📱 Transfer from another device (recommended)                  │    │
│   │     Quick 6-digit code, no phrase needed                        │    │
│   └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐    │
│   │  📝 Enter recovery phrase                                       │    │
│   │     Use your 12-word backup                                     │    │
│   └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

         User selects "Transfer from another device"
                        │
                        ▼

┌─────────────────────────────────────────────────────────────────────────┐
│  Transfer Code                                                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│              Enter this code on your other device:                       │
│                                                                          │
│                         ┌─────────────┐                                  │
│                         │   847-293   │                                  │
│                         └─────────────┘                                  │
│                                                                          │
│                       Expires in 4:52                                    │
│                                                                          │
│   On your other device, go to:                                           │
│   Settings > Identity > Add Another Device                               │
│                                                                          │
│   Or run: omerta device approve                                          │
│                                                                          │
│                    [Cancel]                                              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

         On existing device: enters 847-293, approves
                        │
                        ▼

┌─────────────────────────────────────────────────────────────────────────┐
│  Transfer Complete                                                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│                         ✓ Identity Restored!                             │
│                                                                          │
│   Peer ID: a1b2c3d4e5f67890                                              │
│                                                                          │
│                       [Get Started]                                      │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

**CLI Flows:**

```bash
# === macOS CLI with Keychain (zero friction) ===
$ omerta init --apple --keychain

# Opens browser for Apple Sign-In...
# ✓ Signed in as matt@icloud.com
# ✓ Identity created: a1b2c3d4e5f67890
# ✓ Stored in iCloud Keychain
#
# Your identity will sync to all your Apple devices.
# View recovery phrase: omerta identity recovery-phrase


# === Linux CLI (must see recovery phrase) ===
$ omerta init --google

# Opens browser for Google Sign-In...
# ✓ Signed in as matt@gmail.com
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║  YOUR RECOVERY PHRASE - WRITE THIS DOWN                           ║
# ╠═══════════════════════════════════════════════════════════════════╣
# ║                                                                   ║
# ║   witch    collapse   practice   feed                             ║
# ║   shame    open       despair    creek                            ║
# ║   road     again      ice        laptop                           ║
# ║                                                                   ║
# ║  This phrase is the ONLY way to recover your identity if you      ║
# ║  lose access to this device. Store it somewhere safe.             ║
# ╚═══════════════════════════════════════════════════════════════════╝
#
# Have you written down your recovery phrase? [yes/no]: yes
# Confirm word #3: practice
# Confirm word #8: creek
#
# ✓ Identity created: a1b2c3d4e5f67890


# === Transfer to new device ===
$ omerta init --google

# ✓ Signed in as matt@gmail.com
# Found existing identity on another device.
#
# Restore options:
#   1. Transfer from another device (quick)
#   2. Enter recovery phrase
# > 1
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║  TRANSFER CODE                                                    ║
# ║                                                                   ║
# ║               Enter on your other device:  847-293                ║
# ║                                                                   ║
# ║               Expires in 4:58                                     ║
# ╚═══════════════════════════════════════════════════════════════════╝
#
# Waiting for approval...
# ✓ Identity transferred!
# Peer ID: a1b2c3d4e5f67890


# === Approve transfer from existing device ===
$ omerta device approve
# Enter transfer code: 847-293
#
# Transfer identity to new device?
# Account: matt@gmail.com
# Code: 847-293
#
# [A]pprove / [D]eny: A
# ✓ Identity transferred to new device


# === View recovery phrase ===
$ omerta identity recovery-phrase
#
# ⚠️  Anyone with this phrase can control your identity.
#
# Your recovery phrase:
#   witch collapse practice feed shame open despair creek road again ice laptop
#
# This phrase also works as a cryptocurrency wallet seed (BIP-39).


# === Export to file ===
$ omerta identity export --output backup.enc
# Enter encryption password: ••••••••••
# Confirm password: ••••••••••
# ✓ Exported to backup.enc


# === Restore from recovery phrase ===
$ omerta init --recover
# Enter your 12-word recovery phrase:
# Word 1: witch
# Word 2: collapse
# ...
# Word 12: laptop
# ✓ Identity restored: a1b2c3d4e5f67890


# === Use with password manager ===
$ omerta init --google --keychain=1password
# ✓ Identity stored in 1Password vault "Personal"
```

---

**Smart Prompts:**

```swift
public actor IdentityReminders {

    /// Check if user should be reminded to backup
    func checkBackupReminder(identity: IdentityKeypair, store: IdentityStore) async {
        let hasViewedRecoveryPhrase = UserDefaults.standard.bool(forKey: "hasViewedRecoveryPhrase")
        let daysSinceSetup = Calendar.current.dateComponents(
            [.day],
            from: identity.createdAt,
            to: Date()
        ).day ?? 0

        // After 3 days, if no backup viewed
        if !hasViewedRecoveryPhrase && daysSinceSetup > 3 {
            await showNotification(
                title: "Back up your identity",
                body: "Save your recovery phrase in case you lose access to iCloud.",
                action: .openSettings
            )
        }
    }

    /// Warn before disabling iCloud without backup
    func beforeDisablingiCloud() async -> Bool {
        let hasViewedRecoveryPhrase = UserDefaults.standard.bool(forKey: "hasViewedRecoveryPhrase")

        if !hasViewedRecoveryPhrase {
            let result = await showAlert(
                title: "Save Recovery Phrase First?",
                message: "If you disable iCloud sync without saving your recovery phrase, " +
                         "you may lose access to your identity on other devices.",
                buttons: ["View Recovery Phrase", "Disable Anyway", "Cancel"]
            )

            switch result {
            case "View Recovery Phrase":
                await showRecoveryPhrase()
                return false  // Don't disable yet
            case "Disable Anyway":
                return true   // Proceed with disable
            default:
                return false  // Cancelled
            }
        }
        return true
    }
}
```

---

**Config File (`~/.omerta/config.json`):**

```json
{
  "identity": {
    "peerId": "a1b2c3d4e5f67890",
    "publicKey": "base64-encoded-public-key",
    "storage": "icloud-keychain",
    "ssoProvider": "apple",
    "ssoAccount": "matt@icloud.com",
    "createdAt": "2024-01-15T10:30:00Z"
  },
  "knownPeers": {
    "f1e2d3c4b5a69078": {
      "name": "matt-linux",
      "publicKey": "base64...",
      "trusted": true,
      "lastSeen": "2024-01-15T14:30:00Z"
    }
  },
  "controlPlane": "https://api.omerta.io"
}
```

Note: Private key is stored in Keychain, NOT in config file.

---

**Security Properties:**

| Storage Method | Auto-Sync | Export | Offline Recovery | Server Sees |
|----------------|-----------|--------|------------------|-------------|
| iCloud Keychain | ✅ Apple | ✅ CLI | ❌ Need phrase | Nothing |
| 1Password/Bitwarden | ✅ Cross-platform | ✅ CLI | ❌ Need phrase | Nothing |
| Recovery Phrase | ❌ Manual | ✅ Is export | ✅ Yes | Nothing |
| Transfer Code | ❌ One-time | N/A | N/A | Encrypted blob |
| Control Plane Backup | ✅ Cross-platform | ✅ CLI | ❌ Need device | Encrypted blob |

**What Control Plane Can See:**
- SSO account identity (email)
- That an identity exists
- Encrypted blobs (cannot decrypt)
- Transfer session metadata

**What Control Plane Cannot See:**
- Private key
- Recovery phrase
- Peer ID
- Any decrypted identity data

---

**Unit Tests:** `IdentityTests.swift`

| Test | Description |
|------|-------------|
| `testIdentityGeneration` | Generate keypair, verify peerId matches publicKey |
| `testBIP39Derivation` | Same mnemonic produces same identity |
| `testBIP39CryptoCompatibility` | Can derive ETH/BTC addresses from same seed |
| `testIdentityValidation` | Valid identity passes, tampered identity fails |
| `testSignatureVerification` | Sign data, verify signature with public key |
| `testSignatureTampering` | Tampered signature fails verification |
| `testKeychainStorage` | Save and load from system keychain |
| `testICloudKeychainSync` | Identity syncs via iCloud (integration) |
| `testOnePasswordStorage` | Save and load via 1Password CLI |
| `testExportImport` | Export encrypted, import with password |
| `testRecoveryPhraseExport` | Can retrieve recovery phrase after creation |
| `testTransferCodeGeneration` | 6-digit code generated correctly |
| `testTransferEncryption` | Identity encrypted to ephemeral key |
| `testTransferExpiry` | Expired transfer sessions rejected |

**Integration Tests:** `IdentityIntegrationTests.swift`

| Test | Description |
|------|-------------|
| `testAppleSignInFlow` | Full Apple Sign-In → identity creation |
| `testGoogleSignInFlow` | Full Google Sign-In → identity creation |
| `testCrossDeviceTransfer` | Transfer identity between two devices |
| `testRecoveryFromPhrase` | Lose device, recover with 12 words |
| `testControlPlaneBackup` | Backup and restore via control plane |
| `testPasswordManagerSync` | Sync via 1Password across platforms |

---

#### Phase 5b: DHT Peer Discovery

**Goal:** Decentralized peer discovery using a Kademlia-style DHT.

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaNetwork/DHT/DHTNode.swift` | DHT node implementation |
| `Sources/OmertaNetwork/DHT/DHTClient.swift` | High-level DHT client |
| `Sources/OmertaNetwork/DHT/DHTTransport.swift` | NIO-based UDP transport |
| `Sources/OmertaNetwork/DHT/KBucket.swift` | Kademlia k-bucket routing |
| `Sources/OmertaNetwork/DHT/DHTMessage.swift` | DHT protocol messages |
| `Sources/OmertaNetwork/DHT/PeerAnnouncement.swift` | Peer announcement format |
| `Tests/OmertaNetworkTests/DHTTests.swift` | DHT unit tests (19 tests) |

**DHT Overview:**

```
DHT Key Space (160-bit, same as peer ID extended with zeros)
├── Each peer has position = SHA256(publicKey).prefix(20)
├── Peers store announcements for keys "close" to their position
├── Lookup: iteratively query peers closer to target key
└── Announce: store at K peers closest to your key

Peer Announcement:
┌─────────────────────────────────────────────────────────┐
│  peerId: "a1b2c3d4e5f67890"                             │
│  publicKey: "base64..."                                 │
│  capabilities: ["provider", "relay"]                    │
│  signalingAddresses: ["wss://signal1.example.com"]      │
│  signature: "base64..." (signs all above fields)        │
│  timestamp: 1705312200                                  │
│  ttl: 3600 (seconds)                                    │
└─────────────────────────────────────────────────────────┘
```

**Implementation:**

```swift
/// DHT node for peer discovery
public actor DHTNode {
    private let identity: IdentityKeypair
    private var routingTable: [KBucket]  // 160 buckets for Kademlia
    private let storage: [Data: PeerAnnouncement]  // Local storage

    public init(identity: IdentityKeypair, bootstrapNodes: [String])

    /// Start the DHT node
    public func start() async throws

    /// Announce this peer's availability
    public func announce(_ announcement: PeerAnnouncement) async throws

    /// Find a peer by their peer ID
    public func findPeer(_ peerId: String) async throws -> PeerAnnouncement?

    /// Find peers offering specific capabilities
    public func findProviders(near peerId: String, count: Int) async throws -> [PeerAnnouncement]
}

/// High-level client for peer discovery
public actor DHTClient {
    private let node: DHTNode
    private let identity: IdentityKeypair

    /// Announce as a provider
    public func announceAsProvider(
        signalingAddress: String,
        capabilities: [String] = ["provider"]
    ) async throws {
        let announcement = PeerAnnouncement(
            peerId: identity.identity.peerId,
            publicKey: identity.identity.publicKey,
            capabilities: capabilities,
            signalingAddresses: [signalingAddress],
            timestamp: Date(),
            ttl: 3600
        )
        let signed = try announcement.signed(with: identity)
        try await node.announce(signed)
    }

    /// Look up a specific peer
    public func lookupPeer(_ peerId: String) async throws -> PeerAnnouncement? {
        guard let announcement = try await node.findPeer(peerId) else {
            return nil
        }
        // Verify signature and peerId matches publicKey
        guard announcement.verify() else {
            throw DHTError.invalidAnnouncement
        }
        return announcement
    }

    /// Find available providers
    public func findProviders(count: Int = 10) async throws -> [PeerAnnouncement]
}

/// Peer announcement stored in DHT
public struct PeerAnnouncement: Codable {
    let peerId: String
    let publicKey: String
    let capabilities: [String]
    let signalingAddresses: [String]
    let timestamp: Date
    let ttl: TimeInterval
    var signature: String?

    /// Sign the announcement with identity
    public mutating func signed(with identity: IdentityKeypair) throws -> PeerAnnouncement {
        var copy = self
        copy.signature = nil
        let data = try JSONEncoder().encode(copy)
        copy.signature = try identity.sign(data).base64EncodedString()
        return copy
    }

    /// Verify signature and peerId matches publicKey
    public func verify() -> Bool {
        // 1. Verify peerId matches publicKey
        let identity = PeerIdentity(peerId: peerId, publicKey: publicKey)
        guard identity.isValid else { return false }

        // 2. Verify signature
        guard let sig = signature,
              let sigData = Data(base64Encoded: sig) else { return false }

        var unsigned = self
        unsigned.signature = nil
        guard let data = try? JSONEncoder().encode(unsigned) else { return false }

        return verifySignature(sigData, for: data, from: identity)
    }
}
```

**DHT Protocol (UDP):**

```swift
enum DHTMessage: Codable {
    /// Ping to check if node is alive
    case ping(fromId: String)
    case pong(fromId: String)

    /// Find nodes close to a key
    case findNode(targetId: String, fromId: String)
    case foundNodes(nodes: [DHTNodeInfo], fromId: String)

    /// Store a value
    case store(key: String, value: PeerAnnouncement, fromId: String)
    case stored(key: String, fromId: String)

    /// Retrieve a value
    case findValue(key: String, fromId: String)
    case foundValue(value: PeerAnnouncement, fromId: String)
    case valueNotFound(closerNodes: [DHTNodeInfo], fromId: String)
}

struct DHTNodeInfo: Codable {
    let peerId: String
    let address: String  // UDP address for DHT
    let port: UInt16
}
```

**Bootstrap:**

```swift
// Well-known bootstrap nodes
let defaultBootstrapNodes = [
    "bootstrap1.omerta.io:4000",
    "bootstrap2.omerta.io:4000"
]

// Or run your own
// omerta dht bootstrap --port 4000
```

**Unit Tests:** `DHTTests.swift`

| Test | Description |
|------|-------------|
| `testDHTNodeStartup` | Node starts and joins network via bootstrap |
| `testPeerAnnouncement` | Announce peer, verify stored in DHT |
| `testPeerLookup` | Look up announced peer by peerId |
| `testAnnouncementSignature` | Signed announcement verifies correctly |
| `testInvalidSignatureRejected` | Tampered announcement rejected |
| `testKBucketRouting` | Routing table correctly organizes peers |
| `testIterativeLookup` | Lookup converges to target peer |
| `testAnnouncementExpiry` | Expired announcements not returned |
| `testMultipleProviders` | Find multiple providers near a key |

**Integration Tests:** `DHTIntegrationTests.swift`

| Test | Description |
|------|-------------|
| `testThreeNodeNetwork` | Three nodes discover each other |
| `testProviderDiscovery` | Consumer finds provider via DHT |
| `testNetworkPartitionRecovery` | Nodes reconnect after partition |
| `testBootstrapFromSingleNode` | New node joins via one bootstrap |

---

#### Phase 5c: Signaling Server

**Goal:** Real-time coordination server for NAT traversal (signaling cannot be done over DHT due to latency).

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaRendezvous/main.swift` | Rendezvous server entry point |
| `Sources/OmertaRendezvous/SignalingServer.swift` | WebSocket signaling |
| `Sources/OmertaRendezvous/STUNServer.swift` | STUN endpoint discovery |
| `Sources/OmertaRendezvous/RelayServer.swift` | UDP relay for symmetric NAT |
| `Sources/OmertaRendezvous/PeerRegistry.swift` | Track connected peers |

**Protocol (WebSocket JSON):**

```swift
// Client → Server
enum ClientMessage: Codable {
    case register(peerId: String, networkId: String)
    case requestConnection(targetPeerId: String, myPublicKey: String)
    case reportEndpoint(endpoint: String, natType: NATType)
    case holePunchReady                     // Ready to receive/send
    case holePunchSent(newEndpoint: String) // Symmetric: report new mapping
    case holePunchResult(targetPeerId: String, success: Bool, actualEndpoint: String?)
    case requestRelay(targetPeerId: String)
}

// Server → Client
enum ServerMessage: Codable {
    case registered(serverTime: Date)
    case peerEndpoint(peerId: String, endpoint: String, natType: NATType, publicKey: String)
    case holePunchStrategy(HolePunchStrategy)  // Which strategy to use
    case holePunchNow(targetEndpoint: String)  // Simultaneous: both send now
    case holePunchInitiate(targetEndpoint: String)  // Asymmetric: you send first
    case holePunchWait                         // Asymmetric: wait for incoming
    case holePunchContinue(newEndpoint: String)  // Asymmetric: now send to this
    case relayAssigned(relayEndpoint: String, relayToken: String)
    case error(message: String)
}

enum HolePunchStrategy: String, Codable {
    case simultaneous      // Both cone: send at same time
    case youInitiate       // You're symmetric, peer is cone: you send first
    case peerInitiates     // You're cone, peer is symmetric: wait then reply
    case relay             // Both symmetric: use relay
}
```

**Connection Flows:**

```
Strategy: simultaneous (both cone NAT)
─────────────────────────────────────────────────────────────────────
Consumer (Cone)              Server                  Provider (Cone)
     │                          │                          │
     │ ← peerEndpoint ──────────│────────── peerEndpoint → │
     │ ← holePunchStrategy ─────│─── holePunchStrategy → │
     │   (simultaneous)         │      (simultaneous)      │
     │ ← holePunchNow ──────────│────────── holePunchNow → │
     │                          │                          │
     │ ═══════════════════ UDP both directions ══════════════════ │
     │                          │                          │
     │  holePunchResult ───────►│◄──────── holePunchResult │
     ▼                          ▼                          ▼


Strategy: peerInitiates (consumer=cone, provider=symmetric)
─────────────────────────────────────────────────────────────────────
Consumer (Cone)              Server               Provider (Symmetric)
     │                          │                          │
     │ ← peerEndpoint ──────────│────────── peerEndpoint → │
     │ ← holePunchStrategy ─────│─── holePunchStrategy → │
     │   (peerInitiates)        │     (youInitiate)        │
     │ ← holePunchWait ─────────│─── holePunchInitiate ──► │
     │                          │     (consumer:51820)     │
     │                          │                          │
     │ ◄═══════════════════════ UDP from provider ═════════│
     │  (opens cone NAT)        │  (creates symmetric      │
     │                          │   mapping: Y)            │
     │                          │                          │
     │                          │◄──── holePunchSent ──────│
     │                          │      (newEndpoint: Y)    │
     │                          │                          │
     │ ← holePunchContinue ─────│                          │
     │   (provider:Y)           │                          │
     │                          │                          │
     │ ════════════════════════ UDP to provider:Y ════════►│
     │                          │                          │
     │  holePunchResult ───────►│◄──────── holePunchResult │
     ▼                          ▼                          ▼


Strategy: relay (both symmetric NAT)
─────────────────────────────────────────────────────────────────────
Consumer (Symmetric)         Server               Provider (Symmetric)
     │                          │                          │
     │ ← holePunchStrategy ─────│─── holePunchStrategy → │
     │   (relay)                │       (relay)            │
     │ ← relayAssigned ─────────│───────── relayAssigned → │
     │   (relay:51821)          │         (relay:51822)    │
     │                          │                          │
     │ ════ UDP to relay:51821 ═│═ relay ═│═ UDP to relay:51822 ═══ │
     │                          │         │                │
     ▼                          ▼         ▼                ▼
```

**STUN Implementation (RFC 5389 subset):**

```swift
public actor STUNServer {
    public init(port: UInt16 = 3478)

    /// Handle STUN binding request, return mapped address
    public func handleBindingRequest(from: SocketAddress, data: Data) async -> Data

    /// Detect NAT type by comparing mappings from multiple server IPs
    public func detectNATType(clientEndpoint: String) async -> NATType
}

public enum NATType: String, Codable {
    case fullCone           // Most permissive
    case restrictedCone     // Allows contacted IPs
    case portRestrictedCone // Allows contacted IP:ports
    case symmetric          // Different port per destination
    case unknown
}
```

**Relay Implementation:**

```swift
public actor RelayServer {
    /// Register a relay session between two peers
    public func createSession(peer1: String, peer2: String) async -> RelaySession

    /// Forward UDP packet between peers
    public func relay(from: String, data: Data) async
}

public struct RelaySession {
    let token: String
    let endpoint: String  // Relay's public endpoint for this session
    let peer1: String
    let peer2: String
    let createdAt: Date
    let expiresAt: Date
}
```

**Deployment:**
- Single binary that runs signaling, STUN, and relay
- Stateless (can run multiple instances behind load balancer)
- Default ports: 443 (WebSocket), 3478 (STUN), 3479 (Relay)

**CLI:**
```bash
# Run rendezvous server
omerta-rendezvous --port 443 --stun-port 3478 --relay-port 3479

# Or use hosted server
export OMERTA_RENDEZVOUS=wss://rendezvous.omerta.io
```

---

#### Phase 5d: NAT Traversal Client

**Goal:** Client library for NAT detection and hole punching.

**New Files:**
| File | Purpose |
|------|---------|
| `Sources/OmertaNetwork/NAT/NATTraversal.swift` | Main NAT traversal coordinator |
| `Sources/OmertaNetwork/NAT/STUNClient.swift` | STUN binding requests |
| `Sources/OmertaNetwork/NAT/HolePuncher.swift` | UDP hole punch coordination |
| `Sources/OmertaNetwork/NAT/RendezvousClient.swift` | WebSocket client for signaling |

**Implementation:**

```swift
public actor NATTraversal {
    public init(rendezvousURL: URL, peerId: String, networkKey: Data)

    /// Connect to rendezvous and discover our public endpoint
    public func start() async throws -> PublicEndpoint

    /// Establish connection to peer (hole punch or relay)
    public func connectToPeer(
        peerId: String,
        peerPublicKey: String
    ) async throws -> PeerConnection

    /// Accept incoming connection request
    public func acceptConnection(
        fromPeerId: String
    ) async throws -> PeerConnection

    /// Current NAT type (discovered via STUN)
    public var natType: NATType { get }

    /// Our public endpoint (may change if NAT rebinds)
    public var publicEndpoint: PublicEndpoint { get }
}

public struct PeerConnection {
    let peerId: String
    let endpoint: String           // Peer's reachable endpoint
    let connectionType: ConnectionType
    let rtt: TimeInterval          // Measured round-trip time
}

public enum ConnectionType {
    case direct          // Hole punch succeeded
    case relayed(via: String)  // Using relay server
}

public struct PublicEndpoint {
    let address: String
    let port: UInt16
    let natType: NATType
}
```

**Hole Punch Sequence:**

```swift
public actor HolePuncher {
    /// Execute hole punch based on strategy from server
    public func execute(
        localPort: UInt16,
        strategy: HolePunchStrategy,
        signaling: RendezvousClient
    ) async throws -> HolePunchResult

    /// Strategy: simultaneous - both send at coordinated time
    func simultaneousPunch(
        localPort: UInt16,
        targetEndpoint: String,
        signal: AsyncStream<Void>  // Server tells both to send
    ) async throws -> HolePunchResult

    /// Strategy: youInitiate - we're symmetric, send first to cone peer
    func initiatePunch(
        localPort: UInt16,
        targetEndpoint: String     // Cone peer's stable endpoint
    ) async throws -> (result: HolePunchResult, newEndpoint: String)

    /// Strategy: peerInitiates - we're cone, wait for symmetric peer
    func waitForPunch(
        localPort: UInt16,
        timeout: Duration
    ) async throws -> (sourceEndpoint: String)  // Peer's new mapping
}

public enum HolePunchResult {
    case success(actualEndpoint: String, rtt: TimeInterval)
    case failed(reason: HolePunchFailure)
}

public enum HolePunchFailure {
    case timeout
    case bothSymmetric  // Need relay
    case firewallBlocked
    case peerUnreachable
}
```

**Strategy Selection (server-side):**

```swift
func selectStrategy(consumer: NATType, provider: NATType) -> (
    consumerStrategy: HolePunchStrategy,
    providerStrategy: HolePunchStrategy
) {
    switch (consumer, provider) {
    case (.symmetric, .symmetric):
        return (.relay, .relay)
    case (.symmetric, _):
        // Consumer symmetric, provider cone: consumer initiates
        return (.youInitiate, .peerInitiates)
    case (_, .symmetric):
        // Provider symmetric, consumer cone: provider initiates
        return (.peerInitiates, .youInitiate)
    default:
        // Both cone: simultaneous works
        return (.simultaneous, .simultaneous)
    }
}
```

---

#### Phase 5e: WireGuard Integration

**Goal:** Dynamically update WireGuard endpoints based on NAT traversal results.

**Modified Files:**
| File | Change |
|------|--------|
| `Sources/OmertaNetwork/VPN/EphemeralVPN.swift` | Use NAT traversal for endpoint discovery |
| `Sources/OmertaConsumer/ConsumerSession.swift` | Coordinate NAT traversal before VM request |
| `Sources/OmertaProvider/ProviderSession.swift` | Accept NAT-traversed connections |

**Flow Integration:**

```
Current Flow (requires public IP):
1. Consumer creates WireGuard server on public IP
2. Consumer tells provider: "Connect to my-public-ip:51820"
3. Provider VM connects to consumer

New Flow (NAT traversal):
1. Consumer connects to rendezvous, discovers public endpoint
2. Consumer tells provider: "My peer ID is X, connect via rendezvous"
3. Provider connects to rendezvous, discovers its public endpoint
4. Rendezvous coordinates hole punch between consumer and provider
5. If hole punch succeeds:
   - Consumer WireGuard listens on hole-punched port
   - Provider VM connects to consumer's discovered endpoint
6. If hole punch fails (symmetric NAT):
   - Both connect to relay
   - WireGuard packets forwarded through relay
```

**Relay Mode WireGuard:**

When relay is needed, WireGuard traffic is encapsulated:

```
Normal: [WireGuard UDP] → Internet → [WireGuard UDP]

Relayed: [WireGuard UDP] → [Relay Header + WG UDP] → Relay → [Relay Header + WG UDP] → [WireGuard UDP]
```

The relay adds minimal overhead (8-byte header: 4-byte session token + 4-byte length).

---

#### Phase 5f: CLI Integration

**Goal:** CLI commands for NAT traversal testing and configuration.

**New Commands:**

```bash
# Test NAT type detection
omerta nat detect
# Output:
# NAT Type: Port-Restricted Cone
# Public Endpoint: 203.0.113.50:42831
# Rendezvous: wss://rendezvous.omerta.io (connected)

# Test hole punch to specific peer
omerta nat punch --peer <peer-id>
# Output:
# Attempting hole punch to peer abc123...
# Peer NAT type: Symmetric
# Our NAT type: Port-Restricted Cone
# Strategy: Symmetric side initiates
# Result: SUCCESS (direct connection)
# RTT: 45ms
# Peer endpoint: 198.51.100.20:51234

# Test relay fallback
omerta nat relay-test --peer <peer-id>
# Output:
# Testing relay connection...
# Relay server: rendezvous.omerta.io:3479
# Result: SUCCESS
# RTT via relay: 120ms (vs 45ms direct)

# Show connection status
omerta nat status
# Output:
# Rendezvous: connected (wss://rendezvous.omerta.io)
# NAT Type: Port-Restricted Cone
# Public Endpoint: 203.0.113.50:42831
# Active Connections:
#   peer-abc: direct (RTT: 45ms)
#   peer-xyz: relayed (RTT: 120ms)
```

**Configuration:**

```json
// ~/.omerta/config.json
{
  "nat": {
    "rendezvousServer": "wss://rendezvous.omerta.io",
    "stunServers": [
      "stun1.omerta.io:3478",
      "stun2.omerta.io:3478"
    ],
    "preferDirect": true,
    "holePunchTimeout": 5000,
    "probeCount": 5
  }
}
```

---

**New Files Summary (Phase 5):**

| File | Sub-Phase | Purpose |
|------|-----------|---------|
| `Sources/OmertaRendezvous/main.swift` | 5a | Server entry point |
| `Sources/OmertaRendezvous/SignalingServer.swift` | 5a | WebSocket signaling |
| `Sources/OmertaRendezvous/STUNServer.swift` | 5a | STUN endpoint discovery |
| `Sources/OmertaRendezvous/RelayServer.swift` | 5a | UDP relay |
| `Sources/OmertaRendezvous/PeerRegistry.swift` | 5a | Peer tracking |
| `Sources/OmertaNetwork/NAT/NATTraversal.swift` | 5b | Client coordinator |
| `Sources/OmertaNetwork/NAT/STUNClient.swift` | 5b | STUN client |
| `Sources/OmertaNetwork/NAT/HolePuncher.swift` | 5b | Hole punch logic |
| `Sources/OmertaNetwork/NAT/RendezvousClient.swift` | 5b | WebSocket client |
| `Tests/OmertaNetworkTests/NATTraversalTests.swift` | 5b | NAT traversal tests |
| `Tests/OmertaRendezvousTests/RendezvousServerTests.swift` | 5a | Server tests |

---

**Unit Tests:** `NATTraversalTests.swift`

| Test | Description |
|------|-------------|
| `testSTUNBindingRequest` | STUN request returns valid mapped address |
| `testNATTypeDetection` | Correctly identifies cone vs symmetric NAT |
| `testStrategySelectionBothCone` | Both cone → simultaneous strategy |
| `testStrategySelectionConeSymmetric` | Cone + symmetric → asymmetric strategy |
| `testStrategySelectionBothSymmetric` | Both symmetric → relay strategy |
| `testSimultaneousPunch` | Both peers send on coordinated signal |
| `testAsymmetricPunchInitiator` | Symmetric peer sends first, reports new endpoint |
| `testAsymmetricPunchWaiter` | Cone peer waits, receives, then replies |
| `testHolePunchSuccess` | Direct connection established after punch |
| `testRelayFallback` | Traffic flows through relay when direct fails |
| `testEndpointUpdate` | WireGuard endpoint updated after successful punch |
| `testRendezvousReconnect` | Client reconnects after server disconnect |
| `testMultiplePeers` | Can maintain connections to multiple peers |

**Integration Tests:** `NATTraversalIntegrationTests.swift`

| Test | Description |
|------|-------------|
| `testE2EConeToConeDirect` | Two cone NAT peers connect directly (simultaneous) |
| `testE2EConeToSymmetricDirect` | Cone + symmetric connect directly (asymmetric punch) |
| `testE2ESymmetricToConeOrder` | Verify symmetric peer initiates, cone waits |
| `testE2ESymmetricToSymmetric` | Two symmetric NAT peers use relay |
| `testE2EWireGuardOverPunchedHole` | Full WireGuard tunnel over hole-punched connection |
| `testE2EWireGuardOverRelay` | Full WireGuard tunnel over relay |
| `testE2EConnectionUpgrade` | Relay connection upgrades to direct when possible |
| `testE2EProviderVMConnection` | Provider VM connects to consumer via NAT traversal |

**Performance Tests:** `NATTraversalPerformanceTests.swift`

| Test | Target |
|------|--------|
| `testHolePunchLatency` | < 500ms from signal to connected |
| `testDirectThroughput` | > 500 Mbps over punched hole |
| `testRelayThroughput` | > 100 Mbps over relay |
| `testRelayLatencyOverhead` | < 50ms additional RTT vs direct |

---

**Dependencies:** Phase 4 (E2E CLI flow)

**Verification:**
```bash
# Run unit tests
swift test --filter NATTraversal

# Test NAT detection (requires internet)
omerta nat detect

# Test hole punch (requires two machines or VMs)
# Machine A:
omerta nat punch --peer <machine-b-peer-id>
# Machine B:
omerta nat punch --peer <machine-a-peer-id>

# Full E2E test
./scripts/test-nat-traversal.sh
```

---

### Phase 6: Consumer VM Image

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
- SSH server running
- Ready to accept WireGuard peer connections
- NAT traversal client configured

**Cloud-init config:**
```yaml
#cloud-config
packages:
  - wireguard-tools
  - openssh-server

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

**Dependencies:** Phase 5

**Verification:**
```bash
swift test --filter ConsumerVM
./scripts/build-consumer-vm.sh
```

---

### Phase 7: Port Forwarding

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

**Dependencies:** Phase 6

**Verification:**
```bash
swift test --filter PortForward
ssh -p 2222 localhost
```

---

### Phase 8: Unified Node

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

**Dependencies:** Phase 7

**Verification:**
```bash
swift test --filter UnifiedNode
```

---

### Phase 9: Menu Bar App

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

**Dependencies:** Phase 8

**Verification:**
```bash
open Omerta.app
# Manual UI testing
```

---

### Phase 10: Key Exchange UX

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

**Dependencies:** Phase 9

**Verification:**
```bash
swift test --filter KeyExchange
# Manual: Scan QR code, click link
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

| Phase | Deliverable | Tests | Dependencies | Platform | Status |
|-------|-------------|-------|--------------|----------|--------|
| 1 | CLI integration | Unit, Integration | VM Network Phases 9-11.5 | All | Done |
| 2 | Provider VM boot | Unit, Integration | Phase 1 | macOS, Linux | Done |
| 3 | Consumer WireGuard server | Unit, Integration | Phase 2 | All (needs sudo) | Done |
| 4 | E2E CLI flow | E2E | Phases 1-3 | All | Done |
| 4.5 | Standalone VM tests | Unit, Integration | Phase 2 | All | Done |
| 5a | Peer identity | Unit | Phase 4 | All | Done |
| 5b | DHT peer discovery | Unit, Integration | Phase 5a | All | Done |
| 5c | Signaling server | Unit | Phase 5b | All | Done |
| 5d | NAT traversal client | Unit | Phase 5c | All | Done |
| 5e | WireGuard integration | Integration | Phase 5d | All | Done |
| 5f | P2P CLI commands | Integration | Phase 5e | All | Done |
| 6 | Consumer VM image | Unit, Integration | Phase 5f | All | |
| 7 | Port forwarding | Unit, Integration | Phase 6 | All | |
| 8 | Unified node | Unit, Integration | Phase 7 | All | |
| 9 | Menu bar app | UI | Phase 8 | **macOS only** | |
| 10 | Key exchange UX | Unit | Phase 9 | **macOS only** | |

**Notes:**
- VM network isolation for Linux is in `vm-network-architecture.md` Phase 11.5
- Phases 1-4 enable full CLI E2E flow on both platforms
- **Phase 4.5** adds standalone VM tests for debugging without consumer
- **Phase 5** is comprehensive P2P networking: identity (5a), DHT discovery (5b), signaling (5c), NAT traversal (5d), WireGuard integration (5e), CLI (5f)
- Phases 6-8 enable "easy mode" with consumer VM
- Phases 9-10 add macOS app UI

---

## Files to Create/Modify

### New Files

| File | Phase | Purpose |
|------|-------|---------|
| `Tests/OmertaCLITests/CLIIntegrationTests.swift` | 1 | CLI integration tests |
| `Tests/OmertaConsumerTests/ConsumerProviderHandshakeTests.swift` | 1 | Handshake tests |
| `Tests/OmertaVMTests/VMBootTests.swift` | 2 | VM boot tests |
| `Tests/OmertaVMTests/VMBootIntegrationTests.swift` | 2 | VM boot integration |
| `Sources/OmertaCLI/Commands/VMBootTest.swift` | 4.5 | VM boot test command |
| `Tests/OmertaVMTests/StandaloneVMTests.swift` | 4.5 | Standalone VM tests |
| `Tests/OmertaConsumerTests/ConsumerWireGuardTests.swift` | 3 | Consumer WG tests |
| `Tests/OmertaNetworkTests/FullE2ETests.swift` | 4 | Full E2E tests |
| `scripts/test-e2e.sh` | 4 | E2E test script |
| `Sources/OmertaCore/Identity/PeerIdentity.swift` | 5a | Identity types |
| `Sources/OmertaCore/Identity/IdentityStore.swift` | 5a | Identity persistence |
| `Tests/OmertaCoreTests/IdentityTests.swift` | 5a | Identity unit tests |
| `Sources/OmertaNetwork/DHT/DHTNode.swift` | 5b | DHT node |
| `Sources/OmertaNetwork/DHT/DHTClient.swift` | 5b | High-level DHT client |
| `Sources/OmertaNetwork/DHT/KBucket.swift` | 5b | Kademlia routing |
| `Sources/OmertaNetwork/DHT/PeerAnnouncement.swift` | 5b | Announcement format |
| `Tests/OmertaNetworkTests/DHTTests.swift` | 5b | DHT unit tests |
| `Sources/OmertaRendezvous/SignalingServer.swift` | 5c | WebSocket signaling |
| `Sources/OmertaRendezvous/STUNServer.swift` | 5c | STUN server |
| `Sources/OmertaRendezvous/RelayServer.swift` | 5c | UDP relay |
| `Sources/OmertaNetwork/NAT/NATTraversal.swift` | 5d | NAT traversal coordinator |
| `Sources/OmertaNetwork/NAT/STUNClient.swift` | 5d | STUN client |
| `Sources/OmertaNetwork/NAT/HolePuncher.swift` | 5d | Hole punch logic |
| `Sources/OmertaNetwork/NAT/RendezvousClient.swift` | 5d | Signaling client |
| `Tests/OmertaNetworkTests/NATTraversalTests.swift` | 5d | NAT traversal tests |
| `scripts/test-nat-traversal.sh` | 5f | NAT traversal E2E tests |
| `Resources/consumer-vm/cloud-init/user-data` | 6 | Consumer VM config |
| `Resources/consumer-vm/cloud-init/meta-data` | 6 | Consumer VM metadata |
| `Sources/OmertaVM/ConsumerVMManager.swift` | 6 | Consumer VM manager |
| `scripts/build-consumer-vm.sh` | 6 | Build consumer VM |
| `Tests/OmertaVMTests/ConsumerVMImageTests.swift` | 6 | Consumer VM tests |
| `Sources/OmertaApp/PortForwarder.swift` | 7 | Port forwarding |
| `Tests/OmertaAppTests/PortForwarderTests.swift` | 7 | Port forward tests |
| `Sources/OmertaApp/UnifiedNode.swift` | 8 | Unified node |
| `Sources/OmertaApp/PeerManager.swift` | 8 | Peer tracking |
| `Tests/OmertaAppTests/UnifiedNodeTests.swift` | 8 | Unified node tests |
| `Sources/OmertaApp/AppDelegate.swift` | 9 | App lifecycle |
| `Sources/OmertaApp/StatusMenuController.swift` | 9 | Menu bar UI |
| `Sources/OmertaApp/Omerta.entitlements` | 9 | Entitlements |
| `Sources/OmertaApp/Info.plist` | 9 | App metadata |
| `Sources/OmertaApp/KeyExchange.swift` | 10 | Key sharing |
| `Sources/OmertaApp/QRCodeGenerator.swift` | 10 | QR generation |
| `Tests/OmertaAppTests/KeyExchangeTests.swift` | 10 | Key exchange tests |

### Modified Files

| File | Phase | Changes |
|------|-------|---------|
| `Sources/OmertaVM/SimpleVMManager.swift` | 1, 2 | Accept consumer endpoint, use Phase 9 cloud-init |
| `Sources/OmertaProvider/UDPControlServer.swift` | 1 | Pass consumer endpoint to VM creation |
| `Sources/OmertaConsumer/ConsumerClient.swift` | 1, 3 | Start WG server before request |
| `Sources/OmertaVM/CloudInitGenerator.swift` | 2 | Ensure WG + iptables work |
| `Sources/OmertaProvider/ProviderVPNManager.swift` | 2 | Generate WG keys for VM |
| `Sources/OmertaNetwork/VPN/EphemeralVPN.swift` | 3 | Simplify to wg-quick only |
| `Package.swift` | 9 | Add OmertaApp target |

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

Phases 1-4 and 4.5 are complete. Remaining work:

1. **Phase 5: P2P Networking Foundation**
   - 5a: Identity system (peer IDs from public keys)
   - 5b: DHT peer discovery (decentralized lookup)
   - 5c: Signaling server (optional, for NAT traversal)
   - 5d: NAT traversal (hole punching)
   - 5e: WireGuard integration
   - 5f: CLI integration
2. **Phase 6: Consumer VM Image** - Pre-built VM for "easy mode"
3. **Phase 7-8**: Port forwarding and Unified node
4. **Phase 9-10**: Menu bar app and Key exchange UX (macOS)
