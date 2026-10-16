// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrbitDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OrbitDesk", targets: ["OrbitDesk"])
    ],
    targets: [
        .executableTarget(
            name: "OrbitDesk",
            path: "Sources/OrbitDesk"
        ),
        .testTarget(
            name: "OrbitDeskTests",
            dependencies: ["OrbitDesk"],
            path: "Tests/OrbitDeskTests"
        )
    ]
)
