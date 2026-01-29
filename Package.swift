// swift-tools-version: 5.9
import PackageDescription
import Foundation

let package = Package(
    name: "Omerta",
    // macOS 14+ required for Virtualization.framework
    // Linux doesn't need platform specification
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "omerta", targets: ["OmertaCLI"]),
        .executable(name: "omertad", targets: ["OmertaDaemon"]),
        .library(name: "OmertaCore", targets: ["OmertaCore"]),
    ],
    dependencies: [
        // Mesh networking (extracted to standalone package)
        .package(path: "../omerta_mesh"),

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

        // Provider library
        .target(
            name: "OmertaProvider",
            dependencies: [
                "OmertaCore",
                "OmertaVM",
                "OmertaConsumer",
                .product(name: "OmertaMesh", package: "omerta_mesh"),
                .product(name: "OmertaTunnel", package: "omerta_mesh"),
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
                .product(name: "OmertaMesh", package: "omerta_mesh"),
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
                .product(name: "OmertaSSH", package: "omerta_mesh"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/OmertaCLI"
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
        .testTarget(
            name: "OmertaProviderTests",
            dependencies: [
                "OmertaProvider",
                "OmertaConsumer",
                "OmertaCore",
                .product(name: "OmertaTunnel", package: "omerta_mesh"),
                .product(name: "OmertaMesh", package: "omerta_mesh"),
            ],
            path: "Tests/OmertaProviderTests"
        ),
        .testTarget(
            name: "OmertaConsumerTests",
            dependencies: ["OmertaConsumer", "OmertaCore"],
            path: "Tests/OmertaConsumerTests"
        ),
        .testTarget(
            name: "OmertaDaemonTests",
            dependencies: ["OmertaDaemon", "OmertaCore"],
            path: "Tests/OmertaDaemonTests"
        ),
        .plugin(
            name: "SetupHooks",
            capability: .command(
                intent: .custom(verb: "setup-hooks", description: "Configure git hooks path to .githooks"),
                permissions: []
            )
        ),
    ]
)
