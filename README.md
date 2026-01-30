# Omerta Node

[![codecov](https://codecov.io/gh/mjtomei/omerta_node/graph/badge.svg)](https://codecov.io/gh/mjtomei/omerta_node)

Provider and consumer node implementation for the Omerta compute platform.

## Overview

This repository contains the Swift implementation of Omerta nodes - both provider (shares compute) and consumer (requests compute) functionality. VMs are ephemeral and destroyed after each job completes.

## Development Status

See [plans/notes.txt](../plans/notes.txt) for the latest human-managed TODO list.

**Note:** Currently migrating from WireGuard-based VM networking to a full virtual network built on the mesh. The end-to-end flow is broken during this transition.

### Accomplished

- [x] Core VM management with Virtualization.framework (macOS) and QEMU/KVM (Linux)
- [x] Provider daemon that receives compute requests
- [x] Ephemeral VM lifecycle (create, run, destroy)
- [x] Hardware-level isolation via hypervisor

### TODO

- [ ] Virtual network integration with omerta_mesh
- [ ] Consumer client and end-to-end flow
- [ ] Fix tunnel proxy command and VM-to-consumer connection
- [ ] Cleanup on omertad kill
- [ ] Multiple simultaneous VM requests
- [ ] macOS GUI
- [ ] GPU support (Metal passthrough on macOS)

## Requirements

### macOS
- Apple Silicon or Intel Mac with Hypervisor support
- macOS 14.0+ (Sonoma) for Virtualization.framework
- Swift 6.0+

### Linux
- x86_64 or ARM64 with KVM support
- QEMU: `sudo apt install qemu-system-x86 qemu-utils`
- `/dev/kvm` accessible (add user to `kvm` group)
- Swift 6.0+

## Building

```bash
swift build -c release
```

Release builds are required on macOS to get virtualization entitlements.

## Project Structure

```
omerta_node/
├── Package.swift
├── Proto/
│   └── compute.proto       # Protocol definitions
├── Sources/
│   ├── OmertaCore/         # Core business logic
│   ├── OmertaVM/           # VM lifecycle (Virtualization.framework / QEMU)
│   ├── OmertaProvider/     # Provider logic
│   ├── OmertaConsumer/     # Consumer logic
│   ├── OmertaDaemon/       # omertad daemon
│   ├── OmertaCLI/          # omerta CLI
│   └── OmertaApp/          # macOS app (WIP)
└── Tests/
```

## Testing

```bash
swift test
```

See [README_TESTING.md](README_TESTING.md) for details on running tests with virtualization entitlements.

## Documentation

Working documents in [`plans/`](plans/).
