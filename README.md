# Omerta

A privacy-preserving, peer-to-peer compute sharing platform for macOS.

## Overview

Omerta allows you to share compute resources (CPU and GPU) with others in a secure, isolated environment. Each compute request runs in an ephemeral VM that is destroyed when done, ensuring maximum security and privacy.

### Key Features

- **Privacy-First**: VMs are ephemeral - created for each job and destroyed after completion
- **Network Isolation**: All VM traffic routes through requester-provided VPN
- **Social Networks**: Join compute networks via shared keys (like Discord servers)
- **Multi-Network**: Participate in multiple networks simultaneously
- **Flexible Filtering**: Control who can use your resources via peer ID, IP, reputation, etc.
- **GPU Support**: Metal-based GPU workloads on macOS VMs
- **Both Provider & Consumer**: Share your resources AND use others' compute

## Architecture

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Consumer   │────────▶│   Provider   │◀────────│     VPN      │
│  (Requester) │         │   (Worker)   │         │  (Requester) │
└──────────────┘         └──────────────┘         └──────────────┘
                                 │
                                 ▼
                         ┌──────────────┐
                         │  Ephemeral   │
                         │      VM      │
                         │  (Isolated)  │
                         └──────────────┘
```

- **Consumer**: Submits jobs to providers
- **Provider**: Executes jobs in isolated VMs
- **VPN**: All VM traffic routes through requester's VPN (provider's internet not used)
- **Network Discovery**: Kademlia DHT for decentralized peer discovery

## Requirements

### Hardware
- **Required**: Apple Silicon Mac (M1/M2/M3/M4)
- **Recommended**: 32GB+ RAM (for running multiple VMs)
- **Recommended**: 500GB+ free disk space (VM images can be large)

### Software
- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+
- Swift 5.9+
- Protocol Buffer Compiler: `brew install protobuf`
- WireGuard: `brew install wireguard-tools`

## Quick Start

### 1. Build the Project

```bash
# Clone the repository
git clone <repository-url>
cd omerta

# Build the project
swift build

# Or build in release mode for better performance
swift build -c release
```

### 2. Create a Network

```bash
# Start as provider (shares your compute)
./build/release/omertad start

# In another terminal, create a network
./build/release/omerta network create --name "My Team"
# Save the omerta://join/... key that is displayed

# Share the network key with others via Signal, email, etc.
```

### 3. Join a Network

```bash
# Someone shared a network key with you
./build/release/omerta network join --key "omerta://join/eyJuZXR3b3JrX2tleS..."
```

### 4. Submit a Job

```bash
# Submit a Python script
./build/release/omerta submit \
  --network "My Team" \
  --script "print('Hello from Omerta!')" \
  --language python \
  --cpu 2 \
  --memory 4096 \
  --description "Test job"
```

## Project Structure

```
omerta/
├── Package.swift           # Swift package manifest
├── Proto/
│   └── compute.proto       # gRPC protocol definitions
├── Sources/
│   ├── OmertaCore/         # Core business logic (platform-agnostic)
│   ├── OmertaVM/           # VM lifecycle management (macOS only)
│   ├── OmertaNetwork/      # gRPC + DHT networking
│   ├── OmertaProvider/     # Provider daemon
│   ├── OmertaConsumer/     # Consumer client
│   ├── OmertaCLI/          # Command-line interface
│   └── OmertaGUI/          # macOS SwiftUI app (future)
└── Tests/
    ├── OmertaCoreTests/
    ├── OmertaVMTests/
    └── OmertaNetworkTests/
```

## How It Works

### Network-Based Access Control

Unlike traditional P2P systems with global discovery, Omerta uses **network keys** for access control:

1. **Create a network**: Generates a 256-bit key + bootstrap peer info
2. **Share the key**: Via Signal, email, QR code, etc.
3. **Join the network**: Paste key in GUI or CLI
4. **Discover peers**: Only see peers in your networks
5. **Submit jobs**: To peers within your networks

Networks are like Discord servers - you can be in multiple at once, and they're completely isolated from each other.

### VPN-Based Traffic Routing

Every job includes a VPN configuration:

1. **Requester** creates ephemeral WireGuard VPN
2. **VM** routes ALL traffic through VPN
3. **Provider's internet** only used for provider↔requester communication
4. **Benefits**: Provider's IP stays private, requester controls access

This means:
- Provider doesn't pay for requester's bandwidth
- Requester decides what VM can access (via VPN firewall rules)
- VM cannot make unauthorized connections

### Input/Output

The protocol does NOT include input/output transfer mechanisms. Instead:

- **VM has network access** to requester via VPN
- **Requester chooses**: HTTP server, file share, database, S3, sockets, etc.
- **Example**: Requester runs HTTP server, script does `wget http://10.0.0.1:8000/input.data`
- **Flexible and simple**: No large payloads in gRPC, works for any data size

## Development

### Building

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run tests
swift test
```

### Generating Protocol Buffers

```bash
# Install protoc plugin for Swift
brew install swift-protobuf

# Generate Swift code from proto files
protoc Proto/compute.proto \
  --swift_out=Sources/OmertaNetwork/Protocol/Generated \
  --grpc-swift_out=Sources/OmertaNetwork/Protocol/Generated
```

### Running Locally

```bash
# Terminal 1: Start provider
swift run omertad start --port 50051

# Terminal 2: Create network and get key
swift run omerta network create --name "Local Test"

# Terminal 3: Submit a job
swift run omerta submit \
  --network "Local Test" \
  --script "echo 'Hello World'" \
  --cpu 1 \
  --memory 512
```

## Configuration

Configuration is stored in `~/Library/Application Support/Omerta/`:

```
~/Library/Application Support/Omerta/
├── config.json          # Main configuration
├── networks.json        # Joined networks
├── filters.json         # Filter rules
├── identity/
│   ├── private_key.pem  # Your peer private key
│   └── public_key.pem   # Your peer public key
└── logs/
    └── omerta.log
```

## Security

### VM Isolation

- Every job runs in a fresh macOS VM (using Virtualization.framework)
- VM is destroyed immediately after job completes
- No persistent state between jobs
- Strong hardware-level isolation

### Network Security

- All provider↔consumer communication over TLS
- Mutual authentication using peer keypairs
- VPN encrypts all VM traffic
- Rogue connection detector automatically terminates VMs that bypass VPN

### Access Control

- Network keys for membership (like invite-only Discord servers)
- Per-peer filtering (whitelist/blacklist by peer ID or IP)
- Reputation system to track peer behavior
- Manual approval queue for suspicious requests

## Roadmap

- [x] Phase 0: Project bootstrap (complete)
- [ ] Phase 1: Core VM management
- [ ] Phase 2: VPN routing & network isolation
- [ ] Phase 3: Provider daemon
- [ ] Phase 4: Network discovery (DHT)
- [ ] Phase 5: Consumer client & E2E
- [ ] Phase 6: Advanced filtering
- [ ] Phase 7: GPU support (Metal)
- [ ] Phase 8: macOS GUI
- [ ] Phase 9: Performance optimizations
- [ ] Phase 10: Production hardening

## Contributing

Contributions are welcome! Please read CONTRIBUTING.md for guidelines.

## License

[License TBD]

## Acknowledgments

- Built with Swift and Apple's Virtualization.framework
- Uses gRPC for RPC and Protocol Buffers for serialization
- Network discovery via Kademlia DHT
- VPN tunneling via WireGuard
