# Testing Omerta

## Unit Tests

Run the unit tests (no entitlements required):

```bash
swift test --filter OmertaCoreTests
swift test --filter ResourceAllocatorTests
```

All unit tests should pass.

## Integration Tests (VM Execution)

The VM execution tests require the `com.apple.security.virtualization` entitlement.

### Prerequisites

1. Setup Linux kernel:
```bash
./Scripts/setup-vm-kernel.sh
```

2. Build with release mode for better performance:
```bash
swift build -c release
```

### Running Integration Tests

Since Swift test binaries don't automatically get entitlements, you have two options:

**Option 1: Code sign the test binary** (requires Apple Developer account)
```bash
swift build --build-tests
codesign --entitlements Omerta.entitlements --force --sign - .build/debug/OmertaPackageTests.xctest/Contents/MacOS/OmertaPackageTests
swift test --filter VMExecutionTests
```

**Option 2: Create an Xcode project** (automatic entitlements)
```bash
swift package generate-xcodeproj
# Open in Xcode, add entitlements, run tests from Xcode
```

**Option 3: Manual testing via CLI** (simplest for development)

Create a test script and run via the omerta CLI once Phase 2+ is complete.

## Entitlements Required

The following entitlements are required for VM functionality:

- `com.apple.security.virtualization` - Create and manage VMs
- `com.apple.security.network.server` - Listen for gRPC connections  
- `com.apple.vm.networking` - VM network configuration

See `Omerta.entitlements` for the complete list.

## Known Limitations

- VM tests cannot run via `swift test` without code signing
- Linux kernel download requires internet connection
- VMs require significant RAM (recommend 8GB+ available)
- Apple Silicon (ARM64) Macs only for Linux VM support
