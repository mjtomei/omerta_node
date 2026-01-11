// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Omerta",
    // macOS 14+ required for Virtualization.framework
    // Linux doesn't need platform specification
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "omerta", targets: ["OmertaCLI"]),
        .executable(name: "omertad", targets: ["OmertaDaemon"]),
        .executable(name: "omerta-rendezvous", targets: ["OmertaRendezvous"]),
        .library(name: "OmertaCore", targets: ["OmertaCore"]),
    ],
    dependencies: [
        // gRPC and Protocol Buffers
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),

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

        // VM management (macOS only)
        .target(
            name: "OmertaVM",
            dependencies: [
                "OmertaCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/OmertaVM"
        ),

        // Network layer
        .target(
            name: "OmertaNetwork",
            dependencies: [
                "OmertaCore",
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/OmertaNetwork"
        ),

        // Provider library
        .target(
            name: "OmertaProvider",
            dependencies: [
                "OmertaCore",
                "OmertaVM",
                "OmertaNetwork",
                "OmertaConsumer",
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
                "OmertaNetwork",
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

        // Rendezvous library (signaling, STUN, relay)
        .target(
            name: "OmertaRendezvousLib",
            dependencies: [
                "OmertaCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/OmertaRendezvous",
            exclude: ["main.swift"]
        ),

        // Rendezvous server executable
        .executableTarget(
            name: "OmertaRendezvous",
            dependencies: [
                "OmertaRendezvousLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/OmertaRendezvousCLI"
        ),

        // Tests
        .testTarget(
            name: "OmertaCoreTests",
            dependencies: ["OmertaCore"],
            path: "Tests/OmertaCoreTests"
        ),
        .testTarget(
            name: "OmertaVMTests",
            dependencies: ["OmertaVM", "OmertaNetwork"],
            path: "Tests/OmertaVMTests"
        ),
        .testTarget(
            name: "OmertaNetworkTests",
            dependencies: ["OmertaNetwork"],
            path: "Tests/OmertaNetworkTests"
        ),
        .testTarget(
            name: "OmertaProviderTests",
            dependencies: ["OmertaProvider", "OmertaConsumer", "OmertaCore"],
            path: "Tests/OmertaProviderTests"
        ),
        .testTarget(
            name: "OmertaConsumerTests",
            dependencies: ["OmertaConsumer", "OmertaCore"],
            path: "Tests/OmertaConsumerTests"
        ),
        .testTarget(
            name: "OmertaRendezvousTests",
            dependencies: [
                "OmertaRendezvousLib",
                "OmertaCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Tests/OmertaRendezvousTests"
        ),
    ]
)
