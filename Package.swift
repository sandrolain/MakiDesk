// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MakiDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MakiDesk", targets: ["MakiDesk"])
    ],
    targets: [
        .executableTarget(
            name: "MakiDesk",
            path: "Sources/MakiDesk"
        ),
        .testTarget(
            name: "MakiDeskTests",
            dependencies: ["MakiDesk"],
            path: "Tests/MakiDeskTests"
        )
    ]
)
