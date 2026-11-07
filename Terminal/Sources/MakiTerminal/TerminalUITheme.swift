import AppKit
import MakiShared

/// The helper's own window chrome, taken from the same theme document as the
/// terminal surface, so the sidebar and title bar do not stay system-grey next
/// to a themed terminal.
struct TerminalUITheme {
    let background: NSColor
    let surface: NSColor
    let surfaceSelected: NSColor
    let text: NSColor
    let subtext: NSColor
    let accent: NSColor
    let border: NSColor

    static let fallback = TerminalUITheme(document: .fallback)

    init(document: TerminalThemeDocument) {
        let theme = document.normalized()
        background = NSColor(terminalHex: theme.background) ?? .black
        surface = NSColor(terminalHex: theme.surface ?? theme.background) ?? background
        surfaceSelected = NSColor(terminalHex: theme.surfaceSelected
                                    ?? theme.selectionBackground) ?? surface
        text = NSColor(terminalHex: theme.foreground) ?? .white
        subtext = NSColor(terminalHex: theme.subtext ?? theme.foreground) ?? text
        accent = NSColor(terminalHex: theme.accent ?? theme.cursor) ?? .controlAccentColor
        border = NSColor(terminalHex: theme.border ?? theme.selectionBackground) ?? surface
    }

    var isDark: Bool {
        guard let colour = background.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * colour.redComponent
            + 0.7152 * colour.greenComponent
            + 0.0722 * colour.blueComponent
        return luminance < 0.5
    }
}

extension NSColor {
    convenience init?(terminalHex value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.hasPrefix("#"),
              let number = UInt32(trimmed.dropFirst(), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
                  green: CGFloat((number >> 8) & 0xFF) / 255,
                  blue: CGFloat(number & 0xFF) / 255,
                  alpha: 1)
    }
}
