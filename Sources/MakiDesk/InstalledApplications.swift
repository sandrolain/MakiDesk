import AppKit
import Foundation

/// One application bundle found in the standard Applications folders.
///
/// A value type only: the icon belongs to the palette's presentation cache, so
/// the inventory can be built on a worker queue without touching AppKit.
struct InstalledApplication: Identifiable, Hashable, Sendable {
    /// The bundle's standardized path; also its stable identity across scans.
    let path: String
    /// CFBundleDisplayName / CFBundleName, falling back to the bundle file name.
    let name: String
    /// CFBundleExecutable, shown under the name as the actual binary.
    let executable: String
    let bundleIdentifier: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// Pure matching rules for the palette's application shelf, so ranking can be
/// tested without a file system or a screen.
enum ApplicationSearch {
    static let defaultLimit = 12

    /// Applications matching `query`, best first. Empty queries return nothing:
    /// the shelf then shows its hint instead of an arbitrary alphabetical list.
    static func matches(_ applications: [InstalledApplication], query: String,
                        limit: Int = defaultLimit) -> [InstalledApplication] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let needle = normalize(trimmed)
        let tokens = needle.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let ranked = applications.compactMap { application -> (InstalledApplication, Int)? in
            guard let rank = rank(application, needle: needle, tokens: tokens) else { return nil }
            return (application, rank)
        }
        return ranked.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let nameOrder = lhs.0.name.localizedStandardCompare(rhs.0.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.0.path < rhs.0.path
        }
        .prefix(limit)
        .map(\.0)
    }

    /// Lower is better; nil means no match. The order is stable and deliberate:
    /// the name the user reads, then the executable, then the bundle id, then a
    /// token match for queries such as "visual code".
    private static func rank(_ application: InstalledApplication,
                             needle: String, tokens: [String]) -> Int? {
        let name = normalize(application.name)
        let executable = normalize(application.executable)
        let identifier = normalize(application.bundleIdentifier ?? "")

        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains(where: { $0.hasPrefix(needle) }) { return 2 }
        if executable == needle { return 3 }
        if executable.hasPrefix(needle) { return 4 }
        if name.contains(needle) { return 5 }
        if executable.contains(needle) { return 6 }
        if !identifier.isEmpty, identifier.contains(needle) { return 7 }
        guard tokens.count > 1 else { return nil }
        let searchable = "\(name) \(executable) \(identifier)"
        return tokens.allSatisfy { searchable.contains($0) } ? 8 : nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: .current)
            .lowercased()
    }
}

/// Reads `.app` bundles from `/Applications`, `/System/Applications` and
/// `~/Applications`. No synchronous call here touches the main thread: the
/// palette calls it through `ApplicationCatalog`'s worker queue.
enum ApplicationScanner {
    static var defaultRoots: [URL] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]
        if let userApplications = FileManager.default
            .urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(userApplications)
        }
        return roots
    }

    /// Apps in the given roots, including one level of grouping folders such as
    /// `Utilities`, and never descending inside a bundle. Duplicate bundle ids
    /// keep the shallowest copy (then the first path in standard order), so a
    /// copy inside a folder never displaces the real application.
    static func scan(roots: [URL] = defaultRoots) -> [InstalledApplication] {
        let fileManager = FileManager.default
        var candidates: [InstalledApplication] = []
        var seenPaths = Set<String>()

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                let depth = url.pathComponents.count - root.pathComponents.count
                guard (1...3).contains(depth) else { continue }
                guard let application = application(at: url) else { continue }
                guard seenPaths.insert(application.path).inserted else { continue }
                candidates.append(application)
            }
        }

        let ordered = candidates.sorted { lhs, rhs in
            let leftDepth = lhs.path.split(separator: "/").count
            let rightDepth = rhs.path.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            let pathOrder = lhs.path.localizedStandardCompare(rhs.path)
            if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
            return lhs.path < rhs.path
        }

        var seenBundleIDs = Set<String>()
        var found: [InstalledApplication] = []
        for application in ordered {
            if let bundleID = application.bundleIdentifier, !bundleID.isEmpty {
                guard seenBundleIDs.insert(bundleID).inserted else { continue }
            }
            found.append(application)
        }

        return found.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.path < rhs.path
        }
    }

    private static func application(at url: URL) -> InstalledApplication? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL, options: [.mappedIfSafe]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any] else { return nil }

        let fallback = url.deletingPathExtension().lastPathComponent
        let display = (info["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleName = (info["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = [display, bundleName].compactMap { $0 }.first { !$0.isEmpty } ?? fallback
        let executable = (info["CFBundleExecutable"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return InstalledApplication(
            path: url.standardizedFileURL.path,
            name: name,
            executable: executable.flatMap { $0.isEmpty ? nil : $0 } ?? fallback,
            bundleIdentifier: info["CFBundleIdentifier"] as? String
        )
    }
}

/// Process-wide application inventory. The scan runs on a utility queue, is
/// coalesced while in flight, and publishes on the main queue; the result is
/// reused for a short while so opening the search repeatedly stays instant.
final class ApplicationCatalog {
    static let shared = ApplicationCatalog()

    private(set) var applications: [InstalledApplication] = []
    private(set) var isLoading = false
    private var loadedAt: Date?
    private var waiters: [([InstalledApplication]) -> Void] = []
    private let queue = DispatchQueue(label: "com.makidesk.application-catalog", qos: .utility)
    private let scan: () -> [InstalledApplication]
    /// Installs and removals are rare; a short-lived cache is enough to notice
    /// them without re-reading the folders on every keystroke.
    private static let maximumAge: TimeInterval = 120

    init(scan: @escaping () -> [InstalledApplication] = { ApplicationScanner.scan() }) {
        self.scan = scan
    }

    /// Returns the inventory when it is still fresh; otherwise scans once and
    /// calls every waiter on the main queue. Never blocks the caller.
    func loadIfNeeded(completion: @escaping ([InstalledApplication]) -> Void) {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.maximumAge {
            completion(applications)
            return
        }
        waiters.append(completion)
        guard !isLoading else { return }
        isLoading = true
        let scan = self.scan
        let started = Date()
        queue.async { [weak self] in
            let found = scan()
            DispatchQueue.main.async {
                guard let self else { return }
                let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                self.applications = found
                self.loadedAt = Date()
                self.isLoading = false
                let waiters = self.waiters
                self.waiters.removeAll()
                waiters.forEach { $0(found) }
                makiLog.debug("application catalog: \(found.count) bundles in \(milliseconds) ms")
            }
        }
    }

    /// Opens the bundle. The completion runs on the main queue with the error,
    /// if any; the caller decides how to report it.
    func launch(_ application: InstalledApplication,
                completion: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: application.url, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
