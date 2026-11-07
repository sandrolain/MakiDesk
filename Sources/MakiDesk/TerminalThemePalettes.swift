import AppKit
import MakiShared

/// ANSI palettes for the MakiDesk themes (F2).
///
/// The UI colours come from `PaletteTheme`; these sixteen are the terminal's
/// own vocabulary. Named themes reuse the palette they were drawn from (Plum
/// is Dracula, Arctic is Nord, Midnight is Tokyo Night, Caramel is Gruvbox,
/// Graphite is One Dark), so the terminal and the window agree.
enum TerminalThemePalettes {
    static func ansi(for themeID: String) -> [String] {
        if themeID == "system" {
            let appearance = NSApp?.effectiveAppearance
            let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return palettes[dark ? "macos-dark" : "macos-light"]
                ?? TerminalThemeDocument.standardANSI
        }
        return palettes[themeID] ?? TerminalThemeDocument.standardANSI
    }

    static let palettes: [String: [String]] = [
        "mocha": [
            "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
            "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
            "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF",
            "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8",
        ],
        "macchiato": [
            "#494D64", "#ED8796", "#A6DA95", "#EED49F",
            "#8AADF4", "#F5BDE6", "#8BD5CA", "#B8C0E0",
            "#5B6078", "#ED8796", "#A6DA95", "#EED49F",
            "#8AADF4", "#F5BDE6", "#8BD5CA", "#A5ADCB",
        ],
        "frappe": [
            "#51576D", "#E78284", "#A6D189", "#E5C890",
            "#8CAAEE", "#F4B8E4", "#81C8BE", "#B5BFE2",
            "#626880", "#E78284", "#A6D189", "#E5C890",
            "#8CAAEE", "#F4B8E4", "#81C8BE", "#A5ADCE",
        ],
        "latte": [
            "#5C5F77", "#D20F39", "#40A02B", "#DF8E1D",
            "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
            "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D",
            "#1E66F5", "#EA76CB", "#179299", "#BCC0CC",
        ],
        "plum": [
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C",
            "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
            "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
        ],
        "arctic": [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
        ],
        "midnight": [
            "#15161E", "#F7768E", "#9ECE6A", "#E0AF68",
            "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
            "#414868", "#F7768E", "#9ECE6A", "#E0AF68",
            "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
        ],
        "caramel": [
            "#282828", "#CC241D", "#98971A", "#D79921",
            "#458588", "#B16286", "#689D6A", "#A89984",
            "#928374", "#FB4934", "#B8BB26", "#FABD2F",
            "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
        ],
        "graphite": [
            "#282C34", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
            "#5C6370", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF",
        ],
        "macos-light": [
            "#000000", "#C41A16", "#007400", "#826B28",
            "#0000FF", "#A90D91", "#318495", "#C7C7CC",
            "#555555", "#C41A16", "#007400", "#826B28",
            "#0000FF", "#A90D91", "#318495", "#FFFFFF",
        ],
        "macos-dark": [
            "#000000", "#FF6B68", "#A8FF60", "#FFD36B",
            "#6B9BFF", "#FF7AB2", "#6BFFD3", "#C7C7CC",
            "#666666", "#FF6B68", "#A8FF60", "#FFD36B",
            "#6B9BFF", "#FF7AB2", "#6BFFD3", "#FFFFFF",
        ],
        "solarized-light": [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ],
        "solarized-dark": [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ],
        "rose-pine": [
            "#26233A", "#EB6F92", "#31748F", "#F6C177",
            "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
            "#6E6A86", "#EB6F92", "#31748F", "#F6C177",
            "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
        ],
        "shades-of-purple": [
            "#1E1E3F", "#FF628C", "#A5FF90", "#FFB62C",
            "#4D9DE0", "#FF628C", "#80FFBB", "#FFFFFF",
            "#5C5C8A", "#FF628C", "#A5FF90", "#FFB62C",
            "#4D9DE0", "#FF628C", "#80FFBB", "#FFFFFF",
        ],
        "synthwave-84": [
            "#241B2F", "#F97E72", "#72F1B8", "#FEDE5B",
            "#36F9F6", "#FF7EDB", "#72F1B8", "#FFFFFF",
            "#6E4C7A", "#F97E72", "#72F1B8", "#FEDE5B",
            "#36F9F6", "#FF7EDB", "#72F1B8", "#FFFFFF",
        ],
        "cyberpunk": [
            "#0D0221", "#FF2A6D", "#05D9E8", "#F9F002",
            "#D300C5", "#FF2A6D", "#05D9E8", "#FFFFFF",
            "#3A2D58", "#FF2A6D", "#05D9E8", "#F9F002",
            "#D300C5", "#FF2A6D", "#05D9E8", "#FFFFFF",
        ],
    ]
}
