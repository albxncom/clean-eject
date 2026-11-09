// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanEject",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CleanEject", targets: ["CleanEject"]),
        // Not "cleaneject": it would collide with CleanEject in .build/release on a case-insensitive file system.
        .executable(name: "CleanEjectCLI", targets: ["CleanEjectCLI"]),
        .library(name: "CleanEjectCore", targets: ["CleanEjectCore"]),
    ],
    targets: [
        .target(name: "CleanEjectCore"),
        .executableTarget(name: "CleanEject", dependencies: ["CleanEjectCore"]),
        .executableTarget(name: "CleanEjectCLI", dependencies: ["CleanEjectCore"]),
        .testTarget(name: "CleanEjectCoreTests", dependencies: ["CleanEjectCore"]),
        .testTarget(name: "CleanEjectCLITests", dependencies: ["CleanEjectCLI", "CleanEjectCore"]),
        .testTarget(name: "CleanEjectAppTests", dependencies: ["CleanEject", "CleanEjectCore"]),
    ]
)
