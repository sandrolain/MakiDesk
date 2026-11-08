import Foundation

/// Moving through the sidebar with the keyboard (F4 polish).
public enum TerminalWorkspaceNavigation {
    /// The workspace after `delta` steps, wrapping at both ends. Nil when
    /// there is nothing to select.
    public static func cycledIndex(from index: Int, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        let start = min(max(index, 0), count - 1)
        return ((start + delta) % count + count) % count
    }
}
