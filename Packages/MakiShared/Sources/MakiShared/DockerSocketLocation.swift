import Foundation

/// Where MakiDesk and the Docker helper meet.
///
/// The name is deliberately not `docker.sock`: that path belongs to the Docker
/// daemon, and confusing the two would be a support problem. The directory is
/// `0700` and the socket `0600`, like the terminal's.
public enum DockerSocketLocation {
    /// `~/Library/Application Support/MakiDesk/Docker`.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MakiDesk", isDirectory: true)
            .appendingPathComponent("Docker", isDirectory: true)
    }

    /// `~/Library/Application Support/MakiDesk/Docker/docker-control.sock`.
    public static var socketURL: URL {
        directory.appendingPathComponent("docker-control.sock")
    }
}
