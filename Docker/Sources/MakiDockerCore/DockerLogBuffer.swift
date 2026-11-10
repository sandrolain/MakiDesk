import Foundation

/// A bounded ring of log lines. It accepts arbitrary chunks because a pipe
/// splits UTF-8 and lines wherever it likes; partial text waits for the next
/// chunk.
public struct DockerLogBuffer: Sendable {
    public private(set) var lines: [String] = []
    public private(set) var partial = ""
    public private(set) var bytes = 0
    public let maxLines: Int
    public let maxBytes: Int
    public private(set) var dropped = 0

    public init(maxLines: Int = 20_000, maxBytes: Int = 8 * 1024 * 1024) {
        self.maxLines = max(1, maxLines)
        self.maxBytes = max(1, maxBytes)
    }

    @discardableResult
    public mutating func append(_ chunk: String) -> Bool {
        guard chunk.isEmpty == false else { return false }
        var changed = false
        var buffer = partial + chunk
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            appendLine(line)
            changed = true
        }
        if buffer != partial {
            partial = buffer
            changed = true
        }
        return changed
    }

    public mutating func appendLine(_ line: String) {
        lines.append(line)
        bytes += line.utf8.count + 1
        while lines.count > maxLines || bytes > maxBytes {
            guard lines.isEmpty == false else { break }
            let removed = lines.removeFirst()
            bytes -= removed.utf8.count + 1
            dropped += 1
        }
    }

    public mutating func clear() {
        lines.removeAll(keepingCapacity: true)
        partial = ""
        bytes = 0
        dropped = 0
    }

    public var text: String {
        if partial.isEmpty { return lines.joined(separator: "\n") }
        return (lines + [partial]).joined(separator: "\n")
    }

    public func filtered(by query: String) -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty == false else { return text }
        return lines
            .filter { $0.localizedCaseInsensitiveContains(needle) }
            .joined(separator: "\n")
    }
}
