# End-to-End Mesh Network Test

This test validates real NAT traversal and hole punching between VMs on different hosts.

## Architecture

```
Linux Host (Public IP: relay)
├── Relay Node (UDP port 9999)
└── Linux VM (behind NAT)
    └── Mesh Node A

Mac Host
└── Mac VM (behind NAT)
    └── Mesh Node B
```

## Test Flow

1. Start relay node on Linux host
2. Start Linux VM with mesh node
3. Start Mac VM with mesh node (via SSH)
4. Both VMs register with relay
5. Relay coordinates hole punch
6. VMs communicate directly (bypassing relay)

## Running the Test

```bash
# From the omerta directory:
./scripts/e2e-mesh-test/run-test.sh
```

## Requirements

- Linux host with KVM/QEMU
- Mac accessible via SSH (user@mac.local)
- Ubuntu cloud images installed on both hosts
