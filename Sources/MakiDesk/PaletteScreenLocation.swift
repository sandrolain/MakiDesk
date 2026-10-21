import Foundation

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
}
