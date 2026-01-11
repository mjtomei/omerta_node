import Foundation
import OmertaCore
import NIOCore
import NIOPosix
import Logging

/// DHT node for peer discovery using Kademlia-style routing
public actor DHTNode {
    private let identity: IdentityKeypair
    private let config: DHTConfig
    private var routingTable: RoutingTable
    private var storage: [String: DHTPeerAnnouncement]
    private var pendingRequests: [String: CheckedContinuation<DHTMessage, Error>]
    private var isRunning: Bool
    private let logger: Logger

    // NIO components
    private var channel: Channel?
    private let eventLoopGroup: EventLoopGroup

    /// Our node's DHT key (20 bytes)
    public var nodeKey: Data {
        routingTable.localId
    }

    /// Our peer ID
    public var peerId: String {
        identity.identity.peerId
    }

    public init(
        identity: IdentityKeypair,
        config: DHTConfig = .default,
        eventLoopGroup: EventLoopGroup? = nil
    ) {
        self.identity = identity
        self.config = config
        self.storage = [:]
        self.pendingRequests = [:]
        self.isRunning = false
        self.logger = Logger(label: "io.omerta.dht")

        // Create routing table with our node ID
        let localId = identity.identity.peerId.data(using: .utf8).flatMap { Data(hexString: String(data: $0, encoding: .utf8) ?? "") } ?? Data()
        var extendedId = Data(hexString: identity.identity.peerId) ?? Data()
        while extendedId.count < 20 {
            extendedId.append(0)
        }
        self.routingTable = RoutingTable(localId: extendedId, k: config.k)

        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Start the DHT node
    public func start() async throws {
        guard !isRunning else { return }

        logger.info("Starting DHT node on port \(config.port)")

        // Bootstrap from known nodes
        for bootstrapAddress in config.bootstrapNodes {
            do {
                try await bootstrap(from: bootstrapAddress)
            } catch {
                logger.warning("Failed to bootstrap from \(bootstrapAddress): \(error)")
            }
        }

        isRunning = true
        logger.info("DHT node started with \(routingTable.nodeCount) nodes in routing table")
    }

    /// Stop the DHT node
    public func stop() async {
        guard isRunning else { return }

        isRunning = false

        // Cancel pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: DHTError.notStarted)
        }
        pendingRequests.removeAll()

        // Close channel
        try? await channel?.close()
        channel = nil

        logger.info("DHT node stopped")
    }

    /// Announce a peer's availability
    public func announce(_ announcement: DHTPeerAnnouncement) async throws {
        guard isRunning else { throw DHTError.notStarted }
        guard announcement.verify() else { throw DHTError.invalidAnnouncement }

        // Store locally
        storage[announcement.peerId] = announcement

        // Find K closest nodes to the announcement's key
        let targetKey = announcement.dhtKey
        let closestNodes = routingTable.findClosest(to: targetKey, count: config.k)

        // Store at each of the closest nodes
        for node in closestNodes {
            do {
                try await storeAt(node: node, key: announcement.peerId, value: announcement)
            } catch {
                logger.warning("Failed to store announcement at \(node.peerId): \(error)")
            }
        }
    }

    /// Find a peer by their peer ID
    public func findPeer(_ peerId: String) async throws -> DHTPeerAnnouncement? {
        guard isRunning else { throw DHTError.notStarted }

        // Check local storage first
        if let local = storage[peerId], !local.isExpired {
            return local
        }

        // Create target key from peer ID
        var targetKey = Data(hexString: peerId) ?? Data()
        while targetKey.count < 20 {
            targetKey.append(0)
        }

        // Iterative lookup
        return try await iterativeFindValue(key: peerId, targetKey: targetKey)
    }

    /// Find peers offering specific capabilities near a key
    public func findProviders(near peerId: String, count: Int) async throws -> [DHTPeerAnnouncement] {
        guard isRunning else { throw DHTError.notStarted }

        var targetKey = Data(hexString: peerId) ?? Data()
        while targetKey.count < 20 {
            targetKey.append(0)
        }

        // Find nodes close to the target
        let nodes = try await iterativeFindNode(targetKey: targetKey)

        // Query each node for stored values
        var providers: [DHTPeerAnnouncement] = []
        for node in nodes.prefix(config.k) {
            if let announcement = try? await queryValue(from: node, key: peerId) {
                if announcement.verify() && announcement.capabilities.contains(DHTPeerAnnouncement.capabilityProvider) {
                    providers.append(announcement)
                    if providers.count >= count {
                        break
                    }
                }
            }
        }

        return providers
    }

    /// Add a node to the routing table
    public func addNode(_ node: DHTNodeInfo) {
        routingTable.addOrUpdate(node)
    }

    /// Get nodes from the routing table closest to a target
    public func closestNodes(to targetKey: Data, count: Int) -> [DHTNodeInfo] {
        routingTable.findClosest(to: targetKey, count: count)
    }

    /// Get the number of nodes in the routing table
    public var nodeCount: Int {
        routingTable.nodeCount
    }

    /// Get all stored announcements
    public var storedAnnouncements: [DHTPeerAnnouncement] {
        Array(storage.values).filter { !$0.isExpired }
    }

    // MARK: - Private Methods

    private func bootstrap(from address: String) async throws {
        let parts = address.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            throw DHTError.bootstrapFailed
        }

        let bootstrapNode = DHTNodeInfo(
            peerId: "bootstrap",
            address: String(parts[0]),
            port: port
        )

        // Send find_node for our own ID to populate routing table
        let nodes = try await findNodesFrom(node: bootstrapNode, targetId: peerId)
        for node in nodes {
            routingTable.addOrUpdate(node)
        }
    }

    private func iterativeFindNode(targetKey: Data) async throws -> [DHTNodeInfo] {
        var queried = Set<String>()
        var closest = routingTable.findClosest(to: targetKey, count: config.k)

        while true {
            // Find alpha unqueried nodes from the closest set
            let toQuery = closest.filter { !queried.contains($0.peerId) }.prefix(config.alpha)
            if toQuery.isEmpty {
                break
            }

            // Query them in parallel
            var newNodes: [DHTNodeInfo] = []
            for node in toQuery {
                queried.insert(node.peerId)
                do {
                    let found = try await findNodesFrom(node: node, targetId: targetKey.hexString)
                    newNodes.append(contentsOf: found)
                } catch {
                    logger.debug("Failed to query \(node.peerId): \(error)")
                }
            }

            // Add new nodes to routing table and update closest
            for node in newNodes {
                routingTable.addOrUpdate(node)
            }

            let allNodes = Set(closest + newNodes)
            let sorted = allNodes.sorted { node1, node2 in
                var id1 = Data(hexString: node1.peerId) ?? Data()
                var id2 = Data(hexString: node2.peerId) ?? Data()
                while id1.count < 20 { id1.append(0) }
                while id2.count < 20 { id2.append(0) }

                let dist1 = RoutingTable.xorDistance(targetKey, id1)
                let dist2 = RoutingTable.xorDistance(targetKey, id2)
                return RoutingTable.compareDistance(dist1, dist2) < 0
            }
            closest = Array(sorted.prefix(config.k))
        }

        return closest
    }

    private func iterativeFindValue(key: String, targetKey: Data) async throws -> DHTPeerAnnouncement? {
        var queried = Set<String>()
        var closest = routingTable.findClosest(to: targetKey, count: config.k)

        while true {
            let toQuery = closest.filter { !queried.contains($0.peerId) }.prefix(config.alpha)
            if toQuery.isEmpty {
                break
            }

            for node in toQuery {
                queried.insert(node.peerId)
                do {
                    if let value = try await queryValue(from: node, key: key) {
                        if value.verify() {
                            return value
                        }
                    }
                } catch {
                    logger.debug("Failed to query value from \(node.peerId): \(error)")
                }
            }

            // If no value found, continue with find_node
            var newNodes: [DHTNodeInfo] = []
            for node in toQuery {
                do {
                    let found = try await findNodesFrom(node: node, targetId: key)
                    newNodes.append(contentsOf: found)
                } catch {
                    // Already logged
                }
            }

            for node in newNodes {
                routingTable.addOrUpdate(node)
            }

            let allNodes = Set(closest + newNodes)
            let sorted = allNodes.sorted { node1, node2 in
                var id1 = Data(hexString: node1.peerId) ?? Data()
                var id2 = Data(hexString: node2.peerId) ?? Data()
                while id1.count < 20 { id1.append(0) }
                while id2.count < 20 { id2.append(0) }

                let dist1 = RoutingTable.xorDistance(targetKey, id1)
                let dist2 = RoutingTable.xorDistance(targetKey, id2)
                return RoutingTable.compareDistance(dist1, dist2) < 0
            }
            closest = Array(sorted.prefix(config.k))
        }

        return nil
    }

    private func findNodesFrom(node: DHTNodeInfo, targetId: String) async throws -> [DHTNodeInfo] {
        let message = DHTMessage.findNode(targetId: targetId, fromId: peerId)
        let response = try await sendRequest(to: node, message: message)

        switch response {
        case .foundNodes(let nodes, _):
            return nodes
        default:
            throw DHTError.invalidResponse
        }
    }

    private func queryValue(from node: DHTNodeInfo, key: String) async throws -> DHTPeerAnnouncement? {
        let message = DHTMessage.findValue(key: key, fromId: peerId)
        let response = try await sendRequest(to: node, message: message)

        switch response {
        case .foundValue(let value, _):
            return value
        case .valueNotFound:
            return nil
        default:
            throw DHTError.invalidResponse
        }
    }

    private func storeAt(node: DHTNodeInfo, key: String, value: DHTPeerAnnouncement) async throws {
        let message = DHTMessage.store(key: key, value: value, fromId: peerId)
        let response = try await sendRequest(to: node, message: message)

        switch response {
        case .stored:
            return
        default:
            throw DHTError.invalidResponse
        }
    }

    private func sendRequest(to node: DHTNodeInfo, message: DHTMessage) async throws -> DHTMessage {
        let packet = DHTPacket(message: message)

        // For now, simulate the response based on local state
        // In a real implementation, this would send UDP and wait for response
        return try await withCheckedThrowingContinuation { continuation in
            // Store continuation for response matching
            pendingRequests[packet.transactionId] = continuation

            // Simulate timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(config.rpcTimeout * 1_000_000_000))
                if let cont = pendingRequests.removeValue(forKey: packet.transactionId) {
                    cont.resume(throwing: DHTError.timeout)
                }
            }

            // In a real implementation, we'd send the packet via UDP here
            // For now, handle locally if the node is ourselves
            if node.peerId == peerId {
                handleLocalRequest(packet: packet, continuation: continuation)
            }
        }
    }

    private func handleLocalRequest(packet: DHTPacket, continuation: CheckedContinuation<DHTMessage, Error>) {
        pendingRequests.removeValue(forKey: packet.transactionId)

        switch packet.message {
        case .findNode(let targetId, _):
            var targetKey = Data(hexString: targetId) ?? Data()
            while targetKey.count < 20 { targetKey.append(0) }
            let nodes = routingTable.findClosest(to: targetKey, count: config.k)
            continuation.resume(returning: .foundNodes(nodes: nodes, fromId: peerId))

        case .findValue(let key, _):
            if let value = storage[key], !value.isExpired {
                continuation.resume(returning: .foundValue(value: value, fromId: peerId))
            } else {
                var targetKey = Data(hexString: key) ?? Data()
                while targetKey.count < 20 { targetKey.append(0) }
                let nodes = routingTable.findClosest(to: targetKey, count: config.k)
                continuation.resume(returning: .valueNotFound(closerNodes: nodes, fromId: peerId))
            }

        case .store(let key, let value, _):
            if value.verify() {
                storage[key] = value
                continuation.resume(returning: .stored(key: key, fromId: peerId))
            } else {
                continuation.resume(throwing: DHTError.invalidAnnouncement)
            }

        case .ping:
            continuation.resume(returning: .pong(fromId: peerId))

        default:
            continuation.resume(throwing: DHTError.invalidResponse)
        }
    }

    /// Handle an incoming DHT message
    public func handleMessage(_ packet: DHTPacket, from sender: DHTNodeInfo) -> DHTPacket? {
        // Update routing table with sender
        routingTable.addOrUpdate(sender)

        let response: DHTMessage

        switch packet.message {
        case .ping:
            response = .pong(fromId: peerId)

        case .findNode(let targetId, _):
            var targetKey = Data(hexString: targetId) ?? Data()
            while targetKey.count < 20 { targetKey.append(0) }
            let nodes = routingTable.findClosest(to: targetKey, count: config.k)
            response = .foundNodes(nodes: nodes, fromId: peerId)

        case .findValue(let key, _):
            if let value = storage[key], !value.isExpired {
                response = .foundValue(value: value, fromId: peerId)
            } else {
                var targetKey = Data(hexString: key) ?? Data()
                while targetKey.count < 20 { targetKey.append(0) }
                let nodes = routingTable.findClosest(to: targetKey, count: config.k)
                response = .valueNotFound(closerNodes: nodes, fromId: peerId)
            }

        case .store(let key, let value, _):
            if value.verify() && !value.isExpired {
                storage[key] = value
                response = .stored(key: key, fromId: peerId)
            } else {
                response = .error(message: "Invalid or expired announcement", fromId: peerId)
            }

        case .pong, .foundNodes, .foundValue, .valueNotFound, .stored, .error:
            // These are responses, check if we have a pending request
            if let continuation = pendingRequests.removeValue(forKey: packet.transactionId) {
                continuation.resume(returning: packet.message)
            }
            return nil
        }

        return DHTPacket(transactionId: packet.transactionId, message: response)
    }

    /// Store an announcement directly (for testing)
    public func store(_ announcement: DHTPeerAnnouncement) {
        if announcement.verify() && !announcement.isExpired {
            storage[announcement.peerId] = announcement
        }
    }

    /// Clean up expired announcements
    public func cleanupExpired() {
        storage = storage.filter { !$0.value.isExpired }
    }
}
