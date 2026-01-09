# Native macOS WireGuard Implementation Architecture

## Overview

This document outlines the architecture for completing the native WireGuard implementation on macOS using **GotaTun** (Mullvad's Rust WireGuard library). GotaTun is a BSD-3-Clause licensed fork of Cloudflare's BoringTun with improved architecture and active maintenance.

## System Context

### How WireGuard Fits in Omerta

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Consumer (Linux)                                   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                     EphemeralVPN Server                              │   │
│  │  - Creates WireGuard server (wgXXXXXXXX interface)                   │   │
│  │  - Listens on port 51900                                             │   │
│  │  - VPN IP: 10.99.0.1                                                 │   │
│  │  - Uses kernel WireGuard via netlink                                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                     ▲                                        │
└─────────────────────────────────────┼────────────────────────────────────────┘
                                      │ WireGuard Tunnel
                                      │ (Encrypted UDP)
┌─────────────────────────────────────┼────────────────────────────────────────┐
│                                     ▼                                        │
│                           Provider (macOS)                                   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                  ProviderVPNManager + GotaTun                        │   │
│  │  - Creates WireGuard client (utunN interface)                        │   │
│  │  - Connects to consumer's WireGuard server                           │   │
│  │  - VPN IP: 10.99.0.2                                                 │   │
│  │  - Uses GotaTun for Noise protocol                                   │   │
│  └──────────────────────────────┬──────────────────────────────────────┘   │
│                                 │                                            │
│                                 │ pf NAT/RDR rules                           │
│                                 ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                          VM Instance                                 │   │
│  │  - VZNATNetworkDeviceAttachment (192.168.64.x)                       │   │
│  │  - All traffic NAT'd through host to WireGuard                       │   │
│  │  - VM appears on VPN as 10.99.0.2                                    │   │
│  │  - Can only reach consumer through tunnel                            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Key Insight: Provider is WireGuard Client

The provider's WireGuard acts as a **client** connecting to the consumer's server:
- Consumer hosts the VPN server (EphemeralVPN creates wg interface)
- Provider initiates connection to consumer's endpoint
- GotaTun is specifically designed as a "client-side" implementation - perfect for this

### Traffic Flow

1. **Consumer** creates EphemeralVPN server, sends config to provider
2. **Provider** starts GotaTun with consumer's public key and endpoint
3. **GotaTun** creates utun interface, initiates Noise handshake
4. **Handshake completes**, session keys derived
5. **pf rules** route VM traffic (192.168.64.x) through WireGuard (utunN)
6. **VM traffic** encrypted by GotaTun, sent to consumer
7. **Consumer** decrypts, routes to destination

## Current State

### What's Implemented (Swift)

#### MacOSWireGuardManager.swift
- **utun Interface Creation**: Via `MacOSUtunManager.createInterface()` - working
- **IP Address Assignment**: `addIPv4Address()` - working
- **MTU Configuration**: `setMTU()` - working
- **Route Setup**: `addRoute()` for allowed IPs - working
- **UDP Socket**: Created and bound for WireGuard protocol - working
- **Packet Processing Loop**: Reads from utun and UDP socket - working
- **ChaCha20-Poly1305**: Implemented but needs session keys from handshake

#### What's NOT Implemented (The Problem)
- **Noise_IKpsk2 Handshake**: Only stubs, never completes
- **Session Key Derivation**: `sharedSecret` never populated
- **Result**: Ping fails with "Required key not available"

### Why Native Matters

| Approach | Pros | Cons |
|----------|------|------|
| wg-quick | Works | Requires Homebrew, external binary |
| Network Extension | Signed by Apple | Complex entitlements, App Store only |
| Native (GotaTun) | No deps, works everywhere | Need to integrate library |

For a CLI tool that runs as root, native is the cleanest solution.

## Solution: GotaTun Device Module (Recommended)

### Why GotaTun Device (Option B)?

Rather than calling GotaTun for crypto only (Option A), let GotaTun's Device module handle everything:

| Concern | Option A (Crypto Only) | Option B (Full Device) |
|---------|------------------------|------------------------|
| Code we write | Packet loops, timer loops | Just start/stop/status |
| FFI calls | Per-packet (high frequency) | Start, stop, stats (low frequency) |
| Battle-tested | Our loops might have bugs | Mullvad's production code |
| Maintenance | We maintain packet handling | GotaTun maintains it |
| Performance | FFI overhead per packet | Native Rust performance |

**Recommendation**: Option B - simpler, safer, less code.

### GotaTun Device Architecture

```rust
// gotatun/src/device/mod.rs
pub struct Device<T> {
    // Tunnel state
    private_key: StaticSecret,
    peers: HashMap<PublicKey, Peer>,

    // Network interfaces
    tun_tx: TunWriter,  // Writes to utun
    tun_rx: TunReader,  // Reads from utun

    // UDP transport
    udp_socket: UdpSocket,

    // Peer management
    peer_by_index: HashMap<u32, Peer>,
    peer_by_ip: IpLookupTable<Peer>,
}

// Key methods
impl Device {
    fn handle_incoming(&mut self, packet: &[u8])  // UDP -> decrypt -> TUN
    fn handle_outgoing(&mut self, packet: &[u8])  // TUN -> encrypt -> UDP
    fn handle_timers(&mut self)                    // Keepalives, rekey
}
```

GotaTun's Device module:
- Creates and manages utun interface
- Manages UDP socket for WireGuard protocol
- Runs async packet processing loops (tokio)
- Handles handshakes, keepalives, rekey automatically
- Tracks peer state and session keys

### Integration Architecture (Option B)

```
┌─────────────────────────────────────────────────────────────────┐
│                     Swift (macOS)                                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │              ProviderVPNManager                              ││
│  │  1. Calls gotatun_device_start(config)                       ││
│  │  2. Gets interface name back (utunN)                         ││
│  │  3. Sets up pf rules using interface name                    ││
│  │  4. Periodically calls gotatun_device_stats()                ││
│  │  5. Calls gotatun_device_stop() on cleanup                   ││
│  └─────────────────────────────────────────────────────────────┘│
│                            │                                     │
│                            │ C FFI (simple: start/stop/stats)    │
│                            ▼                                     │
└────────────────────────────┼─────────────────────────────────────┘
                             │
┌────────────────────────────┼─────────────────────────────────────┐
│                            ▼                                     │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │              GotaTun Device                                  ││
│  │  - Creates utun interface automatically                      ││
│  │  - Manages UDP socket                                        ││
│  │  - Runs tokio async runtime internally                       ││
│  │  - Handles Noise handshake                                   ││
│  │  - Encrypts/decrypts all packets                             ││
│  │  - Sends keepalives                                          ││
│  │  - Rekeys when needed                                        ││
│  └─────────────────────────────────────────────────────────────┘│
│                      Rust (libgotatun.a)                         │
└──────────────────────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Add FFI to GotaTun (4-6 hours)

#### 1.1 Fork GotaTun
```bash
cd ${OMERTA_DIR}
git submodule add https://github.com/mullvad/gotatun.git vendor/gotatun
cd vendor/gotatun
```

#### 1.2 Create FFI Module

Create `vendor/gotatun/gotatun/src/ffi.rs`:

```rust
//! C FFI for GotaTun Device
//!
//! Provides a simple interface for Swift to start/stop WireGuard tunnels.

use std::ffi::{c_char, c_void, CStr};
use std::ptr;
use std::sync::Arc;
use tokio::runtime::Runtime;
use crate::device::Device;

/// Opaque handle to a running device
pub struct DeviceHandle {
    runtime: Runtime,
    // Device runs inside the runtime
    interface_name: String,
}

/// Device configuration passed from Swift
#[repr(C)]
pub struct DeviceConfig {
    /// Our WireGuard private key (base64, null-terminated)
    pub private_key: *const c_char,

    /// Peer's public key (base64, null-terminated)
    pub peer_public_key: *const c_char,

    /// Peer's endpoint (e.g., "192.168.1.100:51900", null-terminated)
    pub peer_endpoint: *const c_char,

    /// Our VPN IP address (e.g., "10.99.0.2", null-terminated)
    pub address: *const c_char,

    /// Allowed IPs (e.g., "10.99.0.0/24", null-terminated)
    pub allowed_ips: *const c_char,

    /// Pre-shared key (base64, null-terminated, can be NULL)
    pub preshared_key: *const c_char,

    /// Keepalive interval in seconds (0 = disabled)
    pub keepalive_secs: u16,
}

/// Device statistics
#[repr(C)]
pub struct DeviceStats {
    pub tx_bytes: u64,
    pub rx_bytes: u64,
    pub last_handshake_secs: u64,  // Seconds since last handshake, 0 = never
    pub is_connected: bool,
}

/// Result codes
#[repr(C)]
pub enum ResultCode {
    Ok = 0,
    ErrorInvalidConfig = -1,
    ErrorStartFailed = -2,
    ErrorNotRunning = -3,
    ErrorInvalidHandle = -4,
}

/// Start a WireGuard device
///
/// Returns a handle on success, NULL on failure.
/// The interface name is written to `interface_name_out` (must be at least 16 bytes).
///
/// # Safety
/// - All string pointers in config must be valid null-terminated UTF-8
/// - interface_name_out must point to at least 16 bytes of writable memory
#[no_mangle]
pub unsafe extern "C" fn gotatun_device_start(
    config: *const DeviceConfig,
    interface_name_out: *mut c_char,
) -> *mut DeviceHandle {
    if config.is_null() || interface_name_out.is_null() {
        return ptr::null_mut();
    }

    let config = &*config;

    // Parse configuration
    let private_key = match parse_string(config.private_key) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };
    let peer_public_key = match parse_string(config.peer_public_key) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };
    let peer_endpoint = match parse_string(config.peer_endpoint) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };
    let address = match parse_string(config.address) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };
    let allowed_ips = match parse_string(config.allowed_ips) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };
    let preshared_key = parse_string(config.preshared_key); // Optional

    // Create tokio runtime
    let runtime = match Runtime::new() {
        Ok(rt) => rt,
        Err(_) => return ptr::null_mut(),
    };

    // Start device in runtime
    let interface_name = match runtime.block_on(async {
        start_device(
            &private_key,
            &peer_public_key,
            &peer_endpoint,
            &address,
            &allowed_ips,
            preshared_key.as_deref(),
            config.keepalive_secs,
        ).await
    }) {
        Ok(name) => name,
        Err(_) => return ptr::null_mut(),
    };

    // Write interface name to output buffer
    let name_bytes = interface_name.as_bytes();
    if name_bytes.len() >= 15 {
        return ptr::null_mut(); // Name too long
    }
    ptr::copy_nonoverlapping(
        name_bytes.as_ptr(),
        interface_name_out as *mut u8,
        name_bytes.len(),
    );
    *interface_name_out.add(name_bytes.len()) = 0; // Null terminate

    // Return handle
    Box::into_raw(Box::new(DeviceHandle {
        runtime,
        interface_name,
    }))
}

/// Stop a WireGuard device
///
/// # Safety
/// - handle must be a valid pointer from gotatun_device_start, or NULL
#[no_mangle]
pub unsafe extern "C" fn gotatun_device_stop(handle: *mut DeviceHandle) -> ResultCode {
    if handle.is_null() {
        return ResultCode::ErrorInvalidHandle;
    }

    let handle = Box::from_raw(handle);

    // Runtime drops when handle is dropped, stopping all tasks
    drop(handle);

    ResultCode::Ok
}

/// Get device statistics
///
/// # Safety
/// - handle must be a valid pointer from gotatun_device_start
/// - stats_out must point to valid DeviceStats memory
#[no_mangle]
pub unsafe extern "C" fn gotatun_device_stats(
    handle: *const DeviceHandle,
    stats_out: *mut DeviceStats,
) -> ResultCode {
    if handle.is_null() || stats_out.is_null() {
        return ResultCode::ErrorInvalidHandle;
    }

    // TODO: Query actual stats from device
    // For now, return placeholder indicating connected
    (*stats_out) = DeviceStats {
        tx_bytes: 0,
        rx_bytes: 0,
        last_handshake_secs: 0,
        is_connected: true,
    };

    ResultCode::Ok
}

/// Get the interface name for a running device
///
/// # Safety
/// - handle must be a valid pointer from gotatun_device_start
/// - name_out must point to at least 16 bytes of writable memory
#[no_mangle]
pub unsafe extern "C" fn gotatun_device_interface_name(
    handle: *const DeviceHandle,
    name_out: *mut c_char,
) -> ResultCode {
    if handle.is_null() || name_out.is_null() {
        return ResultCode::ErrorInvalidHandle;
    }

    let handle = &*handle;
    let name_bytes = handle.interface_name.as_bytes();

    ptr::copy_nonoverlapping(
        name_bytes.as_ptr(),
        name_out as *mut u8,
        name_bytes.len(),
    );
    *name_out.add(name_bytes.len()) = 0;

    ResultCode::Ok
}

// Helper to parse C string
unsafe fn parse_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}

// Internal: Start the device (called from FFI)
async fn start_device(
    private_key: &str,
    peer_public_key: &str,
    peer_endpoint: &str,
    address: &str,
    allowed_ips: &str,
    preshared_key: Option<&str>,
    keepalive_secs: u16,
) -> Result<String, Box<dyn std::error::Error>> {
    // TODO: Implement using GotaTun's Device API
    // 1. Parse keys from base64
    // 2. Create Device with config
    // 3. Add peer
    // 4. Start device (creates utun, binds UDP)
    // 5. Return interface name

    // Placeholder - will be implemented using gotatun::device
    Ok("utun99".to_string())
}
```

#### 1.3 Create C Header

Create `vendor/gotatun/include/gotatun.h`:

```c
#ifndef GOTATUN_H
#define GOTATUN_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a running WireGuard device
typedef struct DeviceHandle DeviceHandle;

/// Device configuration
typedef struct {
    const char* private_key;      // Base64-encoded private key
    const char* peer_public_key;  // Base64-encoded peer public key
    const char* peer_endpoint;    // Peer endpoint (e.g., "192.168.1.100:51900")
    const char* address;          // Our VPN address (e.g., "10.99.0.2")
    const char* allowed_ips;      // Allowed IPs (e.g., "10.99.0.0/24")
    const char* preshared_key;    // Optional PSK (NULL if none)
    uint16_t keepalive_secs;      // Keepalive interval (0 = disabled)
} DeviceConfig;

/// Device statistics
typedef struct {
    uint64_t tx_bytes;
    uint64_t rx_bytes;
    uint64_t last_handshake_secs;  // 0 = never
    bool is_connected;
} DeviceStats;

/// Result codes
typedef enum {
    GOTATUN_OK = 0,
    GOTATUN_ERROR_INVALID_CONFIG = -1,
    GOTATUN_ERROR_START_FAILED = -2,
    GOTATUN_ERROR_NOT_RUNNING = -3,
    GOTATUN_ERROR_INVALID_HANDLE = -4,
} GotatunResult;

/// Start a WireGuard device
///
/// @param config Device configuration
/// @param interface_name_out Buffer for interface name (at least 16 bytes)
/// @return Handle on success, NULL on failure
DeviceHandle* gotatun_device_start(
    const DeviceConfig* config,
    char* interface_name_out
);

/// Stop a WireGuard device
///
/// @param handle Device handle from gotatun_device_start
/// @return GOTATUN_OK on success
GotatunResult gotatun_device_stop(DeviceHandle* handle);

/// Get device statistics
///
/// @param handle Device handle
/// @param stats_out Output statistics
/// @return GOTATUN_OK on success
GotatunResult gotatun_device_stats(
    const DeviceHandle* handle,
    DeviceStats* stats_out
);

/// Get interface name for a device
///
/// @param handle Device handle
/// @param name_out Buffer for name (at least 16 bytes)
/// @return GOTATUN_OK on success
GotatunResult gotatun_device_interface_name(
    const DeviceHandle* handle,
    char* name_out
);

#ifdef __cplusplus
}
#endif

#endif // GOTATUN_H
```

#### 1.4 Update Cargo.toml

Add to `vendor/gotatun/gotatun/Cargo.toml`:

```toml
[lib]
crate-type = ["staticlib", "cdylib", "rlib"]

[features]
default = ["device"]
ffi = ["device"]  # FFI requires device feature
```

#### 1.5 Build Script

Create `vendor/gotatun/build-macos.sh`:

```bash
#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building GotaTun for macOS..."

# Build for both architectures
cargo build --release --features ffi --target x86_64-apple-darwin
cargo build --release --features ffi --target aarch64-apple-darwin

# Create universal binary
mkdir -p target/universal
lipo -create \
    target/x86_64-apple-darwin/release/libgotatun.a \
    target/aarch64-apple-darwin/release/libgotatun.a \
    -output target/universal/libgotatun.a

echo "Built: $(pwd)/target/universal/libgotatun.a"
echo ""
echo "To use in Swift:"
echo "  1. Add to Package.swift as systemLibrary"
echo "  2. Link with -lgotatun"
echo "  3. Include header from include/gotatun.h"
```

### Phase 2: Swift Bridge (2-3 hours)

#### 2.1 Module Map

Create `Sources/OmertaNetwork/VPN/GotaTun/module.modulemap`:

```
module CGotaTun [system] {
    header "gotatun.h"
    link "gotatun"
    export *
}
```

#### 2.2 Swift Wrapper

Create `Sources/OmertaNetwork/VPN/GotaTun/GotaTunDevice.swift`:

```swift
#if os(macOS)
import Foundation
import CGotaTun

/// Swift wrapper for GotaTun WireGuard Device
public final class GotaTunDevice: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let interfaceName: String
    private let lock = NSLock()

    /// Device statistics
    public struct Stats {
        public let txBytes: UInt64
        public let rxBytes: UInt64
        public let lastHandshakeSeconds: UInt64
        public let isConnected: Bool
    }

    /// Device configuration
    public struct Config {
        public let privateKey: String        // Base64
        public let peerPublicKey: String     // Base64
        public let peerEndpoint: String      // "ip:port"
        public let address: String           // Our VPN IP
        public let allowedIPs: String        // CIDR notation
        public let presharedKey: String?     // Optional base64 PSK
        public let keepaliveSeconds: UInt16

        public init(
            privateKey: String,
            peerPublicKey: String,
            peerEndpoint: String,
            address: String,
            allowedIPs: String = "0.0.0.0/0",
            presharedKey: String? = nil,
            keepaliveSeconds: UInt16 = 25
        ) {
            self.privateKey = privateKey
            self.peerPublicKey = peerPublicKey
            self.peerEndpoint = peerEndpoint
            self.address = address
            self.allowedIPs = allowedIPs
            self.presharedKey = presharedKey
            self.keepaliveSeconds = keepaliveSeconds
        }
    }

    public enum Error: Swift.Error {
        case invalidConfig
        case startFailed
        case notRunning
        case invalidHandle
    }

    /// Start a WireGuard device
    public init(config: Config) throws {
        var interfaceNameBuffer = [CChar](repeating: 0, count: 16)

        let result = config.privateKey.withCString { privateKey in
            config.peerPublicKey.withCString { peerPublicKey in
                config.peerEndpoint.withCString { peerEndpoint in
                    config.address.withCString { address in
                        config.allowedIPs.withCString { allowedIPs in
                            if let psk = config.presharedKey {
                                return psk.withCString { presharedKey in
                                    var deviceConfig = DeviceConfig(
                                        private_key: privateKey,
                                        peer_public_key: peerPublicKey,
                                        peer_endpoint: peerEndpoint,
                                        address: address,
                                        allowed_ips: allowedIPs,
                                        preshared_key: presharedKey,
                                        keepalive_secs: config.keepaliveSeconds
                                    )
                                    return gotatun_device_start(&deviceConfig, &interfaceNameBuffer)
                                }
                            } else {
                                var deviceConfig = DeviceConfig(
                                    private_key: privateKey,
                                    peer_public_key: peerPublicKey,
                                    peer_endpoint: peerEndpoint,
                                    address: address,
                                    allowed_ips: allowedIPs,
                                    preshared_key: nil,
                                    keepalive_secs: config.keepaliveSeconds
                                )
                                return gotatun_device_start(&deviceConfig, &interfaceNameBuffer)
                            }
                        }
                    }
                }
            }
        }

        guard let handle = result else {
            throw Error.startFailed
        }

        self.handle = handle
        self.interfaceName = String(cString: interfaceNameBuffer)
    }

    deinit {
        stop()
    }

    /// Stop the device
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        if let handle = handle {
            gotatun_device_stop(handle)
            self.handle = nil
        }
    }

    /// Get the interface name (e.g., "utun5")
    public func getInterfaceName() -> String {
        return interfaceName
    }

    /// Get device statistics
    public func getStats() throws -> Stats {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = handle else {
            throw Error.notRunning
        }

        var stats = DeviceStats()
        let result = gotatun_device_stats(handle, &stats)

        guard result == GOTATUN_OK else {
            throw Error.invalidHandle
        }

        return Stats(
            txBytes: stats.tx_bytes,
            rxBytes: stats.rx_bytes,
            lastHandshakeSeconds: stats.last_handshake_secs,
            isConnected: stats.is_connected
        )
    }

    /// Check if handshake has completed
    public func isHandshakeComplete() -> Bool {
        guard let stats = try? getStats() else { return false }
        return stats.lastHandshakeSeconds > 0 || stats.isConnected
    }
}
#endif
```

### Phase 3: Integration with ProviderVPNManager (3-4 hours)

Update `Sources/OmertaProvider/ProviderVPNManager.swift`:

```swift
#if os(macOS)
import OmertaNetwork

public actor ProviderVPNManager {
    private var gotatunDevices: [UUID: GotaTunDevice] = [:]

    /// Start WireGuard for a VM using GotaTun
    public func startWireGuard(
        vmId: UUID,
        privateKey: String,
        peerPublicKey: String,
        peerEndpoint: String,
        vpnIP: String,
        presharedKey: String? = nil
    ) async throws -> String {

        let config = GotaTunDevice.Config(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            peerEndpoint: peerEndpoint,
            address: vpnIP,
            allowedIPs: "0.0.0.0/0",
            presharedKey: presharedKey,
            keepaliveSeconds: 25
        )

        let device = try GotaTunDevice(config: config)
        let interfaceName = device.getInterfaceName()

        gotatunDevices[vmId] = device

        logger.info("GotaTun started", metadata: [
            "vm_id": "\(vmId)",
            "interface": "\(interfaceName)"
        ])

        // Wait for handshake to complete
        for _ in 0..<30 {  // 3 second timeout
            if device.isHandshakeComplete() {
                logger.info("WireGuard handshake complete", metadata: [
                    "vm_id": "\(vmId)"
                ])
                return interfaceName
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw WireGuardError.handshakeTimeout
    }

    /// Stop WireGuard for a VM
    public func stopWireGuard(vmId: UUID) async {
        if let device = gotatunDevices.removeValue(forKey: vmId) {
            device.stop()
            logger.info("GotaTun stopped", metadata: ["vm_id": "\(vmId)"])
        }
    }

    /// Get interface name for a VM
    public func getInterfaceName(vmId: UUID) async -> String? {
        return gotatunDevices[vmId]?.getInterfaceName()
    }
}
#endif
```

### Phase 4: Build System (2-3 hours)

#### 4.1 Update Package.swift

```swift
// In Package.swift
let package = Package(
    name: "Omerta",
    platforms: [.macOS(.v14)],
    products: [...],
    dependencies: [...],
    targets: [
        // GotaTun C library
        .systemLibrary(
            name: "CGotaTun",
            path: "Sources/CGotaTun",
            pkgConfig: nil,
            providers: []
        ),

        .target(
            name: "OmertaNetwork",
            dependencies: [
                "OmertaCore",
                .target(name: "CGotaTun", condition: .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .linkedLibrary("gotatun", .when(platforms: [.macOS])),
                .unsafeFlags(["-L", "vendor/gotatun/target/universal"], .when(platforms: [.macOS])),
            ]
        ),
        // ... other targets
    ]
)
```

#### 4.2 Create CGotaTun Target

Create `Sources/CGotaTun/module.modulemap`:
```
module CGotaTun [system] {
    header "../../vendor/gotatun/include/gotatun.h"
    link "gotatun"
    export *
}
```

Create `Sources/CGotaTun/shim.h`:
```c
#include "../../vendor/gotatun/include/gotatun.h"
```

#### 4.3 Update Build Scripts

Add to build process:
```bash
#!/bin/bash
# scripts/build.sh

set -e

# Build GotaTun first (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
    echo "Building GotaTun..."
    (cd vendor/gotatun && ./build-macos.sh)
fi

# Build Swift
swift build -c release
```

### Phase 5: Testing (3-4 hours)

#### 5.1 Unit Tests

```swift
// Tests/OmertaNetworkTests/GotaTunDeviceTests.swift

#if os(macOS)
import XCTest
@testable import OmertaNetwork

final class GotaTunDeviceTests: XCTestCase {

    func testDeviceCreation() throws {
        // Generate test keys
        let privateKey = "WEFKRUZIQUtKU0hES0pGSERTS0pGSERTOUtKRkg="  // Dummy
        let peerPublicKey = "UEVFUktFWVBFRVJLRVlQRUVSS0VZUEVFUktFWT0="

        let config = GotaTunDevice.Config(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            peerEndpoint: "127.0.0.1:51820",
            address: "10.99.0.2"
        )

        // This will fail without a real peer, but tests FFI linkage
        XCTAssertThrowsError(try GotaTunDevice(config: config))
    }

    func testInterfaceNameFormat() throws {
        // Test that interface names match expected pattern
        let pattern = "^utun[0-9]+$"
        XCTAssertNotNil("utun5".range(of: pattern, options: .regularExpression))
        XCTAssertNotNil("utun123".range(of: pattern, options: .regularExpression))
        XCTAssertNil("wg0".range(of: pattern, options: .regularExpression))
    }
}
#endif
```

#### 5.2 Integration Tests

```swift
// Tests/OmertaNetworkTests/WireGuardIntegrationTests.swift

final class WireGuardIntegrationTests: XCTestCase {

    /// Test handshake between GotaTun (macOS) and kernel WireGuard (Linux)
    func testGotaTunToLinuxKernel() async throws {
        // Requires Linux VM or container with WireGuard
        // 1. Start WireGuard server on Linux
        // 2. Connect with GotaTun
        // 3. Verify handshake completes
        // 4. Send ping, verify response
    }

    /// Full VM flow test
    func testFullVMConnectivity() async throws {
        // 1. Start consumer with EphemeralVPN
        // 2. Start provider, request VM
        // 3. Provider uses GotaTun to connect
        // 4. Verify SSH to VM works through tunnel
    }
}
```

## File Summary

### New Files

| File | Purpose |
|------|---------|
| `vendor/gotatun/` | Git submodule |
| `vendor/gotatun/gotatun/src/ffi.rs` | Rust FFI bindings |
| `vendor/gotatun/include/gotatun.h` | C header |
| `vendor/gotatun/build-macos.sh` | Build script |
| `Sources/CGotaTun/module.modulemap` | Swift module map |
| `Sources/CGotaTun/shim.h` | Header shim |
| `Sources/OmertaNetwork/VPN/GotaTun/GotaTunDevice.swift` | Swift wrapper |
| `Tests/OmertaNetworkTests/GotaTunDeviceTests.swift` | Unit tests |

### Modified Files

| File | Changes |
|------|---------|
| `Package.swift` | Add CGotaTun target, linker settings |
| `Sources/OmertaProvider/ProviderVPNManager.swift` | Use GotaTunDevice |
| `scripts/build.sh` | Build GotaTun before Swift |

## Security Alignment

This implementation maintains all security guarantees from `SECURITY_ARCHITECTURE.md`:

| Security Property | How GotaTun Maintains It |
|-------------------|-------------------------|
| All VM traffic through VPN | pf rules route VM traffic to GotaTun's utun |
| Provider network isolated | VM only reaches consumer through tunnel |
| Encrypted traffic | GotaTun handles ChaCha20-Poly1305 |
| Handshake verification | GotaTun completes Noise_IKpsk2 |
| No external dependencies | GotaTun compiles to static library |

## PSK Integration

The network key from network joining flows through:

```swift
// ConsumerClient creates VPN config
let vpnConfig = VPNConfiguration(
    consumerPublicKey: myPublicKey,
    consumerEndpoint: "\(myIP):51900",
    presharedKey: deriveWireGuardPSK(from: network.sharedKey)  // Network key becomes PSK
)

// Provider receives config, passes to GotaTun
let device = try GotaTunDevice(config: GotaTunDevice.Config(
    privateKey: providerPrivateKey,
    peerPublicKey: vpnConfig.consumerPublicKey,
    peerEndpoint: vpnConfig.consumerEndpoint,
    address: "10.99.0.2",
    presharedKey: vpnConfig.presharedKey  // PSK from network key
))
```

## License Compliance

GotaTun uses BSD-3-Clause. Include in app bundle:

```
# Resources/Licenses/GOTATUN.txt

GotaTun - WireGuard Implementation
Copyright (c) Mullvad VPN AB
Copyright (c) Cloudflare, Inc.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. [...]
```

## Timeline

| Phase | Effort | Dependencies |
|-------|--------|--------------|
| Phase 1: GotaTun FFI | 4-6 hours | Rust toolchain |
| Phase 2: Swift Bridge | 2-3 hours | Phase 1 |
| Phase 3: Integration | 3-4 hours | Phase 2 |
| Phase 4: Build System | 2-3 hours | Phase 3 |
| Phase 5: Testing | 3-4 hours | Phase 4 |
| **Total** | **~2-3 days** | |

## References

- [GotaTun Repository](https://github.com/mullvad/gotatun)
- [WireGuard Protocol](https://www.wireguard.com/protocol/)
- [Noise Protocol Framework](https://noiseprotocol.org/noise.html)
- [Omerta Security Architecture](../SECURITY_ARCHITECTURE.md)
- [Omerta Network Architecture](../NETWORK_ARCHITECTURE_CLARIFICATION.md)
