// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MakiDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MakiDesk", targets: ["MakiDesk"])
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.20.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", revision: "82bb3a533e0801fd2bbaa11dc49676e10bf41948"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.20.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.1.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.20.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", from: "0.20.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", from: "0.20.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.20.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", from: "0.20.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", from: "0.20.0")
    ],
    targets: [
        .executableTarget(
            name: "MakiDesk",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                "GrammarScanners"
            ],
            path: "Sources/MakiDesk"
        ),
        .target(
            name: "GrammarScanners",
            path: "Sources/GrammarScanners",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "MakiDeskTests",
            dependencies: ["MakiDesk"],
            path: "Tests/MakiDeskTests"
        )
    ]
)
