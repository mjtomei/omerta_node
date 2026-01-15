# Mesh Relay Network

A decentralized P2P overlay network where any public node can act as a relay for NAT-bound peers.

## Overview

### What This Is

A **standalone transport layer** that provides:

1. **Participant Management**: Peer discovery, announcements, tracking who's online
2. **Connection Liveness**: Keepalives, failure detection, reconnection
3. **Message Routing**: Send messages to any peer (via relay if needed)
4. **Direct Connection Establishment**: Hole punching for creating direct UDP paths

### What This Is NOT

This layer is **not aware of**:
- Control plane semantics (VM requests, provider/consumer roles)
- Data plane traffic (WireGuard, application data)
- Message contents (opaque bytes to this layer)

Higher-level code uses this as a transport:
```swift
// Higher-level code (control plane, etc.)
let mesh = MeshNetwork(config: ...)
try await mesh.start()

// Send a message to a peer (mesh handles routing)
try await mesh.send(data: controlMessage, to: targetPeerId)

// Create a direct connection for high-bandwidth data
let directConn = try await mesh.establishDirectConnection(to: targetPeerId)
// Now use directConn.endpoint for WireGuard peer config
```

### Goals

1. **Universal Reachability**: Any peer can reach any other peer, regardless of NAT
2. **No Special Infrastructure**: No dedicated relay servers - any public node can relay
3. **Resilience**: Multiple paths to each peer, graceful degradation on failure
4. **Freshness**: Mechanism to recover from stale connection info
5. **Efficiency**: Direct connections when possible, relay only when necessary
6. **Clean Abstraction**: Simple API for higher-level code

### Non-Goals

- Strong consistency (eventual consistency is acceptable)
- Anonymity (peers know who they're talking to)
- Guaranteed delivery (best effort, higher layers handle retries)
- Understanding message semantics (opaque bytes)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         The Mesh                                 │
│                                                                  │
│    ┌───┐         ┌───┐         ┌───┐         ┌───┐              │
│    │ A │◄═══════►│ B │◄═══════►│ C │◄═══════►│ D │   Public     │
│    │pub│         │pub│         │pub│         │pub│   nodes      │
│    └─┬─┘         └─┬─┘         └─┬─┘         └─┬─┘              │
│      ║             ║             ║             ║                 │
│      ║    ┌───┐    ║    ┌───┐    ║    ┌───┐    ║                 │
│      ╚═══►│ E │◄═══╝    │ F │◄═══╝    │ G │◄═══╝    NAT nodes   │
│           │NAT│         │NAT│         │NAT│                      │
│           └───┘         └───┘         └───┘                      │
│                                                                  │
│  ═══  Persistent connection (relay path)                         │
│  ───  Ephemeral connection (direct or via relay)                 │
│                                                                  │
│  E maintains connections to A, B (its relays)                    │
│  E announces: "Reach me via A or B"                              │
│  F wants to reach E: connects to A, asks A to relay to E         │
└─────────────────────────────────────────────────────────────────┘
```

## Public API

### MeshNetwork

The main entry point for higher-level code:

```swift
/// The mesh network transport layer
public actor MeshNetwork {
    /// Initialize with configuration
    public init(identity: IdentityKeypair, config: MeshConfig)

    /// Start the mesh network (NAT detection, bootstrap, announce)
    public func start() async throws

    /// Stop the mesh network
    public func stop() async

    // ─── Participant Management ───

    /// Our peer ID
    public var peerId: String { get }

    /// Our current NAT type
    public var natType: NATType { get async }

    /// List of currently connected peers
    public var connectedPeers: [String] { get async }

    /// Check if a peer is currently reachable
    public func isPeerOnline(_ peerId: String) async -> Bool

    /// Get announcement for a peer (from cache or network query)
    public func getPeerInfo(_ peerId: String) async throws -> PeerAnnouncement

    // ─── Message Routing ───

    /// Send opaque data to a peer (handles routing automatically)
    /// Returns when message is delivered (or throws on failure)
    public func send(data: Data, to peerId: String) async throws

    /// Send and wait for response
    public func sendAndReceive(data: Data, to peerId: String, timeout: TimeInterval) async throws -> Data

    /// Register handler for incoming messages
    public func onMessage(_ handler: @escaping (Data, String) async -> Data?) async

    // ─── Direct Connection Establishment ───

    /// Establish a direct UDP connection to a peer (hole punch if needed)
    /// Returns the endpoint that can be used for direct communication
    /// This is used by higher layers (e.g., WireGuard) that need a direct path
    public func establishDirectConnection(to peerId: String) async throws -> DirectConnection

    // ─── Events ───

    /// Subscribe to network events
    public func onEvent(_ handler: @escaping (MeshEvent) async -> Void) async
}

/// A direct UDP connection established via hole punching
public struct DirectConnection {
    /// The remote endpoint (IP:port) for direct communication
    public let endpoint: String

    /// The local port we're using
    public let localPort: UInt16

    /// How the connection was established
    public let connectionType: ConnectionType

    /// Estimated round-trip time
    public let estimatedRTT: TimeInterval
}

/// Events emitted by the mesh network
public enum MeshEvent {
    case peerConnected(peerId: String)
    case peerDisconnected(peerId: String)
    case relayEstablished(relayPeerId: String)
    case relayLost(relayPeerId: String)
    case natTypeChanged(old: NATType, new: NATType)
    case directConnectionEstablished(peerId: String, endpoint: String)
    case directConnectionFailed(peerId: String, reason: String)
}
```

### Usage Example

```swift
// Initialize mesh network
let identity = try IdentityKeypair.generate()
let config = MeshConfig(
    bootstrapNodes: ["bootstrap1.example.com:7000", "bootstrap2.example.com:7000"]
)
let mesh = MeshNetwork(identity: identity, config: config)

// Start and join the network
try await mesh.start()

// Register message handler (for control plane messages)
await mesh.onMessage { data, fromPeerId in
    let message = try? JSONDecoder().decode(ControlMessage.self, from: data)
    // Process message...
    let response = handleControlMessage(message)
    return try? JSONEncoder().encode(response)
}

// Send a control message to a peer
let request = VMRequest(...)
let requestData = try JSONEncoder().encode(request)
let responseData = try await mesh.sendAndReceive(data: requestData, to: providerPeerId, timeout: 30)
let response = try JSONDecoder().decode(VMResponse.self, from: responseData)

// Establish direct connection for WireGuard
let direct = try await mesh.establishDirectConnection(to: providerPeerId)
print("WireGuard peer endpoint: \(direct.endpoint)")

// Subscribe to events
await mesh.onEvent { event in
    switch event {
    case .peerDisconnected(let peerId):
        print("Peer \(peerId) went offline")
    case .directConnectionFailed(let peerId, let reason):
        print("Could not establish direct connection to \(peerId): \(reason)")
    default:
        break
    }
}
```

## Node Roles

Roles are **dynamic**, determined by NAT type at runtime:

| Role | NAT Type | Behavior |
|------|----------|----------|
| **Public** | None / Full Cone | Can receive unsolicited connections, can relay for others |
| **Hole-Punchable** | Restricted / Port-Restricted Cone | Can receive after sending first, may need relay |
| **Relay-Only** | Symmetric | Must use relay for all incoming connections |

A node discovers its role via STUN at startup and may re-evaluate periodically.

## Data Structures

### Local Node State

```swift
/// What each node knows about itself
struct LocalNodeState {
    let identity: IdentityKeypair
    var natType: NATType
    var publicEndpoint: String?           // If public/hole-punched
    var relayConnections: [RelayConnection]  // Active relay peers
    var recentContacts: [String: RecentContact]  // Who we've talked to recently
}

enum NATType: String, Codable {
    case public              // No NAT, globally routable
    case fullCone            // Any external host can send after we send once
    case restrictedCone      // Only IPs we've sent to can reply
    case portRestrictedCone  // Only IP:port pairs we've sent to can reply
    case symmetric           // Different external port per destination
    case unknown
}
```

### Relay Connection

```swift
/// A persistent connection to a relay peer
struct RelayConnection: Identifiable {
    let id: String
    let relayPeerId: String
    let relayEndpoint: String      // Their public IP:port
    let connectedAt: Date
    var lastHeartbeat: Date
    var latencyMs: Int
    var isHealthy: Bool { Date().timeIntervalSince(lastHeartbeat) < 30 }
}
```

### Peer Announcement

```swift
/// Broadcast to the network: "Here's how to reach me"
struct PeerAnnouncement: Codable, Sendable {
    let peerId: String
    let publicKey: String
    let reachability: [ReachabilityPath]  // Ordered by preference
    let capabilities: [String]            // "provider", "relay", etc.
    let timestamp: Date
    let ttl: TimeInterval
    let signature: String

    var isExpired: Bool { Date().timeIntervalSince(timestamp) > ttl }
}

enum ReachabilityPath: Codable, Sendable {
    /// Direct connection to public endpoint
    case direct(endpoint: String)

    /// Via a relay peer
    case relay(relayPeerId: String, relayEndpoint: String)

    /// Hole-punchable (need coordination)
    case holePunch(publicIP: String, stunEndpoint: String)
}
```

### Recent Contact

```swift
/// Track who we've communicated with recently
struct RecentContact {
    let peerId: String
    let lastSeen: Date
    let reachability: ReachabilityPath   // How we reached them
    let latencyMs: Int
    let connectionType: ConnectionType

    var age: TimeInterval { Date().timeIntervalSince(lastSeen) }
}

enum ConnectionType {
    case direct          // We connected directly
    case inboundDirect   // They connected to us directly
    case viaRelay        // Through a relay
    case holePunched     // Established via hole punching
}
```

## Protocol Messages

### Message Envelope

```swift
/// All messages wrapped in envelope with routing info
struct MeshEnvelope: Codable {
    let messageId: String        // For deduplication
    let fromPeerId: String
    let toPeerId: String?        // nil = broadcast
    let hopCount: Int            // Prevent infinite loops
    let timestamp: Date
    let payload: MeshMessage
    let signature: String
}
```

### Message Types

```swift
enum MeshMessage: Codable {
    // ─── Announcement (Gossip) ───

    /// Broadcast reachability info
    case announce(PeerAnnouncement)

    /// "I can relay for these peers" (public nodes broadcast this)
    case relayCapacity(peerIds: [String], availableSlots: Int)

    // ─── Discovery ───

    /// "How do I reach peer X?"
    case findPeer(peerId: String)

    /// "Here's what I know about X"
    case peerInfo(PeerAnnouncement)

    /// "Never heard of X"
    case peerNotFound(peerId: String)

    // ─── Freshness Queries ───

    /// "Who's talked to X recently?"
    case whoHasRecent(peerId: String, maxAgeSeconds: Int)

    /// "I talked to X N seconds ago, here's how"
    case iHaveRecent(peerId: String, contact: RecentContact)

    /// "This path to X failed for me"
    case pathFailed(peerId: String, path: ReachabilityPath, failedAt: Date)

    // ─── Relay Control ───

    /// "Please relay my connection to X"
    case relayRequest(targetPeerId: String, sessionId: String)

    /// "OK, relay session established"
    case relayAccept(sessionId: String)

    /// "Can't relay: reason"
    case relayDeny(sessionId: String, reason: String)

    /// "Relay session ended"
    case relayEnd(sessionId: String)

    // ─── Relayed Data ───

    /// Data forwarded through relay
    case relayData(sessionId: String, data: Data)

    // ─── Hole Punching ───

    /// "Help us hole punch" (to relay/coordinator)
    case holePunchRequest(targetPeerId: String, myEndpoint: String, myNATType: NATType)

    /// "Peer X wants to hole punch with you"
    case holePunchInvite(fromPeerId: String, theirEndpoint: String, theirNATType: NATType)

    /// "Send probes NOW to this endpoint"
    case holePunchExecute(targetEndpoint: String, strategy: HolePunchStrategy)

    /// "Hole punch succeeded/failed"
    case holePunchResult(targetPeerId: String, success: Bool, establishedEndpoint: String?)

    // ─── Keepalive ───

    /// Heartbeat
    case ping(recentPeers: [String])  // Include who we've talked to

    /// Heartbeat response
    case pong(recentPeers: [String])
}

enum HolePunchStrategy: String, Codable {
    case simultaneous   // Both send at coordinated time
    case youFirst       // You send first (you're symmetric)
    case theyFirst      // They send first (they're symmetric)
}
```

## Node Lifecycle

### 1. Startup and NAT Detection

```swift
actor MeshNode {
    func start() async throws {
        // 1. Detect NAT type via STUN
        let natResult = try await detectNAT()
        self.natType = natResult.type
        self.publicEndpoint = natResult.publicEndpoint

        logger.info("NAT detection complete", metadata: [
            "type": "\(natResult.type)",
            "publicEndpoint": "\(natResult.publicEndpoint ?? "none")"
        ])

        // 2. Start listening (if public)
        if natResult.type == .public || natResult.type == .fullCone {
            try await startListener(port: config.listenPort)
        }

        // 3. Bootstrap into network
        try await bootstrap()

        // 4. Set up reachability based on NAT type
        switch natResult.type {
        case .public, .fullCone:
            await setupAsPublicNode()
        case .restrictedCone, .portRestrictedCone:
            await setupAsHolePunchableNode()
        case .symmetric, .unknown:
            await setupAsRelayOnlyNode()
        }

        // 5. Start background tasks
        startKeepaliveTask()
        startAnnouncementTask()
        startCleanupTask()
    }

    private func detectNAT() async throws -> NATDetectionResult {
        let stunClient = STUNClient()
        return try await stunClient.detectNATType(
            servers: config.stunServers,
            localPort: config.listenPort
        )
    }
}
```

### 2. Bootstrap

```swift
extension MeshNode {
    func bootstrap() async throws {
        // Connect to bootstrap nodes to join the network
        var connected = 0

        for bootstrapAddr in config.bootstrapNodes {
            do {
                let conn = try await connect(to: bootstrapAddr)
                connectedPeers[conn.peerId] = conn
                connected += 1

                // Ask bootstrap node for more peers
                let response = await conn.send(.findPeer(peerId: self.peerId))
                if case .peerInfo(let announcements) = response {
                    for ann in announcements {
                        peerCache[ann.peerId] = ann
                    }
                }
            } catch {
                logger.warning("Bootstrap failed: \(bootstrapAddr)", metadata: ["error": "\(error)"])
            }
        }

        guard connected > 0 else {
            throw MeshError.bootstrapFailed
        }

        logger.info("Bootstrap complete", metadata: ["connectedPeers": "\(connected)"])
    }
}
```

### 3. Relay Selection (NAT Nodes)

```swift
extension MeshNode {
    func setupAsRelayOnlyNode() async {
        // Find and connect to relay peers
        await selectRelays(count: config.targetRelayCount)  // Default: 3

        // Announce our reachability via relays
        await announceViaRelays()
    }

    func selectRelays(count: Int) async {
        // Find public peers that can relay
        let candidates = await findPublicPeers(count: count * 3)

        // Sort by latency and capacity
        let sorted = candidates.sorted { a, b in
            // Prefer low latency, high available slots
            let scoreA = Double(a.latencyMs) - Double(a.availableRelaySlots) * 10
            let scoreB = Double(b.latencyMs) - Double(b.availableRelaySlots) * 10
            return scoreA < scoreB
        }

        // Connect to top candidates
        for candidate in sorted.prefix(count) {
            do {
                let conn = try await connect(to: candidate.endpoint)

                // Request relay service
                let response = await conn.send(.relayRequest(
                    targetPeerId: self.peerId,
                    sessionId: UUID().uuidString
                ))

                if case .relayAccept(let sessionId) = response {
                    let relay = RelayConnection(
                        id: sessionId,
                        relayPeerId: candidate.peerId,
                        relayEndpoint: candidate.endpoint,
                        connectedAt: Date(),
                        lastHeartbeat: Date(),
                        latencyMs: candidate.latencyMs
                    )
                    relayConnections.append(relay)
                    logger.info("Relay established", metadata: ["relay": "\(candidate.peerId)"])
                }
            } catch {
                logger.debug("Failed to establish relay", metadata: [
                    "candidate": "\(candidate.peerId)",
                    "error": "\(error)"
                ])
            }

            if relayConnections.count >= count { break }
        }

        if relayConnections.isEmpty {
            logger.error("Failed to establish any relay connections")
        }
    }
}
```

### 4. Announcement

```swift
extension MeshNode {
    func announceViaRelays() async {
        let paths: [ReachabilityPath] = relayConnections.map { conn in
            .relay(relayPeerId: conn.relayPeerId, relayEndpoint: conn.relayEndpoint)
        }

        let announcement = PeerAnnouncement(
            peerId: identity.peerId,
            publicKey: identity.publicKey,
            reachability: paths,
            capabilities: determineCapabilities(),
            timestamp: Date(),
            ttl: config.announcementTTL  // Default: 1 hour
        ).signed(with: identity)

        // Gossip to all connected peers
        await broadcast(.announce(announcement))

        // Store locally
        self.currentAnnouncement = announcement
    }

    func announceAsPublic() async {
        let announcement = PeerAnnouncement(
            peerId: identity.peerId,
            publicKey: identity.publicKey,
            reachability: [.direct(endpoint: publicEndpoint!)],
            capabilities: determineCapabilities() + ["relay"],  // Public nodes can relay
            timestamp: Date(),
            ttl: config.announcementTTL
        ).signed(with: identity)

        await broadcast(.announce(announcement))
        self.currentAnnouncement = announcement
    }

    private func determineCapabilities() -> [String] {
        var caps: [String] = []
        if isProvider { caps.append("provider") }
        if natType == .public || natType == .fullCone { caps.append("relay") }
        return caps
    }
}
```

## Peer Discovery and Connection

### Finding a Peer

```swift
extension MeshNode {
    /// Main entry point for connecting to a peer
    func connect(to targetPeerId: String) async throws -> PeerConnection {
        // 1. Check if already connected
        if let existing = connectedPeers[targetPeerId], existing.isHealthy {
            return existing
        }

        // 2. Try cached info first
        if let cached = peerCache[targetPeerId], !cached.isExpired {
            if let conn = try? await tryConnect(using: cached) {
                return conn
            }
            // Cache was stale, continue to fresh lookup
        }

        // 3. Get fresh info
        let freshInfo = try await findFreshPeerInfo(targetPeerId)

        // 4. Try to connect using fresh info
        return try await tryConnect(using: freshInfo)
    }

    private func tryConnect(using announcement: PeerAnnouncement) async throws -> PeerConnection {
        var lastError: Error = MeshError.peerUnreachable(announcement.peerId)

        for path in announcement.reachability {
            do {
                switch path {
                case .direct(let endpoint):
                    return try await connectDirect(to: endpoint, peerId: announcement.peerId)

                case .relay(let relayPeerId, let relayEndpoint):
                    return try await connectViaRelay(
                        relayPeerId: relayPeerId,
                        relayEndpoint: relayEndpoint,
                        targetPeerId: announcement.peerId
                    )

                case .holePunch(let publicIP, let stunEndpoint):
                    return try await connectViaHolePunch(
                        targetPeerId: announcement.peerId,
                        theirPublicIP: publicIP
                    )
                }
            } catch {
                lastError = error
                // Report failed path so others know
                await broadcast(.pathFailed(
                    peerId: announcement.peerId,
                    path: path,
                    failedAt: Date()
                ))
            }
        }

        throw lastError
    }
}
```

### Freshness Queries

```swift
extension MeshNode {
    /// Ask the network for fresh info about a peer
    func findFreshPeerInfo(_ targetPeerId: String) async throws -> PeerAnnouncement {
        // Ask all connected peers: "Who's talked to X recently?"
        var responses: [RecentContact] = []

        await withTaskGroup(of: RecentContact?.self) { group in
            for (_, peer) in connectedPeers {
                group.addTask {
                    let response = try? await peer.send(
                        .whoHasRecent(peerId: targetPeerId, maxAgeSeconds: 300),
                        timeout: 5.0
                    )
                    if case .iHaveRecent(_, let contact) = response {
                        return contact
                    }
                    return nil
                }
            }

            for await response in group {
                if let contact = response {
                    responses.append(contact)
                }
            }
        }

        // Sort by freshness (most recent first)
        let sorted = responses.sorted { $0.lastSeen > $1.lastSeen }

        if let freshest = sorted.first {
            // Build announcement from fresh contact info
            let announcement = PeerAnnouncement(
                peerId: targetPeerId,
                publicKey: "", // Will be verified on connection
                reachability: [freshest.reachability],
                capabilities: [],
                timestamp: freshest.lastSeen,
                ttl: 300
            )

            // Update cache
            peerCache[targetPeerId] = announcement

            return announcement
        }

        // Nobody has recent contact - try DHT/gossip cache
        if let cached = peerCache[targetPeerId] {
            return cached
        }

        throw MeshError.peerNotFound(targetPeerId)
    }
}
```

### Handling `whoHasRecent` Queries

```swift
extension MeshNode {
    func handleWhoHasRecent(peerId: String, maxAgeSeconds: Int, from sender: PeerConnection) async {
        // Check our recent contacts
        if let contact = recentContacts[peerId], contact.age < TimeInterval(maxAgeSeconds) {
            await sender.send(.iHaveRecent(peerId: peerId, contact: contact))
        }

        // Optionally forward to peers we haven't asked (gossip query)
        // Be careful not to create query storms
    }
}
```

## Relay Operation

The mesh network supports two relay modes:

1. **Message Relay** (current): Relays opaque message payloads through the mesh protocol. Used for control plane messages and any application data sent via `mesh.send()`. Messages are wrapped in `MeshMessage.relayData` envelopes.

2. **Transparent UDP Relay** (future): Raw UDP packet forwarding for high-throughput scenarios like relaying WireGuard traffic. The relay doesn't inspect or wrap packets - it just maintains a port mapping and forwards. See [Future Enhancements](#future-enhancements) for details.

### Public Node as Relay

```swift
extension MeshNode {
    /// Handle request to relay for a peer
    func handleRelayRequest(from requester: PeerConnection, targetPeerId: String, sessionId: String) async {
        // 1. Check if we're connected to target
        guard let targetConn = connectedPeers[targetPeerId] else {
            await requester.send(.relayDeny(sessionId: sessionId, reason: "Not connected to target"))
            return
        }

        // 2. Check capacity
        guard activeRelaySessions.count < config.maxRelaySessions else {
            await requester.send(.relayDeny(sessionId: sessionId, reason: "At capacity"))
            return
        }

        // 3. Create relay session
        let session = RelaySession(
            id: sessionId,
            requester: requester,
            target: targetConn,
            startedAt: Date()
        )
        activeRelaySessions[sessionId] = session

        // 4. Notify both sides
        await requester.send(.relayAccept(sessionId: sessionId))

        // 5. Start forwarding data
        Task {
            await session.startBidirectionalForwarding()
        }

        logger.info("Relay session started", metadata: [
            "sessionId": "\(sessionId)",
            "from": "\(requester.peerId)",
            "to": "\(targetPeerId)"
        ])
    }
}

actor RelaySession {
    let id: String
    let requester: PeerConnection
    let target: PeerConnection
    let startedAt: Date
    var bytesForwarded: Int = 0

    func startBidirectionalForwarding() async {
        // Forward in both directions until session ends
        await withTaskGroup(of: Void.self) { group in
            // Requester → Target
            group.addTask {
                for await data in self.requester.incomingData {
                    if case .relayData(let sid, let payload) = data, sid == self.id {
                        await self.target.send(.relayData(sessionId: self.id, data: payload))
                        self.bytesForwarded += payload.count
                    }
                }
            }

            // Target → Requester
            group.addTask {
                for await data in self.target.incomingData {
                    if case .relayData(let sid, let payload) = data, sid == self.id {
                        await self.requester.send(.relayData(sessionId: self.id, data: payload))
                        self.bytesForwarded += payload.count
                    }
                }
            }
        }
    }
}
```

## Hole Punching

### When to Hole Punch

Hole punching is attempted when:
1. Both peers are hole-punchable (restricted cone or port-restricted cone)
2. Direct connection fails but peers are on different networks
3. Relay latency is unacceptable

### Hole Punch Flow

```
    Peer A                    Coordinator                    Peer B
    (NAT)                    (Public Node)                   (NAT)
      │                           │                            │
      │──holePunchRequest────────►│                            │
      │  (target: B,              │                            │
      │   myEndpoint: A_pub,      │                            │
      │   myNATType: portRestricted)                           │
      │                           │                            │
      │                           │◄──holePunchRequest─────────│
      │                           │   (target: A,              │
      │                           │    myEndpoint: B_pub,      │
      │                           │    myNATType: restricted)  │
      │                           │                            │
      │                           │  [Determine strategy:      │
      │                           │   both cone → simultaneous]│
      │                           │                            │
      │◄─holePunchExecute─────────│───holePunchExecute────────►│
      │  (target: B_pub,          │   (target: A_pub,          │
      │   strategy: simultaneous) │    strategy: simultaneous) │
      │                           │                            │
      │════════════════UDP probes═══════════════════════════════│
      │                           │                            │
      │◄═══════════════════Direct Connection══════════════════►│
      │                           │                            │
      │──holePunchResult─────────►│◄──holePunchResult──────────│
      │  (success: true)          │   (success: true)          │
```

### Implementation

```swift
extension MeshNode {
    /// Initiate hole punch to a peer
    func holePunch(to targetPeerId: String) async throws -> PeerConnection {
        // 1. Find a coordinator (public peer connected to both of us)
        let coordinator = try await findHolePunchCoordinator(for: targetPeerId)

        // 2. Discover our current public endpoint
        let myEndpoint = try await stunClient.discoverEndpoint(localPort: config.listenPort)

        // 3. Send hole punch request to coordinator
        await coordinator.send(.holePunchRequest(
            targetPeerId: targetPeerId,
            myEndpoint: myEndpoint,
            myNATType: self.natType
        ))

        // 4. Wait for execute instruction
        let executeMsg = try await waitForMessage(type: .holePunchExecute, timeout: 10.0)
        guard case .holePunchExecute(let targetEndpoint, let strategy) = executeMsg else {
            throw MeshError.holePunchFailed("No execute instruction received")
        }

        // 5. Execute hole punch
        let puncher = HolePuncher()
        let result = try await puncher.execute(
            localPort: config.listenPort,
            targetEndpoint: targetEndpoint,
            strategy: strategy
        )

        // 6. Report result
        await coordinator.send(.holePunchResult(
            targetPeerId: targetPeerId,
            success: result.success,
            establishedEndpoint: result.actualEndpoint
        ))

        if result.success, let endpoint = result.actualEndpoint {
            // 7. Establish connection over punched hole
            return try await connectDirect(to: endpoint, peerId: targetPeerId)
        } else {
            throw MeshError.holePunchFailed("Hole punch unsuccessful")
        }
    }

    /// Handle hole punch coordination (public nodes only)
    func handleHolePunchCoordination(
        requesterA: PeerConnection, endpointA: String, natTypeA: NATType,
        requesterB: PeerConnection, endpointB: String, natTypeB: NATType
    ) async {
        // Determine strategy based on NAT types
        let strategy = determineHolePunchStrategy(natTypeA, natTypeB)

        if strategy == .impossible {
            await requesterA.send(.holePunchResult(targetPeerId: requesterB.peerId, success: false, establishedEndpoint: nil))
            await requesterB.send(.holePunchResult(targetPeerId: requesterA.peerId, success: false, establishedEndpoint: nil))
            return
        }

        // Send execute instructions to both
        switch strategy {
        case .simultaneous:
            // Both send at the same time
            await requesterA.send(.holePunchExecute(targetEndpoint: endpointB, strategy: .simultaneous))
            await requesterB.send(.holePunchExecute(targetEndpoint: endpointA, strategy: .simultaneous))

        case .aFirst:
            // A sends first (A is symmetric, B is cone)
            await requesterA.send(.holePunchExecute(targetEndpoint: endpointB, strategy: .youFirst))
            // Wait a bit, then tell B to send
            try? await Task.sleep(nanoseconds: 500_000_000)
            await requesterB.send(.holePunchExecute(targetEndpoint: endpointA, strategy: .theyFirst))

        case .bFirst:
            // B sends first
            await requesterB.send(.holePunchExecute(targetEndpoint: endpointA, strategy: .youFirst))
            try? await Task.sleep(nanoseconds: 500_000_000)
            await requesterA.send(.holePunchExecute(targetEndpoint: endpointB, strategy: .theyFirst))

        case .impossible:
            break // Already handled above
        }
    }

    func determineHolePunchStrategy(_ a: NATType, _ b: NATType) -> HolePunchStrategyDecision {
        switch (a, b) {
        case (.symmetric, .symmetric):
            return .impossible
        case (.symmetric, _):
            return .aFirst  // Symmetric sends first to create mapping
        case (_, .symmetric):
            return .bFirst
        default:
            return .simultaneous  // Both cone types can do simultaneous
        }
    }
}

enum HolePunchStrategyDecision {
    case simultaneous
    case aFirst
    case bFirst
    case impossible
}
```

### Hole Punch Probes

```swift
actor HolePuncher {
    /// Magic bytes to identify hole punch probes
    static let probeMagic: [UInt8] = [0x4F, 0x4D, 0x48, 0x50]  // "OMHP"

    func execute(
        localPort: UInt16,
        targetEndpoint: String,
        strategy: HolePunchStrategy,
        timeout: TimeInterval = 10.0
    ) async throws -> HolePunchResult {
        let socket = try UDPSocket(localPort: localPort)
        defer { socket.close() }

        let startTime = Date()

        switch strategy {
        case .simultaneous, .youFirst:
            // Send probes immediately
            for i in 0..<10 {
                try await sendProbe(socket: socket, to: targetEndpoint, sequence: UInt32(i))
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms between probes
            }

        case .theyFirst:
            // Wait briefly for their probes to arrive first
            try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
            for i in 0..<10 {
                try await sendProbe(socket: socket, to: targetEndpoint, sequence: UInt32(i))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // Wait for response
        if let (responseEndpoint, _) = try await waitForProbe(socket: socket, timeout: timeout) {
            return HolePunchResult(
                success: true,
                actualEndpoint: responseEndpoint,
                rtt: Date().timeIntervalSince(startTime)
            )
        }

        return HolePunchResult(success: false, actualEndpoint: nil, rtt: 0)
    }

    private func sendProbe(socket: UDPSocket, to endpoint: String, sequence: UInt32) async throws {
        var packet = Data(Self.probeMagic)
        packet.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: UInt64(Date().timeIntervalSince1970 * 1000).bigEndian) { Array($0) })
        try await socket.send(packet, to: endpoint)
    }
}

struct HolePunchResult {
    let success: Bool
    let actualEndpoint: String?
    let rtt: TimeInterval
}
```

## Background Tasks

### Keepalive

```swift
extension MeshNode {
    func startKeepaliveTask() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(config.keepaliveInterval * 1_000_000_000))

                // Ping all connected peers
                for (peerId, conn) in connectedPeers {
                    let recentPeerIds = Array(recentContacts.keys.prefix(10))

                    if let response = try? await conn.send(.ping(recentPeers: recentPeerIds), timeout: 5.0) {
                        if case .pong(let theirRecent) = response {
                            // Update our knowledge of who they've talked to
                            for peer in theirRecent {
                                if peerCache[peer] == nil {
                                    // They know a peer we don't - could query for info
                                }
                            }
                        }
                        conn.lastHeartbeat = Date()
                    } else {
                        // Peer unresponsive
                        conn.missedHeartbeats += 1
                        if conn.missedHeartbeats > 3 {
                            await handlePeerDisconnect(peerId)
                        }
                    }
                }

                // Ping relay connections
                for relay in relayConnections {
                    if let conn = connectedPeers[relay.relayPeerId] {
                        // Already pinged above
                        relay.lastHeartbeat = conn.lastHeartbeat
                    }
                }

                // Check if we need more relays
                let healthyRelays = relayConnections.filter { $0.isHealthy }.count
                if natType != .public && healthyRelays < config.minRelayCount {
                    await selectRelays(count: config.targetRelayCount - healthyRelays)
                    await announceViaRelays()
                }
            }
        }
    }
}
```

### Periodic Re-announcement

```swift
extension MeshNode {
    func startAnnouncementTask() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(config.reannounceInterval * 1_000_000_000))

                // Re-announce with fresh timestamp
                switch natType {
                case .public, .fullCone:
                    await announceAsPublic()
                default:
                    await announceViaRelays()
                }
            }
        }
    }
}
```

## Testing Infrastructure

### Goals

1. **Unit tests**: Test individual components in isolation
2. **Integration tests**: Test node interactions on localhost
3. **Network simulation**: Test with simulated NAT, latency, packet loss
4. **Fault injection**: Test recovery from node failures, network partitions

### Test Network Builder

```swift
/// Build test networks with various topologies
class TestNetworkBuilder {
    var nodes: [TestNode] = []
    var nats: [SimulatedNAT] = []
    var links: [NetworkLink] = []

    /// Add a public node
    func addPublicNode(id: String) -> TestNode {
        let node = TestNode(id: id, natType: .public)
        nodes.append(node)
        return node
    }

    /// Add a node behind NAT
    func addNATNode(id: String, natType: NATType) -> TestNode {
        let nat = SimulatedNAT(type: natType)
        let node = TestNode(id: id, natType: natType, nat: nat)
        nodes.append(node)
        nats.append(nat)
        return node
    }

    /// Create link between nodes with optional latency/loss
    func link(_ a: TestNode, _ b: TestNode, latencyMs: Int = 0, lossPercent: Double = 0) {
        let link = NetworkLink(from: a, to: b, latencyMs: latencyMs, lossPercent: lossPercent)
        links.append(link)
    }

    /// Build and start the test network
    func build() async throws -> TestNetwork {
        let network = TestNetwork(nodes: nodes, nats: nats, links: links)
        try await network.start()
        return network
    }
}
```

### Simulated NAT

```swift
/// Simulates NAT behavior for testing
actor SimulatedNAT {
    let type: NATType
    var mappings: [String: NATMapping] = [:]  // internal:port -> external:port
    var nextExternalPort: UInt16 = 10000

    struct NATMapping {
        let internalEndpoint: String
        let externalEndpoint: String
        let createdAt: Date
        let destinationFilter: String?  // For restricted NAT
        var lastUsed: Date
    }

    func translate(from internal: String, to destination: String) -> String? {
        let key = "\(internal)->\(destination)"

        if let existing = mappings[key], !isExpired(existing) {
            // Update last used
            mappings[key]?.lastUsed = Date()
            return existing.externalEndpoint
        }

        // Create new mapping
        switch type {
        case .fullCone:
            // Same external port for all destinations
            let simpleKey = internal
            if let existing = mappings[simpleKey] {
                return existing.externalEndpoint
            }
            let external = "10.0.0.1:\(nextExternalPort)"
            nextExternalPort += 1
            mappings[simpleKey] = NATMapping(
                internalEndpoint: internal,
                externalEndpoint: external,
                createdAt: Date(),
                destinationFilter: nil,
                lastUsed: Date()
            )
            return external

        case .restrictedCone:
            // Same port, but track allowed source IPs
            // ...

        case .portRestrictedCone:
            // Same port, but track allowed source IP:ports
            // ...

        case .symmetric:
            // Different port for each destination
            let external = "10.0.0.1:\(nextExternalPort)"
            nextExternalPort += 1
            mappings[key] = NATMapping(
                internalEndpoint: internal,
                externalEndpoint: external,
                createdAt: Date(),
                destinationFilter: destination,
                lastUsed: Date()
            )
            return external

        default:
            return nil
        }
    }

    func allowIncoming(from source: String, to external: String) -> String? {
        // Check if there's a mapping that allows this incoming packet
        for (_, mapping) in mappings {
            if mapping.externalEndpoint == external {
                switch type {
                case .fullCone:
                    return mapping.internalEndpoint  // Always allow
                case .restrictedCone:
                    // Allow if we've sent to this IP
                    if mapping.destinationFilter?.hasPrefix(source.split(separator: ":").first ?? "") == true {
                        return mapping.internalEndpoint
                    }
                case .portRestrictedCone:
                    // Allow if we've sent to this exact IP:port
                    if mapping.destinationFilter == source {
                        return mapping.internalEndpoint
                    }
                case .symmetric:
                    if mapping.destinationFilter == source {
                        return mapping.internalEndpoint
                    }
                default:
                    break
                }
            }
        }
        return nil  // Packet dropped
    }

    private func isExpired(_ mapping: NATMapping) -> Bool {
        Date().timeIntervalSince(mapping.lastUsed) > 120  // 2 minute timeout
    }
}
```

### Fault Injection

```swift
/// Inject faults into test network
actor FaultInjector {
    enum Fault {
        case nodeFailure(nodeId: String)
        case networkPartition(group1: [String], group2: [String])
        case latencySpike(nodeId: String, additionalMs: Int, duration: TimeInterval)
        case packetLoss(nodeId: String, percent: Double, duration: TimeInterval)
        case natMappingExpiry(nodeId: String)
    }

    func inject(_ fault: Fault, into network: TestNetwork) async {
        switch fault {
        case .nodeFailure(let nodeId):
            await network.killNode(nodeId)

        case .networkPartition(let group1, let group2):
            await network.partition(group1, from: group2)

        case .latencySpike(let nodeId, let ms, let duration):
            await network.addLatency(to: nodeId, ms: ms)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                await network.removeLatency(from: nodeId)
            }

        case .packetLoss(let nodeId, let percent, let duration):
            await network.setPacketLoss(for: nodeId, percent: percent)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                await network.setPacketLoss(for: nodeId, percent: 0)
            }

        case .natMappingExpiry(let nodeId):
            if let nat = await network.getNAT(for: nodeId) {
                await nat.expireAllMappings()
            }
        }
    }
}
```

### Example Tests

```swift
final class MeshNetworkTests: XCTestCase {

    /// Test basic connectivity between public nodes
    func testPublicToPublicConnection() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .link("A", "B")
            .build()
        defer { await network.shutdown() }

        let nodeA = network.node("A")
        let nodeB = network.node("B")

        // A should be able to connect to B
        let conn = try await nodeA.connect(to: "B")
        XCTAssertTrue(conn.isHealthy)

        // Send a message
        let response = try await conn.send(.ping(recentPeers: []))
        XCTAssertEqual(response, .pong(recentPeers: []))
    }

    /// Test NAT node reaching public node via relay
    func testNATToPublicViaRelay() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "relay")
            .addNATNode(id: "natNode", natType: .symmetric)
            .addPublicNode(id: "target")
            .link("natNode", "relay")
            .link("relay", "target")
            .build()
        defer { await network.shutdown() }

        let natNode = network.node("natNode")

        // NAT node should establish relay connection
        try await natNode.start()
        XCTAssertFalse(natNode.relayConnections.isEmpty)

        // Should be able to reach target via relay
        let conn = try await natNode.connect(to: "target")
        XCTAssertTrue(conn.isHealthy)
    }

    /// Test hole punching between two NAT nodes
    func testHolePunchRestrictedCone() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "coordinator")
            .addNATNode(id: "A", natType: .portRestrictedCone)
            .addNATNode(id: "B", natType: .restrictedCone)
            .link("A", "coordinator")
            .link("B", "coordinator")
            .build()
        defer { await network.shutdown() }

        let nodeA = network.node("A")
        let nodeB = network.node("B")

        // Both should connect to coordinator
        try await nodeA.start()
        try await nodeB.start()

        // A should be able to hole punch to B
        let conn = try await nodeA.holePunch(to: "B")
        XCTAssertTrue(conn.isHealthy)
        XCTAssertEqual(conn.connectionType, .holePunched)
    }

    /// Test recovery from stale connection info
    func testStaleInfoRecovery() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .addPublicNode(id: "C")
            .link("A", "B")
            .link("B", "C")
            .link("A", "C")
            .build()
        defer { await network.shutdown() }

        let nodeA = network.node("A")

        // A connects to C, caches the info
        let conn1 = try await nodeA.connect(to: "C")
        XCTAssertTrue(conn1.isHealthy)
        await conn1.close()

        // C's endpoint changes (simulating NAT remapping)
        await network.changeEndpoint(for: "C", to: "10.0.0.99:9999")

        // A's cached info is now stale
        // A should ask around and find fresh info from B
        let conn2 = try await nodeA.connect(to: "C")
        XCTAssertTrue(conn2.isHealthy)
    }

    /// Test network partition and recovery
    func testNetworkPartitionRecovery() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .addPublicNode(id: "C")
            .addPublicNode(id: "D")
            .link("A", "B")
            .link("B", "C")
            .link("C", "D")
            .link("A", "D")
            .build()
        defer { await network.shutdown() }

        let injector = FaultInjector()

        // Partition: {A, B} can't reach {C, D}
        await injector.inject(.networkPartition(group1: ["A", "B"], group2: ["C", "D"]), into: network)

        // A should not be able to reach C
        let nodeA = network.node("A")
        do {
            _ = try await nodeA.connect(to: "C")
            XCTFail("Should not be able to connect during partition")
        } catch {
            // Expected
        }

        // Heal partition
        await network.healPartition()

        // Now A should be able to reach C
        let conn = try await nodeA.connect(to: "C")
        XCTAssertTrue(conn.isHealthy)
    }

    /// Test NAT mapping expiry and relay failover
    func testNATMappingExpiry() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "relay1")
            .addPublicNode(id: "relay2")
            .addNATNode(id: "natNode", natType: .symmetric)
            .addPublicNode(id: "target")
            .link("natNode", "relay1")
            .link("natNode", "relay2")
            .link("relay1", "target")
            .link("relay2", "target")
            .build()
        defer { await network.shutdown() }

        let natNode = network.node("natNode")
        try await natNode.start()

        // Connect to target via relay1
        let conn = try await natNode.connect(to: "target")
        XCTAssertTrue(conn.isHealthy)

        // Expire NAT mappings (simulating timeout)
        let injector = FaultInjector()
        await injector.inject(.natMappingExpiry(nodeId: "natNode"), into: network)

        // Connection should fail, then recover via relay2
        // Give it time to detect failure and failover
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should still be able to reach target (via relay2)
        let conn2 = try await natNode.connect(to: "target")
        XCTAssertTrue(conn2.isHealthy)
    }
}
```

## Configuration

```swift
struct MeshConfig {
    // Network
    var listenPort: UInt16 = 0          // 0 = auto-assign
    var bootstrapNodes: [String] = []

    // STUN (our own relay infrastructure)
    var stunServers: [String] = [
        "stun1.omerta.io:3478",
        "stun2.omerta.io:3478"
    ]

    // Relay
    var targetRelayCount: Int = 3       // How many relays to maintain
    var minRelayCount: Int = 1          // Minimum before re-selecting
    var maxRelaySessions: Int = 50      // Max sessions to relay for others

    // Timing
    var keepaliveInterval: TimeInterval = 15
    var reannounceInterval: TimeInterval = 300   // 5 minutes
    var announcementTTL: TimeInterval = 3600     // 1 hour
    var connectionTimeout: TimeInterval = 10
    var holePunchTimeout: TimeInterval = 10

    // Gossip
    var maxHopCount: Int = 5
    var maxRecentContacts: Int = 100
    var recentContactMaxAge: TimeInterval = 300  // 5 minutes
}
```

## Code Reuse from OmertaNetwork

The `OmertaNetwork` module will be **replaced entirely** by `OmertaMesh`. The following code will be migrated and reused:

### Direct Reuse (copy with minimal changes)

| Existing File | New Location | Changes |
|---------------|--------------|---------|
| `OmertaNetwork/NAT/STUNClient.swift` | `OmertaMesh/STUN/STUNClient.swift` | Module imports only |
| `OmertaNetwork/NAT/HolePuncher.swift` | `OmertaMesh/HolePunch/HolePuncher.swift` | Extract probe logic, remove RendezvousClient dependency |
| `OmertaNetwork/DHT/KBucket.swift` | `OmertaMesh/Routing/KBucket.swift` | Module imports only |
| `OmertaNetwork/P2P/WireGuardRelay.swift` | `OmertaMesh/Relay/WireGuardRelay.swift` | Module imports only |

### Adapt and Extend

| Existing File | New Location | Changes |
|---------------|--------------|---------|
| `OmertaNetwork/DHT/PeerAnnouncement.swift` | `OmertaMesh/Discovery/PeerAnnouncement.swift` | Add `reachability: [ReachabilityPath]`, remove `signalingAddresses` |
| `OmertaNetwork/DHT/DHTNode.swift` | `OmertaMesh/Discovery/PeerDiscovery.swift` | Extract routing logic, replace with gossip protocol |
| `OmertaNetwork/NAT/NATTraversal.swift` | `OmertaMesh/NAT/NATDetector.swift` | Extract detection logic, remove RendezvousClient coordination |

### Do Not Reuse (replaced by new design)

| Existing File | Reason |
|---------------|--------|
| `OmertaNetwork/NAT/RendezvousClient.swift` | Replaced by peer-to-peer gossip |
| `OmertaNetwork/P2P/P2PSession.swift` | Replaced by MeshNetwork |
| `OmertaNetwork/P2P/P2PVPNManager.swift` | Higher-level code will use MeshNetwork directly |
| `OmertaNetwork/DHT/DHTClient.swift` | Replaced by PeerDiscovery with gossip |
| `OmertaNetwork/DHT/DHTTransport.swift` | Replaced by MeshNode transport |

### Migration Strategy

1. Create `OmertaMesh` module alongside `OmertaNetwork`
2. Copy reusable files, update imports
3. Build new functionality in `OmertaMesh`
4. Update consumers to use `OmertaMesh`
5. Delete `OmertaNetwork` module

---

## Development Phases

### Phase 0: Test Infrastructure Foundation

**Goal**: Build minimal test infrastructure first so all phases can have integration tests.

**Deliverables**:
- `VirtualNetwork` - in-process packet routing (no real UDP)
- `TestNode` - wrapper around MeshNode for testing
- `TestNetworkBuilder` - DSL for creating test topologies
- Basic `SimulatedNAT` - just public and symmetric initially

**Files**:
```
Tests/OmertaMeshTests/
├── Infrastructure/
│   ├── VirtualNetwork.swift
│   ├── TestNode.swift
│   ├── TestNetworkBuilder.swift
│   └── SimulatedNAT.swift
```

**Exit Criteria**:
- Can create 3-node virtual network
- Packets route between virtual nodes
- Tests run without real network I/O

**Why First**: Every subsequent phase needs this for integration tests. Building it first means we can test each phase thoroughly as we go.

---

### Phase 1: Core Transport Layer

**Goal**: Basic UDP messaging between two nodes on localhost.

**Reuse**: None (new foundation)

**Deliverables**:
- `UDPSocket` - async/await UDP socket wrapper
- `MeshEnvelope` - message serialization/deserialization
- `IdentityKeypair` - Ed25519 key generation and signing
- `PeerConnection` - represents a connection to a peer
- Basic `MeshNode` actor that can send/receive messages

**Files**:
```
Sources/OmertaMesh/
├── Transport/
│   ├── UDPSocket.swift
│   └── MeshEnvelope.swift
├── Identity/
│   ├── IdentityKeypair.swift
│   └── Signature.swift
├── Connection/
│   └── PeerConnection.swift
└── MeshNode.swift
```

**Exit Criteria**:
- Two nodes on localhost can exchange ping/pong messages
- Messages are signed and signatures are verified
- Message deduplication works (same messageId ignored)

#### Phase 1 Integration Tests

```swift
class Phase1IntegrationTests: XCTestCase {
    /// Two nodes on localhost exchange messages (real UDP)
    func testTwoNodePingPong() async throws {
        let nodeA = try await MeshNode(port: 10001)
        let nodeB = try await MeshNode(port: 10002)
        defer { await nodeA.stop(); await nodeB.stop() }

        try await nodeA.start()
        try await nodeB.start()

        // A sends ping to B
        let response = try await nodeA.sendAndReceive(
            .ping(recentPeers: []),
            to: "127.0.0.1:10002",
            timeout: 5.0
        )

        XCTAssertEqual(response, .pong(recentPeers: []))
    }

    /// Message signature verification
    func testInvalidSignatureRejected() async throws {
        let nodeA = try await MeshNode(port: 10001)
        let nodeB = try await MeshNode(port: 10002)
        defer { await nodeA.stop(); await nodeB.stop() }

        try await nodeA.start()
        try await nodeB.start()

        // Craft message with wrong signature
        var envelope = MeshEnvelope(
            from: nodeA.peerId,
            to: nodeB.peerId,
            payload: .ping(recentPeers: [])
        )
        envelope.signature = "invalid"

        // B should reject it
        let rejected = await nodeB.receiveEnvelope(envelope)
        XCTAssertFalse(rejected)
    }

    /// Duplicate message ignored
    func testMessageDeduplication() async throws {
        let nodeA = try await MeshNode(port: 10001)
        let nodeB = try await MeshNode(port: 10002)
        defer { await nodeA.stop(); await nodeB.stop() }

        try await nodeA.start()
        try await nodeB.start()

        var receivedCount = 0
        await nodeB.onMessage { _, _ in
            receivedCount += 1
            return nil
        }

        // Send same message twice
        let envelope = try await nodeA.createEnvelope(.ping(recentPeers: []), to: nodeB.peerId)
        try await nodeA.sendRaw(envelope, to: "127.0.0.1:10002")
        try await nodeA.sendRaw(envelope, to: "127.0.0.1:10002")

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(receivedCount, 1)  // Only processed once
    }

    /// Virtual network test (no real UDP)
    func testVirtualNetworkBasic() async throws {
        let network = try await TestNetworkBuilder()
            .addNode(id: "A")
            .addNode(id: "B")
            .link("A", "B")
            .build()
        defer { await network.shutdown() }

        let response = try await network.node("A").sendAndReceive(
            .ping(recentPeers: []),
            to: "B",
            timeout: 1.0
        )

        XCTAssertEqual(response, .pong(recentPeers: []))
    }
}
```

---

### Phase 2: NAT Detection

**Goal**: Detect NAT type using STUN protocol.

**Reuse**: `OmertaNetwork/NAT/STUNClient.swift` (copy with module import changes)

**Deliverables**:
- `STUNClient` - STUN binding request/response (reused)
- `STUNMessage` - STUN packet encoding/decoding (reused)
- `NATDetector` - runs the detection algorithm
- `NATType` enum with all types

**Files**:
```
Sources/OmertaMesh/
├── STUN/
│   ├── STUNClient.swift       ← from OmertaNetwork
│   ├── STUNMessage.swift      ← from OmertaNetwork
│   └── STUNAttributes.swift   ← from OmertaNetwork
└── NAT/
    ├── NATDetector.swift
    └── NATType.swift
```

**Exit Criteria**:
- Can detect public/fullCone/restrictedCone/portRestrictedCone/symmetric
- Works with our own STUN servers (stun1.omerta.io, stun2.omerta.io)
- Unit tests with mock STUN server

#### Phase 2 Integration Tests

```swift
class Phase2IntegrationTests: XCTestCase {
    /// Real STUN detection (requires internet and deployed STUN servers)
    func testRealSTUNDetection() async throws {
        let detector = NATDetector(stunServers: [
            "stun1.omerta.io:3478",
            "stun2.omerta.io:3478"
        ])

        let result = try await detector.detect()

        XCTAssertNotEqual(result.type, .unknown)
        XCTAssertNotNil(result.publicEndpoint)
        print("Detected: \(result.type), endpoint: \(result.publicEndpoint!)")
    }

    /// Mock STUN for deterministic testing
    func testMockSTUNPublicIP() async throws {
        let mockSTUN = MockSTUNServer(responseType: .public)
        try await mockSTUN.start(port: 19000)
        defer { await mockSTUN.stop() }

        let detector = NATDetector(stunServers: ["127.0.0.1:19000"])
        let result = try await detector.detect()

        XCTAssertEqual(result.type, .public)
    }

    /// Simulated NAT returns correct type
    func testSimulatedNATDetection() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "client", natType: .symmetric)
            .addSTUNServer(id: "stun")
            .link("client", "stun")
            .build()
        defer { await network.shutdown() }

        let result = try await network.node("client").detectNAT()
        XCTAssertEqual(result.type, .symmetric)
    }

    /// Node startup includes NAT detection
    func testNodeStartupDetectsNAT() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "client", natType: .restrictedCone)
            .addSTUNServer(id: "stun")
            .link("client", "stun")
            .build()
        defer { await network.shutdown() }

        let node = network.node("client")
        try await node.start()

        XCTAssertEqual(await node.natType, .restrictedCone)
        XCTAssertNotNil(await node.publicEndpoint)
    }
}
```

---

### Phase 3: Bootstrap and Peer Discovery

**Goal**: Join the network and discover peers.

**Reuse**:
- `OmertaNetwork/DHT/KBucket.swift` (routing table logic)
- `OmertaNetwork/DHT/PeerAnnouncement.swift` (extend with reachability paths)

**Deliverables**:
- `PeerAnnouncement` - signed peer info structure (extended)
- `PeerCache` - LRU cache with TTL expiration
- Bootstrap flow implementation
- `findPeer` / `peerInfo` / `peerList` message handling
- Peer persistence across restarts
- Gossip broadcast for announcements

**Files**:
```
Sources/OmertaMesh/
├── Discovery/
│   ├── PeerAnnouncement.swift  ← extended from OmertaNetwork
│   ├── PeerCache.swift
│   ├── Bootstrap.swift
│   ├── PeerStore.swift
│   └── Gossip.swift
├── Routing/
│   └── KBucket.swift           ← from OmertaNetwork
└── Messages/
    └── DiscoveryMessages.swift
```

**Exit Criteria**:
- Node can bootstrap from hardcoded addresses
- Learns about other peers through gossip
- Persists and reloads known peers
- Can find specific peer by ID

#### Phase 3 Integration Tests

```swift
class Phase3IntegrationTests: XCTestCase {
    /// Bootstrap from known node
    func testBootstrapFromSingleNode() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "bootstrap")
            .addPublicNode(id: "newNode")
            .link("newNode", "bootstrap")
            .build()
        defer { await network.shutdown() }

        // Bootstrap knows about some peers
        await network.node("bootstrap").addToCache(
            PeerAnnouncement(peerId: "peerA", ...),
            PeerAnnouncement(peerId: "peerB", ...)
        )

        // New node bootstraps
        let newNode = network.node("newNode")
        try await newNode.bootstrap(from: ["bootstrap"])

        // Should have learned about peers
        XCTAssertNotNil(await newNode.peerCache["peerA"])
        XCTAssertNotNil(await newNode.peerCache["peerB"])
    }

    /// Gossip propagates announcements
    func testGossipPropagation() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .addPublicNode(id: "C")
            .link("A", "B")
            .link("B", "C")
            // A and C not directly connected
            .build()
        defer { await network.shutdown() }

        // Start all nodes
        for id in ["A", "B", "C"] {
            try await network.node(id).start()
        }

        // Connect the chain
        try await network.node("A").connect(to: "B")
        try await network.node("B").connect(to: "C")

        // A announces itself
        await network.node("A").announce()

        // Wait for gossip
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // C should know about A (via B)
        let cached = await network.node("C").peerCache["A"]
        XCTAssertNotNil(cached)
    }

    /// Peer persistence across restart
    func testPeerPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // First run: learn about peers
        let node1 = try await MeshNode(port: 10001, persistenceDir: tempDir)
        try await node1.start()
        await node1.addToCache(PeerAnnouncement(peerId: "remembered", ...))
        await node1.stop()

        // Second run: should remember
        let node2 = try await MeshNode(port: 10001, persistenceDir: tempDir)
        try await node2.start()

        XCTAssertNotNil(await node2.peerCache["remembered"])
    }

    /// Find specific peer by ID
    func testFindPeerById() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "seeker")
            .addPublicNode(id: "hub")
            .addPublicNode(id: "target")
            .link("seeker", "hub")
            .link("hub", "target")
            .build()
        defer { await network.shutdown() }

        for id in ["seeker", "hub", "target"] {
            try await network.node(id).start()
        }

        // Hub knows about target
        try await network.node("hub").connect(to: "target")

        // Seeker finds target through hub
        let announcement = try await network.node("seeker").findPeer("target")
        XCTAssertEqual(announcement.peerId, "target")
    }
}
```

---

### Phase 4: Relay Infrastructure

**Goal**: NAT nodes can be reached via public relay nodes.

**Reuse**:
- `OmertaNetwork/P2P/WireGuardRelay.swift` (packet encapsulation for future high-throughput mode)

**Deliverables**:
- `RelayConnection` - persistent connection to relay peer
- `RelaySession` - bidirectional forwarding state
- Relay selection algorithm (latency + capacity)
- `relayRequest` / `relayAccept` / `relayDeny` / `relayData` handling
- Announcement with relay paths

**Files**:
```
Sources/OmertaMesh/
├── Relay/
│   ├── RelayConnection.swift
│   ├── RelaySession.swift
│   ├── RelaySelector.swift
│   ├── RelayManager.swift
│   └── WireGuardRelay.swift    ← from OmertaNetwork (for future use)
└── Messages/
    └── RelayMessages.swift
```

**Exit Criteria**:
- NAT node establishes connections to 3 relays
- NAT node announces reachability via relays
- Other nodes can reach NAT node through relay
- Relay failover works when one relay dies

#### Phase 4 Integration Tests

```swift
class Phase4IntegrationTests: XCTestCase {
    /// NAT node selects relays on startup
    func testNATNodeSelectsRelays() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "relay1")
            .addPublicNode(id: "relay2")
            .addPublicNode(id: "relay3")
            .addNATNode(id: "natNode", natType: .symmetric)
            .link("natNode", "relay1")
            .link("natNode", "relay2")
            .link("natNode", "relay3")
            .build()
        defer { await network.shutdown() }

        let natNode = network.node("natNode")
        try await natNode.start()

        // Should have established relay connections
        let relays = await natNode.relayConnections
        XCTAssertGreaterThanOrEqual(relays.count, 1)
        XCTAssertLessThanOrEqual(relays.count, 3)
    }

    /// Communication through relay
    func testMessageThroughRelay() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "relay")
            .addNATNode(id: "natNode", natType: .symmetric)
            .addPublicNode(id: "sender")
            .link("natNode", "relay")
            .link("sender", "relay")
            // sender and natNode can't communicate directly
            .build()
        defer { await network.shutdown() }

        for id in ["relay", "natNode", "sender"] {
            try await network.node(id).start()
        }

        // natNode announces via relay
        await network.node("natNode").announce()
        try await Task.sleep(nanoseconds: 500_000_000)

        // sender connects to natNode (should go through relay)
        let conn = try await network.node("sender").connect(to: "natNode")

        XCTAssertTrue(conn.isHealthy)
        XCTAssertEqual(conn.connectionType, .viaRelay)

        // Exchange messages
        let response = try await conn.sendAndReceive(
            data: "Hello NAT node".data(using: .utf8)!,
            timeout: 5.0
        )
        XCTAssertNotNil(response)
    }

    /// Relay failover
    func testRelayFailover() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "relay1")
            .addPublicNode(id: "relay2")
            .addNATNode(id: "natNode", natType: .symmetric)
            .addPublicNode(id: "sender")
            .link("natNode", "relay1")
            .link("natNode", "relay2")
            .link("sender", "relay1")
            .link("sender", "relay2")
            .build()
        defer { await network.shutdown() }

        for id in ["relay1", "relay2", "natNode", "sender"] {
            try await network.node(id).start()
        }

        // Establish connection through relay1
        let conn1 = try await network.node("sender").connect(to: "natNode")
        XCTAssertTrue(conn1.isHealthy)

        // Kill relay1
        await network.killNode("relay1")

        // Wait for detection and failover
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should still be able to communicate (via relay2)
        let conn2 = try await network.node("sender").connect(to: "natNode")
        XCTAssertTrue(conn2.isHealthy)
    }

    /// Relay selection prefers low latency
    func testRelaySelectionByLatency() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "fastRelay")
            .addPublicNode(id: "slowRelay")
            .addNATNode(id: "natNode", natType: .symmetric)
            .link("natNode", "fastRelay", latencyMs: 10)
            .link("natNode", "slowRelay", latencyMs: 200)
            .build()
        defer { await network.shutdown() }

        let natNode = network.node("natNode")
        try await natNode.start()

        // Should prefer fast relay
        let primaryRelay = await natNode.relayConnections.first
        XCTAssertEqual(primaryRelay?.relayPeerId, "fastRelay")
    }
}
```

---

### Phase 5: Freshness Queries

**Goal**: Recover from stale peer information.

**Reuse**: None (new functionality)

**Deliverables**:
- `RecentContact` tracking
- `whoHasRecent` / `iHaveRecent` / `pathFailed` handling
- Freshness-aware connection logic
- Query flood prevention (rate limiting, hop counting)

**Files**:
```
Sources/OmertaMesh/
├── Freshness/
│   ├── RecentContactTracker.swift
│   ├── FreshnessQuery.swift
│   └── PathFailureReporter.swift
└── Messages/
    └── FreshnessMessages.swift
```

**Exit Criteria**:
- Node with stale cache can find fresh info
- Path failures are reported and propagated
- Query storms are prevented
- Connection succeeds even when cached info is wrong

#### Phase 5 Integration Tests

```swift
class Phase5IntegrationTests: XCTestCase {
    /// Recover from stale cached endpoint
    func testStaleEndpointRecovery() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "seeker")
            .addPublicNode(id: "hub")
            .addPublicNode(id: "target")
            .link("seeker", "hub")
            .link("hub", "target")
            .build()
        defer { await network.shutdown() }

        for id in ["seeker", "hub", "target"] {
            try await network.node(id).start()
        }

        // Seeker learns about target
        try await network.node("hub").connect(to: "target")
        let oldAnnouncement = try await network.node("seeker").findPeer("target")

        // Target's endpoint changes
        await network.changeEndpoint(for: "target", to: "10.0.0.99:9999")

        // Hub connects to new endpoint (has fresh info)
        try await network.node("hub").connect(to: "target")

        // Seeker's cache is stale - but should recover via freshness query
        let conn = try await network.node("seeker").connect(to: "target")
        XCTAssertTrue(conn.isHealthy)
    }

    /// Path failure is reported
    func testPathFailureReporting() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .addPublicNode(id: "target")
            .link("A", "B")
            .link("B", "target")
            .build()
        defer { await network.shutdown() }

        for id in ["A", "B", "target"] {
            try await network.node(id).start()
        }

        // A learns about target
        await network.node("A").addToCache(
            PeerAnnouncement(peerId: "target", reachability: [.direct(endpoint: "old:1234")])
        )

        // Try to connect with bad info - should fail and report
        var pathFailureReceived = false
        await network.node("B").onMessage { msg, from in
            if case .pathFailed(let peerId, _, _) = msg, peerId == "target" {
                pathFailureReceived = true
            }
            return nil
        }

        _ = try? await network.node("A").connect(to: "target")

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(pathFailureReceived)
    }

    /// Query flood prevention
    func testQueryFloodPrevention() async throws {
        let network = try await TestNetworkBuilder()
            .addLinearTopology(count: 10)  // A-B-C-D-E-F-G-H-I-J
            .build()
        defer { await network.shutdown() }

        // Track how many queries each node receives
        var queryCounts: [String: Int] = [:]
        for i in 0..<10 {
            let id = "node\(i)"
            await network.node(id).onMessage { msg, _ in
                if case .whoHasRecent = msg {
                    queryCounts[id, default: 0] += 1
                }
                return nil
            }
        }

        // node0 asks for unknown peer
        _ = try? await network.node("node0").findFreshPeerInfo("unknown")

        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Later nodes should receive fewer queries (hop count limits)
        // node9 should receive 0 or very few queries
        XCTAssertLessThan(queryCounts["node9", default: 0], queryCounts["node1", default: 0])
    }

    /// Recent contacts are tracked
    func testRecentContactTracking() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .link("A", "B")
            .build()
        defer { await network.shutdown() }

        try await network.node("A").start()
        try await network.node("B").start()

        // A connects to B
        try await network.node("A").connect(to: "B")

        // A should have B as recent contact
        let recent = await network.node("A").recentContacts["B"]
        XCTAssertNotNil(recent)
        XCTAssertLessThan(recent!.age, 1.0)
    }
}
```

---

### Phase 6: Hole Punching

**Goal**: Establish direct connections through NAT.

**Reuse**: `OmertaNetwork/NAT/HolePuncher.swift` (probe sending logic)

**Deliverables**:
- `HolePuncher` - sends UDP probes (reused + adapted)
- `HolePunchCoordinator` - public node coordination logic (new)
- Strategy selection based on NAT types
- `holePunchRequest` / `holePunchInvite` / `holePunchExecute` / `holePunchResult` handling

**Files**:
```
Sources/OmertaMesh/
├── HolePunch/
│   ├── HolePuncher.swift          ← adapted from OmertaNetwork
│   ├── HolePunchCoordinator.swift
│   ├── HolePunchStrategy.swift
│   └── ProbePacket.swift
└── Messages/
    └── HolePunchMessages.swift
```

**Exit Criteria**:
- Two restricted-cone nodes can hole punch
- Port-restricted to restricted works
- Symmetric NAT correctly falls back to relay
- Coordinator handles concurrent requests

#### Phase 6 Integration Tests

```swift
class Phase6IntegrationTests: XCTestCase {
    /// Hole punch between two restricted cone NATs
    func testRestrictedToRestrictedHolePunch() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "A", natType: .restrictedCone)
            .addNATNode(id: "B", natType: .restrictedCone)
            .addPublicNode(id: "coordinator")
            .link("A", "coordinator")
            .link("B", "coordinator")
            .build()
        defer { await network.shutdown() }

        for id in ["A", "B", "coordinator"] {
            try await network.node(id).start()
        }

        let conn = try await network.node("A").establishDirectConnection(to: "B")

        XCTAssertTrue(conn.isHealthy)
        XCTAssertEqual(conn.connectionType, .holePunched)
    }

    /// Port-restricted to full cone
    func testPortRestrictedToFullCone() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "A", natType: .portRestrictedCone)
            .addNATNode(id: "B", natType: .fullCone)
            .addPublicNode(id: "coordinator")
            .link("A", "coordinator")
            .link("B", "coordinator")
            .build()
        defer { await network.shutdown() }

        for id in ["A", "B", "coordinator"] {
            try await network.node(id).start()
        }

        let conn = try await network.node("A").establishDirectConnection(to: "B")
        XCTAssertEqual(conn.connectionType, .holePunched)
    }

    /// Symmetric to symmetric falls back to relay
    func testSymmetricToSymmetricFallback() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "A", natType: .symmetric)
            .addNATNode(id: "B", natType: .symmetric)
            .addPublicNode(id: "coordinator")  // Also acts as relay
            .link("A", "coordinator")
            .link("B", "coordinator")
            .build()
        defer { await network.shutdown() }

        for id in ["A", "B", "coordinator"] {
            try await network.node(id).start()
        }

        // Direct connection should fail, but connect() should fall back to relay
        let conn = try await network.node("A").connect(to: "B")
        XCTAssertTrue(conn.isHealthy)
        XCTAssertEqual(conn.connectionType, .viaRelay)
    }

    /// Coordinator handles concurrent hole punch requests
    func testConcurrentHolePunchRequests() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "A", natType: .restrictedCone)
            .addNATNode(id: "B", natType: .restrictedCone)
            .addNATNode(id: "C", natType: .restrictedCone)
            .addNATNode(id: "D", natType: .restrictedCone)
            .addPublicNode(id: "coordinator")
            .link("A", "coordinator")
            .link("B", "coordinator")
            .link("C", "coordinator")
            .link("D", "coordinator")
            .build()
        defer { await network.shutdown() }

        for id in ["A", "B", "C", "D", "coordinator"] {
            try await network.node(id).start()
        }

        // Concurrent hole punch requests
        async let conn1 = network.node("A").establishDirectConnection(to: "B")
        async let conn2 = network.node("C").establishDirectConnection(to: "D")

        let results = try await [conn1, conn2]
        XCTAssertTrue(results[0].isHealthy)
        XCTAssertTrue(results[1].isHealthy)
    }

    /// Correct strategy selected based on NAT types
    func testHolePunchStrategySelection() async throws {
        // Symmetric initiating to cone = symmetric sends first
        let strategy1 = HolePunchStrategy.select(
            initiator: .symmetric,
            responder: .restrictedCone
        )
        XCTAssertEqual(strategy1, .initiatorFirst)

        // Both cone = simultaneous
        let strategy2 = HolePunchStrategy.select(
            initiator: .restrictedCone,
            responder: .portRestrictedCone
        )
        XCTAssertEqual(strategy2, .simultaneous)

        // Both symmetric = impossible
        let strategy3 = HolePunchStrategy.select(
            initiator: .symmetric,
            responder: .symmetric
        )
        XCTAssertEqual(strategy3, .impossible)
    }
}
```

---

### Phase 7: Public API and Integration

**Goal**: Clean public API for higher-level code.

**Reuse**: None (new public interface)

**Deliverables**:
- `MeshNetwork` public actor (the main entry point)
- `MeshConfig` with sensible defaults
- `MeshEvent` stream for subscribers
- `DirectConnection` for WireGuard integration
- Error types and documentation

**Files**:
```
Sources/OmertaMesh/
├── Public/
│   ├── MeshNetwork.swift
│   ├── MeshConfig.swift
│   ├── MeshEvent.swift
│   ├── MeshError.swift
│   └── DirectConnection.swift
└── OmertaMesh.swift  (module exports)
```

**Exit Criteria**:
- Higher-level code can use MeshNetwork without knowing internals
- All public types are documented
- Event stream works for monitoring
- DirectConnection provides endpoint for WireGuard

#### Phase 7 Integration Tests

```swift
class Phase7IntegrationTests: XCTestCase {
    /// Full public API workflow
    func testPublicAPIWorkflow() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "provider")
            .addNATNode(id: "consumer", natType: .restrictedCone)
            .addPublicNode(id: "relay")
            .link("consumer", "relay")
            .link("relay", "provider")
            .build()
        defer { await network.shutdown() }

        // Use public API
        let mesh = network.node("consumer").publicAPI  // MeshNetwork

        try await mesh.start()
        XCTAssertNotNil(mesh.peerId)
        XCTAssertNotEqual(await mesh.natType, .unknown)

        // Send message
        let response = try await mesh.sendAndReceive(
            data: "Hello".data(using: .utf8)!,
            to: "provider",
            timeout: 10.0
        )
        XCTAssertNotNil(response)

        // Establish direct connection
        let direct = try await mesh.establishDirectConnection(to: "provider")
        XCTAssertNotNil(direct.endpoint)
    }

    /// Event stream works
    func testEventStream() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .link("A", "B")
            .build()
        defer { await network.shutdown() }

        let mesh = network.node("A").publicAPI
        var events: [MeshEvent] = []

        await mesh.onEvent { event in
            events.append(event)
        }

        try await mesh.start()
        try await mesh.connect(to: "B")

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(events.contains { event in
            if case .peerConnected(let peerId) = event, peerId == "B" {
                return true
            }
            return false
        })
    }

    /// Config defaults work
    func testConfigDefaults() async throws {
        let config = MeshConfig()

        XCTAssertEqual(config.targetRelayCount, 3)
        XCTAssertEqual(config.keepaliveInterval, 15)
        XCTAssertFalse(config.stunServers.isEmpty)
    }

    /// Error types are descriptive
    func testErrorTypes() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "lonely")
            .build()
        defer { await network.shutdown() }

        let mesh = network.node("lonely").publicAPI
        try await mesh.start()

        do {
            _ = try await mesh.connect(to: "nonexistent")
            XCTFail("Should throw")
        } catch let error as MeshError {
            switch error {
            case .peerNotFound(let peerId):
                XCTAssertEqual(peerId, "nonexistent")
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
}
```

---

### Phase 8: Advanced Test Infrastructure

**Goal**: Complete test harness with fault injection.

**Reuse**: None (builds on Phase 0)

**Deliverables**:
- Complete `SimulatedNAT` - all NAT type behaviors
- `FaultInjector` - partition, latency, loss, NAT expiry
- Performance benchmarks
- Chaos testing scenarios

**Files**:
```
Tests/OmertaMeshTests/
├── Infrastructure/
│   ├── SimulatedNAT.swift      ← complete implementation
│   ├── FaultInjector.swift
│   └── ChaosScenarios.swift
├── Benchmarks/
│   └── PerformanceBenchmarks.swift
└── Chaos/
    └── ChaosTests.swift
```

**Exit Criteria**:
- All NAT types are accurately simulated
- Fault injection is reliable and deterministic
- Benchmarks establish performance baselines
- Chaos tests verify resilience

#### Phase 8 Integration Tests

```swift
class Phase8IntegrationTests: XCTestCase {
    /// Network partition and healing
    func testNetworkPartitionRecovery() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .addPublicNode(id: "C")
            .link("A", "B")
            .link("B", "C")
            .link("A", "C")
            .build()
        defer { await network.shutdown() }

        for id in ["A", "B", "C"] {
            try await network.node(id).start()
        }

        // Partition: A alone
        let injector = FaultInjector()
        await injector.inject(.networkPartition(group1: ["A"], group2: ["B", "C"]), into: network)

        // A cannot reach C
        do {
            _ = try await network.node("A").connect(to: "C")
            XCTFail("Should fail during partition")
        } catch { }

        // Heal
        await network.healPartition()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Now works
        let conn = try await network.node("A").connect(to: "C")
        XCTAssertTrue(conn.isHealthy)
    }

    /// NAT mapping expiry
    func testNATMappingExpiry() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "natNode", natType: .symmetric)
            .addPublicNode(id: "relay1")
            .addPublicNode(id: "relay2")
            .link("natNode", "relay1")
            .link("natNode", "relay2")
            .build()
        defer { await network.shutdown() }

        try await network.node("natNode").start()

        // Expire NAT mappings
        let injector = FaultInjector()
        await injector.inject(.natMappingExpiry(nodeId: "natNode"), into: network)

        // Node should recover with new relay connections
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let relays = await network.node("natNode").relayConnections
        XCTAssertFalse(relays.isEmpty)
    }

    /// 100 node scale test
    func testHundredNodeNetwork() async throws {
        let builder = TestNetworkBuilder()

        for i in 0..<10 {
            builder.addPublicNode(id: "pub\(i)")
        }
        for i in 0..<90 {
            let natType: NATType = [.fullCone, .restrictedCone, .portRestrictedCone, .symmetric].randomElement()!
            builder.addNATNode(id: "nat\(i)", natType: natType)
        }

        // Random mesh connectivity
        for _ in 0..<300 {
            let nodes = builder.nodes
            let a = nodes.randomElement()!
            let b = nodes.randomElement()!
            if a.id != b.id {
                builder.link(a.id, b.id)
            }
        }

        let network = try await builder.build()
        defer { await network.shutdown() }

        // Pick random source, try to reach everyone
        let source = network.nodes.randomElement()!
        var reachable = 0

        for target in network.nodes where target.id != source.id {
            if let _ = try? await source.connect(to: target.id, timeout: 5.0) {
                reachable += 1
            }
        }

        // At least 90% reachable
        XCTAssertGreaterThan(reachable, 89)
    }

    /// Chaos: random failures during operation
    func testChaosResilience() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .addPublicNode(id: "C")
            .addPublicNode(id: "D")
            .link("A", "B")
            .link("B", "C")
            .link("C", "D")
            .link("A", "D")
            .build()
        defer { await network.shutdown() }

        for id in ["A", "B", "C", "D"] {
            try await network.node(id).start()
        }

        let injector = FaultInjector()

        // Run chaos for 10 seconds
        let chaos = Task {
            for _ in 0..<20 {
                let fault: FaultInjector.Fault = [
                    .latencySpike(nodeId: ["A", "B", "C", "D"].randomElement()!, additionalMs: 500, duration: 1.0),
                    .packetLoss(nodeId: ["A", "B", "C", "D"].randomElement()!, percent: 30, duration: 1.0),
                ].randomElement()!

                await injector.inject(fault, into: network)
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // Meanwhile, try to maintain connections
        var successfulConnections = 0
        for _ in 0..<20 {
            if let _ = try? await network.node("A").connect(to: "D", timeout: 5.0) {
                successfulConnections += 1
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        chaos.cancel()

        // Should succeed most of the time despite chaos
        XCTAssertGreaterThan(successfulConnections, 10)
    }
}
```

---

## Test Plan

### Unit Tests (per phase)

#### Phase 1: Core Transport
```swift
class UDPSocketTests: XCTestCase {
    func testSendReceive() async throws
    func testTimeout() async throws
    func testConcurrentSends() async throws
}

class MeshEnvelopeTests: XCTestCase {
    func testSerializeDeserialize() throws
    func testSignatureVerification() throws
    func testInvalidSignatureRejected() throws
    func testMessageDeduplication() async throws
}

class IdentityKeypairTests: XCTestCase {
    func testKeyGeneration() throws
    func testSignAndVerify() throws
    func testInvalidSignature() throws
    func testPeerIdDerivation() throws
}
```

#### Phase 2: NAT Detection
```swift
class STUNMessageTests: XCTestCase {
    func testBindingRequestEncoding() throws
    func testBindingResponseDecoding() throws
    func testXorMappedAddress() throws
    func testChangeRequestAttribute() throws
}

class NATDetectorTests: XCTestCase {
    func testPublicDetection() async throws      // Mock: same IP returned
    func testFullConeDetection() async throws    // Mock: alternate IP response received
    func testRestrictedConeDetection() async throws
    func testPortRestrictedConeDetection() async throws
    func testSymmetricDetection() async throws   // Mock: different port per dest
    func testSTUNServerFailover() async throws
}
```

#### Phase 3: Bootstrap and Discovery
```swift
class PeerAnnouncementTests: XCTestCase {
    func testSignAndVerify() throws
    func testExpiration() throws
    func testReachabilityPaths() throws
}

class PeerCacheTests: XCTestCase {
    func testInsertAndRetrieve() async throws
    func testTTLExpiration() async throws
    func testLRUEviction() async throws
    func testConcurrentAccess() async throws
}

class BootstrapTests: XCTestCase {
    func testSuccessfulBootstrap() async throws
    func testBootstrapNodeFailover() async throws
    func testNoBootstrapNodesAvailable() async throws
    func testPeerPersistence() async throws
}
```

#### Phase 4: Relay Infrastructure
```swift
class RelayConnectionTests: XCTestCase {
    func testEstablishConnection() async throws
    func testHeartbeat() async throws
    func testHealthCheck() async throws
    func testReconnectOnFailure() async throws
}

class RelaySelectorTests: XCTestCase {
    func testSelectByLatency() async throws
    func testSelectByCapacity() async throws
    func testAvoidOverloadedRelays() async throws
}

class RelaySessionTests: XCTestCase {
    func testBidirectionalForwarding() async throws
    func testSessionTermination() async throws
    func testMaxSessionsEnforced() async throws
}
```

#### Phase 5: Freshness Queries
```swift
class RecentContactTrackerTests: XCTestCase {
    func testTrackContact() async throws
    func testAgeCalculation() async throws
    func testMaxContactsEnforced() async throws
}

class FreshnessQueryTests: XCTestCase {
    func testWhoHasRecentQuery() async throws
    func testIHaveRecentResponse() async throws
    func testQueryRateLimiting() async throws
    func testHopCountDecrement() async throws
}
```

#### Phase 6: Hole Punching
```swift
class HolePuncherTests: XCTestCase {
    func testProbePacketFormat() throws
    func testSimultaneousStrategy() async throws
    func testYouFirstStrategy() async throws
    func testTheyFirstStrategy() async throws
    func testTimeout() async throws
}

class HolePunchCoordinatorTests: XCTestCase {
    func testStrategySelection() throws
    func testConcurrentRequests() async throws
    func testMismatchedNATTypes() async throws
}
```

---

### Integration Tests

#### Localhost Integration (Real UDP, No Simulation)
```swift
class LocalhostIntegrationTests: XCTestCase {

    /// Two nodes on localhost exchange messages
    func testTwoNodeCommunication() async throws {
        let nodeA = try await MeshNode(config: .localhost(port: 10001))
        let nodeB = try await MeshNode(config: .localhost(port: 10002))
        defer { await nodeA.stop(); await nodeB.stop() }

        try await nodeA.start()
        try await nodeB.start()

        // A connects to B
        let conn = try await nodeA.connect(to: "localhost:10002")

        // Exchange messages
        let response = try await conn.sendAndReceive(
            data: "Hello".data(using: .utf8)!,
            timeout: 5.0
        )
        XCTAssertEqual(String(data: response, encoding: .utf8), "Hello back")
    }

    /// Three nodes form a triangle, test gossip
    func testThreeNodeGossip() async throws {
        let nodes = try await (0..<3).asyncMap { i in
            try await MeshNode(config: .localhost(port: 10001 + i))
        }
        defer { for node in nodes { await node.stop() } }

        // Start all nodes
        for node in nodes { try await node.start() }

        // Connect in triangle: A-B, B-C, C-A
        try await nodes[0].connect(to: "localhost:10002")
        try await nodes[1].connect(to: "localhost:10003")
        try await nodes[2].connect(to: "localhost:10001")

        // A announces something
        await nodes[0].announce()

        // Wait for gossip
        try await Task.sleep(nanoseconds: 500_000_000)

        // B and C should know about A
        XCTAssertNotNil(await nodes[1].peerCache[nodes[0].peerId])
        XCTAssertNotNil(await nodes[2].peerCache[nodes[0].peerId])
    }

    /// Test relay through a third node
    func testRelayThroughMiddleNode() async throws {
        // A and C can't talk directly, B relays
        let nodeA = try await MeshNode(config: .localhost(port: 10001))
        let nodeB = try await MeshNode(config: .localhost(port: 10002))
        let nodeC = try await MeshNode(config: .localhost(port: 10003))
        defer { await nodeA.stop(); await nodeB.stop(); await nodeC.stop() }

        try await nodeA.start()
        try await nodeB.start()
        try await nodeC.start()

        // A connects to B, C connects to B
        try await nodeA.connect(to: "localhost:10002")
        try await nodeC.connect(to: "localhost:10002")

        // A requests relay to C through B
        let conn = try await nodeA.connectViaRelay(
            to: nodeC.peerId,
            through: nodeB.peerId
        )

        let response = try await conn.sendAndReceive(
            data: "Hello via relay".data(using: .utf8)!,
            timeout: 5.0
        )
        XCTAssertEqual(String(data: response, encoding: .utf8), "Got it")
    }
}
```

---

### Simulated Network Tests

#### NAT Topology Tests
```swift
class SimulatedNATTests: XCTestCase {

    /// Public node can receive from anyone
    func testPublicNodeReceivesFromAnyone() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "server")
            .addPublicNode(id: "client1")
            .addPublicNode(id: "client2")
            .build()
        defer { await network.shutdown() }

        let server = network.node("server")

        // Both clients can reach server without prior communication
        let conn1 = try await network.node("client1").connect(to: "server")
        let conn2 = try await network.node("client2").connect(to: "server")

        XCTAssertTrue(conn1.isHealthy)
        XCTAssertTrue(conn2.isHealthy)
    }

    /// Full cone NAT allows replies from any IP
    func testFullConeNAT() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "client", natType: .fullCone)
            .addPublicNode(id: "server1")
            .addPublicNode(id: "server2")
            .build()
        defer { await network.shutdown() }

        let client = network.node("client")

        // Client sends to server1
        try await client.connect(to: "server1")

        // Server2 can now send to client's mapped port (full cone allows this)
        let conn = try await network.node("server2").connectToMappedPort(of: "client")
        XCTAssertTrue(conn.isHealthy)
    }

    /// Restricted cone only allows replies from IPs we've sent to
    func testRestrictedConeNAT() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "client", natType: .restrictedCone)
            .addPublicNode(id: "server1")
            .addPublicNode(id: "server2")
            .build()
        defer { await network.shutdown() }

        let client = network.node("client")

        // Client sends to server1
        try await client.connect(to: "server1")

        // Server2 cannot reach client (different IP)
        do {
            _ = try await network.node("server2").connectToMappedPort(of: "client")
            XCTFail("Should not be able to connect")
        } catch {
            // Expected - restricted cone blocks this
        }
    }

    /// Port-restricted cone requires exact IP:port match
    func testPortRestrictedConeNAT() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "client", natType: .portRestrictedCone)
            .addPublicNode(id: "server", ports: [5000, 5001])
            .build()
        defer { await network.shutdown() }

        let client = network.node("client")
        let server = network.node("server")

        // Client sends to server:5000
        try await client.connect(to: "server:5000")

        // Server can reply from port 5000
        let conn1 = try await server.connectFromPort(5000, toMappedPortOf: "client")
        XCTAssertTrue(conn1.isHealthy)

        // Server cannot reach from port 5001 (wrong port)
        do {
            _ = try await server.connectFromPort(5001, toMappedPortOf: "client")
            XCTFail("Should not be able to connect from different port")
        } catch {
            // Expected
        }
    }

    /// Symmetric NAT uses different external port per destination
    func testSymmetricNAT() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "client", natType: .symmetric)
            .addPublicNode(id: "server1")
            .addPublicNode(id: "server2")
            .build()
        defer { await network.shutdown() }

        let client = network.node("client")
        let nat = network.nat(for: "client")

        // Client sends to both servers
        try await client.connect(to: "server1")
        try await client.connect(to: "server2")

        // NAT should have created different mappings
        let mapping1 = await nat.getMapping(to: "server1")
        let mapping2 = await nat.getMapping(to: "server2")

        XCTAssertNotEqual(mapping1?.externalPort, mapping2?.externalPort)
    }

    /// Symmetric to symmetric cannot hole punch
    func testSymmetricToSymmetricFails() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "A", natType: .symmetric)
            .addNATNode(id: "B", natType: .symmetric)
            .addPublicNode(id: "coordinator")
            .link("A", "coordinator")
            .link("B", "coordinator")
            .build()
        defer { await network.shutdown() }

        let nodeA = network.node("A")

        // Attempt hole punch should fail
        do {
            _ = try await nodeA.holePunch(to: "B")
            XCTFail("Symmetric to symmetric should fail")
        } catch MeshError.holePunchImpossible {
            // Expected
        }

        // But relay should work
        let conn = try await nodeA.connect(to: "B")  // Falls back to relay
        XCTAssertTrue(conn.isHealthy)
        XCTAssertEqual(conn.connectionType, .viaRelay)
    }
}
```

#### Hole Punch Tests
```swift
class HolePunchIntegrationTests: XCTestCase {

    /// Restricted cone to restricted cone (should work)
    func testRestrictedToRestricted() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "A", natType: .restrictedCone)
            .addNATNode(id: "B", natType: .restrictedCone)
            .addPublicNode(id: "coordinator")
            .link("A", "coordinator")
            .link("B", "coordinator")
            .build()
        defer { await network.shutdown() }

        let nodeA = network.node("A")
        try await nodeA.start()
        try await network.node("B").start()

        let conn = try await nodeA.holePunch(to: "B")

        XCTAssertTrue(conn.isHealthy)
        XCTAssertEqual(conn.connectionType, .holePunched)
    }

    /// Port-restricted to full cone (should work)
    func testPortRestrictedToFullCone() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "A", natType: .portRestrictedCone)
            .addNATNode(id: "B", natType: .fullCone)
            .addPublicNode(id: "coordinator")
            .link("A", "coordinator")
            .link("B", "coordinator")
            .build()
        defer { await network.shutdown() }

        let conn = try await network.node("A").holePunch(to: "B")

        XCTAssertTrue(conn.isHealthy)
        XCTAssertEqual(conn.connectionType, .holePunched)
    }

    /// Symmetric to restricted cone (may work with prediction)
    func testSymmetricToRestrictedCone() async throws {
        let network = try await TestNetworkBuilder()
            .addNATNode(id: "A", natType: .symmetric, portAllocation: .sequential)
            .addNATNode(id: "B", natType: .restrictedCone)
            .addPublicNode(id: "coordinator")
            .link("A", "coordinator")
            .link("B", "coordinator")
            .build()
        defer { await network.shutdown() }

        // This might work if we can predict A's next port
        let result = try? await network.node("A").holePunch(to: "B")

        // Whether it works depends on port prediction accuracy
        // Just verify we don't crash and fall back to relay if needed
        if let conn = result {
            XCTAssertEqual(conn.connectionType, .holePunched)
        }
    }
}
```

#### Fault Tolerance Tests
```swift
class FaultToleranceTests: XCTestCase {

    /// Node recovers when relay dies
    func testRelayFailover() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "relay1")
            .addPublicNode(id: "relay2")
            .addNATNode(id: "natNode", natType: .symmetric)
            .addPublicNode(id: "target")
            .link("natNode", "relay1")
            .link("natNode", "relay2")
            .link("relay1", "target")
            .link("relay2", "target")
            .build()
        defer { await network.shutdown() }

        let natNode = network.node("natNode")
        try await natNode.start()

        // Verify connection works
        let conn1 = try await natNode.connect(to: "target")
        XCTAssertTrue(conn1.isHealthy)

        // Kill relay1
        await network.killNode("relay1")

        // Wait for failure detection
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should still be able to reach target via relay2
        let conn2 = try await natNode.connect(to: "target")
        XCTAssertTrue(conn2.isHealthy)
    }

    /// Network partition heals and connectivity restores
    func testPartitionHealing() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .addPublicNode(id: "C")
            .link("A", "B")
            .link("B", "C")
            .link("A", "C")
            .build()
        defer { await network.shutdown() }

        // Partition: A alone, B-C together
        let injector = FaultInjector()
        await injector.inject(.networkPartition(group1: ["A"], group2: ["B", "C"]), into: network)

        // A cannot reach C
        do {
            _ = try await network.node("A").connect(to: "C")
            XCTFail("Should not connect during partition")
        } catch { }

        // Heal partition
        await network.healPartition()

        // Wait for reconnection
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // A can now reach C
        let conn = try await network.node("A").connect(to: "C")
        XCTAssertTrue(conn.isHealthy)
    }

    /// Stale cache is recovered via freshness query
    func testStaleCacheRecovery() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .addPublicNode(id: "C")
            .link("A", "B")
            .link("B", "C")
            .build()
        defer { await network.shutdown() }

        let nodeA = network.node("A")
        let nodeC = network.node("C")

        // A learns about C through B
        try await nodeA.connect(to: "B")
        let cachedInfo = await nodeA.peerCache["C"]
        XCTAssertNotNil(cachedInfo)

        // C's endpoint changes (NAT rebinding)
        await network.changeEndpoint(for: "C", to: "10.0.0.99:9999")

        // A's cache is now stale - direct connect fails
        // But freshness query through B should find fresh info
        let conn = try await nodeA.connect(to: "C")
        XCTAssertTrue(conn.isHealthy)
    }

    /// High latency doesn't break connections
    func testHighLatencyResilience() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .link("A", "B", latencyMs: 500)  // 500ms each way
            .build()
        defer { await network.shutdown() }

        let nodeA = network.node("A")

        // Should still connect despite latency
        let conn = try await nodeA.connect(to: "B")
        XCTAssertTrue(conn.isHealthy)

        // Keepalives should work
        try await Task.sleep(nanoseconds: 5_000_000_000)
        XCTAssertTrue(conn.isHealthy)
    }

    /// Packet loss is handled gracefully
    func testPacketLossResilience() async throws {
        let network = try await TestNetworkBuilder()
            .addPublicNode(id: "A")
            .addPublicNode(id: "B")
            .link("A", "B", lossPercent: 20)  // 20% packet loss
            .build()
        defer { await network.shutdown() }

        let nodeA = network.node("A")

        // Should still work despite loss (retries)
        let conn = try await nodeA.connect(to: "B")
        XCTAssertTrue(conn.isHealthy)

        // Messages should eventually get through
        for i in 0..<10 {
            let response = try await conn.sendAndReceive(
                data: "message \(i)".data(using: .utf8)!,
                timeout: 10.0
            )
            XCTAssertNotNil(response)
        }
    }
}
```

#### Scale Tests
```swift
class ScaleTests: XCTestCase {

    /// 100 node network stays healthy
    func testHundredNodeNetwork() async throws {
        let builder = TestNetworkBuilder()

        // Create 10 public nodes, 90 NAT nodes
        for i in 0..<10 {
            builder.addPublicNode(id: "pub\(i)")
        }
        for i in 0..<90 {
            let natType: NATType = [.fullCone, .restrictedCone, .portRestrictedCone, .symmetric].randomElement()!
            builder.addNATNode(id: "nat\(i)", natType: natType)
        }

        // Random connectivity
        for _ in 0..<300 {
            let a = builder.nodes.randomElement()!
            let b = builder.nodes.randomElement()!
            if a.id != b.id {
                builder.link(a, b)
            }
        }

        let network = try await builder.build()
        defer { await network.shutdown() }

        // All nodes should be reachable
        let randomSource = network.nodes.randomElement()!
        var reachable = 0

        for target in network.nodes where target.id != randomSource.id {
            if let _ = try? await randomSource.connect(to: target.id) {
                reachable += 1
            }
        }

        // At least 90% should be reachable
        XCTAssertGreaterThan(reachable, 89)
    }

    /// Gossip propagates in reasonable time
    func testGossipPropagation() async throws {
        let network = try await TestNetworkBuilder()
            .addLinearTopology(count: 20)  // A-B-C-D-...-T
            .build()
        defer { await network.shutdown() }

        // First node announces
        let firstNode = network.node("node0")
        await firstNode.announce()

        let startTime = Date()

        // Wait for last node to receive announcement
        let lastNode = network.node("node19")
        while await lastNode.peerCache["node0"] == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            if Date().timeIntervalSince(startTime) > 10 {
                XCTFail("Gossip did not propagate in time")
                return
            }
        }

        let propagationTime = Date().timeIntervalSince(startTime)
        print("Gossip propagated through 20 nodes in \(propagationTime)s")

        // Should propagate in under 5 seconds
        XCTAssertLessThan(propagationTime, 5.0)
    }
}
```

---

### End-to-End Tests

```swift
class EndToEndTests: XCTestCase {

    /// Real STUN detection (requires internet and deployed STUN servers)
    func testRealSTUNDetection() async throws {
        let detector = NATDetector(stunServers: [
            "stun1.omerta.io:3478",
            "stun2.omerta.io:3478"
        ])

        let result = try await detector.detect()

        // We should detect something
        XCTAssertNotEqual(result.type, .unknown)
        print("Detected NAT type: \(result.type)")
        print("Public endpoint: \(result.publicEndpoint ?? "none")")
    }

    /// Full flow: two machines across the internet
    /// NOTE: This test requires manual setup with two machines
    func testCrossInternetConnection() async throws {
        throw XCTSkip("Manual test - requires two machines")

        // Machine A runs:
        // let mesh = MeshNetwork(config: .init(listenPort: 7000))
        // try await mesh.start()
        // print("My peer ID: \(mesh.peerId)")

        // Machine B runs (with A's peer ID):
        // let mesh = MeshNetwork(config: .init(
        //     bootstrapNodes: ["machine-a.example.com:7000"]
        // ))
        // try await mesh.start()
        // let response = try await mesh.sendAndReceive(
        //     data: "Hello from B".data(using: .utf8)!,
        //     to: "peer-id-of-A",
        //     timeout: 30
        // )
    }
}
```

---

### Test Metrics and Coverage Goals

| Phase | Unit Test Coverage | Integration Tests |
|-------|-------------------|-------------------|
| 1. Core Transport | 90% | 3 tests |
| 2. NAT Detection | 85% | 2 tests |
| 3. Bootstrap/Discovery | 85% | 5 tests |
| 4. Relay Infrastructure | 80% | 5 tests |
| 5. Freshness Queries | 80% | 3 tests |
| 6. Hole Punching | 75% | 8 tests |
| 7. Public API | 90% | 5 tests |
| 8. Test Infrastructure | N/A | All above use it |

**Total**: ~40+ integration tests, aiming for 80%+ unit test coverage overall.

---

## Future Enhancements

1. **High-throughput relay mode**: Lightweight, hardware-accelerated UDP packet routing for rare cases when all WireGuard traffic must traverse a relay (symmetric NAT on both ends). This should:
   - Use kernel-bypass techniques (io_uring on Linux, dispatch_source on macOS) for minimal CPU overhead
   - Support optional DPDK/XDP acceleration for dedicated relay nodes
   - Maintain line-rate forwarding without per-packet userspace processing
   - Be transparent to WireGuard (relay just forwards encrypted UDP packets)

2. **Bandwidth-aware relay selection**: Prefer relays with capacity for high-throughput connections
3. **Geographic awareness**: Prefer nearby relays for lower latency
4. **Reputation system**: Track relay reliability, prefer good actors
5. **Encrypted relay**: E2E encryption so relays can't read content (note: for WireGuard relay, traffic is already encrypted)
6. **Multi-path**: Use multiple relays simultaneously for redundancy
7. **QUIC transport**: Better performance through NAT than UDP for control plane

## References

- [RFC 5389 - STUN](https://tools.ietf.org/html/rfc5389)
- [RFC 5766 - TURN](https://tools.ietf.org/html/rfc5766)
- [RFC 8445 - ICE](https://tools.ietf.org/html/rfc8445)
- [libp2p Circuit Relay](https://docs.libp2p.io/concepts/circuit-relay/)
- [Kademlia DHT Paper](https://pdos.csail.mit.edu/~petar/papers/maymounkov-kademlia-lncs.pdf)
