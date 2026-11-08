import Foundation
import MakiShared

/// Where an image pasted into the terminal is written, and what its path looks
/// like (F3 L2).
///
/// A terminal can only send text to the shell, so an image on the clipboard is
/// turned into a file and its path is typed instead. The files live under the
/// helper's own Application Support directory and are pruned at launch: the
/// directory is not a scratch space that grows forever.
public enum TerminalImagePaste {
    /// `~/Library/Application Support/MakiDesk/Terminal/pasted-images`.
    public static var directory: URL {
        TerminalSocketLocation.directory
            .appendingPathComponent("pasted-images", isDirectory: true)
    }

    /// A sortable, mostly unique name: `paste-20261108-123456-ab12cd34.png`.
    public static func fileName(date: Date = Date(),
                                identifier: UUID = UUID(),
                                timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = identifier.uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(8)
        return "paste-\(formatter.string(from: date))-\(suffix).png"
    }

    /// A path that a shell reads as one word, including the space in
    /// `Application Support` and any quote in the name.
    public static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What is typed at the cursor: the quoted path and a trailing space, so an
    /// argument can follow without reaching for the space bar.
    public static func text(for path: String) -> String {
        shellQuoted(path) + " "
    }

    /// One file the pruner may remove.
    public struct File: Equatable, Sendable {
        public let url: URL
        public let modified: Date

        public init(url: URL, modified: Date) {
            self.url = url
            self.modified = modified
        }
    }

    /// Files to delete: everything past the newest `keepNewest` and anything
    /// older than `maximumAge`. Deleting by count and age together keeps a
    /// burst of screenshots from filling the disk and a year of silence from
    /// keeping a huge directory.
    public static func filesToRemove(_ files: [File],
                                     now: Date,
                                     keepNewest: Int = 100,
                                     maximumAge: TimeInterval = 7 * 24 * 60 * 60) -> [URL] {
        let ordered = files.sorted { $0.modified > $1.modified }
        var removals: [URL] = []
        for (index, file) in ordered.enumerated() {
            let tooOld = now.timeIntervalSince(file.modified) > maximumAge
            if index >= max(keepNewest, 0) || tooOld {
                removals.append(file.url)
            }
        }
        return removals
    }

    /// Applies `filesToRemove` to the real directory. Safe to call off the main
    /// thread; a missing directory is simply nothing to do.
    public static func prune(in directory: URL = TerminalImagePaste.directory,
                             now: Date = Date(),
                             keepNewest: Int = 100,
                             maximumAge: TimeInterval = 7 * 24 * 60 * 60,
                             fileManager: FileManager = .default) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let files: [File] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return File(url: url, modified: values.contentModificationDate ?? .distantPast)
        }
        for url in filesToRemove(files, now: now,
                                 keepNewest: keepNewest,
                                 maximumAge: maximumAge) {
            try? fileManager.removeItem(at: url)
        }
    }
}
