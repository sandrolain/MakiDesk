import AppKit
import SwiftUI

/// A colour theme for the palette, panels and overlay.
struct PaletteTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let background: Color
    let surface: Color
    let surfaceSelected: Color
    let text: Color
    let subtext: Color
    let accent: Color
    let border: Color

    static let all: [PaletteTheme] = [
        PaletteTheme(id: "mocha", name: "Mocha",
                     background: .hex(0x1E1E2E), surface: .hex(0x313244), surfaceSelected: .hex(0x45475A),
                     text: .hex(0xCDD6F4), subtext: .hex(0xA6ADC8), accent: .hex(0xCBA6F7), border: .hex(0x585B70)),
        PaletteTheme(id: "macchiato", name: "Macchiato",
                     background: .hex(0x24273A), surface: .hex(0x363A4F), surfaceSelected: .hex(0x494D64),
                     text: .hex(0xCAD3F5), subtext: .hex(0xA5ADCB), accent: .hex(0xC6A0F6), border: .hex(0x5B6078)),
        PaletteTheme(id: "frappe", name: "Frappé",
                     background: .hex(0x303446), surface: .hex(0x414559), surfaceSelected: .hex(0x51576D),
                     text: .hex(0xC6D0F5), subtext: .hex(0xB5BFE2), accent: .hex(0xCA9EE6), border: .hex(0x626880)),
        PaletteTheme(id: "latte", name: "Latte",
                     background: .hex(0xEFF1F5), surface: .hex(0xCCD0DA), surfaceSelected: .hex(0xBCC0CC),
                     text: .hex(0x4C4F69), subtext: .hex(0x5C5F77), accent: .hex(0x8839EF), border: .hex(0x9CA0B0)),
        PaletteTheme(id: "plum", name: "Plum",
                     background: .hex(0x282A36), surface: .hex(0x44475A), surfaceSelected: .hex(0x565A73),
                     text: .hex(0xF8F8F2), subtext: .hex(0xBFBFBF), accent: .hex(0xBD93F9), border: .hex(0x6272A4)),
        PaletteTheme(id: "arctic", name: "Arctic",
                     background: .hex(0x2E3440), surface: .hex(0x3B4252), surfaceSelected: .hex(0x434C5E),
                     text: .hex(0xECEFF4), subtext: .hex(0xD8DEE9), accent: .hex(0x88C0D0), border: .hex(0x4C566A)),
        PaletteTheme(id: "midnight", name: "Midnight",
                     background: .hex(0x1A1B26), surface: .hex(0x24283B), surfaceSelected: .hex(0x2F334D),
                     text: .hex(0xC0CAF5), subtext: .hex(0xA9B1D6), accent: .hex(0x7AA2F7), border: .hex(0x3B4261)),
        PaletteTheme(id: "caramel", name: "Caramel",
                     background: .hex(0x282828), surface: .hex(0x3C3836), surfaceSelected: .hex(0x504945),
                     text: .hex(0xEBDBB2), subtext: .hex(0xD5C4A1), accent: .hex(0xD79921), border: .hex(0x665C54)),
        PaletteTheme(id: "graphite", name: "Graphite",
                     background: .hex(0x282C34), surface: .hex(0x3A3F4B), surfaceSelected: .hex(0x474E5D),
                     text: .hex(0xABB2BF), subtext: .hex(0x8B93A1), accent: .hex(0x61AFEF), border: .hex(0x4B5263)),
        PaletteTheme(id: "macos-light", name: "macOS Light",
                     background: .hex(0xF5F5F7), surface: .hex(0xFFFFFF), surfaceSelected: .hex(0xE8E8ED),
                     text: .hex(0x1D1D1F), subtext: .hex(0x6E6E73), accent: .hex(0x007AFF), border: .hex(0xD2D2D7)),
        PaletteTheme(id: "macos-dark", name: "macOS Dark",
                     background: .hex(0x1C1C1E), surface: .hex(0x2C2C2E), surfaceSelected: .hex(0x3A3A3C),
                     text: .hex(0xF5F5F7), subtext: .hex(0xAEAEB2), accent: .hex(0x0A84FF), border: .hex(0x48484A)),
        PaletteTheme(id: "solarized-light", name: "Solarized Light",
                     background: .hex(0xFDF6E3), surface: .hex(0xEEE8D5), surfaceSelected: .hex(0xE3DCC8),
                     text: .hex(0x586E75), subtext: .hex(0x657B83), accent: .hex(0x268BD2), border: .hex(0xD6CEBA)),
        PaletteTheme(id: "solarized-dark", name: "Solarized Dark",
                     background: .hex(0x002B36), surface: .hex(0x073642), surfaceSelected: .hex(0x164854),
                     text: .hex(0x839496), subtext: .hex(0x93A1A1), accent: .hex(0x2AA198), border: .hex(0x28535D)),
        PaletteTheme(id: "rose-pine", name: "Rosé Pine",
                     background: .hex(0x191724), surface: .hex(0x1F1D2E), surfaceSelected: .hex(0x26233A),
                     text: .hex(0xE0DEF4), subtext: .hex(0x908CAA), accent: .hex(0xC4A7E7), border: .hex(0x403D52)),
        PaletteTheme(id: "shades-of-purple", name: "Shades of Purple",
                     background: .hex(0x2D2B55), surface: .hex(0x3A3768), surfaceSelected: .hex(0x4D4A7A),
                     text: .hex(0xFFFFFF), subtext: .hex(0xA599E9), accent: .hex(0xFAD000), border: .hex(0x5A55A0)),
        PaletteTheme(id: "synthwave-84", name: "SynthWave 84",
                     background: .hex(0x241B2F), surface: .hex(0x2A2139), surfaceSelected: .hex(0x3A2D58),
                     text: .hex(0xF8F8F2), subtext: .hex(0xB6B1D0), accent: .hex(0xFF7EDB), border: .hex(0x4B3B6B)),
        PaletteTheme(id: "cyberpunk", name: "Cyberpunk",
                     background: .hex(0x0D0221), surface: .hex(0x1A0B2E), surfaceSelected: .hex(0x2A1B4A),
                     text: .hex(0xF8F8F2), subtext: .hex(0xA8B2D1), accent: .hex(0xFCEE0A), border: .hex(0x5A2A6A)),
        PaletteTheme(id: "system", name: "System",
                     background: Color(nsColor: .windowBackgroundColor),
                     surface: Color(nsColor: .controlBackgroundColor),
                     surfaceSelected: Color(nsColor: .unemphasizedSelectedContentBackgroundColor),
                     text: Color(nsColor: .labelColor),
                     subtext: Color(nsColor: .secondaryLabelColor),
                     accent: Color(nsColor: .controlAccentColor),
                     border: Color(nsColor: .separatorColor))
    ]

    static func named(_ id: String) -> PaletteTheme {
        all.first { $0.id == id } ?? all[0]
    }

    /// Derived from the palette luminance. Used to give native
    /// controls (switches, popups, titlebars) a matching appearance when a whole
    /// window is painted with the theme, as Settings now is (T42).
    @MainActor
    var isDark: Bool {
        if followsSystemAppearance {
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let color = NSColor(background).usingColorSpace(.sRGB) ?? .black
        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance < 0.5
    }

    var followsSystemAppearance: Bool { id == "system" }

    /// Keeps an older stored theme id from selecting nothing in Settings.
    static func normalized(_ id: String) -> String {
        all.contains { $0.id == id } ? id : all[0].id
    }
}

/// One of the nine screen anchor positions for the palette.
enum PalettePosition: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight
    case middleLeft, center, middleRight
    case bottomLeft, bottomCenter, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top"
        case .topRight: return "Top Right"
        case .middleLeft: return "Left"
        case .center: return "Center"
        case .middleRight: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Origin for a panel of `size` inside `frame` (Cocoa coordinates).
    func origin(size: CGSize, in frame: CGRect) -> CGPoint {
        let margin: CGFloat = 24
        let x: CGFloat
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: x = frame.minX + margin
        case .topCenter, .center, .bottomCenter: x = frame.midX - size.width / 2
        case .topRight, .middleRight, .bottomRight: x = frame.maxX - size.width - margin
        }
        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight: y = frame.maxY - size.height - margin
        case .middleLeft, .center, .middleRight: y = frame.midY - size.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight: y = frame.minY + margin
        }
        return CGPoint(x: x, y: y)
    }
}

extension Color {
    static func hex(_ value: Int) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

/// Makes the current palette theme available to small views that paint with it
/// (Settings sections, slider rows) without threading it through every init.
private struct PaletteThemeKey: EnvironmentKey {
    static let defaultValue = PaletteTheme.all[0]
}

extension EnvironmentValues {
    var paletteTheme: PaletteTheme {
        get { self[PaletteThemeKey.self] }
        set { self[PaletteThemeKey.self] = newValue }
    }
}

extension Notification.Name {
    /// The palette theme changed: panels that paint with it repaint (T20).
    static let makiDeskThemeChanged = Notification.Name("makiDeskThemeChanged")
}
