// swift-tools-version: 5.9
import PackageDescription

// The only code both apps link: the IPC envelope and its framing, the socket
// and CLI locations, and the opt-in agent-hook merge. Kept free of AppKit and
// of either app's model, so the boundary stays small and testable.
let package = Package(
    name: "MakiShared",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MakiShared", targets: ["MakiShared"]),
    ],
    targets: [
        .target(name: "MakiShared"),
        .testTarget(name: "MakiSharedTests", dependencies: ["MakiShared"]),
    ]
)
