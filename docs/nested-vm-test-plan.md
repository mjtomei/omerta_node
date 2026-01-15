# Realistic NAT Testing with Nested VMs

## Problem Statement

The current NAT simulation using network namespaces has limitations:
1. Namespaces share the kernel network stack - traffic can route directly between them
2. The "symmetric NAT" iptables rules don't truly prevent direct connections
3. We never trigger the actual relay fallback code path
4. Hole punch coordination isn't tested under realistic conditions

## Goal

Create a nested VM architecture where:
- Each peer runs in its own VM with isolated network stack
- NAT behavior is implemented at the VM boundary (not just iptables rules)
- We can verify that symmetric+symmetric actually fails and falls back to relay
- Network conditions (latency, packet loss) can be simulated

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Outer VM (test-runner)                           │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    Virtual "Internet" Bridge                     │   │
│  │                      (br-internet: 192.168.100.0/24)            │   │
│  └──────┬─────────────────────┬─────────────────────┬──────────────┘   │
│         │                     │                     │                   │
│    ┌────┴────┐           ┌────┴────┐           ┌────┴────┐             │
│    │ NAT GW 1│           │ NAT GW 2│           │  Relay  │             │
│    │(router) │           │(router) │           │   VM    │             │
│    │  .100.1 │           │  .100.2 │           │  .100.3 │             │
│    └────┬────┘           └────┬────┘           └─────────┘             │
│         │                     │                                         │
│  ┌──────┴──────┐       ┌──────┴──────┐                                 │
│  │  LAN 1      │       │  LAN 2      │                                 │
│  │ 10.0.1.0/24 │       │ 10.0.2.0/24 │                                 │
│  └──────┬──────┘       └──────┴──────┘                                 │
│         │                     │                                         │
│    ┌────┴────┐           ┌────┴────┐                                   │
│    │ Peer 1  │           │ Peer 2  │                                   │
│    │   VM    │           │   VM    │                                   │
│    │ 10.0.1.2│           │ 10.0.2.2│                                   │
│    └─────────┘           └─────────┘                                   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. NAT Gateway VMs (Lightweight Alpine Linux)
- Implement actual NAT behavior using nftables
- Support all 5 NAT types with proper connection tracking
- Configurable via cloud-init or simple config file

### 2. Peer VMs (Minimal Ubuntu)
- Run omerta-mesh binary
- Isolated network - can only reach NAT gateway
- No direct route to other peers

### 3. Relay VM (Minimal Ubuntu)
- Public IP on the "internet" bridge
- Runs omerta-mesh in relay mode
- Acts as hole punch coordinator

### 4. Virtual Networks
- `br-internet`: Simulates public internet (192.168.100.0/24)
- `br-lan1`, `br-lan2`: Private LANs behind each NAT (10.0.x.0/24)

## NAT Implementation (nftables)

### Full Cone NAT
```nft
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100;
        oifname "eth0" masquerade persistent
    }
    chain prerouting {
        type nat hook prerouting priority -100;
        # Allow all inbound to mapped ports
    }
}
```

### Address-Restricted Cone
```nft
table ip filter {
    chain forward {
        type filter hook forward priority 0;
        # Only allow replies from IPs we've contacted
        ct state established,related accept
        iifname "eth0" drop
    }
}
```

### Port-Restricted Cone
```nft
table ip filter {
    chain forward {
        type filter hook forward priority 0;
        # Only allow replies from exact IP:port we contacted
        ct state established,related accept
        iifname "eth0" drop
    }
}
# Plus stricter conntrack settings
```

### Symmetric NAT
```nft
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100;
        # Use different source port for each destination
        oifname "eth0" masquerade random,persistent
    }
}
# Plus per-destination port allocation tracking
```

## Implementation Plan

### Phase 1: Infrastructure Setup Script
**File**: `scripts/e2e-mesh-test/nested-vm/setup-infra.sh`

1. Create virtual bridges using `ip link`
2. Download/create base VM images:
   - Alpine Linux for NAT gateways (~50MB)
   - Ubuntu minimal for peers (~250MB)
3. Create cloud-init templates for each VM type

### Phase 2: NAT Gateway VM
**Files**:
- `scripts/e2e-mesh-test/nested-vm/nat-gateway/` directory
- `nat-gateway.sh` - nftables configuration script
- `cloud-init-nat.yaml` - cloud-init for NAT VM

Features:
- Accept NAT type as boot parameter
- Configure nftables rules accordingly
- Enable IP forwarding
- Optional: tc/netem for latency simulation

### Phase 3: Test Orchestrator
**File**: `scripts/e2e-mesh-test/nested-vm/run-nested-test.sh`

1. Start infrastructure (bridges)
2. Boot NAT gateway VMs with specified NAT types
3. Boot peer VMs behind each NAT
4. Boot relay VM on public network
5. Copy omerta-mesh binary and Swift libs to peer VMs
6. Execute test scenario
7. Collect results and logs
8. Cleanup all VMs

### Phase 4: Test Scenarios
**File**: `scripts/e2e-mesh-test/nested-vm/scenarios/`

Define test matrices:
```yaml
# scenario-direct.yaml
name: "Direct connection (both full-cone)"
nat1: full-cone
nat2: full-cone
use_relay: false
expected: direct
timeout: 30

# scenario-holepunch.yaml
name: "Hole punch (cone + symmetric)"
nat1: port-restricted
nat2: symmetric
use_relay: false  # But coordinator available
expected: hole-punch
timeout: 45

# scenario-relay-fallback.yaml
name: "Relay fallback (both symmetric)"
nat1: symmetric
nat2: symmetric
use_relay: true
expected: relay
timeout: 60
```

### Phase 5: Network Condition Simulation
Add tc/netem support to NAT gateways:
```bash
# Add latency
tc qdisc add dev eth0 root netem delay 50ms 10ms

# Add packet loss
tc qdisc add dev eth0 root netem loss 1%

# Combine
tc qdisc add dev eth0 root netem delay 50ms loss 0.5%
```

## File Structure

```
scripts/e2e-mesh-test/nested-vm/
├── setup-infra.sh           # Create bridges, download images
├── run-nested-test.sh       # Main test orchestrator
├── cleanup.sh               # Tear down everything
├── lib/
│   ├── vm-utils.sh          # VM lifecycle helpers
│   ├── network-utils.sh     # Bridge/interface helpers
│   └── nat-config.sh        # NAT type configurations
├── images/
│   ├── nat-gateway.qcow2    # Alpine-based NAT gateway
│   └── peer.qcow2           # Ubuntu peer VM
├── cloud-init/
│   ├── nat-gateway.yaml     # NAT gateway cloud-init
│   ├── peer.yaml            # Peer VM cloud-init
│   └── relay.yaml           # Relay VM cloud-init
└── scenarios/
    ├── all-combinations.yaml
    └── stress-test.yaml
```

## Resource Requirements

Per test run (5 VMs):
- NAT Gateway 1: 256MB RAM, 1 vCPU
- NAT Gateway 2: 256MB RAM, 1 vCPU
- Peer 1: 512MB RAM, 1 vCPU
- Peer 2: 512MB RAM, 1 vCPU
- Relay: 512MB RAM, 1 vCPU
- **Total**: ~2GB RAM, 5 vCPUs

Outer VM should have: 4GB RAM, 4 vCPUs minimum

## Verification

The test passes when:
1. **Direct tests**: Peers connect without relay, logs show `[direct]` messages
2. **Hole punch tests**: Coordinator is contacted, probes exchanged, connection established
3. **Relay tests**: Initial direct/holepunch fails, falls back to relay, logs show `[relay]` messages

Packet captures can verify:
- NAT gateway rewrites source ports correctly
- Symmetric NAT uses different ports for different destinations
- Hole punch probes are sent/received
- Relay traffic flows through relay VM

## Test Matrix

| NAT1 | NAT2 | Expected Path | Test Priority |
|------|------|---------------|---------------|
| full-cone | full-cone | direct | P1 |
| full-cone | symmetric | hole-punch | P1 |
| symmetric | symmetric | relay | P1 |
| port-restrict | port-restrict | hole-punch | P2 |
| addr-restrict | symmetric | hole-punch | P2 |
| public | symmetric | direct | P2 |

## Coverage of mesh-relay-network.md Design

Based on reviewing the design doc, these features need test coverage:

### 1. NAT Detection (STUN)
- [ ] Correctly identifies all 5 NAT types
- [ ] Handles STUN server unreachable (fallback)
- [ ] Two-server detection for symmetric NAT
- **Test**: Each NAT gateway VM responds to STUN differently

### 2. Bootstrap Process
- [ ] Single bootstrap node works
- [ ] Multiple bootstrap nodes (uses fastest)
- [ ] All bootstrap nodes offline → error + retry
- [ ] Malicious bootstrap (invalid peer lists) → ignored
- **Test**: Control which VMs respond to bootstrap requests

### 3. Peer Announcements & Gossip
- [ ] Public nodes announce direct endpoint
- [ ] NAT nodes announce relay paths
- [ ] Announcements propagate through mesh
- [ ] TTL expiration causes re-announcement
- **Test**: Monitor announcement messages across VMs

### 4. Relay Selection & Connection
- [ ] NAT nodes select 3 relays (configurable)
- [ ] Relays sorted by latency + capacity
- [ ] Relay health checks work
- [ ] Failed relay triggers re-selection
- **Test**: Kill relay VM mid-connection

### 5. Freshness Queries ("whoHasRecent")
- [ ] Query returns most recent contact
- [ ] Stale paths trigger re-lookup
- [ ] Path failure reports propagate
- **Test**: Change peer's endpoint, verify network updates

### 6. Hole Punching Coordination
- [ ] Coordinator selected correctly
- [ ] Strategy selection based on NAT types:
  - simultaneous (both cone)
  - initiatorFirst (initiator is symmetric)
  - responderFirst (responder is symmetric)
  - impossible (both symmetric)
- [ ] Probe packets sent at coordinated time
- [ ] Success/failure reported back
- **Test**: Packet captures showing probe timing

### 7. Relay Data Forwarding
- [ ] Messages forwarded bidirectionally
- [ ] Session tracking works
- [ ] Capacity limits enforced
- [ ] Session cleanup on disconnect
- **Test**: Verify relay adds <100ms latency

### 8. Connection Recovery
- [ ] Reconnects after brief network interruption
- [ ] Failover to backup relay
- [ ] Path re-discovery after failure
- **Test**: tc netem to simulate interruptions

## Coverage of mesh-protocol-test-plan.md

The existing test plan defines comprehensive tests. The nested VM setup enables:

| Test Category | Current Coverage | With Nested VMs |
|---------------|------------------|-----------------|
| T1.* Topologies | ⚠️ Single VM only | ✅ True multi-machine |
| T2.* NAT Configs | ⚠️ Namespace simulation | ✅ Real NAT behavior |
| T3.* Fault Injection | ⚠️ Limited tc | ✅ Per-VM netem |
| T4.* Protocol | ⚠️ Same kernel | ✅ Isolated stacks |
| T5.* Performance | ⚠️ Unrealistic | ✅ Realistic latency |

### Critical Tests Enabled by Nested VMs

1. **T2.4.3 Relay Fallback**: Symmetric+Symmetric actually fails hole punch, falls back
2. **T2.M.25**: Full 5x5 NAT combination matrix with real behavior
3. **T3.8.* Network Partitions**: True VM isolation, not just iptables rules
4. **T4.2.* Hole Punching**: Real coordinated probes across machines
5. **T4.3.* Relay Operations**: Relay VM handles actual traffic forwarding

## Implementation Priority

### Phase 1: Basic Infrastructure (P0)
- Bridge creation
- NAT gateway VM (Alpine + nftables)
- Peer VM (Ubuntu + Swift runtime)
- Single NAT type test (full-cone + full-cone)

### Phase 2: All NAT Types (P1)
- All 5 NAT implementations
- Symmetric NAT with proper per-destination ports
- 5x5 NAT combination matrix

### Phase 3: Failure Scenarios (P2)
- Relay VM crash/restart
- Network partition simulation
- tc/netem latency and loss

### Phase 4: Observability (P3)
- Packet captures per VM
- Metrics collection
- Test result reporting

## Next Steps After Implementation

1. Add packet capture integration (tcpdump per VM)
2. Add metrics collection (time-to-connect, success rate)
3. CI integration with test result reporting
4. Chaos testing (kill relay mid-connection, NAT restart)
