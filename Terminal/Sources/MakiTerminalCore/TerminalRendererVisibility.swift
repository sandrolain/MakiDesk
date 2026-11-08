import Foundation

/// The one rule for "is the hosting window visible enough to render".
///
/// `NSWindow.occlusionState` is the authoritative signal on a real display: a
/// miniaturized, fully covered or off-space window drops `.visible`. On a
/// virtual display AppKit may never raise that bit even though the window is
/// ordered in and drawing, so until a window has reported `.visible` once its
/// ordinary on-screen state is trusted instead. A key window is always visible.
public enum TerminalRendererVisibility {
    public static func isVisible(occlusionVisible: Bool,
                                 windowHasReportedVisible: Bool,
                                 isVisible: Bool,
                                 isMiniaturized: Bool,
                                 isOnActiveSpace: Bool,
                                 isKeyWindow: Bool) -> Bool {
        if occlusionVisible || isKeyWindow { return true }
        // Once the window has proved it reports occlusion, honour it.
        if windowHasReportedVisible { return false }
        return isVisible && isMiniaturized == false && isOnActiveSpace
    }
}
