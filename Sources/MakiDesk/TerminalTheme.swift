import AppKit
import MakiShared
import SwiftUI

/// Turns the MakiDesk palette into the document the terminal helper reads.
///
/// The helper never loads the user's Ghostty configuration: the theme is the
/// one chosen in Settings, plus a fixed ANSI palette for now. Per-theme ANSI
/// colours are a separate design pass.
extension TerminalThemeDocument {
    init(palette: PaletteTheme) {
        self.init(
            id: palette.id,
            name: palette.name,
            background: palette.background.terminalHex,
            foreground: palette.text.terminalHex,
            cursor: palette.accent.terminalHex,
            selectionBackground: palette.surfaceSelected.terminalHex,
            selectionForeground: palette.text.terminalHex,
            surface: palette.surface.terminalHex,
            surfaceSelected: palette.surfaceSelected.terminalHex,
            subtext: palette.subtext.terminalHex,
            accent: palette.accent.terminalHex,
            border: palette.border.terminalHex,
            ansi: TerminalThemePalettes.ansi(for: palette.id)
        )
    }
}

private extension Color {
    var terminalHex: String {
        guard let colour = NSColor(self).usingColorSpace(.sRGB) else {
            return "#000000"
        }
        let red = Int((colour.redComponent * 255).rounded())
        let green = Int((colour.greenComponent * 255).rounded())
        let blue = Int((colour.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
