// swift-tools-version: 5.9
import PackageDescription

// MakiBrowser is a separate app, like Terminal and Docker: MakiDesk launches it
// as a regular application, so its window is discoverable by the AX inventory
// and works with the existing palette, tiling and groups.
let package = Package(
    name: "MakiBrowser",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "MakiDeskBrowser", targets: ["MakiDeskBrowser"]),
    ],
    dependencies: [
        .package(path: "../Packages/MakiShared"),
    ],
    targets: [
        .target(
            name: "MakiBrowser",
            dependencies: [
                .product(name: "MakiShared", package: "MakiShared"),
            ],
            path: "Sources/MakiBrowser",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "MakiDeskBrowser",
            dependencies: ["MakiBrowser"],
            path: "Sources/MakiDeskBrowser"
        ),
        .testTarget(
            name: "MakiBrowserTests",
            dependencies: ["MakiBrowser"],
            path: "Tests/MakiBrowserTests"
        ),
    ]
)
