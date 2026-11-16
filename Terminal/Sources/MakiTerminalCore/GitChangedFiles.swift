import Foundation

public struct GitChangedFile: Equatable, Sendable {
    public let path: String
    public let status: String
}

public enum GitChangedFilesParser {
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
