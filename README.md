# Omerta

A privacy-preserving, peer-to-peer compute sharing platform for macOS and Linux.

## Overview

Omerta allows you to share compute resources (CPU and GPU) with others in a secure, isolated environment. Each compute request runs in an ephemeral VM that is destroyed when done, ensuring maximum security and privacy.

### Key Features

- **Privacy-First**: VMs are ephemeral - created for each job and destroyed after completion
- **Network Isolation**: All VM traffic routes through requester-provided VPN
- **Social Networks**: Join compute networks via shared keys (like Discord servers)
- **Multi-Network**: Participate in multiple networks simultaneously
- **Flexible Filtering**: Control who can use your resources via peer ID, IP, reputation, etc.
- **GPU Support**: Metal GPU passthrough (macOS), NVIDIA/AMD passthrough (Linux, planned)
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

**macOS:**
- Apple Silicon Mac (M1/M2/M3/M4) or Intel Mac with Hypervisor support
- 16GB+ RAM recommended (for running VMs)

**Linux:**
- x86_64 or ARM64 processor with KVM support
- 16GB+ RAM recommended
- `/dev/kvm` accessible (add user to `kvm` group)

### Software

**macOS:**
- macOS 14.0+ (Sonoma) - Required for Virtualization.framework
- WireGuard Tools: `brew install wireguard-tools`
- Swift 5.9+ (for building from source)

**Linux:**
- QEMU with KVM: `sudo apt install qemu-system-x86 qemu-utils`
- WireGuard Tools: `sudo apt install wireguard-tools`
- Swift 5.9+ (for building from source)

#### Build Dependencies (both platforms)
- **Swift 5.9+**
- **Protocol Buffer Compiler** (for regenerating protocol files)
  ```bash
  # macOS
  brew install protobuf swift-protobuf

  # Linux
  sudo apt install protobuf-compiler
  ```

## Installation

### Quick Install

Use the installation script (works on macOS and Linux):

```bash
# Clone the repository
git clone https://github.com/omerta/omerta.git
cd omerta

# Run install script
./Scripts/install.sh
```

This script will:
- Check system requirements
- Install WireGuard if missing
- Set up necessary directories (`~/.omerta/`)
- Build and install Omerta binaries

### Manual Installation

#### 1. Install Dependencies

**macOS:**
```bash
brew install wireguard-tools
```

**Linux (Debian/Ubuntu):**
```bash
sudo apt-get update
sudo apt-get install -y wireguard-tools qemu-system-x86 qemu-utils

# Enable KVM access
sudo usermod -aG kvm $USER
# Log out and back in for group change to take effect
```

**Linux (Fedora/RHEL):**
```bash
sudo dnf install -y wireguard-tools qemu-kvm qemu-img
sudo usermod -aG kvm $USER
```

#### 2. Build from Source

```bash
# Clone the repository
git clone <repository-url>
cd omerta

# Build the project
swift build -c release

# Install to system (optional)
sudo cp .build/release/omerta /usr/local/bin/
sudo cp .build/release/omertad /usr/local/bin/
```

#### 3. Verify Installation

```bash
# Check that Omerta is installed
omerta status

# Verify all dependencies are satisfied
omerta check-deps
```

Expected output:
```
Checking system dependencies...

✅ WireGuard Tools
   Version: wireguard-tools v1.0.20250521

✅ WireGuard Quick
   Version: wg-quick

✅ All dependencies satisfied
```

### Quick Start

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
│   ├── OmertaVM/           # VM lifecycle management (Virtualization.framework on macOS, QEMU on Linux)
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

Configuration is stored in platform-specific locations:

**macOS:** `~/Library/Application Support/Omerta/`
**Linux:** `~/.config/omerta/`

```
<config-dir>/
├── config.json          # Main configuration
├── networks.json        # Joined networks
├── filters.json         # Filter rules
├── identity/
│   ├── private_key.pem  # Your peer private key
│   └── public_key.pem   # Your peer public key
└── logs/
    └── omerta.log
```

### Runtime Directory

Runtime files are stored in `~/.omerta/` (both platforms):

```
~/.omerta/
├── vpn/                 # VPN configuration files
├── kernel/
│   └── vmlinuz         # Linux kernel for VMs (macOS only)
├── images/             # VM disk images
├── jobs/               # Job working directories
└── logs/               # Execution logs
```

## Troubleshooting

### WireGuard Not Found

**Symptom:** `wg: command not found`

**Solution:**
```bash
# macOS
brew install wireguard-tools

# Linux (Debian/Ubuntu)
sudo apt install wireguard-tools
```

### macOS: Virtualization Entitlement Missing

**Symptom:** `Error Domain=VZErrorDomain Code=2 "The process doesn't have the 'com.apple.security.virtualization' entitlement"`

**Solution:** Build with release configuration (automatically signs with entitlements):
```bash
swift build -c release
```

### macOS: Version Too Old

**Symptom:** Error about Virtualization.framework

**Solution:** Omerta requires macOS 14 (Sonoma) or later for Virtualization.framework.

### Linux: KVM Not Available

**Symptom:** `KVM not available` or slow VM performance

**Solution:**
```bash
# Check if KVM is available
ls -la /dev/kvm

# Add user to kvm group
sudo usermod -aG kvm $USER
# Log out and back in

# If /dev/kvm doesn't exist, enable virtualization in BIOS/UEFI
```

### Linux: QEMU Not Found

**Symptom:** `QEMU not found`

**Solution:**
```bash
# Debian/Ubuntu
sudo apt install qemu-system-x86 qemu-utils

# Fedora/RHEL
sudo dnf install qemu-kvm qemu-img
```

### Permission Denied (VPN)

**Symptom:** Permission errors when creating VPN tunnels

**Solution:** WireGuard operations require root. Omerta prompts for sudo when needed.

## Security

### VM Isolation

- Every job runs in a fresh Linux VM
  - macOS: Apple Virtualization.framework
  - Linux: QEMU with KVM acceleration
- VM is destroyed immediately after job completes
- No persistent state between jobs
- Hardware-level isolation via hypervisor
- All VM traffic routed through requester's VPN (see [VM Network Architecture](docs/vm-network-architecture.md))

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

## Documentation

Detailed technical documentation is available in the [`docs/`](docs/) directory:

| Document | Description |
|----------|-------------|
| [CLI Architecture](docs/cli-architecture.md) | CLI design and implementation plan |
| [VM Network Architecture](docs/vm-network-architecture.md) | Network isolation modes and security model |
| [VM Network Implementation](docs/vm-network-implementation.md) | Phased implementation details |
| [VM Network Tests](docs/vm-network-tests.md) | Test specifications and performance targets |
| [Rogue Detection](docs/rogue-detection.md) | Traffic monitoring and violation detection |
| [Enhancements](docs/enhancements.md) | Future improvements and platform support |

For testing instructions, see [README_TESTING.md](README_TESTING.md).

## Roadmap

- [x] Phase 0: Project bootstrap
- [x] Phase 1: Core VM management
- [x] Phase 2: VPN routing & network isolation
- [x] Phase 3: Provider daemon (local request processing)
- [x] Phase 4: Network discovery & multi-network support
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

- Built with Swift
- VM isolation via Apple Virtualization.framework (macOS) and QEMU/KVM (Linux)
- Network discovery via Kademlia DHT
- VPN tunneling via WireGuard
- gRPC and Protocol Buffers for serialization
