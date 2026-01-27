# VM Network Test Plan

This document covers security, performance, and reliability testing for the VM network architecture.

**Related Documents:**
- [Architecture Overview](vm-network-architecture.md) - Design, security model, and mode comparison
- [Implementation Details](vm-network-implementation.md) - Phased implementation plan and code

## Security Checklist

- [ ] FilteredNAT only allows consumer endpoint
- [ ] Inbound packets only accepted from consumer
- [ ] No path for VM to reach internet
- [ ] No path for VM to reach provider LAN
- [ ] No path for VM to reach provider host
- [ ] VM iptables configured as defense in depth
- [ ] Logging of blocked traffic for debugging
- [ ] No sensitive data in logs

## Test Plan

### Unit Tests

#### EthernetFrame Parser (`EthernetFrameTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testParseValidIPv4Frame` | Parse well-formed IPv4 ethernet frame | Correct MAC addresses, etherType=0x0800 |
| `testParseValidARPFrame` | Parse ARP frame | etherType=0x0806 |
| `testParseIPv6Frame` | Parse IPv6 frame | etherType=0x86DD |
| `testParseTruncatedFrame` | Frame < 14 bytes | Returns nil |
| `testParseEmptyPayload` | Valid header, no payload | Valid frame with empty payload |
| `testRoundTrip` | Parse then serialize | Identical bytes |
| `testMACAddressExtraction` | Various MAC addresses | Correct 6-byte extraction |

#### IPv4Packet Parser (`IPv4PacketTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testParseValidUDPPacket` | Standard UDP packet | Correct src/dst IP, proto=17 |
| `testParseValidTCPPacket` | Standard TCP packet | Correct src/dst IP, proto=6 |
| `testParseICMPPacket` | ICMP echo request | proto=1 |
| `testParseWithIPOptions` | IP header with options | Correct header length |
| `testParseTruncatedHeader` | Packet < 20 bytes | Returns nil |
| `testParseInvalidHeaderLength` | IHL field too small | Returns nil |
| `testDestinationPortUDP` | UDP destination port | Correct port extraction |
| `testDestinationPortTCP` | TCP destination port | Correct port extraction |
| `testUDPPayloadExtraction` | Extract UDP payload | Correct offset |

#### FilteredNAT Allowlist (`FilteredNATTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testAllowedEndpointPasses` | Packet to allowed endpoint | Forwarded |
| `testBlockedEndpointDropped` | Packet to non-allowed endpoint | Dropped, logged |
| `testEmptyAllowlistBlocksAll` | No endpoints configured | All packets dropped |
| `testMultipleAllowedEndpoints` | Two allowed endpoints | Both pass, others blocked |
| `testPortMismatchBlocked` | Correct IP, wrong port | Dropped |
| `testIPMismatchBlocked` | Wrong IP, correct port | Dropped |
| `testInboundFromAllowed` | Response from consumer | Accepted |
| `testInboundFromUnknown` | Packet from random IP | Dropped |
| `testSetAllowedEndpoint` | Update allowlist | New endpoint allowed |

#### Filtering Strategies (`FilteringStrategyTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testFullFilterAllowsValidTraffic` | Packet to consumer | `.forward` |
| `testFullFilterDropsInvalidTraffic` | Packet to random IP | `.drop` |
| `testConntrackFirstPacketChecked` | First packet | Allowlist consulted |
| `testConntrackRepeatPacketFastPath` | Second packet to same endpoint | No allowlist check |
| `testConntrackBadFlowTerminates` | Packet to non-allowed endpoint | `.terminate` |
| `testSampledSkipsMostPackets` | 1000 packets at 1% rate | ~990 not checked |
| `testSampledCatchesViolation` | Bad packet in sample | `.terminate` |

#### Network Mode Selection (`VMNetworkManagerTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testDirectModeCreatesNATAttachment` | Create with `.direct` | `VZNATNetworkDeviceAttachment` |
| `testFilteredModeCreatesFileHandle` | Create with `.filtered` | `VZFileHandleNetworkDeviceAttachment` |
| `testConntrackModeUsesConntrackStrategy` | Create with `.conntrack` | ConntrackStrategy instance |
| `testSampledModeUsesSampledStrategy` | Create with `.sampled` | SampledStrategy instance |
| `testSamplingRateConfigurable` | Set sampling rate to 5% | Strategy uses 0.05 |
| `testCleanupStopsBackgroundTasks` | Stop network handle | Task cancelled |

### Integration Tests

#### VM Network Setup (`VMNetworkIntegrationTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testFileHandleAttachmentCreation` | Create VZFileHandleNetworkDeviceAttachment | Valid attachment |
| `testVMReceivesFrames` | Send frame to VM handle | VM sees frame on eth0 |
| `testVMSendsFrames` | VM sends packet | Frame readable from host |
| `testARPResolution` | VM ARP request | Responded or forwarded |
| `testDHCPOptional` | VM boots without DHCP | Static IP works |

#### End-to-End Connectivity (`E2EConnectivityTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMToConsumerPing` | Ping consumer from VM | ICMP reaches consumer |
| `testVMToConsumerUDP` | UDP to consumer WireGuard port | Packet delivered |
| `testWireGuardHandshake` | Full WireGuard handshake | Tunnel established |
| `testEncryptedDataTransfer` | Send data through tunnel | Data received |
| `testBidirectionalTraffic` | Consumer sends to VM | Response received |

### Security Tests

#### Isolation Verification by Mode (`SecurityIsolationTests.swift`)

**Filtered Mode (guaranteed isolation):**

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testFilteredVMCannotReachInternet` | VM tries 8.8.8.8 | Dropped |
| `testFilteredVMCannotReachProviderLAN` | VM tries 192.168.1.1 | Dropped |
| `testFilteredVMCannotReachProviderHost` | VM tries provider's IP | Dropped |
| `testFilteredVMCannotReachOtherVMs` | VM tries other VM's IP | Dropped |
| `testFilteredVMCannotScanPorts` | Port scan attempt | All dropped |
| `testFilteredDNSBlocked` | VM tries DNS (53/udp) | Dropped |

**Conntrack Mode (terminates on violation):**

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testConntrackTerminatesOnInternetAccess` | VM tries 8.8.8.8 | VM terminated |
| `testConntrackTerminatesOnLANAccess` | VM tries 192.168.1.1 | VM terminated |
| `testConntrackAllowsRepeatedGoodTraffic` | Repeated consumer traffic | All forwarded |

**Direct Mode (VM-side only):**

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testDirectModeIptablesBlocks` | VM with iptables tries internet | Blocked by VM |
| `testDirectModeBypassable` | VM disables iptables | Traffic leaks |
| `testDirectModeLocalhostBlocked` | VM tries provider localhost | Blocked by macOS NAT |

#### Bypass Attempts (`SecurityBypassTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testSpoofedSourceIP` | VM spoofs source IP | Still blocked |
| `testSpoofedSourceMAC` | VM spoofs MAC address | No effect |
| `testFragmentedPacket` | Fragmented IP packet | Reassembled or dropped |
| `testOversizedPacket` | Jumbo frame | Handled gracefully |
| `testMalformedIPHeader` | Invalid IP header | Dropped, no crash |
| `testMalformedEthernetFrame` | Truncated frame | Dropped, no crash |
| `testRapidEndpointChanges` | Race allowlist | Only configured allowed |
| `testIPv6Blocked` | VM sends IPv6 | Dropped |
| `testNonIPProtocol` | Raw ethernet frames | Dropped |

#### Defense in Depth (`DefenseInDepthTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMIptablesActive` | Check VM firewall rules | OUTPUT policy DROP |
| `testVMIptablesSurvivesReboot` | Reboot VM | Rules persist |
| `testVMWithoutIptables` | Disable VM iptables | FilteredNAT still blocks |
| `testLayeredBlocking` | Both layers see blocked packet | Logged at both |

### Performance Tests

#### Throughput Benchmarks (`ThroughputBenchmarkTests.swift`)

| Test Case | Target | Measurement |
|-----------|--------|-------------|
| `testSmallPacketThroughput` | >100K pps | 64-byte UDP for 10s |
| `testLargePacketThroughput` | >2 Gbps | 1400-byte UDP for 10s |
| `testMixedSizeThroughput` | >1.5 Gbps | Realistic distribution |
| `testSustainedThroughput` | Stable | 60s continuous |
| `testBurstThroughput` | No drops | 1000 packets in <10ms |
| `testBidirectionalThroughput` | >1 Gbps each | Simultaneous upload/download |

#### Latency Benchmarks (`LatencyBenchmarkTests.swift`)

| Test Case | Target | Measurement |
|-----------|--------|-------------|
| `testFrameProcessingLatency` | <100 μs p50 | Timestamp at ingress/egress |
| `testAllowlistCheckLatency` | <1 μs | Microbenchmark |
| `testE2ELatency` | <500 μs p50 | Round-trip ping |
| `testLatencyUnderLoad` | <200 μs p50 | At 50% throughput |
| `testLatencyPercentiles` | p99 <1ms | 10K samples |
| `testJitter` | <100 μs stddev | Latency variance |

#### Stress Tests (`StressTests.swift`)

| Test Case | Description | Success Criteria |
|-----------|-------------|------------------|
| `testHighPacketRate` | 500K pps for 60s | No crashes, <1% loss |
| `testMemoryStability` | 1M packets | No memory leaks |
| `testCPUUtilization` | Max throughput | <80% one core |
| `testLongRunning` | 1 hour continuous | No degradation |
| `testConnectionChurn` | Rapid VM start/stop | Clean cleanup |
| `testConcurrentVMs` | 4 VMs simultaneously | Fair sharing |

### Reliability Tests

#### Error Handling (`ErrorHandlingTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMHandleClose` | VM terminates unexpectedly | Clean shutdown |
| `testNetworkSocketError` | UDP socket error | Graceful failure |
| `testResourceExhaustion` | Out of file descriptors | Graceful error |
| `testInvalidFrameRecovery` | Stream of invalid frames | Continue processing |
| `testPartialRead` | Incomplete frame read | Buffer and wait |

#### Recovery (`RecoveryTests.swift`)

| Test Case | Description | Expected Result |
|-----------|-------------|-----------------|
| `testVMRestart` | Stop and start VM | New instance works |
| `testConsumerReconnect` | Consumer IP changes | Allowlist updated |
| `testProviderNetworkFlap` | Provider loses network | Recovers |

## Test Infrastructure

### Test Utilities

```swift
// Mock VM handle for unit tests
class MockVMHandle: FileHandle {
    var sentFrames: [Data] = []
    var framesToReceive: [Data] = []
}

// Packet generators
func generateTestPacket(
    destIP: IPv4Address = .consumer,
    destPort: UInt16 = 51900,
    size: Int = 100
) -> Data

// Traffic generators for load testing
actor TrafficGenerator {
    func generateLoad(pps: Int, duration: TimeInterval) async
    func generateBurst(packets: Int) async
}

// Metrics collectors
class PerformanceMetrics {
    func recordLatency(_ duration: Duration)
    func recordThroughput(bytes: Int, duration: Duration)
    func generateReport() -> PerformanceReport
}
```

### Dual-Platform Testing

All unit tests for phases 1-7 must pass on both platforms:

| Platform | Test Environment | Notes |
|----------|-----------------|-------|
| **macOS** | Any Apple Silicon Mac | Virtualization.framework available |
| **Linux** | Any Linux machine with KVM | aarch64 or x86_64, QEMU/KVM |

**Platform-specific code:**
- Phases 1-7 (parsers, allowlist, forwarder, strategies): Must work on both platforms
- Phase 8+ (VMNetworkManager): macOS only (uses Virtualization.framework)

**Testing procedure for each phase:**
```bash
# On Linux
swift test --filter <TestName>

# On macOS
swift test --filter <TestName>
```

**Verification checklist:**
- [x] Phase 1: EthernetFrameTests - Linux (16 tests) macOS (16 tests)
- [x] Phase 2: IPv4PacketTests - Linux (24 tests) macOS (24 tests)
- [x] Phase 3: EndpointAllowlistTests - Linux (22 tests) macOS (22 tests)
- [x] Phase 4: UDPForwarderTests - Linux (11 tests) macOS (11 tests)
- [x] Phase 5: FramePacketBridgeTests - Linux (15 tests) macOS (15 tests)
- [x] Phase 6: FilteredNATTests - Linux (12 tests) macOS (12 tests)
- [x] Phase 7: FilteringStrategyTests - Linux (16 tests) macOS (16 tests)

### CI Integration

```yaml
# .github/workflows/test.yml
performance-tests:
  runs-on: macos-14  # Apple Silicon
  steps:
    - name: Run throughput benchmarks
      run: swift test --filter ThroughputBenchmark

    - name: Run latency benchmarks
      run: swift test --filter LatencyBenchmark

    - name: Compare against baseline
      run: swift test --filter BaselineComparison

    - name: Upload performance results
      uses: actions/upload-artifact@v3
      with:
        name: perf-results
        path: .build/perf-*.json
```

## Measured Overhead

### RogueConnectionDetector

| Operation | Time |
|-----------|------|
| Run `netstat` | ~5-10ms |
| Parse output | ~1-2ms |
| Run `ip route get` per connection | ~5ms each |
| **Total per check** | ~10-20ms |

- **Polling interval:** 5 seconds (configurable)
- **CPU impact:** <0.01%

### VPN Tunnel Overhead

| Metric | Impact |
|--------|--------|
| Latency added | +5-10ms per request |
| Bandwidth overhead | ~5-10% (headers + encryption) |
| CPU (WireGuard) | Minimal |

### FilteredNAT Overhead (Filtered Mode)

| Component | Latency | Notes |
|-----------|---------|-------|
| Frame read from VM | ~10-50 μs | File handle I/O |
| IP header parsing | ~1 μs | Pure computation |
| Allowlist check | ~0.1 μs | Hash lookup |
| UDP socket send | ~10-50 μs | Syscall |
| **Total per packet** | **~50-150 μs** | |

## Performance Targets Summary

| Metric | Target | Stretch Goal |
|--------|--------|--------------|
| Throughput (large packets) | 2 Gbps | 4 Gbps |
| Throughput (small packets) | 100K pps | 200K pps |
| Latency (p50) | 100 μs | 50 μs |
| Latency (p99) | 500 μs | 200 μs |
| Memory per VM | <10 MB | <5 MB |
| CPU at max throughput | <80% | <50% |
| Packet loss under load | <0.1% | 0% |

## Cross-Machine E2E Test (Mesh VM Provisioning)

This test verifies the full VM provisioning flow over the mesh network between two machines.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Linux (Consumer)                               │
│                                                                          │
│  ┌─────────────┐     IPC (Unix Socket)     ┌─────────────────────────┐  │
│  │ omerta CLI  │◄─────────────────────────►│ omertad                 │  │
│  │             │   ping → endpoint          │ (MeshNetwork running)   │  │
│  └──────┬──────┘                           └───────────┬─────────────┘  │
│         │                                              │                 │
│         │  Direct encrypted UDP                        │ Mesh protocol   │
│         │  (VM request)                                │ (keepalives,    │
│         │                                              │  discovery)     │
└─────────┼──────────────────────────────────────────────┼─────────────────┘
          │                                              │
          │         ════════════════════════════         │
          │                  Network                     │
          │         ════════════════════════════         │
          │                                              │
┌─────────┼──────────────────────────────────────────────┼─────────────────┐
│         │                                              │                 │
│         │                                              │                 │
│         ▼                                              ▼                 │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                     omertad (MeshProviderDaemon)                 │    │
│  │                                                                  │    │
│  │  - Receives VM request via MeshNetwork                          │    │
│  │  - Creates VM with WireGuard                                    │    │
│  │  - Returns VM info + provider WireGuard public key              │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│                           macOS (Provider)                               │
└──────────────────────────────────────────────────────────────────────────┘
```

### Test Setup

**Prerequisites:**
- Both machines on the same network (or with port forwarding)
- Same Omerta network created and joined on both machines
- Swift toolchain installed on both

**Create shared network (one-time setup):**
```bash
# On provider (macOS)
cd ~/omerta
.build/debug/omerta network create --name "test" --endpoint "<provider-ip>:9999"
# Note the network ID and invite link

# On consumer (Linux)
cd ~/omerta
.build/debug/omerta network join "<invite-link>"
```

### Running the Test

**Step 1: Start provider daemon (macOS)**
```bash
cd ~/omerta
.build/debug/omertad start --network <network-id>
# Note the Peer ID printed (e.g., 75af67f14ec0f9ba)
```

**Step 2: Start consumer daemon (Linux)**
```bash
cd ~/omerta
.build/debug/omertad start --network <network-id>
```

**Step 3: Request VM (Linux, separate terminal)**
```bash
.build/debug/omerta vm request --network <network-id> --peer <provider-peer-id>
```

**Step 4: Verify SSH access**
```bash
# Use the SSH command printed by vm request
ssh -i ~/.omerta/ssh/id_ed25519 omerta@<vm-wireguard-ip>
```

### Dry Run Mode

To test the mesh communication without creating actual VMs (no root required):

```bash
# Provider (macOS)
.build/debug/omertad start --network <network-id> --dry-run

# Consumer (Linux)
.build/debug/omertad start --network <network-id> --dry-run

# Request (Linux)
.build/debug/omerta vm request --network <network-id> --peer <provider-peer-id> --dry-run
```

This tests the full mesh communication flow without VM/VPN creation.

### Success Criteria

| Step | Verification |
|------|--------------|
| Daemon startup | "Mesh provider daemon started" logged |
| IPC ping | "Provider reachable: Xms latency" printed |
| VM request | "VM Created Successfully!" printed |
| WireGuard tunnel | `sudo wg show` shows peer with recent handshake |
| SSH access | SSH command connects to VM |

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Provider endpoint not available" | omertad not running or can't reach provider | Start omertad, check network connectivity |
| "No response from provider" | Provider daemon not running or wrong network | Verify both use same network ID |
| "Failed to decrypt message" | Different network keys | Re-join network on consumer |
| SSH timeout | VM still booting | Wait 30-60 seconds after VM creation |

## References

- [VZFileHandleNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment)
- [Virtualization.framework](https://developer.apple.com/documentation/virtualization)
- [WireGuard Protocol](https://www.wireguard.com/protocol/)
- [io_uring](https://kernel.dk/io_uring.pdf)
- [AF_XDP](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
