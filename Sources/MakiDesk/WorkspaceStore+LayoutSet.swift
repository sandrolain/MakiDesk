import AppKit

/// The pure side of "which windows does a layout command arrange": no
/// Accessibility call and no model state, so it is tested without a desktop.
extension WorkspaceStore {
    /// What a layout command does with one live window: place it, or leave it
    /// alone for a stated reason (T24).
    enum LayoutDisposition: Equatable {
        /// In view and arrangeable.
        case arrange
        /// In full screen: the app owns the frame and refuses ours.
        case fullScreen
        /// Minimised, or owned by an app that is hidden: out of view on purpose.
        case away
    }

    static func disposition(minimized: Bool, appHidden: Bool, fullScreen: Bool) -> LayoutDisposition {
        if minimized || appHidden { return .away }
        if fullScreen { return .fullScreen }
        return .arrange
    }

    /// A layout command's candidates, with what it deliberately left out so the
    /// feedback can say how many windows it placed and why there were not more
    /// (T24).
    struct ArrangeableSet {
        var windows: [ActionableWindow] = []
        /// In view, but in full screen: no frame of ours to set.
        var fullScreen = 0
        /// Out of view on purpose: minimised, or its app is hidden.
        var away = 0
        var unavailable = 0

        init(windows: [ActionableWindow] = []) { self.windows = windows }

        var isEmpty: Bool { windows.isEmpty }
    }

    /// Pure core of `arrangeableSet()`: every flag comes from the inventory read
    /// that preceded the command, so no Accessibility call runs per window here.
    static func arrangeableSet(from windows: [ActionableWindow],
                               appHidden: (pid_t) -> Bool) -> ArrangeableSet {
        var set = ArrangeableSet()
        for window in windows {
            if window.state == .unavailable { set.unavailable += 1; continue }
            let disposition = Self.disposition(
                minimized: window.minimized,
                appHidden: appHidden(window.pid),
                fullScreen: window.fullScreen
            )
            switch disposition {
            case .arrange: set.windows.append(window)
            case .fullScreen: set.fullScreen += 1
            case .away: set.away += 1
            }
        }
        return set
    }

    /// One line saying how many windows a layout placed and, when that is fewer
    /// than what is in view, why: a window that is away stays away, a full-screen
    /// window cannot be given a frame of ours (T24).
    static func layoutSummary(_ set: ArrangeableSet) -> String {
        var text = set.windows.count == 1 ? "1 window" : "\(set.windows.count) windows"
        if set.fullScreen == 1 { text += " · 1 full screen" }
        if set.fullScreen > 1 { text += " · \(set.fullScreen) full screen" }
        if set.away == 1 { text += " · 1 away" }
        if set.away > 1 { text += " · \(set.away) away" }
        if set.unavailable > 0 { text += " · \(set.unavailable) temporarily unavailable" }
        return text
    }
}
