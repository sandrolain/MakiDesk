import Foundation

public struct GitChangedFile: Equatable, Sendable {
    public let path: String
    public let status: String

    public var changeKind: GitChangedFileChangeKind {
        GitChangedFileChangeKind(status: status)
    }
}

public enum GitChangedFileChangeKind: Equatable, Sendable {
    case added
    case modified
    case deleted
    case other

    public init(status: String) {
        if status.contains("D") {
            self = .deleted
        } else if status == "??" || status.contains("A") {
            self = .added
        } else if status.contains("M") || status.contains("T")
                    || status.contains("R") || status.contains("C") {
            self = .modified
        } else {
            self = .other
        }
    }
}

public struct GitChangedFileTreeNode: Equatable, Sendable {
    public let name: String
    public let status: String?
    public let isDirectory: Bool
    public let children: [GitChangedFileTreeNode]

    public init(name: String,
                status: String? = nil,
                isDirectory: Bool = false,
                children: [GitChangedFileTreeNode] = []) {
        self.name = name
        self.status = status
        self.isDirectory = isDirectory
        self.children = children
    }
}

public enum GitChangedFilesParser {
    private final class TreeBuilderNode {
        let name: String
        var status: String?
        var isDirectory: Bool
        var children: [String: TreeBuilderNode] = [:]

        init(name: String, status: String?, isDirectory: Bool) {
            self.name = name
            self.status = status
            self.isDirectory = isDirectory
        }
    }

    /// Parses porcelain v1 NUL records, including the extra source path on renames.
    public static func parse(_ data: Data) -> [GitChangedFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var result: [GitChangedFile] = []
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard record.count >= 4 else { continue }
            let status = String(decoding: record.prefix(2), as: UTF8.self)
            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            result.append(GitChangedFile(path: path, status: status))
            if status.contains("R") || status.contains("C") { index += 1 }
        }
        return result
    }

    /// Builds an immutable tree so callers can prepare large results off the UI queue.
    public static func tree(_ files: [GitChangedFile]) -> [GitChangedFileTreeNode] {
        let root = TreeBuilderNode(name: "", status: nil, isDirectory: true)

        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard components.isEmpty == false else { continue }
            var parent = root

            for (index, name) in components.enumerated() {
                let isDirectory = index < components.count - 1
                let node: TreeBuilderNode
                if let existing = parent.children[name] {
                    node = existing
                    if isDirectory == false { node.status = file.status }
                } else {
                    node = TreeBuilderNode(name: name,
                                           status: isDirectory ? nil : file.status,
                                           isDirectory: isDirectory)
                    parent.children[name] = node
                }
                node.isDirectory = isDirectory
                parent = node
            }
        }

        func freeze(_ nodes: [String: TreeBuilderNode]) -> [GitChangedFileTreeNode] {
            nodes.values
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    let comparison = lhs.name.localizedStandardCompare(rhs.name)
                    return comparison == .orderedSame ? lhs.name < rhs.name : comparison == .orderedAscending
                }
                .map { node in
                    GitChangedFileTreeNode(name: node.name,
                                           status: node.status,
                                           isDirectory: node.isDirectory,
                                           children: freeze(node.children))
                }
        }

        return freeze(root.children)
    }

    public static func treeLines(_ files: [GitChangedFile]) -> [String] {
        var paths = Set<String>()
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            var prefix: [String] = []
            for (offset, part) in parts.enumerated() {
                prefix.append(part)
                if offset < parts.count - 1 { paths.insert(prefix.joined(separator: "/") + "/") }
                else { paths.insert(prefix.joined(separator: "/") + " [\(file.status)]") }
            }
        }
        return paths.sorted().map { path in
            let isDirectory = path.hasSuffix("/")
            let clean = path.replacingOccurrences(of: " [", with: "[")
            let components = clean.split(separator: "/")
            let name = components.last.map(String.init) ?? clean
            let depth = max(0, components.count - 1)
            return String(repeating: "  ", count: depth) + name + (isDirectory ? "/" : "")
        }
    }
}
