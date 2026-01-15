# End-to-End Mesh Network NAT Tests

Tests NAT traversal and hole punching between mesh nodes with different NAT types.

## Quick Start (Recommended)

Run tests inside an isolated VM (no sudo required on host):

```bash
# Run a specific NAT combination
./run-in-vm.sh full-cone full-cone

# Run all NAT combinations
./run-in-vm.sh --all

# Get a shell inside the test VM
./run-in-vm.sh --shell
```

The VM approach:
- Downloads Ubuntu cloud image automatically
- Creates an ephemeral VM with QEMU
- Copies test binaries and scripts into VM
- Runs NAT simulation inside VM (isolated)
- No host network changes required

## Direct Execution (Requires sudo)

If you prefer to run directly on the host (requires root):

```bash
# Setup NAT namespace and run test
sudo ./run-nat-test.sh symmetric public
sudo ./run-nat-test.sh full-cone port-restrict
sudo ./run-nat-test.sh symmetric symmetric relay
```

## NAT Types

| Type | Description | Traversability |
|------|-------------|----------------|
| `public` | No NAT, direct IP | Easy |
| `full-cone` | Any external host can send to mapped port | Easy |
| `addr-restrict` | Only contacted IPs can reply | Medium |
| `port-restrict` | Only contacted IP:port can reply | Medium |
| `symmetric` | Different port for each destination | Hard (needs relay) |

## Expected Results

| Peer A | Peer B | Expected Outcome |
|--------|--------|------------------|
| public | anything | Direct connection |
| full-cone | anything | Direct connection |
| addr-restrict | addr-restrict | Hole punch |
| port-restrict | port-restrict | Hole punch |
| symmetric | cone types | Hole punch (maybe) |
| symmetric | symmetric | Requires relay |

## Cross-Host Test

Test real mesh communication between Linux and Mac:

```bash
./run-mesh-test.sh
```

This starts mesh nodes on both hosts and verifies they can discover and communicate.

## Files

- `run-in-vm.sh` - Run tests inside isolated VM (recommended)
- `run-nat-test.sh` - Run NAT combination test (requires sudo)
- `nat-simulation.sh` - Create network namespaces with NAT rules
- `run-mesh-test.sh` - Cross-host test between Linux and Mac

## Requirements

For VM-based testing:
- QEMU (native architecture support for best performance)
  - On ARM64: uses `qemu-system-aarch64` with KVM
  - On x86_64: uses `qemu-system-x86_64` with KVM
- ~500MB free disk space (for cloud image)
- SSH key in `~/.ssh/` for VM access
- Swift toolchain (libraries are copied to VM automatically)

For direct execution:
- Root access
- iptables, iproute2
