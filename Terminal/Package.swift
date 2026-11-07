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
    ],
    targets: [
        // Fetched by `task terminal:fetch`; not in the repository.
        .binaryTarget(
            name: "GhosttyKit",
            path: "../vendor/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "MakiTerminal",
            dependencies: ["GhosttyKit"],
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
    ]
)
