// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DensosoWorkoutDomain",
    platforms: [
        // `swift test` executes this package on the macOS GitHub runner;
        // URLSession's async data API requires macOS 12 or later.
        .macOS(.v12),
        .iOS(.v18),
        .watchOS(.v11)
    ],
    products: [
        .library(name: "DensosoWorkoutDomain", targets: ["DensosoWorkoutDomain"])
    ],
    targets: [
        .target(name: "DensosoWorkoutDomain"),
        .testTarget(
            name: "DensosoWorkoutDomainTests",
            dependencies: ["DensosoWorkoutDomain"]
        )
    ]
)
