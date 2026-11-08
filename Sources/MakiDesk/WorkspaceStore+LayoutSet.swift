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

    /// One screen a layout command may place windows on. `area` is the usable
    /// frame in the same (AX, top-left) coordinates as `ActionableWindow.frame`.
    struct LayoutScreen: Equatable {
        let id: CGDirectDisplayID
        let area: CGRect
    }

    /// The windows a layout command places together on one screen.
    struct LayoutGroup {
        let screen: LayoutScreen
        var windows: [ActionableWindow]
    }

    /// Splits `windows` by the screen each one is on, preserving the input
    /// order inside a group and the `screens` order across groups. A window
    /// whose display is unknown — or no longer connected — falls back to the
    /// screen it overlaps most, then to the first screen. Pure: the caller
    /// supplies the display lookup, so this runs in tests without a desktop.
    ///
    /// `NSScreen.main` is deliberately not a fallback: a layout command must
    /// not drag a window onto the focused display just because it is focused.
    static func layoutGroups(
        for windows: [ActionableWindow],
        screens: [LayoutScreen],
        displayID: (ActionableWindow) -> CGDirectDisplayID?
    ) -> [LayoutGroup] {
        guard !screens.isEmpty else { return [] }
        var indexByID: [CGDirectDisplayID: Int] = [:]
        for (index, screen) in screens.enumerated() { indexByID[screen.id] = index }

        var buckets = [Int: [ActionableWindow]](minimumCapacity: screens.count)
        for window in windows {
            let index = displayID(window).flatMap { indexByID[$0] }
                ?? fallbackScreenIndex(for: window, screens: screens)
            buckets[index, default: []].append(window)
        }
        return screens.indices.compactMap { index in
            guard let windows = buckets[index], windows.isEmpty == false else { return nil }
            return LayoutGroup(screen: screens[index], windows: windows)
        }
    }

    /// The screen whose usable area holds most of the window. Ties go to the
    /// earlier screen; a window overlapping none goes to the first screen, so
    /// the result is always deterministic.
    private static func fallbackScreenIndex(for window: ActionableWindow,
                                            screens: [LayoutScreen]) -> Int {
        var best = 0
        var bestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let hit = screen.area.intersection(window.frame)
            let area = hit.isNull ? 0 : hit.width * hit.height
            if area > bestArea + 0.5 {
                bestArea = area
                best = index
            }
        }
        return best
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
