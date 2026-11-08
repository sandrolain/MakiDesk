import AppKit

/// The identity of a set of displays: which panels are connected and their
/// full sizes. Visible frames and backing scales are deliberately absent — a
/// Dock resize changes the desk, not which saved layout applies to it.
struct DisplayLayoutIdentity: Equatable, Hashable {
    struct Screen: Equatable, Hashable {
        let id: CGDirectDisplayID
        let width: Int
        let height: Int
    }

    /// Sorted by display id, so the same desk always produces the same key
    /// whatever order `NSScreen.screens` came back in.
    let screens: [Screen]

    init(_ screens: [(id: CGDirectDisplayID, size: CGSize)]) {
        self.screens = screens.map { entry in
            Screen(id: entry.id,
                   width: Int(entry.size.width.rounded()),
                   height: Int(entry.size.height.rounded()))
        }.sorted { $0.id < $1.id }
    }

    var key: String {
        screens.map { "\($0.id):\($0.width)x\($0.height)" }.joined(separator: "|")
    }

    static func key(for screens: [NSScreen]) -> String {
        DisplayLayoutIdentity(screens.compactMap { screen in
            guard let id = WorkspaceStore.displayID(of: screen) else { return nil }
            return (id, screen.frame.size)
        }).key
    }
}

/// A full reading of the desk: the display identity plus the parts that must
/// stop changing before a transition is treated as settled — the usable area,
/// which moves with the Dock and the menu bar, and the backing scale.
struct DisplayFingerprint: Equatable {
    let identity: DisplayLayoutIdentity
    let visible: [CGDirectDisplayID: CGRect]
    let scales: [CGDirectDisplayID: CGFloat]

    init(screens: [NSScreen]) {
        var entries: [(id: CGDirectDisplayID, size: CGSize)] = []
        var visible: [CGDirectDisplayID: CGRect] = [:]
        var scales: [CGDirectDisplayID: CGFloat] = [:]
        for screen in screens {
            guard let id = WorkspaceStore.displayID(of: screen) else { continue }
            entries.append((id, screen.frame.size))
            visible[id] = screen.visibleFrame
            scales[id] = screen.backingScaleFactor
        }
        self.init(identity: DisplayLayoutIdentity(entries),
                  visible: visible, scales: scales)
    }

    init(identity: DisplayLayoutIdentity,
         visible: [CGDirectDisplayID: CGRect],
         scales: [CGDirectDisplayID: CGFloat]) {
        self.identity = identity
        self.visible = visible
        self.scales = scales
    }

    /// A comparable reading of everything that decides whether a display
    /// transition has finished. Rounded, because AppKit reports sub-point
    /// differences that a user cannot see and a layout does not care about.
    var signature: String {
        let visiblePart = visible.keys.sorted().map { id -> String in
            let rect = visible[id] ?? .zero
            return "\(id)=\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())),"
                + "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
        }.joined(separator: ";")
        let scalePart = scales.keys.sorted().map { id in
            "\(id)=\(Int(((scales[id] ?? 1) * 100).rounded()))"
        }.joined(separator: ";")
        return "\(identity.key)#\(visiblePart)#\(scalePart)"
    }
}
