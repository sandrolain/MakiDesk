import Foundation
import MakiShared

/// Keeps a stable path to the bundled `makidesk` CLI (F3 L2).
///
/// The path inside `MakiDeskTerminal.app` moves with the app and can contain
/// spaces; a symlink under Application Support is stable, has no spaces and is
/// what `MAKIDESK_CLI` points at. The helper recreates it at every launch.
public enum TerminalCLI {
    public static var stableURL: URL {
        TerminalSocketLocation.directory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("makidesk")
    }

    /// Returns the path to use, preferring the stable symlink. Nil when the
    /// bundled binary is missing (a development build without the helper app).
    @discardableResult
    public static func install(
        bundledURL: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("makidesk"),
        stableURL: URL = TerminalCLI.stableURL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let bundledURL,
              fileManager.isExecutableFile(atPath: bundledURL.path) else { return nil }
        let directory = stableURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            if fileManager.fileExists(atPath: stableURL.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: stableURL.path)) != nil {
                try fileManager.removeItem(at: stableURL)
            }
            try fileManager.createSymbolicLink(at: stableURL, withDestinationURL: bundledURL)
            return stableURL
        } catch {
            // A failed symlink must not hide the CLI: use the bundled path.
            return bundledURL
        }
    }

    /// Whether the stable link currently resolves to an executable.
    public static func isAvailable(fileManager: FileManager = .default) -> Bool {
        fileManager.isExecutableFile(atPath: stableURL.path)
    }
}
