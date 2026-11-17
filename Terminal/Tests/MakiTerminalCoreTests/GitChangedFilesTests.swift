import Foundation
import XCTest
@testable import MakiTerminalCore

final class GitChangedFilesTests: XCTestCase {
    func testParsesPorcelainNULRecordsAndRenames() {
        let output = Data(" M Sources/App.swift\0A  staged.swift\0?? new file.txt\0R  new-name.swift\0old-name.swift\0".utf8)

        XCTAssertEqual(GitChangedFilesParser.parse(output), [
            GitChangedFile(path: "Sources/App.swift", status: " M"),
            GitChangedFile(path: "staged.swift", status: "A "),
            GitChangedFile(path: "new file.txt", status: "??"),
            GitChangedFile(path: "new-name.swift", status: "R "),
        ])
    }

    func testBuildsSortedIndentedTree() {
        let files = [
            GitChangedFile(path: "Sources/Z.swift", status: " M"),
            GitChangedFile(path: "README.md", status: "??"),
            GitChangedFile(path: "Sources/Core/A.swift", status: "A "),
        ]

        XCTAssertEqual(GitChangedFilesParser.treeLines(files), [
            "README.md[??]",
            "Sources/",
            "  Core/",
            "    A.swift[A ]",
            "  Z.swift[ M]",
        ])
    }

    func testBuildsSortedImmutableTree() {
        let files = [
            GitChangedFile(path: "Sources/Z.swift", status: " M"),
            GitChangedFile(path: "README.md", status: "??"),
            GitChangedFile(path: "Sources/Core/A.swift", status: "A "),
        ]

        XCTAssertEqual(GitChangedFilesParser.tree(files), [
            GitChangedFileTreeNode(
                name: "Sources",
                isDirectory: true,
                children: [
                    GitChangedFileTreeNode(
                        name: "Core",
                        isDirectory: true,
                        children: [GitChangedFileTreeNode(name: "A.swift", status: "A ")]
                    ),
                    GitChangedFileTreeNode(name: "Z.swift", status: " M"),
                ]
            ),
            GitChangedFileTreeNode(name: "README.md", status: "??"),
        ])
    }
}
