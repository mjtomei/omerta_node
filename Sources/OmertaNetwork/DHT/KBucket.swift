import Foundation

/// A k-bucket for Kademlia routing table
/// Each bucket stores up to K nodes at a specific distance from our node
public struct KBucket: Sendable {
    /// Maximum number of nodes per bucket
    public let k: Int

    /// Nodes in this bucket, ordered by last seen (most recent last)
    public private(set) var nodes: [DHTNodeInfo]

    /// Last time this bucket was refreshed
    public private(set) var lastRefreshed: Date

    public init(k: Int = 20) {
        self.k = k
        self.nodes = []
        self.lastRefreshed = Date()
    }

    /// Add or update a node in this bucket
    /// Returns the evicted node if bucket was full and a new node was added
    @discardableResult
    public mutating func addOrUpdate(_ node: DHTNodeInfo) -> DHTNodeInfo? {
        // If node already exists, move it to the end (most recently seen)
        if let index = nodes.firstIndex(where: { $0.peerId == node.peerId }) {
            nodes.remove(at: index)
            nodes.append(node)
            return nil
        }

        // If bucket is not full, just add
        if nodes.count < k {
            nodes.append(node)
            return nil
        }

        // Bucket is full - in a real implementation, we'd ping the oldest node
        // and only evict if it doesn't respond. For now, we evict the oldest.
        let evicted = nodes.removeFirst()
        nodes.append(node)
        return evicted
    }

    /// Remove a node from this bucket
    public mutating func remove(_ peerId: String) {
        nodes.removeAll { $0.peerId == peerId }
    }

    /// Check if bucket contains a node
    public func contains(_ peerId: String) -> Bool {
        nodes.contains { $0.peerId == peerId }
    }

    /// Get a node by peer ID
    public func get(_ peerId: String) -> DHTNodeInfo? {
        nodes.first { $0.peerId == peerId }
    }

    /// Mark bucket as refreshed
    public mutating func markRefreshed() {
        lastRefreshed = Date()
    }

    /// Check if bucket needs refresh
    public func needsRefresh(interval: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastRefreshed) > interval
    }

    /// Number of nodes in bucket
    public var count: Int {
        nodes.count
    }

    /// Check if bucket is full
    public var isFull: Bool {
        nodes.count >= k
    }

    /// Check if bucket is empty
    public var isEmpty: Bool {
        nodes.isEmpty
    }
}

/// Kademlia routing table with 160 k-buckets
public struct RoutingTable: Sendable {
    /// Our node's ID (20 bytes = 160 bits)
    public let localId: Data

    /// K-buckets, one for each bit position
    public private(set) var buckets: [KBucket]

    /// K parameter
    public let k: Int

    public init(localId: Data, k: Int = 20) {
        self.localId = localId.count >= 20 ? Data(localId.prefix(20)) : localId + Data(repeating: 0, count: 20 - localId.count)
        self.k = k
        self.buckets = (0..<160).map { _ in KBucket(k: k) }
    }

    /// Calculate XOR distance between two node IDs
    public static func xorDistance(_ a: Data, _ b: Data) -> Data {
        let aBytes = Array(a.prefix(20))
        let bBytes = Array(b.prefix(20))

        var result = Data(count: 20)
        for i in 0..<20 {
            let aByte = i < aBytes.count ? aBytes[i] : 0
            let bByte = i < bBytes.count ? bBytes[i] : 0
            result[i] = aByte ^ bByte
        }
        return result
    }

    /// Get the bucket index for a given node ID
    /// This is the position of the highest bit set in XOR distance
    public func bucketIndex(for nodeId: Data) -> Int {
        let distance = Self.xorDistance(localId, nodeId)

        // Find the highest bit set
        for (byteIndex, byte) in distance.enumerated() {
            if byte != 0 {
                // Find highest bit in this byte
                for bitIndex in (0..<8).reversed() {
                    if (byte & (1 << bitIndex)) != 0 {
                        return (byteIndex * 8) + (7 - bitIndex)
                    }
                }
            }
        }

        // Distance is 0 (same node) - use last bucket
        return 159
    }

    /// Add or update a node in the routing table
    @discardableResult
    public mutating func addOrUpdate(_ node: DHTNodeInfo) -> DHTNodeInfo? {
        guard let nodeId = Data(hexString: node.peerId) else { return nil }

        // Extend to 20 bytes
        var extendedId = nodeId
        while extendedId.count < 20 {
            extendedId.append(0)
        }

        let index = bucketIndex(for: extendedId)
        return buckets[index].addOrUpdate(node)
    }

    /// Remove a node from the routing table
    public mutating func remove(_ peerId: String) {
        guard let nodeId = Data(hexString: peerId) else { return }

        var extendedId = nodeId
        while extendedId.count < 20 {
            extendedId.append(0)
        }

        let index = bucketIndex(for: extendedId)
        buckets[index].remove(peerId)
    }

    /// Find the K closest nodes to a target ID
    public func findClosest(to targetId: Data, count: Int) -> [DHTNodeInfo] {
        var allNodes: [(node: DHTNodeInfo, distance: Data)] = []

        for bucket in buckets {
            for node in bucket.nodes {
                guard let nodeId = Data(hexString: node.peerId) else { continue }

                var extendedId = nodeId
                while extendedId.count < 20 {
                    extendedId.append(0)
                }

                let distance = Self.xorDistance(targetId, extendedId)
                allNodes.append((node, distance))
            }
        }

        // Sort by distance (lexicographic comparison of XOR distance)
        allNodes.sort { Self.compareDistance($0.distance, $1.distance) < 0 }

        return Array(allNodes.prefix(count).map { $0.node })
    }

    /// Compare two distances (returns -1, 0, or 1)
    public static func compareDistance(_ a: Data, _ b: Data) -> Int {
        for i in 0..<min(a.count, b.count) {
            if a[i] < b[i] { return -1 }
            if a[i] > b[i] { return 1 }
        }
        return 0
    }

    /// Get a node by peer ID
    public func get(_ peerId: String) -> DHTNodeInfo? {
        guard let nodeId = Data(hexString: peerId) else { return nil }

        var extendedId = nodeId
        while extendedId.count < 20 {
            extendedId.append(0)
        }

        let index = bucketIndex(for: extendedId)
        return buckets[index].get(peerId)
    }

    /// Check if a node exists in the routing table
    public func contains(_ peerId: String) -> Bool {
        get(peerId) != nil
    }

    /// Total number of nodes in the routing table
    public var nodeCount: Int {
        buckets.reduce(0) { $0 + $1.count }
    }

    /// Get all nodes in the routing table
    public var allNodes: [DHTNodeInfo] {
        buckets.flatMap { $0.nodes }
    }

    /// Get buckets that need refresh
    public func bucketsNeedingRefresh(interval: TimeInterval) -> [Int] {
        buckets.enumerated()
            .filter { $0.element.needsRefresh(interval: interval) }
            .map { $0.offset }
    }

    /// Mark a bucket as refreshed
    public mutating func markBucketRefreshed(_ index: Int) {
        guard index >= 0 && index < buckets.count else { return }
        buckets[index].markRefreshed()
    }
}
