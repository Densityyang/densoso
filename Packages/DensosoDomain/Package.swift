// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DensosoDomain",
    platforms: [
        // `swift test` executes this Foundation-only package on the macOS runner.
        // macOS 12 keeps its Swift concurrency baseline explicit.
        .macOS(.v12),
        .iOS(.v18),
        .watchOS(.v11)
    ],
    products: [
        .library(name: "DensosoDomain", targets: ["DensosoDomain"])
    ],
    targets: [
        .target(name: "DensosoDomain"),
        .testTarget(
            name: "DensosoDomainTests",
            dependencies: ["DensosoDomain"]
        )
    ]
)
