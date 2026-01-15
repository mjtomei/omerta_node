# OmertaMesh Integration Plan

This document plans the integration of `OmertaMesh` into the existing CLI binaries (`omerta`, `omertad`) and outlines required test updates and E2E infrastructure changes.

## Overview

The `OmertaMesh` module implements a complete decentralized P2P overlay network that replaces the original Phase 5 P2P Networking Foundation from [cli-architecture.md](cli-architecture.md). OmertaMesh provides:

- NAT detection via STUN
- Bootstrap and peer discovery via gossip
- Relay infrastructure for NAT-bound peers
- Freshness queries for stale connection recovery
- Hole punching for direct connections through NAT
- Clean public API (`MeshNetwork`, `MeshConfig`, `DirectConnection`)

**Current State:**
- All 8 OmertaMesh phases are implemented and tested (see [mesh-relay-network.md](mesh-relay-network.md))
- `omerta-mesh` CLI works as a standalone mesh node
- E2E test infrastructure exists in `scripts/e2e-mesh-test/`

**Remaining Work:**
- Integrate OmertaMesh into `OmertaCLI` and `OmertaDaemon`
- Update existing tests to use mesh networking
- Extend E2E test infrastructure for full VM provisioning over mesh

---

## Architecture: Old vs New

### Old Architecture (OmertaNetwork)

```
┌─────────────┐         Direct IP:Port          ┌─────────────┐
│  Consumer   │◄───────────────────────────────►│  Provider   │
│ (omerta)    │     UDPControlClient/Server     │ (omertad)   │
└─────────────┘                                 └─────────────┘
      │                                               │
      │ Requires: Known IP, no NAT, or manual        │
      │ port forwarding                               │
      ▼                                               ▼
┌─────────────┐                                 ┌─────────────┐
│ EphemeralVPN│                                 │ SimpleVM    │
│ (WireGuard) │                                 │ Manager     │
└─────────────┘                                 └─────────────┘
```

### New Architecture (OmertaMesh)

```
┌─────────────┐                                 ┌─────────────┐
│  Consumer   │         Mesh Network            │  Provider   │
│ (omerta)    │◄═══════════════════════════════►│ (omertad)   │
└──────┬──────┘    (relay, hole punch, or       └──────┬──────┘
       │            direct based on NAT)               │
       ▼                                               ▼
┌─────────────┐                                 ┌─────────────┐
│ MeshNetwork │◄────────────────────────────────│ MeshNetwork │
│   Actor     │   discover, connect, send       │   Actor     │
└──────┬──────┘                                 └──────┬──────┘
       │                                               │
       │  DirectConnection.endpoint                    │
       ▼                                               ▼
┌─────────────┐         WireGuard Tunnel        ┌─────────────┐
│ EphemeralVPN│◄───────────────────────────────►│ Provider VM │
└─────────────┘                                 └─────────────┘
```

---

## Integration Phases

### Phase M1: Add OmertaMesh Dependency to Binaries

**Goal:** Wire OmertaMesh into the module dependency graph.

**Package.swift Changes:**

```swift
// OmertaConsumer - add OmertaMesh dependency
.target(
    name: "OmertaConsumer",
    dependencies: [
        "OmertaCore",
        "OmertaNetwork",
        "OmertaMesh",  // NEW
        // ...
    ]
)

// OmertaProvider - add OmertaMesh dependency
.target(
    name: "OmertaProvider",
    dependencies: [
        "OmertaCore",
        "OmertaVM",
        "OmertaNetwork",
        "OmertaMesh",  // NEW
        // ...
    ]
)
```

**Deliverable:** Code compiles with new dependencies.

---

### Phase M2: MeshNetwork Integration in OmertaConsumer

**Goal:** ConsumerClient can discover and connect to providers via mesh.

**Files to Create/Modify:**

| File | Changes |
|------|---------|
| `Sources/OmertaConsumer/MeshConsumerClient.swift` | New: Mesh-aware consumer client |
| `Sources/OmertaConsumer/ConsumerClient.swift` | Add mesh transport option |
| `Sources/OmertaCore/Config/OmertaConfig.swift` | Add mesh config (bootstrap peers, etc.) |

**New MeshConsumerClient API:**

```swift
public actor MeshConsumerClient {
    private let mesh: MeshNetwork
    private let controlClient: UDPControlClient

    public init(config: OmertaConfig) async throws {
        // Create mesh network with config
        var meshConfig = MeshConfig.default
        meshConfig.bootstrapPeers = config.mesh?.bootstrapPeers ?? []

        let peerId = config.localPeerId ?? UUID().uuidString
        self.mesh = MeshNetwork(peerId: peerId, config: meshConfig)
        self.controlClient = UDPControlClient(encryptionKey: config.localKeyData()!)
    }

    /// Start the mesh network
    public func start() async throws {
        try await mesh.start()
    }

    /// Request VM from a provider by peer ID (mesh handles NAT traversal)
    public func requestVM(
        providerPeerId: String,
        resources: ResourceRequest
    ) async throws -> VMSession {
        // 1. Connect to provider via mesh (handles NAT)
        let connection = try await mesh.connect(to: providerPeerId)

        // 2. Send control message over mesh
        let request = VMRequest(resources: resources, ...)
        let requestData = try JSONEncoder().encode(request)
        let responseData = try await mesh.sendAndReceive(
            data: requestData,
            to: providerPeerId,
            timeout: 30
        )
        let response = try JSONDecoder().decode(VMResponse.self, from: responseData)

        // 3. Use DirectConnection.endpoint for WireGuard peer config
        return VMSession(
            vmId: response.vmId,
            wireGuardEndpoint: connection.endpoint,
            wireGuardPeerPublicKey: response.wireGuardPublicKey,
            sshAddress: response.sshAddress
        )
    }

    /// Request VM from a provider by direct IP (legacy mode)
    public func requestVMDirect(
        providerAddress: String,
        resources: ResourceRequest
    ) async throws -> VMSession {
        // Existing UDPControlClient flow
        return try await controlClient.requestVM(...)
    }
}
```

**OmertaConfig Additions:**

```swift
public struct MeshConfigOptions: Codable, Sendable {
    public var enabled: Bool = false
    public var bootstrapPeers: [String] = []
    public var relayMode: Bool = false
    public var stunServers: [String] = [
        "stun1.omerta.io:3478",
        "stun2.omerta.io:3478"
    ]
}

public struct OmertaConfig: Codable, Sendable {
    // Existing fields...
    public var mesh: MeshConfigOptions?  // NEW
}
```

**Deliverable:** Consumer can request VMs using peer ID instead of IP address.

---

### Phase M3: MeshNetwork Integration in OmertaProvider

**Goal:** ProviderDaemon joins mesh network and accepts requests via relay/hole punch.

**Files to Create/Modify:**

| File | Changes |
|------|---------|
| `Sources/OmertaProvider/MeshProviderDaemon.swift` | New: Mesh-aware provider daemon |
| `Sources/OmertaProvider/ProviderDaemon.swift` | Add mesh mode option |

**New MeshProviderDaemon:**

```swift
public actor MeshProviderDaemon {
    private let mesh: MeshNetwork
    private let vmManager: SimpleVMManager
    private let config: Configuration

    public struct Configuration {
        public var peerId: String
        public var meshConfig: MeshConfig
        public var vmConfig: VMConfiguration
        public var networkKeys: [String: Data]
    }

    public init(config: Configuration) {
        var meshConfig = config.meshConfig
        meshConfig.canRelay = true  // Providers can relay
        meshConfig.canCoordinateHolePunch = true

        self.mesh = MeshNetwork(peerId: config.peerId, config: meshConfig)
        self.vmManager = SimpleVMManager()
        self.config = config
    }

    public func start() async throws {
        // Set up message handler for VM requests
        await mesh.setMessageHandler { [self] fromPeerId, data in
            return await handleMessage(from: fromPeerId, data: data)
        }

        // Start mesh network
        try await mesh.start()

        // Announce as provider
        // (MeshNetwork handles this via gossip)
    }

    private func handleMessage(from peerId: String, data: Data) async -> Data? {
        // Decrypt and process VM request
        // Similar to existing UDPControlServer logic
        guard let request = try? JSONDecoder().decode(VMRequest.self, from: data) else {
            return nil
        }

        // Get connection info for WireGuard endpoint
        let connection = await mesh.connection(to: peerId)
        let consumerEndpoint = connection?.endpoint ?? ""

        // Create VM with WireGuard configured to connect to consumer
        let vm = try? await vmManager.createVM(
            request: request,
            consumerEndpoint: consumerEndpoint
        )

        let response = VMResponse(vmId: vm?.id, ...)
        return try? JSONEncoder().encode(response)
    }
}
```

**Deliverable:** Provider can receive VM requests from NAT-bound consumers.

---

### Phase M4: CLI Integration

**Goal:** `omerta` and `omertad` CLIs support mesh networking.

**OmertaCLI Changes:**

| Command | Current | New |
|---------|---------|-----|
| `omerta vm request --provider IP:PORT` | Direct UDP | Keep for legacy |
| `omerta vm request --peer PEER_ID` | N/A | NEW: Via mesh |
| `omerta mesh status` | N/A | NEW: Show mesh network status |
| `omerta mesh peers` | N/A | NEW: List discovered peers |

**New CLI Commands:**

```swift
// In OmertaCLI/main.swift

struct MeshCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "mesh",
        abstract: "Mesh network operations",
        subcommands: [
            MeshStatus.self,
            MeshPeers.self,
            MeshConnect.self
        ]
    )
}

struct MeshStatus: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Show mesh network status"
    )

    mutating func run() async throws {
        let client = try await MeshConsumerClient(config: loadConfig())
        try await client.start()

        let stats = await client.mesh.statistics()
        print("NAT Type: \(stats.natType.rawValue)")
        print("Public Endpoint: \(stats.publicEndpoint ?? "none")")
        print("Known Peers: \(stats.peerCount)")
        print("Direct Connections: \(stats.directConnectionCount)")
        print("Relay Connections: \(stats.relayCount)")
    }
}

struct MeshPeers: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "List discovered peers"
    )

    mutating func run() async throws {
        let client = try await MeshConsumerClient(config: loadConfig())
        try await client.start()

        // Wait for discovery
        try await Task.sleep(for: .seconds(5))

        let peers = await client.mesh.knownPeers()
        for peerId in peers {
            let connection = await client.mesh.connection(to: peerId)
            let status = connection != nil ? "connected" : "discovered"
            print("\(peerId.prefix(16))... [\(status)]")
        }
    }
}
```

**VM Request with Peer ID:**

```swift
struct VMRequest: AsyncParsableCommand {
    // Existing options...

    @Option(name: .long, help: "Provider peer ID (mesh mode)")
    var peer: String?

    @Option(name: .long, help: "Provider IP:port (direct mode)")
    var provider: String?

    mutating func run() async throws {
        if let peerId = peer {
            // Mesh mode
            let client = try await MeshConsumerClient(config: loadConfig())
            try await client.start()
            let session = try await client.requestVM(providerPeerId: peerId, ...)
            print("VM ready: \(session.sshAddress)")
        } else if let address = provider {
            // Legacy direct mode
            // Existing implementation
        } else {
            print("Error: Specify --peer or --provider")
        }
    }
}
```

**OmertaDaemon Changes:**

```swift
struct Start: AsyncParsableCommand {
    // Existing options...

    @Flag(name: .long, help: "Enable mesh networking")
    var mesh: Bool = false

    @Option(name: .long, help: "Mesh peer ID")
    var meshPeerId: String?

    @Option(name: .long, help: "Bootstrap peers (comma-separated)")
    var bootstrapPeers: String?

    mutating func run() async throws {
        if mesh {
            // Start mesh-aware provider
            let config = MeshProviderDaemon.Configuration(
                peerId: meshPeerId ?? UUID().uuidString,
                meshConfig: MeshConfig(
                    bootstrapPeers: bootstrapPeers?.split(separator: ",").map(String.init) ?? []
                ),
                // ...
            )
            let daemon = MeshProviderDaemon(config: config)
            try await daemon.start()
        } else {
            // Existing direct UDP provider
            let daemon = ProviderDaemon(config: config)
            try await daemon.start()
        }
    }
}
```

**Deliverable:** Full CLI support for mesh networking alongside legacy direct mode.

---

## Test Updates

### Unit Tests to Update

| Test File | Changes |
|-----------|---------|
| `Tests/OmertaConsumerTests/ConsumerClientTests.swift` | Add tests for MeshConsumerClient |
| `Tests/OmertaProviderTests/ProviderDaemonTests.swift` | Add tests for MeshProviderDaemon |
| `Tests/OmertaCoreTests/ConfigTests.swift` | Add tests for MeshConfig serialization |

### New Unit Tests to Create

| Test File | Description |
|-----------|-------------|
| `Tests/OmertaConsumerTests/MeshConsumerClientTests.swift` | Test mesh client initialization, peer discovery, VM request |
| `Tests/OmertaProviderTests/MeshProviderDaemonTests.swift` | Test mesh provider message handling, VM creation |
| `Tests/OmertaIntegrationTests/MeshVMProvisioningTests.swift` | Test full VM provisioning over mesh |

**Example Test:**

```swift
// Tests/OmertaConsumerTests/MeshConsumerClientTests.swift

final class MeshConsumerClientTests: XCTestCase {

    func testMeshClientStartsAndDetectsNAT() async throws {
        var config = OmertaConfig.default
        config.mesh = MeshConfigOptions(enabled: true)

        let client = try await MeshConsumerClient(config: config)
        try await client.start()

        let stats = await client.mesh.statistics()
        XCTAssertNotEqual(stats.natType, .unknown)
    }

    func testMeshClientDiscoversBootstrapPeers() async throws {
        // Start a test relay node
        let relay = MeshNetwork.createRelay(peerId: "test-relay", port: 9000)
        try await relay.start()
        defer { Task { await relay.stop() } }

        // Configure client with bootstrap
        var config = OmertaConfig.default
        config.mesh = MeshConfigOptions(
            enabled: true,
            bootstrapPeers: ["test-relay@localhost:9000"]
        )

        let client = try await MeshConsumerClient(config: config)
        try await client.start()

        // Wait for discovery
        try await Task.sleep(for: .seconds(2))

        let peers = await client.mesh.knownPeers()
        XCTAssertTrue(peers.contains("test-relay"))
    }
}
```

### Integration Tests to Update

| Test File | Changes |
|-----------|---------|
| `Tests/OmertaProviderTests/ConsumerProviderHandshakeTests.swift` | Add mesh handshake tests |
| `Tests/OmertaVMTests/VMBootIntegrationTests.swift` | Add mesh-based VM boot tests |

### New Integration Tests to Create

| Test File | Description |
|-----------|-------------|
| `Tests/OmertaIntegrationTests/MeshNATTraversalTests.swift` | Test VM provisioning through simulated NAT |
| `Tests/OmertaIntegrationTests/MeshRelayFallbackTests.swift` | Test relay fallback when hole punch fails |

---

## E2E Test Infrastructure Changes

### Current E2E Infrastructure

```
scripts/e2e-mesh-test/
├── run-mesh-test.sh          # Basic mesh node test
├── run-nat-test.sh           # NAT traversal test
├── nat-simulation.sh         # iptables NAT rules
├── run-in-vm.sh              # Run tests in VM
├── run-isolated-test.sh      # Isolated network namespace test
└── nested-vm/
    ├── setup-infra.sh        # Set up nested VM infrastructure
    ├── run-nested-test.sh    # Run test in nested VMs
    ├── run-roaming-test.sh   # Test WireGuard roaming
    └── cloud-init/
        ├── relay.yaml        # Cloud-init for relay node
        ├── peer.yaml         # Cloud-init for peer node
        └── nat-gateway.yaml  # Cloud-init for NAT gateway
```

### New E2E Tests Needed

#### E2E Test 1: Mesh VM Provisioning (Same LAN)

```bash
#!/bin/bash
# scripts/e2e-mesh-test/run-mesh-vm-provision.sh
#
# Tests full VM provisioning over mesh network (no NAT)
#
# Setup:
#   - Machine A: omertad --mesh (provider)
#   - Machine B: omerta vm request --peer (consumer)
#
# Success criteria:
#   - Consumer discovers provider via bootstrap
#   - VM request succeeds
#   - SSH to VM works over WireGuard tunnel

set -e

PROVIDER_PEER_ID="provider-$(uuidgen | cut -c1-8)"
CONSUMER_PEER_ID="consumer-$(uuidgen | cut -c1-8)"
PROVIDER_PORT=9000

echo "=== Mesh VM Provisioning Test (Same LAN) ==="
echo ""

# Start provider with mesh
echo "[1/4] Starting provider..."
omertad start --mesh --mesh-peer-id "$PROVIDER_PEER_ID" --port "$PROVIDER_PORT" &
PROVIDER_PID=$!
sleep 5

# Start consumer and request VM
echo "[2/4] Requesting VM via mesh..."
RESULT=$(omerta vm request \
    --peer "$PROVIDER_PEER_ID" \
    --bootstrap "$PROVIDER_PEER_ID@localhost:$PROVIDER_PORT" \
    --output json)

VM_IP=$(echo "$RESULT" | jq -r '.ssh_address')
echo "VM IP: $VM_IP"

# Test SSH
echo "[3/4] Testing SSH connection..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "omerta@$VM_IP" "echo 'SSH works!'"

# Cleanup
echo "[4/4] Cleaning up..."
omerta vm release --all
kill $PROVIDER_PID 2>/dev/null || true

echo ""
echo "=== TEST PASSED ==="
```

#### E2E Test 2: Mesh VM Provisioning (Through NAT)

```bash
#!/bin/bash
# scripts/e2e-mesh-test/run-mesh-vm-nat.sh
#
# Tests VM provisioning when consumer is behind NAT
#
# Setup (using network namespaces):
#   - ns-public: Relay node + Provider
#   - ns-nat: Consumer behind simulated NAT
#
# Success criteria:
#   - Consumer behind NAT can reach provider
#   - Hole punch or relay establishes connection
#   - VM provisioning succeeds

set -e

echo "=== Mesh VM Provisioning Test (Through NAT) ==="
echo ""

# Create network namespaces
echo "[1/6] Setting up network namespaces..."
sudo ip netns add ns-public || true
sudo ip netns add ns-nat || true

# Create veth pairs
sudo ip link add veth-pub type veth peer name veth-nat
sudo ip link set veth-pub netns ns-public
sudo ip link set veth-nat netns ns-nat

# Configure IPs
sudo ip netns exec ns-public ip addr add 10.0.0.1/24 dev veth-pub
sudo ip netns exec ns-public ip link set veth-pub up
sudo ip netns exec ns-public ip link set lo up

sudo ip netns exec ns-nat ip addr add 10.0.0.2/24 dev veth-nat
sudo ip netns exec ns-nat ip link set veth-nat up
sudo ip netns exec ns-nat ip link set lo up

# Set up NAT on ns-nat (simulates being behind NAT)
sudo ip netns exec ns-nat iptables -t nat -A POSTROUTING -o veth-nat -j MASQUERADE

# Start relay in ns-public
echo "[2/6] Starting relay node..."
sudo ip netns exec ns-public omerta-mesh \
    --peer-id relay-node \
    --port 9000 \
    --relay &
RELAY_PID=$!
sleep 3

# Start provider in ns-public
echo "[3/6] Starting provider..."
sudo ip netns exec ns-public omertad start \
    --mesh \
    --mesh-peer-id provider-node \
    --bootstrap "relay-node@10.0.0.1:9000" \
    --port 9001 &
PROVIDER_PID=$!
sleep 5

# Start consumer in ns-nat (behind NAT)
echo "[4/6] Requesting VM from behind NAT..."
RESULT=$(sudo ip netns exec ns-nat omerta vm request \
    --peer provider-node \
    --bootstrap "relay-node@10.0.0.1:9000" \
    --output json)

VM_IP=$(echo "$RESULT" | jq -r '.ssh_address')
echo "VM IP: $VM_IP"

# Test SSH (may go through relay)
echo "[5/6] Testing SSH connection..."
sudo ip netns exec ns-nat ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 \
    "omerta@$VM_IP" "echo 'SSH through NAT works!'"

# Cleanup
echo "[6/6] Cleaning up..."
sudo ip netns exec ns-nat omerta vm release --all 2>/dev/null || true
kill $PROVIDER_PID $RELAY_PID 2>/dev/null || true
sudo ip netns delete ns-public 2>/dev/null || true
sudo ip netns delete ns-nat 2>/dev/null || true

echo ""
echo "=== TEST PASSED ==="
```

#### E2E Test 3: Nested VM NAT Test

```bash
#!/bin/bash
# scripts/e2e-mesh-test/nested-vm/run-mesh-vm-nested.sh
#
# Tests VM provisioning using nested VMs for realistic NAT
#
# Setup:
#   - Outer VM: NAT gateway (iptables MASQUERADE)
#   - Inner VM 1: Provider (public IP)
#   - Inner VM 2: Consumer (behind NAT)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Mesh VM Provisioning Test (Nested VMs) ==="
echo ""

# Build binaries
echo "[1/5] Building omerta binaries..."
swift build -c release

# Set up infrastructure
echo "[2/5] Setting up nested VM infrastructure..."
"$SCRIPT_DIR/setup-infra.sh"

# Copy binaries to VMs
echo "[3/5] Deploying binaries..."
scp -P 2201 .build/release/omertad vm-provider:/usr/local/bin/
scp -P 2201 .build/release/omerta vm-provider:/usr/local/bin/
scp -P 2202 .build/release/omerta vm-consumer:/usr/local/bin/

# Start provider
echo "[4/5] Starting provider and requesting VM..."
ssh -p 2201 vm-provider "omertad start --mesh --mesh-peer-id provider &"
sleep 5

# Request VM from consumer (behind NAT)
ssh -p 2202 vm-consumer "omerta vm request --peer provider --bootstrap provider@10.0.0.10:9000"

# Test result
echo "[5/5] Verifying..."
RESULT=$(ssh -p 2202 vm-consumer "omerta vm list --output json")
VM_COUNT=$(echo "$RESULT" | jq '.vms | length')

if [ "$VM_COUNT" -gt 0 ]; then
    echo "=== TEST PASSED ==="
else
    echo "=== TEST FAILED ==="
    exit 1
fi
```

### Cross-Platform Testing

Tests must pass on both Linux and macOS, and cross-machine tests verify real network behavior.

#### Single-Machine Tests

| Test Type | Linux | macOS | Notes |
|-----------|-------|-------|-------|
| Unit tests | ✓ | ✓ | `swift test` |
| Integration tests | ✓ | ✓ | `swift test --filter MeshIntegration` |
| E2E same LAN | ✓ | ✓ | `run-mesh-vm-provision.sh` |
| E2E NAT simulation | ✓ | - | Requires `ip netns` (Linux only) |
| E2E nested VMs | ✓ | - | Requires QEMU/KVM (Linux only) |

#### Cross-Machine Tests

These tests require two machines on the same LAN (or with port forwarding configured).

```bash
# scripts/e2e-mesh-test/run-cross-machine.sh
#
# Run from consumer machine, provider runs on remote machine
#
# Usage:
#   PROVIDER_HOST=192.168.1.100 ./run-cross-machine.sh

set -e

PROVIDER_HOST=${PROVIDER_HOST:?Must set PROVIDER_HOST}
PROVIDER_PEER_ID=${PROVIDER_PEER_ID:-provider-node}
PROVIDER_PORT=${PROVIDER_PORT:-9000}

echo "=== Cross-Machine Mesh Test ==="
echo "Provider: $PROVIDER_HOST"
echo ""

# Assume provider is already running:
#   omertad start --mesh --mesh-peer-id provider-node --port 9000

# Request VM via mesh
echo "[1/3] Requesting VM..."
RESULT=$(omerta vm request \
    --peer "$PROVIDER_PEER_ID" \
    --bootstrap "$PROVIDER_PEER_ID@$PROVIDER_HOST:$PROVIDER_PORT" \
    --output json)

VM_IP=$(echo "$RESULT" | jq -r '.ssh_address')
echo "VM IP: $VM_IP"

# Test SSH
echo "[2/3] Testing SSH..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "omerta@$VM_IP" "hostname"

# Cleanup
echo "[3/3] Releasing VM..."
omerta vm release --all

echo "=== TEST PASSED ==="
```

#### Cross-Machine Test Matrix

| Provider | Consumer | Test Command | Notes |
|----------|----------|--------------|-------|
| Linux | Linux | `PROVIDER_HOST=<linux-ip> ./run-cross-machine.sh` | Both machines Linux |
| macOS | macOS | `PROVIDER_HOST=<mac-ip> ./run-cross-machine.sh` | Both machines macOS |
| Linux | macOS | `PROVIDER_HOST=<linux-ip> ./run-cross-machine.sh` | Run from Mac |
| macOS | Linux | `PROVIDER_HOST=<mac-ip> ./run-cross-machine.sh` | Run from Linux |

#### Real NAT Test

To test actual NAT traversal (not simulated), use a router:

```
┌─────────────────────────────────────────────────────────┐
│                     Home Router                          │
│                   (NAT + Firewall)                       │
└─────────────────────┬───────────────────────────────────┘
                      │
        ┌─────────────┴─────────────┐
        │                           │
   ┌────┴────┐                 ┌────┴────┐
   │  Linux  │                 │  macOS  │
   │ Machine │                 │ Laptop  │
   │ (LAN)   │                 │ (WiFi)  │
   └─────────┘                 └─────────┘
```

**Test scenarios:**

1. **Both behind same NAT:**
   ```bash
   # Machine A (provider)
   omertad start --mesh --mesh-peer-id provider --port 9000

   # Machine B (consumer) - same LAN
   omerta vm request --peer provider --bootstrap provider@<lan-ip>:9000
   ```

2. **One on mobile hotspot (different NAT):**
   ```bash
   # Machine A (provider) - on home network

   # Machine B (consumer) - on phone hotspot
   # Requires a relay or public bootstrap node
   omerta vm request --peer provider --bootstrap relay@<public-ip>:9000
   ```

3. **One with public IP (VPS relay):**
   ```bash
   # VPS (relay)
   omerta-mesh --peer-id relay --port 9000 --relay

   # Home machine (provider)
   omertad start --mesh --mesh-peer-id provider --bootstrap relay@<vps-ip>:9000

   # Laptop on different network (consumer)
   omerta vm request --peer provider --bootstrap relay@<vps-ip>:9000
   ```

---

## Implementation Order

| Phase | Description | Depends On | Estimated Effort |
|-------|-------------|------------|------------------|
| M1 | Add OmertaMesh dependencies | - | Small |
| M2 | MeshConsumerClient | M1 | Medium |
| M3 | MeshProviderDaemon | M1 | Medium |
| M4 | CLI integration | M2, M3 | Medium |
| T1 | Unit tests | M2, M3 | Small |
| T2 | Integration tests | M4, T1 | Medium |
| E1 | E2E: Same LAN | M4 | Small |
| E2 | E2E: NAT simulation | E1 | Medium |
| E3 | E2E: Nested VMs | E2 | Large |

**Critical Path:** M1 → M2 → M3 → M4 → E1 → E2

---

## Phase Success Criteria and Tests

### Phase M1: Add OmertaMesh Dependencies

**Success Criteria:**
- [ ] `swift build` succeeds with OmertaMesh added to OmertaConsumer and OmertaProvider

**Verification:**
```bash
swift build
```

**Tests:** None (build-only phase)

---

### Phase M2: MeshConsumerClient

**Success Criteria:**
- [ ] MeshConsumerClient can initialize with config
- [ ] MeshConsumerClient can start and detect NAT type
- [ ] MeshConsumerClient can discover bootstrap peers
- [ ] MeshConsumerClient can send/receive messages via mesh

**Unit Tests:**

| Test | File | Description |
|------|------|-------------|
| `testMeshConsumerClientInit` | `MeshConsumerClientTests.swift` | Client initializes with valid config |
| `testMeshConsumerClientStartDetectsNAT` | `MeshConsumerClientTests.swift` | Client starts and NAT type is not `.unknown` |
| `testMeshConsumerClientDiscoversPeers` | `MeshConsumerClientTests.swift` | Client discovers bootstrap peer within 5s |
| `testMeshConsumerClientSendReceive` | `MeshConsumerClientTests.swift` | Client sends message, receives response |
| `testMeshConfigSerialization` | `ConfigTests.swift` | MeshConfigOptions encodes/decodes correctly |

**Verification:**
```bash
swift test --filter MeshConsumerClient
swift test --filter ConfigTests
```

---

### Phase M3: MeshProviderDaemon

**Success Criteria:**
- [ ] MeshProviderDaemon can initialize with config
- [ ] MeshProviderDaemon can start and join mesh network
- [ ] MeshProviderDaemon receives and handles VM request messages
- [ ] MeshProviderDaemon creates VM with correct WireGuard endpoint

**Unit Tests:**

| Test | File | Description |
|------|------|-------------|
| `testMeshProviderDaemonInit` | `MeshProviderDaemonTests.swift` | Daemon initializes with valid config |
| `testMeshProviderDaemonStartJoinsMesh` | `MeshProviderDaemonTests.swift` | Daemon starts and is discoverable |
| `testMeshProviderDaemonHandlesVMRequest` | `MeshProviderDaemonTests.swift` | Daemon receives request, returns response |
| `testMeshProviderDaemonExtractsEndpoint` | `MeshProviderDaemonTests.swift` | Daemon extracts consumer endpoint from connection |

**Verification:**
```bash
swift test --filter MeshProviderDaemon
```

---

### Phase M4: CLI Integration

**Success Criteria:**
- [ ] `omerta mesh status` shows NAT type and peer count
- [ ] `omerta mesh peers` lists discovered peers
- [ ] `omerta vm request --peer PEER_ID` sends request via mesh
- [ ] `omertad start --mesh` starts mesh-enabled provider
- [ ] Legacy `--provider IP:PORT` mode still works

**Integration Tests:**

| Test | File | Description |
|------|------|-------------|
| `testCLIMeshStatusCommand` | `CLIMeshIntegrationTests.swift` | `mesh status` outputs NAT type |
| `testCLIMeshPeersCommand` | `CLIMeshIntegrationTests.swift` | `mesh peers` lists bootstrap peer |
| `testCLIVMRequestWithPeer` | `CLIMeshIntegrationTests.swift` | `vm request --peer` returns VM info |
| `testCLILegacyProviderMode` | `CLIMeshIntegrationTests.swift` | `vm request --provider` still works |
| `testDaemonMeshFlag` | `DaemonMeshIntegrationTests.swift` | `omertad start --mesh` joins network |

**Verification:**
```bash
swift test --filter CLIMeshIntegration
swift test --filter DaemonMeshIntegration
```

---

### Phase T1: Unit Tests

**Success Criteria:**
- [ ] All M2 unit tests pass
- [ ] All M3 unit tests pass
- [ ] Existing OmertaConsumer tests still pass
- [ ] Existing OmertaProvider tests still pass

**Test Files:**

| File | New/Updated | Tests |
|------|-------------|-------|
| `Tests/OmertaConsumerTests/MeshConsumerClientTests.swift` | New | 4+ tests |
| `Tests/OmertaProviderTests/MeshProviderDaemonTests.swift` | New | 4+ tests |
| `Tests/OmertaCoreTests/ConfigTests.swift` | Updated | +2 tests for MeshConfigOptions |
| `Tests/OmertaConsumerTests/ConsumerClientTests.swift` | Existing | Must still pass |
| `Tests/OmertaProviderTests/ProviderDaemonTests.swift` | Existing | Must still pass |

**Verification:**
```bash
swift test --filter OmertaConsumerTests
swift test --filter OmertaProviderTests
swift test --filter OmertaCoreTests
```

---

### Phase T2: Integration Tests

**Success Criteria:**
- [ ] Consumer and provider can complete handshake over mesh
- [ ] VM boots with correct WireGuard config pointing to mesh endpoint
- [ ] Relay fallback works when direct connection fails

**Test Files:**

| File | New/Updated | Tests |
|------|-------------|-------|
| `Tests/OmertaIntegrationTests/MeshHandshakeTests.swift` | New | Consumer↔Provider handshake over mesh |
| `Tests/OmertaIntegrationTests/MeshVMProvisioningTests.swift` | New | Full VM creation via mesh |
| `Tests/OmertaIntegrationTests/MeshRelayFallbackTests.swift` | New | Symmetric NAT falls back to relay |
| `Tests/OmertaProviderTests/ConsumerProviderHandshakeTests.swift` | Updated | Add mesh handshake variant |

**Integration Tests Detail:**

| Test | File | Description |
|------|------|-------------|
| `testMeshHandshakeLocalhost` | `MeshHandshakeTests.swift` | Consumer and provider on localhost complete handshake |
| `testMeshHandshakeWithRelay` | `MeshHandshakeTests.swift` | Handshake succeeds via relay node |
| `testMeshVMProvisioningLocalhost` | `MeshVMProvisioningTests.swift` | VM created with correct endpoint |
| `testMeshVMProvisioningWireGuardConfig` | `MeshVMProvisioningTests.swift` | VM cloud-init has correct WG peer |
| `testRelayFallbackOnSymmetricNAT` | `MeshRelayFallbackTests.swift` | Simulated symmetric NAT uses relay |

**Verification:**
```bash
swift test --filter MeshHandshake
swift test --filter MeshVMProvisioning
swift test --filter MeshRelayFallback
```

---

### Phase E1: E2E Same LAN

**Success Criteria:**
- [ ] Provider starts with `--mesh` flag
- [ ] Consumer discovers provider via bootstrap
- [ ] VM request succeeds and returns SSH address
- [ ] SSH to VM works over WireGuard tunnel

**E2E Test:**

| Script | Description |
|--------|-------------|
| `scripts/e2e-mesh-test/run-mesh-vm-provision.sh` | Full VM provisioning on same LAN |

**Test Steps:**
1. Start `omertad start --mesh --mesh-peer-id provider`
2. Run `omerta vm request --peer provider --bootstrap provider@localhost:9000`
3. SSH to returned VM address
4. Verify SSH command succeeds

**Verification:**
```bash
./scripts/e2e-mesh-test/run-mesh-vm-provision.sh
```

---

### Phase E2: E2E NAT Simulation

**Success Criteria:**
- [ ] Consumer behind simulated NAT can reach provider
- [ ] Hole punch succeeds (for compatible NAT types)
- [ ] Relay fallback works (for symmetric NAT)
- [ ] VM provisioning completes through NAT

**E2E Tests:**

| Script | Description |
|--------|-------------|
| `scripts/e2e-mesh-test/run-mesh-vm-nat.sh` | VM provisioning through network namespace NAT |
| `scripts/e2e-mesh-test/run-mesh-holepunch.sh` | Verify hole punch between restricted cone NATs |
| `scripts/e2e-mesh-test/run-mesh-relay-only.sh` | Verify relay works for symmetric NAT |

**Test Matrix:**

| Consumer NAT | Provider NAT | Expected Path | Test |
|--------------|--------------|---------------|------|
| None | None | Direct | `run-mesh-vm-provision.sh` |
| Restricted Cone | None | Hole punch | `run-mesh-holepunch.sh` |
| Symmetric | None | Relay | `run-mesh-relay-only.sh` |
| Restricted Cone | Restricted Cone | Hole punch | `run-mesh-holepunch.sh` |
| Symmetric | Symmetric | Relay | `run-mesh-relay-only.sh` |

**Verification:**
```bash
sudo ./scripts/e2e-mesh-test/run-mesh-vm-nat.sh
sudo ./scripts/e2e-mesh-test/run-mesh-holepunch.sh
sudo ./scripts/e2e-mesh-test/run-mesh-relay-only.sh
```

---

### Phase E3: E2E Nested VMs

**Success Criteria:**
- [ ] Nested VM infrastructure sets up correctly
- [ ] Real NAT gateway VM works (not just iptables simulation)
- [ ] Provider in "public" VM is reachable
- [ ] Consumer in "NAT" VM can provision VMs

**E2E Tests:**

| Script | Description |
|--------|-------------|
| `scripts/e2e-mesh-test/nested-vm/run-mesh-vm-nested.sh` | Full test with nested VMs |
| `scripts/e2e-mesh-test/nested-vm/run-nat-types.sh` | Test all NAT type combinations |

**Infrastructure Components:**

| Component | Cloud-Init | Role |
|-----------|------------|------|
| NAT Gateway VM | `nat-gateway.yaml` | iptables MASQUERADE, routes traffic |
| Provider VM | `relay.yaml` | Public IP, runs omertad |
| Consumer VM | `peer.yaml` | Behind NAT, runs omerta |

**Verification:**
```bash
sudo ./scripts/e2e-mesh-test/nested-vm/run-mesh-vm-nested.sh
```

---

## Test Summary by Phase

| Phase | Unit Tests | Integration Tests | E2E Tests |
|-------|------------|-------------------|-----------|
| M1 | - | - | - |
| M2 | 5 | - | - |
| M3 | 4 | - | - |
| M4 | - | 5 | - |
| T1 | 9+ (all unit) | - | - |
| T2 | - | 5+ | - |
| E1 | - | - | 1 script |
| E2 | - | - | 3 scripts |
| E3 | - | - | 2 scripts |

**Total New Tests:**
- Unit tests: ~9
- Integration tests: ~10
- E2E scripts: ~6

---

## Migration Strategy

### Backward Compatibility

Both direct (IP-based) and mesh (peer ID-based) modes will be supported:

```bash
# Legacy: Direct connection (works without mesh infrastructure)
omerta vm request --provider 192.168.1.100:51820

# New: Mesh connection (works through NAT)
omerta vm request --peer provider-abc123

# Provider can serve both
omertad start --port 51820 --mesh --mesh-peer-id provider-abc123
```

### Deprecation Timeline

1. **Phase 1 (Current):** Both modes supported, mesh optional
2. **Phase 2 (Future):** Mesh enabled by default, direct mode still available
3. **Phase 3 (Future):** Direct mode deprecated, mesh required

---

## Final Success Criteria

Integration is complete when all phase criteria are met:

**Code:**
- [ ] M1: `swift build` succeeds
- [ ] M2: MeshConsumerClient implemented
- [ ] M3: MeshProviderDaemon implemented
- [ ] M4: CLI commands working

**Unit Tests (T1):**
- [ ] `swift test --filter MeshConsumerClient` passes (5 tests)
- [ ] `swift test --filter MeshProviderDaemon` passes (4 tests)
- [ ] `swift test --filter OmertaConsumerTests` passes (existing + new)
- [ ] `swift test --filter OmertaProviderTests` passes (existing + new)

**Integration Tests (T2):**
- [ ] `swift test --filter MeshHandshake` passes
- [ ] `swift test --filter MeshVMProvisioning` passes
- [ ] `swift test --filter MeshRelayFallback` passes

**E2E Tests (Single Machine):**
- [ ] `run-mesh-vm-provision.sh` passes on Linux
- [ ] `run-mesh-vm-provision.sh` passes on macOS
- [ ] `run-mesh-vm-nat.sh` passes (E2: NAT simulation, Linux only)
- [ ] `run-mesh-holepunch.sh` passes (E2: hole punch)
- [ ] `run-mesh-relay-only.sh` passes (E2: relay fallback)
- [ ] `run-mesh-vm-nested.sh` passes (E3: nested VMs, Linux only)

**E2E Tests (Cross-Machine):**
- [ ] Linux provider ↔ Linux consumer (same LAN)
- [ ] macOS provider ↔ macOS consumer (same LAN)
- [ ] Linux provider ↔ macOS consumer (same LAN)
- [ ] macOS provider ↔ Linux consumer (same LAN)
- [ ] Cross-machine with one behind NAT (router test)
