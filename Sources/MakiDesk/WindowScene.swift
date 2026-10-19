import Foundation

/// T15/T17, the scene: which windows are left in use, what has to come forward
/// for them, and what is put away behind them.
///
/// Pure — no accessibility, no windows — so the rules can be pinned down
/// exactly: an app with no member is hidden, an app holding a member only has
/// its *other* windows minimised (hiding it would hide the member too), a
/// window whose app cannot be hidden is minimised, and anything the user had
/// already put away is left alone and never claimed as ours to restore.
///
/// The two halves run in the order of §6.3: **reveal** a window in use before it
/// can be placed, and only **remove** what is behind it once it is.
enum WindowScene {
    /// Every live window, member or not, as the planner sees it. Members are
    /// passed in too: their app must be known, so that hiding it can be avoided.
    struct Candidate: Equatable {
        var id: String
        var pid: pid_t
        /// Already minimised before the recall: the user put it away, so it is
        /// left alone and never claimed as ours to restore.
        var minimized: Bool
        /// The app is already hidden: not ours either, for the same reason.
        var appHidden: Bool
        /// Whether the app can be hidden at all. Some apps (background agents,
        /// Accessory apps) cannot, and then their windows are minimised instead.
        var appHideable: Bool
        /// Whether the window is on the display being cleared. A window on
        /// another screen belongs to no scene and is left alone.
        var onDisplay: Bool
        /// A window this mode may not move: a full screen is a workspace of its
        /// own, and a minimised fullscreen window is not a tile either. It is
        /// never minimised, and while it is visible its app is not hidden
        /// either — hiding the app would take this window down with it.
        var unmanaged: Bool

        init(id: String, pid: pid_t, minimized: Bool = false,
             appHidden: Bool = false, appHideable: Bool = true,
             onDisplay: Bool = true, unmanaged: Bool = false) {
            self.id = id
            self.pid = pid
            self.minimized = minimized
            self.appHidden = appHidden
            self.appHideable = appHideable
            self.onDisplay = onDisplay
            self.unmanaged = unmanaged
        }
    }

    /// What to do, split into the step that brings a window forward and the one
    /// that takes it away. Fields are listed in the order they must run.
    struct Plan: Equatable {
        /// Apps to show again: they own a window that must be in use, and a
        /// hidden app draws none of its windows.
        var revealedApps: [pid_t] = []
        /// Members to bring back from the Dock before they can be placed.
        var restoredWindows: [String] = []
        /// Apps to hide, by pid; none of them owns a member of the scene.
        var hiddenApps: [pid_t] = []
        /// Windows to minimise, by id; these belong either to an app that also
        /// owns a member (hiding it would hide the member too) or to an app that
        /// cannot be hidden.
        var minimizedWindows: [String] = []

        /// Whether anything has to be brought forward before the arranging.
        var hasReveals: Bool { !revealedApps.isEmpty || !restoredWindows.isEmpty }

        /// How many windows the scene moved out of the way. Hiding an app counts
        /// once per app, not per window: that is what the HUD reports, and the
        /// step the tray counts.
        var count: Int { hiddenApps.count + minimizedWindows.count }

        /// Whether there is nothing left to do — the state a scene reaches when
        /// it is presented again and is already the only thing on screen.
        var isEmpty: Bool { !hasReveals && hiddenApps.isEmpty && minimizedWindows.isEmpty }
    }

    /// The reveal half (§6.2): what must come forward so that a member can be
    /// placed. A member whose app is hidden needs the app shown; a member in the
    /// Dock needs to come back before it can take a frame. Members already on
    /// screen ask for nothing.
    static func revealPlan(members: [Candidate]) -> Plan {
        var plan = Plan()
        var seenApps = Set<pid_t>()
        var seenWindows = Set<String>()
        for member in members {
            if member.appHidden, seenApps.insert(member.pid).inserted {
                plan.revealedApps.append(member.pid)
            }
            if member.minimized, seenWindows.insert(member.id).inserted {
                plan.restoredWindows.append(member.id)
            }
        }
        return plan
    }

    /// Puts everything on the scene's display that is not `members` away. An app
    /// is hidden only when none of its windows is in the group: an app holding a
    /// member must stay visible, so only its other windows are minimised. Windows
    /// the user had already minimised, apps already hidden, windows of an app the
    /// system will not hide, and windows on other displays are left untouched and
    /// never written into the plan.
    static func plan(windows: [Candidate], members: Set<String>) -> Plan {
        let memberPids = Set(windows.filter { members.contains($0.id) }.map(\.pid))
        // An app with a window we may not touch (a fullscreen one) cannot be
        // hidden, or that window would go with it: only its other windows are.
        let pinnedApps = Set(windows.filter {
            $0.unmanaged && !$0.minimized && !$0.appHidden && $0.onDisplay
        }.map(\.pid))

        var plan = Plan()
        var seenApps = Set<pid_t>()
        var seenWindows = Set<String>()
        for window in windows {
            if members.contains(window.id) { continue }   // never touched
            if window.unmanaged { continue }              // not ours to touch
            if !window.onDisplay { continue }             // another screen keeps it
            if window.minimized { continue }              // already away, not by us
            if window.appHidden { continue }              // same, for the whole app
            if memberPids.contains(window.pid) || pinnedApps.contains(window.pid) || !window.appHideable {
                if seenWindows.insert(window.id).inserted { plan.minimizedWindows.append(window.id) }
            } else if seenApps.insert(window.pid).inserted {
                plan.hiddenApps.append(window.pid)
            }
        }
        return plan
    }
}
