// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Compute the package directory for linker paths
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Omerta",
    // macOS 14+ required for Virtualization.framework
    // Linux doesn't need platform specification
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "omerta", targets: ["OmertaCLI"]),
        .executable(name: "omertad", targets: ["OmertaDaemon"]),
        .executable(name: "omerta-mesh", targets: ["OmertaMeshCLI"]),
        .library(name: "OmertaCore", targets: ["OmertaCore"]),
        .library(name: "OmertaMesh", targets: ["OmertaMesh"]),
        // OmertaVPN removed - WireGuard replaced by mesh tunnels (OmertaTunnel)
    ],
    dependencies: [
        // Networking
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),

        // Utilities
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // Core domain logic
        .target(
            name: "OmertaCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/OmertaCore"
        ),

        // Mesh relay network (decentralized P2P overlay)
        .target(
            name: "OmertaMesh",
            dependencies: [
                "OmertaCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/OmertaMesh"
        ),

        // C library for netstack (Go compiled as C archive)
        .systemLibrary(
            name: "CNetstack",
            path: "Sources/CNetstack"
        ),

        // Tunnel utility (persistent sessions + traffic routing via netstack)
        .target(
            name: "OmertaTunnel",
            dependencies: [
                "OmertaMesh",
                "CNetstack",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/OmertaTunnel",
            exclude: ["Netstack"],  // Exclude Go source files
            linkerSettings: [
                .linkedLibrary("netstack", .when(platforms: [.macOS, .linux])),
                .unsafeFlags(["-L\(packageDir)/Sources/CNetstack"], .when(platforms: [.macOS, .linux])),
            ]
        ),

        // OmertaVPN removed - WireGuard replaced by mesh tunnels (OmertaTunnel)

        // VM management (macOS only)
        .target(
            name: "OmertaVM",
            dependencies: [
                "OmertaCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/OmertaVM"
        ),

        // Provider library
        .target(
            name: "OmertaProvider",
            dependencies: [
                "OmertaCore",
                "OmertaVM",
                "OmertaConsumer",
                "OmertaMesh",
                "OmertaTunnel",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/OmertaProvider"
        ),

        // Provider daemon executable
        .executableTarget(
            name: "OmertaDaemon",
            dependencies: [
                "OmertaProvider",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/OmertaDaemon"
        ),

        // Consumer client
        .target(
            name: "OmertaConsumer",
            dependencies: [
                "OmertaCore",
                "OmertaMesh",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/OmertaConsumer"
        ),

        // CLI application
        .executableTarget(
            name: "OmertaCLI",
            dependencies: [
                "OmertaCore",
                "OmertaProvider",
                "OmertaConsumer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/OmertaCLI"
        ),

        // Mesh node CLI for E2E testing
        .executableTarget(
            name: "OmertaMeshCLI",
            dependencies: [
                "OmertaMesh",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/OmertaMeshCLI"
        ),

        // Tests
        .testTarget(
            name: "OmertaCoreTests",
            dependencies: ["OmertaCore"],
            path: "Tests/OmertaCoreTests"
        ),
        .testTarget(
            name: "OmertaVMTests",
            dependencies: ["OmertaVM"],
            path: "Tests/OmertaVMTests"
        ),
        // OmertaVPNTests removed - WireGuard replaced by mesh tunnels
        .testTarget(
            name: "OmertaProviderTests",
            dependencies: ["OmertaProvider", "OmertaConsumer", "OmertaCore", "OmertaTunnel", "OmertaMesh"],
            path: "Tests/OmertaProviderTests"
        ),
        .testTarget(
            name: "OmertaConsumerTests",
            dependencies: ["OmertaConsumer", "OmertaCore"],
            path: "Tests/OmertaConsumerTests"
        ),
        .testTarget(
            name: "OmertaMeshTests",
            dependencies: [
                "OmertaMesh",
                "OmertaCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Tests/OmertaMeshTests"
        ),
        .testTarget(
            name: "OmertaDaemonTests",
            dependencies: ["OmertaDaemon", "OmertaCore"],
            path: "Tests/OmertaDaemonTests"
        ),
        .testTarget(
            name: "OmertaTunnelTests",
            dependencies: ["OmertaTunnel", "OmertaMesh"],
            path: "Tests/OmertaTunnelTests"
        ),
    ]
)
