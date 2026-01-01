# Phase 4 Testing Checklist

**Status**: ⚠️ Requires macOS for Swift build and testing
**Commit**: 510d264

## Pre-Testing Setup (macOS Required)

### Build the Project

```bash
cd /path/to/omerta
swift build
```

**Expected**: Clean build with no errors

**Possible Issues to Fix**:
- Import resolution issues
- Actor isolation edge cases
- Missing module dependencies
- Sendable conformance issues

## Unit Testing Plan

### 1. NetworkManager Tests

**File to Create**: `Tests/OmertaNetworkTests/NetworkManagerTests.swift`

**Tests to Implement**:
- ✅ Test network creation with key generation
- ✅ Test network key encoding/decoding (omerta://join/...)
- ✅ Test joining a network
- ✅ Test leaving a network
- ✅ Test enable/disable network
- ✅ Test persistence (save and load networks)
- ✅ Test duplicate join prevention
- ✅ Test network not found errors

**Example Test**:
```swift
import XCTest
@testable import OmertaNetwork
@testable import OmertaCore

final class NetworkManagerTests: XCTestCase {
    func testNetworkCreation() async throws {
        let manager = NetworkManager(configPath: "/tmp/test-networks.json")

        let key = await manager.createNetwork(
            name: "Test Network",
            bootstrapEndpoint: "192.168.1.100:50051"
        )

        // Verify key can be encoded
        let encoded = try key.encode()
        XCTAssertTrue(encoded.hasPrefix("omerta://join/"))

        // Verify network was added
        let networks = await manager.getNetworks()
        XCTAssertEqual(networks.count, 1)
        XCTAssertEqual(networks[0].name, "Test Network")
    }

    func testNetworkKeyEncoding() throws {
        let key = NetworkKey.generate(
            networkName: "My Network",
            bootstrapEndpoint: "localhost:50051"
        )

        // Encode
        let encoded = try key.encode()
        XCTAssertTrue(encoded.hasPrefix("omerta://join/"))

        // Decode
        let decoded = try NetworkKey.decode(from: encoded)
        XCTAssertEqual(decoded.networkName, "My Network")
        XCTAssertEqual(decoded.bootstrapPeers, ["localhost:50051"])
    }
}
```

### 2. PeerRegistry Tests

**File to Create**: `Tests/OmertaNetworkTests/PeerRegistryTests.swift`

**Tests to Implement**:
- ✅ Test peer registration from announcement
- ✅ Test peer removal
- ✅ Test online/offline status tracking
- ✅ Test network-scoped peer organization
- ✅ Test finding peers by requirements
- ✅ Test peer filtering by CPU/memory/GPU
- ✅ Test stale peer cleanup
- ✅ Test peer statistics

**Example Test**:
```swift
func testPeerRegistration() async throws {
    let registry = PeerRegistry()

    let announcement = PeerAnnouncement.local(
        peerId: "peer-123",
        networkId: "network-abc",
        endpoint: "192.168.1.100:50051",
        capabilities: [
            ResourceCapability(
                type: .cpuOnly,
                availableCpuCores: 8,
                availableMemoryMb: 16384,
                hasGpu: false,
                gpu: nil,
                supportedWorkloadTypes: ["script", "binary"]
            )
        ]
    )

    await registry.registerPeer(from: announcement)

    let peers = await registry.getPeers(networkId: "network-abc")
    XCTAssertEqual(peers.count, 1)
    XCTAssertEqual(peers[0].peerId, "peer-123")
}

func testFindPeersByRequirements() async throws {
    let registry = PeerRegistry()

    // Register multiple peers with different capabilities
    // ... register peers ...

    let requirements = ResourceRequirements(
        type: .cpuOnly,
        cpuCores: 4,
        memoryMB: 8192
    )

    let matching = await registry.findPeers(
        networkId: "network-abc",
        requirements: requirements,
        maxResults: 10
    )

    // Verify all results meet requirements
    for peer in matching {
        XCTAssertGreaterThanOrEqual(peer.capabilities[0].availableCpuCores, 4)
        XCTAssertGreaterThanOrEqual(peer.capabilities[0].availableMemoryMb, 8192)
    }
}
```

### 3. PeerDiscovery Tests

**File to Create**: `Tests/OmertaNetworkTests/PeerDiscoveryTests.swift`

**Tests to Implement**:
- ✅ Test discovery start/stop
- ✅ Test periodic announcements
- ✅ Test peer registration
- ✅ Test finding peers in network
- ✅ Test cleanup of stale peers
- ✅ Test statistics

**Example Test**:
```swift
func testDiscoveryStartStop() async throws {
    let manager = NetworkManager(configPath: "/tmp/test-networks.json")
    let registry = PeerRegistry()

    let config = PeerDiscovery.Configuration(
        localPeerId: "test-peer",
        localEndpoint: "localhost:50051",
        announcementInterval: 1.0,  // Short interval for testing
        cleanupInterval: 2.0
    )

    let discovery = PeerDiscovery(
        config: config,
        networkManager: manager,
        peerRegistry: registry
    )

    await discovery.start()

    let stats = await discovery.getStatistics()
    XCTAssertTrue(stats.isRunning)

    await discovery.stop()

    let stats2 = await discovery.getStatistics()
    XCTAssertFalse(stats2.isRunning)
}
```

### 4. Converter Tests

**File to Create**: `Tests/OmertaNetworkTests/ConverterTests.swift`

**Tests to Implement**:
- ✅ Test ComputeJob <-> ComputeRequest conversion
- ✅ Test ResourceRequirements <-> Proto_ResourceRequirements
- ✅ Test VPNConfiguration <-> Proto_VPNConfiguration
- ✅ Test WorkloadSpec conversions (script and binary)
- ✅ Test ExecutionResult -> ComputeResponse
- ✅ Test error response creation

**Example Test**:
```swift
func testComputeJobConversion() throws {
    let job = ComputeJob(
        requesterId: "requester-123",
        networkId: "network-abc",
        requirements: ResourceRequirements(
            type: .cpuOnly,
            cpuCores: 4,
            memoryMB: 8192
        ),
        workload: .script(ScriptWorkload(
            language: "python",
            scriptContent: "print('hello')"
        )),
        vpnConfig: VPNConfiguration(
            wireguardConfig: "[Interface]...",
            endpoint: "192.168.1.100:51820",
            publicKey: Data([1, 2, 3]),
            vpnServerIP: "10.0.0.1"
        )
    )

    // Convert to proto
    let request = ComputeRequest.from(job, requesterId: "requester-123", networkId: "network-abc")

    // Verify conversion
    XCTAssertEqual(request.requestId, job.id.uuidString)
    XCTAssertEqual(request.metadata.peerId, "requester-123")
    XCTAssertEqual(request.requirements.cpuCores, 4)

    // Convert back to domain
    let converted = request.toComputeJob()

    XCTAssertEqual(converted.requesterId, job.requesterId)
    XCTAssertEqual(converted.requirements.cpuCores, job.requirements.cpuCores)
}
```

## Integration Testing

### 1. Network Creation & Joining Flow

**Test Steps**:
```bash
# Terminal 1: Create network
$ omerta network create --name "Test Network" --endpoint "localhost:50051"
# Copy the omerta://join/... key

# Terminal 2: Join network
$ omerta network join --key "omerta://join/..."

# Verify both terminals see the network
$ omerta network list
```

**Expected**:
- Network created successfully
- Key is base64-encoded JSON
- Join succeeds with the key
- Network appears in list on both machines

### 2. Network Persistence

**Test Steps**:
```bash
# Create a network
$ omerta network create --name "Persistent Test" --endpoint "localhost:50051"

# Check file was created
$ cat ~/Library/Application\ Support/Omerta/networks.json

# Exit and restart CLI
# List networks again
$ omerta network list
```

**Expected**:
- networks.json file created
- Network persists across CLI restarts
- JSON is valid and readable

### 3. Network Enable/Disable (when implemented)

**Test Steps**:
```bash
$ omerta network list
$ omerta network disable --id <network-id>
$ omerta network list  # Should show as paused
$ omerta network enable --id <network-id>
$ omerta network list  # Should show as active
```

### 4. Provider Daemon with gRPC Service

**Test Steps**:
```bash
# Start provider daemon
$ omertad start --port 50051

# In another terminal, check status
$ omertad status
```

**Expected**:
- Daemon starts without errors
- gRPC service is initialized
- ComputeServiceProvider is configured
- ProviderDaemon implements JobSubmissionHandler

## Build Issues to Watch For

### 1. Import Resolution
**Possible Error**:
```
error: no such module 'OmertaNetwork'
```

**Fix**: Ensure Package.swift dependencies are correct

### 2. Actor Isolation
**Possible Error**:
```
error: actor-isolated property cannot be referenced from nonisolated context
```

**Fix**: Add `await` or make calling context isolated

### 3. Sendable Conformance
**Possible Error**:
```
warning: type 'X' does not conform to the 'Sendable' protocol
```

**Fix**: Add `Sendable` conformance to types crossing actor boundaries

### 4. SwiftProtobuf Import
**Possible Error**:
```
error: no such module 'SwiftProtobuf'
```

**Fix**: May need to remove SwiftProtobuf import if not using actual protoc-generated code

### 5. Protocol Import
**Possible Error**:
```
error: cannot find 'OmertaNetwork.JobSubmissionHandler' in scope
```

**Fix**: Verify protocol is public and correctly imported

## Manual Smoke Tests

### Test 1: Network Key Generation
```bash
$ swift run omerta network create --name "Smoke Test" --endpoint "localhost:50051"
```
✅ Generates valid omerta://join/... key
✅ Key can be decoded back to NetworkKey

### Test 2: Multi-Network Support
```bash
$ swift run omerta network create --name "Network 1" --endpoint "localhost:50051"
$ swift run omerta network create --name "Network 2" --endpoint "localhost:50052"
$ swift run omerta network list
```
✅ Both networks appear
✅ Each has unique ID
✅ Can manage independently

### Test 3: CLI Version
```bash
$ swift run omerta --version
```
✅ Shows version 0.4.0

### Test 4: Help Text
```bash
$ swift run omerta network --help
```
✅ Shows all 5 subcommands
✅ Help text is clear

## Performance Testing

### Peer Registry Scale Test
- Register 100 peers
- Query peers with requirements
- Measure lookup time (should be < 100ms)

### Announcement Loop Test
- Start discovery with 30s interval
- Monitor for 5 minutes
- Verify announcements happen on schedule
- Check memory usage (should be stable)

## Known Issues (Expected)

1. ⚠️ **Build on Linux**: Will fail (no Swift toolchain)
2. ⚠️ **SwiftProtobuf**: May need to be removed from imports
3. ⚠️ **System Resource Detection**: Returns placeholder values
4. ⚠️ **Authentication**: Signatures are empty Data()
5. ⚠️ **gRPC Streaming**: Not implemented (polls instead)

## Testing Checklist

**Build & Compile**:
- [ ] `swift build` succeeds
- [ ] No compiler errors
- [ ] No critical warnings

**Unit Tests**:
- [ ] NetworkManager tests pass
- [ ] PeerRegistry tests pass
- [ ] PeerDiscovery tests pass
- [ ] Converter tests pass

**Integration Tests**:
- [ ] Network creation works
- [ ] Network joining works
- [ ] Network persistence works
- [ ] Multi-network support works
- [ ] CLI commands work

**Manual Tests**:
- [ ] Generate and decode network keys
- [ ] Create multiple networks
- [ ] Join network with key
- [ ] List networks
- [ ] Show network details
- [ ] Leave network

**Performance Tests**:
- [ ] Peer registry handles 100+ peers
- [ ] Discovery announcements on schedule
- [ ] Memory usage is stable

## Next Steps After Testing

Once testing passes on macOS:

1. **Fix any build issues** found
2. **Implement missing tests**
3. **Benchmark performance**
4. **Document any platform-specific issues**
5. **Update PHASE4_SUMMARY.md** with test results
6. **Proceed to Phase 5** (Consumer Client & E2E)

## Test Results (To Be Filled In)

**Build Status**:
- Platform:
- Swift Version:
- Result:

**Test Results**:
- Unit Tests:
- Integration Tests:
- Manual Tests:

**Issues Found**:
1.
2.
3.

**Fixes Applied**:
1.
2.
3.
