import XCTest
@testable import OmertaCore

final class NetworkTests: XCTestCase {
    
    func testNetworkKeyGeneration() {
        let key = NetworkKey.generate(
            networkName: "Test Network",
            bootstrapEndpoint: "alice.local:50051"
        )
        
        XCTAssertEqual(key.networkName, "Test Network")
        XCTAssertEqual(key.networkKey.count, 32) // 256 bits
        XCTAssertEqual(key.bootstrapPeers.count, 1)
        XCTAssertEqual(key.bootstrapPeers[0], "alice.local:50051")
    }
    
    func testNetworkKeyEncodeDecode() throws {
        let originalKey = NetworkKey.generate(
            networkName: "My Team",
            bootstrapEndpoint: "server.example.com:50051"
        )
        
        // Encode to string
        let encoded = try originalKey.encode()
        XCTAssertTrue(encoded.hasPrefix("omerta://join/"))
        
        // Decode back
        let decoded = try NetworkKey.decode(from: encoded)
        
        XCTAssertEqual(decoded.networkName, originalKey.networkName)
        XCTAssertEqual(decoded.networkKey, originalKey.networkKey)
        XCTAssertEqual(decoded.bootstrapPeers, originalKey.bootstrapPeers)
    }
    
    func testInvalidNetworkKeyDecoding() {
        // Test invalid prefix
        XCTAssertThrowsError(try NetworkKey.decode(from: "invalid://join/abc123")) { error in
            XCTAssertTrue(error is NetworkKeyError)
        }
        
        // Test invalid base64
        XCTAssertThrowsError(try NetworkKey.decode(from: "omerta://join/!@#$%^")) { error in
            XCTAssertTrue(error is NetworkKeyError)
        }
    }
    
    func testNetworkKeyDeriveId() {
        let key = NetworkKey.generate(
            networkName: "Test",
            bootstrapEndpoint: "localhost:50051"
        )
        
        let networkId = key.deriveNetworkId()
        
        XCTAssertFalse(networkId.isEmpty)
        
        // Same key should produce same ID
        let networkId2 = key.deriveNetworkId()
        XCTAssertEqual(networkId, networkId2)
    }
    
    func testNetwork() {
        let key = NetworkKey.generate(
            networkName: "Production",
            bootstrapEndpoint: "prod.example.com:50051"
        )
        
        let network = Network(
            id: key.deriveNetworkId(),
            name: "Production",
            key: key,
            isActive: true
        )
        
        XCTAssertEqual(network.name, "Production")
        XCTAssertTrue(network.isActive)
        XCTAssertNotNil(network.joinedAt)
    }
    
    func testNetworkStats() {
        let stats = NetworkStats(
            networkId: "net-123",
            peerCount: 10,
            jobsSubmitted: 100,
            jobsCompleted: 95,
            averageLatencyMs: 250.5
        )
        
        XCTAssertEqual(stats.networkId, "net-123")
        XCTAssertEqual(stats.peerCount, 10)
        XCTAssertEqual(stats.jobsSubmitted, 100)
        XCTAssertEqual(stats.jobsCompleted, 95)
        XCTAssertEqual(stats.averageLatencyMs, 250.5, accuracy: 0.1)
    }
}
