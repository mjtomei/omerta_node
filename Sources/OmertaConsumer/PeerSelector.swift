import Foundation
import OmertaCore
import OmertaNetwork

/// Selects and ranks providers based on resource requirements
public actor PeerSelector {
    private let peerRegistry: PeerRegistry

    public init(peerRegistry: PeerRegistry) {
        self.peerRegistry = peerRegistry
    }

    // MARK: - Provider Selection

    /// Select best provider for requirements
    public func selectProvider(
        in networkId: String,
        for requirements: ResourceRequirements,
        excludePeers: Set<String> = []
    ) async throws -> PeerRegistry.DiscoveredPeer {
        let ranked = await rankProviders(
            in: networkId,
            for: requirements,
            excludePeers: excludePeers
        )

        guard let best = ranked.first else {
            throw ConsumerError.noSuitableProviders
        }

        return best
    }

    /// Get multiple ranked provider options
    public func rankProviders(
        in networkId: String,
        for requirements: ResourceRequirements,
        excludePeers: Set<String> = [],
        maxResults: Int = 10
    ) async -> [PeerRegistry.DiscoveredPeer] {
        // Get all online peers in network
        let allPeers = await peerRegistry.getOnlinePeers(networkId: networkId)

        // Filter by requirements and exclusions
        let candidates = allPeers.filter { peer in
            !excludePeers.contains(peer.peerId) &&
            matchesRequirements(peer.capabilities, requirements)
        }

        // Score and sort
        let scored = candidates.map { peer in
            (peer: peer, score: scoreProvider(peer))
        }

        let sorted = scored.sorted { $0.score > $1.score }

        return sorted.prefix(maxResults).map { $0.peer }
    }

    // MARK: - Resource Matching

    /// Check if capabilities match requirements
    private func matchesRequirements(
        _ capabilities: [ResourceCapability],
        _ requirements: ResourceRequirements
    ) -> Bool {
        // Check if any capability satisfies requirements
        // (Provider may advertise multiple capability sets)
        return capabilities.contains { capability in
            matchesSingleCapability(capability, requirements)
        }
    }

    /// Check if a single capability matches requirements
    private func matchesSingleCapability(
        _ capability: ResourceCapability,
        _ requirements: ResourceRequirements
    ) -> Bool {
        // CPU cores
        if let required = requirements.cpuCores {
            guard capability.cpuCores >= required else { return false }
        }

        // CPU architecture
        if let required = requirements.cpuArchitecture {
            guard capability.cpuArchitecture == required else { return false }
        }

        // Memory
        if let required = requirements.memoryMB {
            guard capability.availableMemoryMB >= required else { return false }
        }

        // Storage
        if let required = requirements.storageMB {
            guard capability.availableStorageMB >= required else { return false }
        }

        // Network bandwidth
        if let required = requirements.networkBandwidthMbps {
            // Only check if provider advertises bandwidth
            if let available = capability.networkBandwidthMbps {
                guard available >= required else { return false }
            }
            // If provider doesn't advertise bandwidth, assume it's acceptable
        }

        // GPU matching
        if let gpuReq = requirements.gpu {
            guard matchesGPURequirements(capability.gpu, gpuReq) else {
                return false
            }
        }

        // Image availability
        if let imageId = requirements.imageId {
            guard capability.availableImages.contains(imageId) else {
                return false
            }
        }

        return true
    }

    /// Check if GPU capability matches requirements
    private func matchesGPURequirements(
        _ gpuCap: GPUCapability?,
        _ gpuReq: GPURequirements
    ) -> Bool {
        guard let gpuCap = gpuCap else {
            // Provider has no GPU, but consumer needs one
            return false
        }

        // Exact model match (if specified)
        if let model = gpuReq.model {
            // Case-insensitive substring match
            // e.g., "RTX 4090" matches "NVIDIA RTX 4090"
            guard gpuCap.model.lowercased().contains(model.lowercased()) else {
                return false
            }
        }

        // VRAM
        if let required = gpuReq.vramMB {
            guard gpuCap.availableVramMB >= required else { return false }
        }

        // Vendor
        if let vendor = gpuReq.vendor {
            guard gpuCap.vendor == vendor else { return false }
        }

        // Required APIs
        if let requiredAPIs = gpuReq.requiredAPIs {
            for api in requiredAPIs {
                // Check if any supported API contains the required API
                // e.g., "CUDA 12.0" contains "CUDA"
                let hasAPI = gpuCap.supportedAPIs.contains { supportedAPI in
                    supportedAPI.lowercased().contains(api.lowercased())
                }
                guard hasAPI else { return false }
            }
        }

        return true
    }

    // MARK: - Provider Scoring

    /// Score provider based on reputation, response time, and availability
    private func scoreProvider(_ peer: PeerRegistry.DiscoveredPeer) -> Double {
        // Reputation score (0-100) weighted 60%
        let reputationScore = Double(peer.metadata.reputationScore) * 0.6

        // Response time (lower is better) weighted 30%
        // Convert response time to score: faster = higher score
        let responseTimeMs = peer.metadata.averageResponseTimeMs
        let responseScore = (1000.0 / max(responseTimeMs, 1.0)) * 0.3

        // Availability/freshness weighted 10%
        // How recently was the peer seen?
        let secondsSinceLastSeen = Date().timeIntervalSince(peer.lastSeen)
        let freshnessScore: Double
        if secondsSinceLastSeen < 30 {
            freshnessScore = 10.0  // Very fresh
        } else if secondsSinceLastSeen < 60 {
            freshnessScore = 7.0   // Reasonably fresh
        } else if secondsSinceLastSeen < 120 {
            freshnessScore = 5.0   // Getting stale
        } else {
            freshnessScore = 2.0   // Stale
        }

        return reputationScore + responseScore + freshnessScore
    }
}

// MARK: - Helper Extensions

extension PeerSelector {
    /// Find providers with any NVIDIA GPU
    public func findNvidiaProviders(
        in networkId: String,
        minVRAM: UInt64? = nil
    ) async -> [PeerRegistry.DiscoveredPeer] {
        let requirements = ResourceRequirements(
            gpu: GPURequirements(
                vramMB: minVRAM,
                vendor: .nvidia
            )
        )
        return await rankProviders(in: networkId, for: requirements)
    }

    /// Find providers with specific GPU model (fuzzy match)
    public func findGPUModel(
        _ model: String,
        in networkId: String,
        minVRAM: UInt64? = nil
    ) async -> [PeerRegistry.DiscoveredPeer] {
        let requirements = ResourceRequirements(
            gpu: GPURequirements(
                model: model,
                vramMB: minVRAM
            )
        )
        return await rankProviders(in: networkId, for: requirements)
    }

    /// Find providers with specific CPU architecture
    public func findArchitecture(
        _ arch: CPUArchitecture,
        in networkId: String,
        minCores: UInt32? = nil,
        minMemory: UInt64? = nil
    ) async -> [PeerRegistry.DiscoveredPeer] {
        let requirements = ResourceRequirements(
            cpuCores: minCores,
            cpuArchitecture: arch,
            memoryMB: minMemory
        )
        return await rankProviders(in: networkId, for: requirements)
    }

    /// Find any available provider (no requirements)
    public func findAnyProvider(in networkId: String) async throws -> PeerRegistry.DiscoveredPeer {
        try await selectProvider(
            in: networkId,
            for: ResourceRequirements()
        )
    }
}
