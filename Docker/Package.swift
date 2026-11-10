// swift-tools-version: 5.9
import PackageDescription

// The Docker helper is a separate package, like the terminal: `swift build` at
// the repository root must keep working without building this app. It has no
// binary dependencies, only the shared IPC and theme types.
let package = Package(
    name: "MakiDocker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MakiDeskDocker", targets: ["MakiDeskDocker"]),
    ],
    dependencies: [
        .package(path: "../Packages/MakiShared"),
    ],
    targets: [
        .target(
            name: "MakiDockerCore",
            dependencies: [
                .product(name: "MakiShared", package: "MakiShared"),
            ]
        ),
        .executableTarget(
            name: "MakiDeskDocker",
            dependencies: [
                "MakiDockerCore",
                .product(name: "MakiShared", package: "MakiShared"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "MakiDockerCoreTests",
            dependencies: ["MakiDockerCore"]
        ),
    ]
)
