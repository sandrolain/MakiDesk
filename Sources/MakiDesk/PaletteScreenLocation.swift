import AppKit

/// Which display hosts the switcher and search when a new session opens.
enum PaletteScreenLocation: String, CaseIterable, Identifiable {
    case focusedWindow
    case mouse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .focusedWindow: return "Focused window"
        case .mouse: return "Mouse pointer"
        }
    }

    /// Uses Cocoa screen coordinates throughout, including negative origins.
    /// If the pointer is outside all displays, keep the keyboard-focus display.
    func screenIndex(frames: [CGRect], focusedIndex: Int?, mouse: CGPoint) -> Int? {
        if self == .mouse, let index = frames.firstIndex(where: { $0.contains(mouse) }) {
            return index
        }
        if let focusedIndex, frames.indices.contains(focusedIndex) { return focusedIndex }
        return frames.isEmpty ? nil : 0
    }

    /// The display this choice means, with the palette's fallback. One rule for
    /// the notices, the checklist and the countdown card.
    @MainActor
    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.isEmpty == false else { return nil }
        let focusedID = NSScreen.main.flatMap(Self.displayID)
        let focusedIndex = focusedID.flatMap { id in
            screens.firstIndex { Self.displayID($0) == id }
        }
        let index = screenIndex(frames: screens.map(\.frame),
                                focusedIndex: focusedIndex,
                                mouse: NSEvent.mouseLocation)
        return index.map { screens[$0] } ?? NSScreen.main ?? screens.first
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
