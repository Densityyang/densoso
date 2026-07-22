// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DensosoWorkoutDomain",
    platforms: [
        .iOS(.v26),
        .watchOS(.v26)
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
