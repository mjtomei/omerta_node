# Identity System Compatibility Plan

## Problem Statement

OmertaCore and OmertaMesh have incompatible identity systems:

| Aspect | OmertaCore | OmertaMesh |
|--------|-----------|-----------|
| **Peer ID Format** | 16-char hex (SHA256 first 8 bytes) | Base64 (raw 32-byte public key) |
| **Recovery** | BIP-39 mnemonic | None |
| **Signing** | Basic (in IdentityKeypair) | Full (MeshEnvelope + PeerAnnouncement) |
| **Enforcement** | N/A | Exists but **not enforced** |

**Critical Issues:**
1. `omerta-mesh` CLI accepts arbitrary peer IDs (`--peerId "anything"`)
2. MeshNetwork accepts any string as peerId, not derived from keys
3. Signature verification is implemented but skipped in multiple places:
   - Line 473-477: "For now, allow unsigned messages for testing"
   - Line 462-470: Falls back to using `fromPeerId` as public key (wrong)
   - Line 981-987: `receiveEnvelope()` skips verification if peer unknown
4. Peer ID formats are incompatible between modules
5. No validation that peer ID is derived from public key (allows impersonation)

## Goals

1. **Compatible peer ID format** - same derivation in both systems
2. **Enforce message signing** - reject unsigned/invalid messages
3. **Keep OmertaMesh standalone** - no OmertaCore dependency required
4. **OmertaCore identity usable with OmertaMesh** - when both available

## Design

### Peer ID Format (Unified)

Adopt OmertaCore's format for both:
```
SHA256(public_key)[0..8] → hex encode → 16 lowercase hex chars
```

This is collision-resistant (2^64 space) and human-readable.

### Phase 1: Update OmertaMesh Peer ID Derivation

**File:** `Sources/OmertaMesh/Identity/IdentityKeypair.swift`

Change peer ID from base64 to hex-SHA256:

```swift
public var peerId: PeerId {
    // Old: publicKey.rawRepresentation.base64EncodedString()
    // New: SHA256 first 8 bytes, hex encoded
    let hash = SHA256.hash(data: publicKey.rawRepresentation)
    return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
}
```

Add extension for public key → peer ID:
```swift
extension Curve25519.Signing.PublicKey {
    public var peerId: PeerId {
        let hash = SHA256.hash(data: rawRepresentation)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
```

**Phase 1 Tests:**

```swift
// Tests/OmertaMeshTests/IdentityKeypairTests.swift

func testPeerIdIs16HexChars() {
    let keypair = IdentityKeypair()
    XCTAssertEqual(keypair.peerId.count, 16)
    XCTAssertTrue(keypair.peerId.allSatisfy { $0.isHexDigit })
}

func testPeerIdIsLowercase() {
    let keypair = IdentityKeypair()
    XCTAssertEqual(keypair.peerId, keypair.peerId.lowercased())
}

func testPeerIdIsDeterministic() {
    // Same key always produces same peer ID
    let keypair = IdentityKeypair()
    let keyData = keypair.privateKeyData
    let restored = try! IdentityKeypair(privateKeyData: keyData)
    XCTAssertEqual(keypair.peerId, restored.peerId)
}

func testPeerIdMatchesOmertaCoreDerivation() {
    // Verify compatible with OmertaCore's PeerIdentity.deriveId()
    let keypair = IdentityKeypair()
    let hash = SHA256.hash(data: keypair.publicKeyData)
    let expected = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(keypair.peerId, expected)
}

func testDifferentKeysProduceDifferentPeerIds() {
    let keypair1 = IdentityKeypair()
    let keypair2 = IdentityKeypair()
    XCTAssertNotEqual(keypair1.peerId, keypair2.peerId)
}
```

### Phase 2: Remove CLI Peer ID Option

**File:** `Sources/OmertaMeshCLI/main.swift`

Remove `--peerId` option. Generate identity on startup:

```swift
// Old: let myPeerId = peerId ?? "mesh-\(UUID().uuidString.prefix(8))"
// New:
let identity = IdentityKeypair()  // Generate new
let myPeerId = identity.peerId    // Derived from public key

// Or load from file:
let identity = try loadOrGenerateIdentity()
```

Add identity persistence (simple file-based):
- Save to `~/.omerta-mesh/identity.json`
- Load on startup if exists
- Generate and save if not

**Phase 2 Tests:**

```swift
// Tests/OmertaMeshTests/IdentityPersistenceTests.swift

func testIdentitySavedToFile() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let identity = try loadOrGenerateIdentity(directory: tempDir)
    let identityFile = tempDir.appendingPathComponent("identity.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: identityFile.path))
}

func testIdentityLoadedFromFile() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // First call generates and saves
    let identity1 = try loadOrGenerateIdentity(directory: tempDir)
    // Second call loads existing
    let identity2 = try loadOrGenerateIdentity(directory: tempDir)
    XCTAssertEqual(identity1.peerId, identity2.peerId)
}

func testIdentityFileContainsValidJSON() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let identity = try loadOrGenerateIdentity(directory: tempDir)
    let identityFile = tempDir.appendingPathComponent("identity.json")
    let data = try Data(contentsOf: identityFile)
    let json = try JSONDecoder().decode([String: String].self, from: data)
    XCTAssertNotNil(json["privateKey"])
}
```

**CLI Integration Test:**
```bash
# Verify --peerId option no longer exists
.build/debug/omerta-mesh --help | grep -q "peerId" && echo "FAIL: --peerId still exists" || echo "PASS"

# Verify identity is auto-generated with 16-char hex format
.build/debug/omerta-mesh --port 9000 &
PID=$!
sleep 2
# Check output shows 16-char hex peer ID
kill $PID
```

### Phase 3: Update MeshNetwork Initialization

**File:** `Sources/OmertaMesh/Public/MeshNetwork.swift`

Change from string peerId to IdentityKeypair:

```swift
// Old:
public init(peerId: PeerId, config: MeshConfig = .default)

// New:
public init(identity: IdentityKeypair, config: MeshConfig = .default) {
    self.identity = identity
    self.peerId = identity.peerId  // Derived, not arbitrary
    // ...
}

// Convenience for standalone use:
public init(config: MeshConfig = .default) {
    self.init(identity: IdentityKeypair(), config: config)
}
```

**Phase 3 Tests:**

```swift
// Tests/OmertaMeshTests/MeshNetworkInitTests.swift

func testMeshNetworkRequiresIdentity() async throws {
    // Old API should not compile (string peerId)
    // let mesh = MeshNetwork(peerId: "arbitrary-string")  // Should fail to compile

    // New API requires IdentityKeypair
    let identity = IdentityKeypair()
    let mesh = MeshNetwork(identity: identity)
    let peerId = await mesh.peerId
    XCTAssertEqual(peerId, identity.peerId)
}

func testMeshNetworkConvenienceInitGeneratesIdentity() async throws {
    let mesh = MeshNetwork()
    let peerId = await mesh.peerId
    XCTAssertEqual(peerId.count, 16)
    XCTAssertTrue(peerId.allSatisfy { $0.isHexDigit })
}

func testMeshNetworkPeerIdIsDerivedNotArbitrary() async throws {
    let identity = IdentityKeypair()
    let mesh = MeshNetwork(identity: identity)

    // Peer ID must match derivation from public key
    let hash = SHA256.hash(data: identity.publicKeyData)
    let expectedPeerId = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    let actualPeerId = await mesh.peerId
    XCTAssertEqual(actualPeerId, expectedPeerId)
}

func testCannotOverridePeerId() async throws {
    // Verify there's no way to set arbitrary peer ID
    // This is a compile-time guarantee - MeshNetwork has no peerId setter
    let identity = IdentityKeypair()
    var config = MeshConfig.default
    // config.peerId = "fake"  // Should not exist
    let mesh = MeshNetwork(identity: identity, config: config)
    let peerId = await mesh.peerId
    XCTAssertEqual(peerId, identity.peerId)
}
```

### Phase 4: Remove ALL Unverified Communication Fallbacks

**File:** `Sources/OmertaMesh/MeshNode.swift`

There are multiple locations where signature verification is bypassed. ALL must be fixed:

#### 4a. Main message handler (lines 473-477)

**Current:**
```swift
if !envelope.verifySignature(publicKeyBase64: senderPublicKey) {
    // For now, allow unsigned messages for testing
    logger.debug("Message signature verification skipped (peer key unknown)")
}
```

**Fix:** Remove fallback, reject invalid signatures:
```swift
guard envelope.verifySignature(publicKeyBase64: senderPublicKey) else {
    logger.warning("Rejecting message with invalid signature",
                   metadata: ["from": "\(envelope.fromPeerId.prefix(8))..."])
    return  // Drop the message
}
```

#### 4b. Unknown sender fallback (lines 462-470)

**Current:**
```swift
if let peer = peers[envelope.fromPeerId] {
    senderPublicKey = await peer.publicKey.rawRepresentation.base64EncodedString()
} else {
    // For ping messages, the sender includes their public key in the peerId
    // (since peerId is derived from public key, we can derive the key)
    senderPublicKey = envelope.fromPeerId  // WRONG: peerId is NOT the public key
}
```

**Fix:** Must look up from registry or reject:
```swift
guard let senderPublicKey = peerPublicKeys[envelope.fromPeerId] else {
    // Unknown sender - only accept self-authenticating messages
    // (handled in Phase 5)
    return handleUnknownSender(envelope, from: address)
}
```

#### 4c. Test helper receiveEnvelope (lines 979-996)

**Current:**
```swift
public func receiveEnvelope(_ envelope: MeshEnvelope) async -> Bool {
    // Verify signature if we know the sender
    if let peer = peers[envelope.fromPeerId] {
        // ... verifies ...
    }
    // FALLS THROUGH if peer unknown - no verification!
```

**Fix:** Require verification for all envelopes:
```swift
public func receiveEnvelope(_ envelope: MeshEnvelope) async -> Bool {
    guard let senderPublicKey = peerPublicKeys[envelope.fromPeerId] else {
        logger.warning("Rejected envelope from unknown peer: \(envelope.fromPeerId)")
        return false
    }
    guard envelope.verifySignature(publicKeyBase64: senderPublicKey) else {
        logger.warning("Rejected envelope with invalid signature from \(envelope.fromPeerId)")
        return false
    }
    // ... rest of method
}
```

**Phase 4 Tests:**

```swift
// Tests/OmertaMeshTests/SignatureEnforcementTests.swift

func testRejectsUnsignedMessage() async throws {
    let node = try await createTestNode()
    let attacker = IdentityKeypair()

    // Create envelope without signature
    var envelope = MeshEnvelope(
        fromPeerId: attacker.peerId,
        payload: .ping(nonce: 12345),
        signature: ""  // Empty signature
    )

    let accepted = await node.receiveEnvelope(envelope)
    XCTAssertFalse(accepted, "Unsigned message should be rejected")
}

func testRejectsInvalidSignature() async throws {
    let node = try await createTestNode()
    let attacker = IdentityKeypair()
    let victim = IdentityKeypair()

    // Register victim's key so node knows them
    await node.registerPeerPublicKey(victim.peerId, publicKey: victim.publicKeyBase64)

    // Attacker signs message but claims to be victim
    let envelope = try MeshEnvelope.signed(
        from: attacker,  // Signed with attacker's key
        payload: .ping(nonce: 12345)
    )
    var spoofed = envelope
    spoofed.fromPeerId = victim.peerId  // But claims to be victim

    let accepted = await node.receiveEnvelope(spoofed)
    XCTAssertFalse(accepted, "Message with wrong signature should be rejected")
}

func testRejectsUnknownSenderNonAnnouncement() async throws {
    let node = try await createTestNode()
    let unknown = IdentityKeypair()

    // Valid signature from unknown peer (not registered)
    let envelope = try MeshEnvelope.signed(
        from: unknown,
        payload: .ping(nonce: 12345)  // Not an announcement
    )

    let accepted = await node.receiveEnvelope(envelope)
    XCTAssertFalse(accepted, "Non-announcement from unknown peer should be rejected")
}

func testAcceptsValidSignatureFromKnownPeer() async throws {
    let node = try await createTestNode()
    let peer = IdentityKeypair()

    // Register peer's public key
    await node.registerPeerPublicKey(peer.peerId, publicKey: peer.publicKeyBase64)

    // Valid signature from known peer
    let envelope = try MeshEnvelope.signed(
        from: peer,
        payload: .ping(nonce: 12345)
    )

    let accepted = await node.receiveEnvelope(envelope)
    XCTAssertTrue(accepted, "Valid signature from known peer should be accepted")
}

func testNoFallbackToUnsignedMessagesExists() async throws {
    // Verify the old fallback code paths are removed
    // This is a code review/grep test:
    // grep -r "allow unsigned" Sources/OmertaMesh/ should return nothing
    // grep -r "verification skipped" Sources/OmertaMesh/ should return nothing
}
```

**Regression Test (ensures fallbacks are removed):**
```bash
# Run from project root - should find NO matches
echo "Checking for removed fallback code..."
! grep -r "allow unsigned" Sources/OmertaMesh/ && \
! grep -r "verification skipped" Sources/OmertaMesh/ && \
! grep -r "FALLS THROUGH" Sources/OmertaMesh/ && \
echo "PASS: All fallbacks removed"
```

### Phase 5: Peer Public Key Registry and Self-Authenticating Messages

**File:** `Sources/OmertaMesh/MeshNode.swift`

#### 5a. Add peer public key tracking:

```swift
/// Known peer public keys (peer ID → base64 public key)
private var peerPublicKeys: [PeerId: String] = [:]
```

#### 5b. Handle unknown senders (self-authenticating messages only):

Only `PeerAnnouncement` messages can be accepted from unknown senders because they contain their own public key:

```swift
private func handleUnknownSender(_ envelope: MeshEnvelope, from address: SocketAddress) async {
    // Only PeerAnnouncement messages are self-authenticating
    guard case .peerAnnouncement(let announcement) = envelope.payload else {
        logger.warning("Rejecting non-announcement from unknown peer",
                       metadata: ["from": "\(envelope.fromPeerId.prefix(8))..."])
        return
    }

    // Verify the announcement signature using its embedded public key
    guard envelope.verifySignature(publicKeyBase64: announcement.publicKey) else {
        logger.warning("Rejecting announcement with invalid signature")
        return
    }

    // Verify peer ID is correctly derived from public key
    guard verifyPeerIdDerivation(peerId: announcement.peerId, publicKey: announcement.publicKey) else {
        logger.warning("Rejecting announcement with mismatched peer ID")
        return
    }

    // Now we can trust this peer - register their public key
    peerPublicKeys[announcement.peerId] = announcement.publicKey
    logger.info("Registered new peer from announcement",
                metadata: ["peerId": "\(announcement.peerId)"])

    // Process the announcement
    await handlePeerAnnouncement(announcement, from: address)
}

/// Verify that a peer ID was correctly derived from a public key
private func verifyPeerIdDerivation(peerId: PeerId, publicKey: String) -> Bool {
    guard let keyData = Data(base64Encoded: publicKey) else { return false }
    let hash = SHA256.hash(data: keyData)
    let expected = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    return peerId == expected
}
```

#### 5c. Update PeerAnnouncement handling to register keys:

```swift
// In handlePeerAnnouncement:
// Verify and register the public key
guard verifyPeerIdDerivation(peerId: announcement.peerId, publicKey: announcement.publicKey) else {
    logger.warning("Ignoring announcement with invalid peer ID derivation")
    return
}
peerPublicKeys[announcement.peerId] = announcement.publicKey
```

#### 5d. Bootstrap peer registration:

When connecting to a bootstrap peer, we must receive their announcement first:

```swift
// Bootstrap connection flow:
// 1. Send our announcement (signed) to bootstrap
// 2. Receive bootstrap's announcement (they must announce before we accept other messages)
// 3. Verify bootstrap announcement signature with embedded key
// 4. Register bootstrap's public key
// 5. Now we can accept other messages from bootstrap
```

**Phase 5 Tests:**

```swift
// Tests/OmertaMeshTests/PeerRegistryTests.swift

func testAcceptsSelfAuthenticatingAnnouncement() async throws {
    let node = try await createTestNode()
    let newPeer = IdentityKeypair()

    // Create valid announcement from unknown peer
    let announcement = PeerAnnouncement(
        peerId: newPeer.peerId,
        publicKey: newPeer.publicKeyBase64,
        reachability: [],
        capabilities: [],
        timestamp: Date(),
        ttlSeconds: 300
    )
    let envelope = try MeshEnvelope.signed(
        from: newPeer,
        payload: .peerAnnouncement(announcement)
    )

    let accepted = await node.receiveEnvelope(envelope)
    XCTAssertTrue(accepted, "Self-authenticating announcement should be accepted")

    // Verify peer was registered
    let registeredKey = await node.getPublicKey(for: newPeer.peerId)
    XCTAssertEqual(registeredKey, newPeer.publicKeyBase64)
}

func testRejectsAnnouncementWithMismatchedPeerId() async throws {
    let node = try await createTestNode()
    let peer = IdentityKeypair()

    // Announcement with fake peer ID that doesn't match public key
    let announcement = PeerAnnouncement(
        peerId: "fakepeerid123456",  // Wrong - doesn't match publicKey
        publicKey: peer.publicKeyBase64,
        reachability: [],
        capabilities: [],
        timestamp: Date(),
        ttlSeconds: 300
    )
    let envelope = try MeshEnvelope.signed(
        from: peer,
        payload: .peerAnnouncement(announcement)
    )

    let accepted = await node.receiveEnvelope(envelope)
    XCTAssertFalse(accepted, "Announcement with mismatched peer ID should be rejected")
}

func testRejectsAnnouncementWithWrongSignature() async throws {
    let node = try await createTestNode()
    let peer = IdentityKeypair()
    let attacker = IdentityKeypair()

    // Announcement signed by attacker claiming to be peer
    let announcement = PeerAnnouncement(
        peerId: peer.peerId,
        publicKey: peer.publicKeyBase64,
        reachability: [],
        capabilities: [],
        timestamp: Date(),
        ttlSeconds: 300
    )
    // Signed with attacker's key, not peer's key
    let envelope = try MeshEnvelope.signed(
        from: attacker,
        payload: .peerAnnouncement(announcement)
    )

    let accepted = await node.receiveEnvelope(envelope)
    XCTAssertFalse(accepted, "Announcement with wrong signature should be rejected")
}

func testVerifyPeerIdDerivation() {
    let keypair = IdentityKeypair()

    // Correct derivation
    XCTAssertTrue(verifyPeerIdDerivation(
        peerId: keypair.peerId,
        publicKey: keypair.publicKeyBase64
    ))

    // Wrong peer ID
    XCTAssertFalse(verifyPeerIdDerivation(
        peerId: "wrongpeerid12345",
        publicKey: keypair.publicKeyBase64
    ))

    // Invalid public key
    XCTAssertFalse(verifyPeerIdDerivation(
        peerId: keypair.peerId,
        publicKey: "not-valid-base64!!!"
    ))
}

func testSubsequentMessagesAcceptedAfterAnnouncement() async throws {
    let node = try await createTestNode()
    let peer = IdentityKeypair()

    // First: send announcement to register
    let announcement = PeerAnnouncement(
        peerId: peer.peerId,
        publicKey: peer.publicKeyBase64,
        reachability: [],
        capabilities: [],
        timestamp: Date(),
        ttlSeconds: 300
    )
    let announcementEnvelope = try MeshEnvelope.signed(
        from: peer,
        payload: .peerAnnouncement(announcement)
    )
    _ = await node.receiveEnvelope(announcementEnvelope)

    // Now: subsequent messages should be accepted
    let pingEnvelope = try MeshEnvelope.signed(
        from: peer,
        payload: .ping(nonce: 12345)
    )
    let accepted = await node.receiveEnvelope(pingEnvelope)
    XCTAssertTrue(accepted, "Message from registered peer should be accepted")
}
```

**Bootstrap Flow Integration Test:**
```swift
func testBootstrapConnectionFlow() async throws {
    let bootstrap = try await createTestNode(isRelay: true)
    let client = try await createTestNode()

    // 1. Client connects and sends announcement
    let clientAnnouncement = try client.createAnnouncement()
    await bootstrap.receiveEnvelope(clientAnnouncement)

    // 2. Bootstrap sends its announcement
    let bootstrapAnnouncement = try bootstrap.createAnnouncement()
    await client.receiveEnvelope(bootstrapAnnouncement)

    // 3. Now both can exchange messages
    let clientPing = try MeshEnvelope.signed(from: client.identity, payload: .ping(nonce: 1))
    let bootstrapPing = try MeshEnvelope.signed(from: bootstrap.identity, payload: .ping(nonce: 2))

    XCTAssertTrue(await bootstrap.receiveEnvelope(clientPing))
    XCTAssertTrue(await client.receiveEnvelope(bootstrapPing))
}
```

### Phase 6: Update Message Formats

**File:** `Sources/OmertaMesh/Types/MeshMessage.swift`

Ensure PeerAnnouncement includes full public key (already does at line 130):
```swift
public let publicKey: String  // Base64-encoded signing public key
```

No changes needed - structure already supports this.

**Phase 6 Tests:**

```swift
// Tests/OmertaMeshTests/PeerAnnouncementTests.swift

func testPeerAnnouncementContainsPublicKey() {
    let keypair = IdentityKeypair()
    let announcement = PeerAnnouncement(
        peerId: keypair.peerId,
        publicKey: keypair.publicKeyBase64,
        reachability: [],
        capabilities: [],
        timestamp: Date(),
        ttlSeconds: 300
    )

    XCTAssertEqual(announcement.publicKey, keypair.publicKeyBase64)
    XCTAssertFalse(announcement.publicKey.isEmpty)
}

func testPeerAnnouncementEncodesDecodes() throws {
    let keypair = IdentityKeypair()
    let original = PeerAnnouncement(
        peerId: keypair.peerId,
        publicKey: keypair.publicKeyBase64,
        reachability: [.direct(endpoint: "192.168.1.1:9000")],
        capabilities: ["relay"],
        timestamp: Date(),
        ttlSeconds: 300
    )

    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PeerAnnouncement.self, from: encoded)

    XCTAssertEqual(decoded.peerId, original.peerId)
    XCTAssertEqual(decoded.publicKey, original.publicKey)
}

func testPeerAnnouncementPublicKeyIsBase64() {
    let keypair = IdentityKeypair()
    let announcement = PeerAnnouncement(
        peerId: keypair.peerId,
        publicKey: keypair.publicKeyBase64,
        reachability: [],
        capabilities: [],
        timestamp: Date(),
        ttlSeconds: 300
    )

    // Verify it's valid base64 that decodes to 32 bytes (Curve25519 key)
    let keyData = Data(base64Encoded: announcement.publicKey)
    XCTAssertNotNil(keyData)
    XCTAssertEqual(keyData?.count, 32)
}
```

### Phase 7: OmertaCore Compatibility (Optional Bridge)

When OmertaCore is available, allow using its IdentityKeypair:

**File:** `Sources/OmertaMesh/Identity/IdentityKeypair.swift`

Add initializer from raw key data:
```swift
public init(privateKeyData: Data) throws {
    self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
    self.publicKey = privateKey.publicKey
}
```

In consuming code (e.g., MeshConsumerClient):
```swift
// Convert OmertaCore identity to OmertaMesh identity
let meshIdentity = try OmertaMesh.IdentityKeypair(
    privateKeyData: omertaCoreKeypair.privateKey
)
```

**Phase 7 Tests:**

```swift
// Tests/OmertaMeshTests/OmertaCoreCompatibilityTests.swift

func testCreateFromPrivateKeyData() throws {
    // Generate a keypair, export private key, recreate from data
    let original = IdentityKeypair()
    let privateData = original.privateKeyData

    let restored = try IdentityKeypair(privateKeyData: privateData)

    XCTAssertEqual(restored.peerId, original.peerId)
    XCTAssertEqual(restored.publicKeyBase64, original.publicKeyBase64)
}

func testCreateFromBase64PrivateKey() throws {
    let original = IdentityKeypair()
    let privateBase64 = original.privateKeyBase64

    let restored = try IdentityKeypair(privateKeyBase64: privateBase64)

    XCTAssertEqual(restored.peerId, original.peerId)
}

func testInvalidPrivateKeyDataThrows() {
    let invalidData = Data([0, 1, 2, 3])  // Too short

    XCTAssertThrowsError(try IdentityKeypair(privateKeyData: invalidData)) { error in
        XCTAssertTrue(error is IdentityError)
    }
}

func testInvalidBase64PrivateKeyThrows() {
    XCTAssertThrowsError(try IdentityKeypair(privateKeyBase64: "not-valid-base64!!!"))
}

func testOmertaCoreKeyProducesSamePeerId() throws {
    // Simulate OmertaCore key generation (same algorithm)
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey

    // OmertaCore peer ID derivation
    let hash = SHA256.hash(data: publicKey.rawRepresentation)
    let omertaCorePeerId = hash.prefix(8).map { String(format: "%02x", $0) }.joined()

    // Create OmertaMesh identity from same key
    let meshIdentity = try IdentityKeypair(privateKeyData: privateKey.rawRepresentation)

    XCTAssertEqual(meshIdentity.peerId, omertaCorePeerId,
                   "OmertaMesh and OmertaCore should derive identical peer IDs")
}

func testSignatureFromOmertaCoreKeyVerifiesInMesh() throws {
    // Create key using OmertaCore-style
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey

    // Sign with "OmertaCore" (raw Crypto)
    let message = "test message".data(using: .utf8)!
    let signature = try privateKey.signature(for: message)

    // Verify with OmertaMesh identity
    let meshIdentity = try IdentityKeypair(privateKeyData: privateKey.rawRepresentation)
    let meshSignature = Signature(data: signature)

    XCTAssertTrue(meshSignature.verify(message, publicKeyBase64: meshIdentity.publicKeyBase64))
}
```

**Cross-Module Integration Test:**
```swift
// This test would be in a combined test target that has access to both modules
func testOmertaCoreIdentityWorksWithMeshNetwork() async throws {
    // 1. Create identity using OmertaCore
    let coreKeypair = OmertaCore.IdentityKeypair.generate()

    // 2. Convert to OmertaMesh identity
    let meshIdentity = try OmertaMesh.IdentityKeypair(
        privateKeyData: coreKeypair.privateKey
    )

    // 3. Create mesh network with converted identity
    let mesh = MeshNetwork(identity: meshIdentity)

    // 4. Verify peer IDs match
    let corePeerId = OmertaCore.PeerIdentity.deriveId(from: coreKeypair.publicKey)
    let meshPeerId = await mesh.peerId
    XCTAssertEqual(corePeerId, meshPeerId)

    // 5. Verify messages signed with core key verify in mesh
    try await mesh.start()
    // ... send messages, verify they're properly signed
    await mesh.stop()
}
```

### Phase 7b: Fix Network ID Derivation (Security Fix)

**File:** `Sources/OmertaCore/Domain/Network.swift`

The current `deriveNetworkId()` function has a **placeholder implementation** that is cryptographically broken:

**Current (BROKEN):**
```swift
public func deriveNetworkId() -> String {
    // Simple SHA256 hash for now, will use Crypto framework properly later
    let hash = networkKey.withUnsafeBytes { bytes in
        var result = [UInt8](repeating: 0, count: 32)
        // Placeholder - will use CryptoKit properly
        for (i, byte) in bytes.enumerated() {
            result[i % 32] ^= byte
        }
        return Data(result)
    }
    return hash.base64EncodedString()
}
```

This is NOT SHA256 - it's just XORing bytes! This causes:
- Collision risk: different network keys could produce the same network ID
- Predictability: network IDs don't have cryptographic strength
- Security weakness: attacker could craft keys with specific network IDs

**Fix:**
```swift
import Crypto

public func deriveNetworkId() -> String {
    let hash = SHA256.hash(data: networkKey)
    // Use first 16 bytes (128 bits) encoded as base64 for shorter IDs
    // Or full 32 bytes if longer IDs are acceptable
    return Data(hash).base64EncodedString()
}
```

**Alternative (shorter IDs, consistent with peer ID style):**
```swift
public func deriveNetworkId() -> String {
    let hash = SHA256.hash(data: networkKey)
    // 16 hex chars like peer IDs (first 8 bytes of SHA256)
    return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
}
```

**Phase 7b Tests:**

```swift
// Tests/OmertaCoreTests/NetworkKeyTests.swift

func testNetworkIdIsDeterministic() {
    let key = NetworkKey.generate(networkName: "test", bootstrapEndpoint: "localhost:9000")
    let id1 = key.deriveNetworkId()
    let id2 = key.deriveNetworkId()
    XCTAssertEqual(id1, id2, "Same key should always produce same network ID")
}

func testDifferentKeysProduceDifferentNetworkIds() {
    let key1 = NetworkKey.generate(networkName: "test1", bootstrapEndpoint: "localhost:9000")
    let key2 = NetworkKey.generate(networkName: "test2", bootstrapEndpoint: "localhost:9000")
    XCTAssertNotEqual(key1.deriveNetworkId(), key2.deriveNetworkId(),
                      "Different keys should produce different network IDs")
}

func testNetworkIdIsProperSHA256() {
    let key = NetworkKey.generate(networkName: "test", bootstrapEndpoint: "localhost:9000")

    // Verify it matches manual SHA256 computation
    let expectedHash = SHA256.hash(data: key.networkKey)
    let expectedId = Data(expectedHash).base64EncodedString()

    XCTAssertEqual(key.deriveNetworkId(), expectedId)
}

func testNetworkIdNotXorBased() {
    // Create two keys where XOR would produce same result but SHA256 won't
    var keyData1 = Data(repeating: 0xAA, count: 32)
    var keyData2 = Data(repeating: 0xAA, count: 32)
    keyData2[0] = 0xBB  // Different first byte

    let key1 = NetworkKey(networkKey: keyData1, networkName: "test", bootstrapPeers: [])
    let key2 = NetworkKey(networkKey: keyData2, networkName: "test", bootstrapPeers: [])

    // With broken XOR implementation, these might collide
    // With proper SHA256, they won't
    XCTAssertNotEqual(key1.deriveNetworkId(), key2.deriveNetworkId())
}

func testNetworkIdHasExpectedLength() {
    let key = NetworkKey.generate(networkName: "test", bootstrapEndpoint: "localhost:9000")
    let networkId = key.deriveNetworkId()

    // If using base64 of full SHA256: 44 chars (32 bytes = 44 base64 chars with padding)
    // If using 16 hex chars like peer IDs: 16 chars
    // Adjust based on chosen format
    XCTAssertEqual(networkId.count, 44)  // or 16 for hex format
}
```

**Regression Test:**
```bash
# Verify placeholder code is removed
! grep -r "Placeholder" Sources/OmertaCore/Domain/Network.swift && \
! grep -r "will use.*properly later" Sources/OmertaCore/Domain/Network.swift && \
echo "PASS: Placeholder code removed"
```

## Files to Modify

| File | Changes |
|------|---------|
| `Sources/OmertaCore/Domain/Network.swift` | **Security fix:** Replace XOR placeholder with proper SHA256 in `deriveNetworkId()` |
| `Sources/OmertaMesh/Identity/IdentityKeypair.swift` | Change peerId derivation to SHA256-hex, add `verifyPeerIdDerivation()` |
| `Sources/OmertaMeshCLI/main.swift` | Remove --peerId option, add identity persistence |
| `Sources/OmertaMesh/Public/MeshNetwork.swift` | Accept IdentityKeypair instead of string peerId |
| `Sources/OmertaMesh/MeshNode.swift` | **Major changes:** Remove all verification fallbacks (lines 462-477, 981-987), add `peerPublicKeys` registry, add `handleUnknownSender()`, add `verifyPeerIdDerivation()` |
| `Sources/OmertaMesh/Discovery/Gossip.swift` | No changes (already uses identity correctly) |
| `Tests/OmertaMeshTests/` | Update tests for new peer ID format, add signature rejection tests |

## Verification

1. **Unit Tests:**
   ```bash
   swift test --filter OmertaMeshTests
   swift test --filter OmertaCoreTests.NetworkKeyTests
   ```
   - Verify peer ID is 16 hex chars
   - Verify signature enforcement rejects bad signatures
   - Verify identity persistence works
   - Verify network ID uses proper SHA256 (not XOR placeholder)

2. **Security Regression Check:**
   ```bash
   # Verify all placeholder/fallback code is removed
   ! grep -r "Placeholder" Sources/OmertaCore/Domain/Network.swift && \
   ! grep -r "allow unsigned" Sources/OmertaMesh/ && \
   ! grep -r "verification skipped" Sources/OmertaMesh/ && \
   echo "PASS: All insecure code removed"
   ```

3. **Security Tests:
   ```swift
   // Test that unsigned messages are rejected
   func testRejectsUnsignedMessage() async {
       let node = MeshNode(...)
       var envelope = MeshEnvelope(...)
       envelope.signature = ""  // No signature
       let accepted = await node.receiveEnvelope(envelope)
       XCTAssertFalse(accepted)
   }

   // Test that forged signatures are rejected
   func testRejectsForgedSignature() async {
       let node = MeshNode(...)
       let envelope = MeshEnvelope.signed(from: attackerKeypair, ...)
       // Attacker signs with their key but claims to be victim
       let accepted = await node.receiveEnvelope(envelope)
       XCTAssertFalse(accepted)
   }

   // Test that mismatched peer ID is rejected
   func testRejectsMismatchedPeerId() async {
       var announcement = PeerAnnouncement(
           peerId: "fakepeerid12345",  // Doesn't match publicKey
           publicKey: validPublicKeyBase64,
           ...
       )
       // Should be rejected because peerId != SHA256(publicKey)[0..8]
   }

   // Test that unknown sender non-announcement is rejected
   func testRejectsUnknownSenderNonAnnouncement() async {
       // Send a ping from unknown peer (not in registry)
       // Should be rejected - only announcements accepted from unknowns
   }
   ```

3. **Integration Test:**
   ```bash
   # Terminal 1: Start relay
   .build/debug/omerta-mesh --relay --port 9000

   # Terminal 2: Start peer (note: no --peerId)
   .build/debug/omerta-mesh --bootstrap <relay-id>@localhost:9000

   # Verify peer IDs are 16-char hex, not arbitrary strings
   ```

4. **Cross-Module Test:**
   - Use OmertaCore identity with MeshConsumerClient
   - Verify messages are properly signed and verified

5. **Attack Simulation:**
   - Attempt to send message claiming to be another peer ID
   - Attempt to send announcement with wrong peer ID derivation
   - Attempt to connect without sending announcement first
   - All should be rejected

---

## Phase 8: Identity Aliases and Verified Claims

### 8a. Self-Declared Names

Peers can announce a human-readable display name (unverified):

**Update PeerAnnouncement structure:**
```swift
public struct PeerAnnouncement {
    public let peerId: String
    public let publicKey: String
    public let displayName: String?       // NEW: "Alice", "Bob's Laptop", etc.
    public let reachability: [ReachabilityPath]
    public let capabilities: [String]
    public let claims: [IdentityClaim]    // NEW: verified claims (see 8c)
    public let timestamp: Date
    public let ttlSeconds: Int
    public let signature: String
}
```

**Conflict Detection:**

When two peers claim the same display name, surface the conflict:

```swift
/// Tracks display name → peer IDs mapping
private var displayNameIndex: [String: Set<PeerId>] = [:]

func registerPeerName(_ name: String, peerId: PeerId) {
    displayNameIndex[name, default: []].insert(peerId)
}

func getNameConflicts() -> [(name: String, peerIds: [PeerId])] {
    displayNameIndex.filter { $0.value.count > 1 }
                    .map { ($0.key, Array($0.value)) }
}

/// Resolve a name - returns nil if ambiguous
func resolveName(_ name: String) -> PeerId? {
    guard let peerIds = displayNameIndex[name], peerIds.count == 1 else {
        return nil  // Ambiguous or unknown
    }
    return peerIds.first
}
```

**CLI/UI Surfacing:**
```
$ omerta peers
PEER ID          NAME              VERIFIED
a1b2c3d4e5f6g7h8 Alice             phone:+1555...
b2c3d4e5f6g7h8a1 Bob               -
c3d4e5f6g7h8a1b2 Alice             -          ⚠️ CONFLICT

Warning: Multiple peers claim the name "Alice"
  - a1b2c3d4... (verified phone)
  - c3d4e5f6... (unverified)
```

### 8b. Local Aliases (Address Book)

Users can assign local names that override self-declared names:

**File:** `~/.omerta/contacts.json`
```json
{
  "contacts": {
    "a1b2c3d4e5f6g7h8": {
      "localAlias": "Alice (work)",
      "publicKey": "base64...",
      "notes": "Met at conference",
      "trustLevel": "verified",
      "addedAt": "2024-01-15T..."
    }
  },
  "blockedPeers": ["deadbeef12345678"]
}
```

**API:**
```swift
public actor ContactBook {
    func setAlias(peerId: PeerId, alias: String)
    func getAlias(peerId: PeerId) -> String?
    func resolve(nameOrAlias: String) -> PeerId?  // Checks local first, then network
    func block(peerId: PeerId)
    func isBlocked(peerId: PeerId) -> Bool
}
```

### 8c. Verified Claims (Phone, Email) via Bootstrap Nodes

Bootstrap nodes serve as identity verifiers. This is natural because:
- Users already trust bootstrap nodes to join the network
- Bootstraps are semi-public infrastructure (known endpoints)
- Multiple bootstraps can verify = no single point of trust
- Users can self-host bootstraps = decentralization option

**Claim Structure (Double-Signed):**

Claims require TWO signatures:
1. **Verifier signature** - Bootstrap attests "I verified this claim"
2. **Owner signature** - User attests "I accept this claim as mine"

This prevents bootstraps from creating fake claims without user consent.

```swift
public struct IdentityClaim: Codable, Sendable {
    public enum ClaimType: String, Codable {
        case phone       // Verified phone number
        case email       // Verified email address
        case domain      // Verified domain ownership (DNS TXT record)
    }

    public let type: ClaimType
    public let value: String              // "+15551234567" or "alice@example.com"
    public let ownerPeerId: PeerId        // User who owns this claim
    public let verifierPeerId: PeerId     // Bootstrap node that verified this
    public let verifiedAt: Date
    public let expiresAt: Date?           // Claims expire, require re-verification

    // Double signatures - BOTH required for validity
    public let verifierSignature: String  // Bootstrap signs: (ownerPeerId|type|value|verifiedAt)
    public let ownerSignature: String     // User signs: (type|value|verifierPeerId|verifiedAt)
}

// Validation requires both signatures:
func validateClaim(_ claim: IdentityClaim) async -> Bool {
    // 1. Verify bootstrap's attestation
    let verifierData = "\(claim.ownerPeerId)|\(claim.type)|\(claim.value)|\(claim.verifiedAt)"
    guard verifySignature(claim.verifierSignature, data: verifierData,
                         publicKey: peerPublicKeys[claim.verifierPeerId]) else {
        return false  // Bootstrap didn't verify this
    }

    // 2. Verify user's acceptance
    let ownerData = "\(claim.type)|\(claim.value)|\(claim.verifierPeerId)|\(claim.verifiedAt)"
    guard verifySignature(claim.ownerSignature, data: ownerData,
                         publicKey: peerPublicKeys[claim.ownerPeerId]) else {
        return false  // User didn't accept this claim
    }

    // 3. Check expiration and trust
    // ...
    return true
}
```

**Email Verification Flow (Challenge-Response):**
```
1. User connects to bootstrap, sends: RequestEmailVerification("alice@example.com")

2. Bootstrap generates challenge, responds:
   EmailChallenge(
     challenge: "verify-a1b2c3d4-7f8e9d",
     sendTo: "verify@bootstrap.omerta.io",
     expiresIn: 300  // 5 minutes
   )

3. User sends email:
   FROM: alice@example.com
   TO: verify@bootstrap.omerta.io
   SUBJECT: verify-a1b2c3d4-7f8e9d

4. Bootstrap receives email, validates:
   - DKIM signature valid (proves sender domain)
   - FROM matches claimed email
   - SUBJECT contains correct challenge
   - Within expiration window

5. Bootstrap creates partial claim with its signature:
   EmailVerified(
     partialClaim: PartialClaim(
       type: .email,
       value: "alice@example.com",
       ownerPeerId: userPeerId,
       verifierPeerId: bootstrapPeerId,
       verifierSignature: sign(bootstrapKey, "a1b2c3d4|email|alice@example.com|2024-01-15"),
       verifiedAt: now,
       expiresAt: now + 90days
     )
   )

6. User counter-signs to complete the claim:
   let ownerSignature = sign(userKey, "email|alice@example.com|bootstrapPeerId|2024-01-15")
   let completeClaim = IdentityClaim(
     ...partialClaim,
     ownerSignature: ownerSignature
   )

7. User includes complete (double-signed) claim in PeerAnnouncement

7. Other peers verify:
   - Bootstrap's signature is valid
   - Bootstrap is in their trusted verifiers list
   - Claim hasn't expired
```

**OAuth/OIDC Email Verification (Preferred):**

For a smoother user experience, bootstrap nodes can integrate with OAuth/OIDC providers:

```swift
public enum OAuthProvider: String, Codable {
    case google     // Gmail addresses
    case apple      // Apple ID emails
    case microsoft  // Outlook/Hotmail
    case github     // GitHub verified email
    case facebook   // Facebook email
}

// OAuth verification flow:
// 1. User requests OAuth verification: RequestOAuthVerification(provider: .google)
// 2. Bootstrap returns authorization URL: OAuthChallenge(authUrl: "https://accounts.google.com/...")
// 3. User completes OAuth flow in browser, gets authorization code
// 4. User sends code to bootstrap: OAuthResponse(code: "4/0AX4XfWh...")
// 5. Bootstrap exchanges code for token, fetches email from provider
// 6. Bootstrap creates partial claim with its signature
// 7. User counter-signs to complete the claim
```

This is preferred over email challenge-response because:
- No need for users to manually send emails
- Instant verification (no waiting for email delivery)
- Works with any OAuth-supporting provider
- Bootstrap doesn't need its own SMTP server

```swift
// Additional verification message types for OAuth
public enum VerificationMessage: Codable {
    // ... existing cases ...
    case requestOAuthVerification(provider: OAuthProvider)
    case oauthChallenge(authUrl: String, state: String, expiresIn: Int)
    case oauthResponse(code: String, state: String)
}
```

**Phone Verification Flow (SMS Challenge):**
```
1. User connects to bootstrap, sends: RequestPhoneVerification("+15551234567")

2. Bootstrap generates 6-digit code, sends SMS:
   "Omerta verification code: 847291"

3. Bootstrap responds to user:
   PhoneChallenge(expiresIn: 300)

4. User enters code back to bootstrap:
   PhoneChallengeResponse(code: "847291")

5. Bootstrap validates code, creates partial claim with its signature:
   PhoneVerified(
     partialClaim: PartialClaim(
       type: .phone,
       value: "+15551234567",
       ownerPeerId: userPeerId,
       verifierPeerId: bootstrapPeerId,
       verifierSignature: sign(bootstrapKey, "a1b2c3d4|phone|+15551234567|2024-01-15"),
       verifiedAt: now,
       expiresAt: now + 90days
     )
   )

6. User counter-signs to complete the claim:
   let ownerSignature = sign(userKey, "phone|+15551234567|bootstrapPeerId|2024-01-15")
   let completeClaim = IdentityClaim(...partialClaim, ownerSignature: ownerSignature)

7. User includes complete (double-signed) claim in PeerAnnouncement
```

**Domain Verification Flow (DNS TXT Record):**
```
1. User requests domain verification for "example.com"

2. Bootstrap responds with challenge:
   "Add DNS TXT record: _omerta.example.com = omerta-verify=a1b2c3d4e5f6g7h8"

3. User adds TXT record to their DNS

4. User tells bootstrap to check

5. Bootstrap queries DNS, validates TXT record exists with correct value

6. Bootstrap signs attestation
```

**Bootstrap Verification Protocol Messages:**
```swift
public enum VerificationMessage: Codable {
    // Requests (client → bootstrap)
    case requestEmailVerification(email: String)
    case requestPhoneVerification(phone: String)
    case requestDomainVerification(domain: String)
    case phoneChallengeResponse(code: String)
    case domainChallengeCheck

    // Responses (bootstrap → client)
    case emailChallenge(challenge: String, sendTo: String, expiresIn: Int)
    case phoneChallenge(expiresIn: Int)
    case domainChallenge(txtRecord: String, txtValue: String)
    case verificationSucceeded(claim: IdentityClaim)
    case verificationFailed(reason: String)
}
```

**Bootstrap Verifier Trust:**

Peers automatically trust bootstraps they connect through, but can configure additional trusted verifiers:

```swift
/// Trusted verifiers = bootstrap nodes we trust for identity claims
/// By default, includes bootstraps we've successfully connected through
public actor TrustedVerifiers {
    /// Bootstraps we connected through (automatically trusted)
    private var connectedBootstraps: Set<PeerId> = []

    /// Manually added trusted verifiers
    private var manuallyTrusted: Set<PeerId> = []

    /// Explicitly distrusted (overrides automatic trust)
    private var distrusted: Set<PeerId> = []

    func isTrusted(_ peerId: PeerId) -> Bool {
        guard !distrusted.contains(peerId) else { return false }
        return connectedBootstraps.contains(peerId) || manuallyTrusted.contains(peerId)
    }

    func trustBootstrap(_ peerId: PeerId) {
        connectedBootstraps.insert(peerId)
    }
}
```

**Full Claim Validation (with Trust Check):**
```swift
func validateClaim(_ claim: IdentityClaim) async -> Bool {
    // 1. Check expiration
    if let expires = claim.expiresAt, expires < Date() {
        return false
    }

    // 2. Check verifier is trusted
    guard await trustedVerifiers.isTrusted(claim.verifierPeerId) else {
        return false
    }

    // 3. Verify BOTH signatures (see double-signature section above)
    let verifierData = "\(claim.ownerPeerId)|\(claim.type)|\(claim.value)|\(claim.verifiedAt)"
    guard let verifierKey = peerPublicKeys[claim.verifierPeerId],
          verifySignature(claim.verifierSignature, data: verifierData, publicKey: verifierKey) else {
        return false  // Bootstrap signature invalid
    }

    let ownerData = "\(claim.type)|\(claim.value)|\(claim.verifierPeerId)|\(claim.verifiedAt)"
    guard let ownerKey = peerPublicKeys[claim.ownerPeerId],
          verifySignature(claim.ownerSignature, data: ownerData, publicKey: ownerKey) else {
        return false  // User signature invalid
    }

    return true
}
```

**Multiple Verifier Redundancy:**

Users can verify with multiple bootstraps for stronger trust:

```swift
public struct IdentityClaim {
    // ... existing fields ...

    /// Additional attestations from other verifiers (optional)
    public let additionalAttestations: [Attestation]?
}

// CLI shows verification strength:
// alice@example.com ✓✓✓ (verified by 3 bootstraps)
// bob@example.com ✓ (verified by 1 bootstrap)
```

### 8d. Privacy Considerations

- Display names and claims are **optional** - peers can be anonymous
- Claims reveal real-world identity (phone/email) - user chooses what to share
- Local aliases are private - not shared with network
- Blocked peers list is private

**Selective Disclosure:**
```swift
public struct AnnouncementPrivacy {
    var shareDisplayName: Bool = true
    var shareClaims: [IdentityClaim.ClaimType] = []  // Empty = share none
}
```

### Files to Add/Modify for Phase 8

| File | Changes |
|------|---------|
| `Sources/OmertaMesh/Types/MeshMessage.swift` | Add `displayName` and `claims` to PeerAnnouncement, add `VerificationMessage` enum |
| `Sources/OmertaMesh/Identity/IdentityClaim.swift` | NEW: Claim types, validation, attestation structures |
| `Sources/OmertaMesh/Identity/ContactBook.swift` | NEW: Local alias storage and resolution |
| `Sources/OmertaMesh/Identity/TrustedVerifiers.swift` | NEW: Bootstrap trust management |
| `Sources/OmertaMesh/Identity/DisplayNameIndex.swift` | NEW: Name conflict detection |
| `Sources/OmertaMesh/Bootstrap/VerificationService.swift` | NEW: Bootstrap-side verification logic (email/phone/domain) |
| `Sources/OmertaMesh/MeshNode.swift` | Handle verification protocol messages |
| `Sources/OmertaCore/Identity/` | Bridge to OmertaCore identity if available |

### Bootstrap Node Requirements for Verification

Bootstrap nodes that want to offer verification services need:

| Claim Type | Bootstrap Requirement |
|------------|----------------------|
| Email | SMTP server to receive verification emails (e.g., verify@bootstrap.example.com) |
| Phone | SMS gateway access (Twilio, AWS SNS, or similar) |
| Domain | DNS resolver (standard, no special setup) |

Bootstraps can choose which verification types to support. The `PeerAnnouncement` for a bootstrap includes its capabilities:

```swift
public struct BootstrapCapabilities {
    let supportsRelay: Bool
    let supportsHolePunchCoordination: Bool
    let supportsVerification: [IdentityClaim.ClaimType]  // e.g., [.email, .domain]
}
```

---

## Migration Notes

- Existing peer IDs will change format (base64 → hex)
- No backwards compatibility needed (mesh is not in production)
- CLI users will need to remove any --peerId flags
