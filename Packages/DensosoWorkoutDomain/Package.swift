// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DensosoWorkoutDomain",
    platforms: [
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
