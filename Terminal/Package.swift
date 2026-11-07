// swift-tools-version: 5.9
import PackageDescription

// Kept apart from the main package on purpose: `swift build` at the repository
// root must not require the GhosttyKit binary. Only the terminal target links
// the engine, so the menu-bar app stays buildable without it.
let package = Package(
    name: "MakiTerminal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MakiTerminal", targets: ["MakiTerminal"]),
        .executable(name: "makidesk", targets: ["makidesk"]),
    ],
    dependencies: [
        .package(path: "../Packages/MakiShared"),
    ],
    targets: [
        // Fetched by `task terminal:fetch`; not in the repository.
        .binaryTarget(
            name: "GhosttyKit",
            path: "../vendor/GhosttyKit.xcframework"
        ),
        .target(name: "MakiTerminalCore",
                dependencies: [.product(name: "MakiShared", package: "MakiShared")]),
        .executableTarget(
            name: "makidesk",
            dependencies: [.product(name: "MakiShared", package: "MakiShared")]
        ),
        .executableTarget(
            name: "MakiTerminal",
            dependencies: [
                "GhosttyKit",
                "MakiTerminalCore",
                .product(name: "MakiShared", package: "MakiShared"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
            ]
        ),
        .testTarget(
            name: "MakiTerminalCoreTests",
            dependencies: ["MakiTerminalCore"]
        ),
    ]
)
