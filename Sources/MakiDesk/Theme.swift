import SwiftUI

/// A colour theme for the palette / mini-map. Inspired by the OpenCode theme
/// list (Catppuccin, Dracula, Nord, Tokyo Night, Gruvbox, …).
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
        PaletteTheme(id: "catppuccin-mocha", name: "Catppuccin Mocha",
                     background: .hex(0x1E1E2E), surface: .hex(0x313244), surfaceSelected: .hex(0x45475A),
                     text: .hex(0xCDD6F4), subtext: .hex(0xA6ADC8), accent: .hex(0xCBA6F7), border: .hex(0x585B70)),
        PaletteTheme(id: "catppuccin-macchiato", name: "Catppuccin Macchiato",
                     background: .hex(0x24273A), surface: .hex(0x363A4F), surfaceSelected: .hex(0x494D64),
                     text: .hex(0xCAD3F5), subtext: .hex(0xA5ADCB), accent: .hex(0xC6A0F6), border: .hex(0x5B6078)),
        PaletteTheme(id: "catppuccin-frappe", name: "Catppuccin Frappé",
                     background: .hex(0x303446), surface: .hex(0x414559), surfaceSelected: .hex(0x51576D),
                     text: .hex(0xC6D0F5), subtext: .hex(0xB5BFE2), accent: .hex(0xCA9EE6), border: .hex(0x626880)),
        PaletteTheme(id: "catppuccin-latte", name: "Catppuccin Latte",
                     background: .hex(0xEFF1F5), surface: .hex(0xCCD0DA), surfaceSelected: .hex(0xBCC0CC),
                     text: .hex(0x4C4F69), subtext: .hex(0x5C5F77), accent: .hex(0x8839EF), border: .hex(0x9CA0B0)),
        PaletteTheme(id: "dracula", name: "Dracula",
                     background: .hex(0x282A36), surface: .hex(0x44475A), surfaceSelected: .hex(0x565A73),
                     text: .hex(0xF8F8F2), subtext: .hex(0xBFBFBF), accent: .hex(0xBD93F9), border: .hex(0x6272A4)),
        PaletteTheme(id: "nord", name: "Nord",
                     background: .hex(0x2E3440), surface: .hex(0x3B4252), surfaceSelected: .hex(0x434C5E),
                     text: .hex(0xECEFF4), subtext: .hex(0xD8DEE9), accent: .hex(0x88C0D0), border: .hex(0x4C566A)),
        PaletteTheme(id: "tokyonight", name: "Tokyo Night",
                     background: .hex(0x1A1B26), surface: .hex(0x24283B), surfaceSelected: .hex(0x2F334D),
                     text: .hex(0xC0CAF5), subtext: .hex(0xA9B1D6), accent: .hex(0x7AA2F7), border: .hex(0x3B4261)),
        PaletteTheme(id: "gruvbox", name: "Gruvbox Dark",
                     background: .hex(0x282828), surface: .hex(0x3C3836), surfaceSelected: .hex(0x504945),
                     text: .hex(0xEBDBB2), subtext: .hex(0xD5C4A1), accent: .hex(0xD79921), border: .hex(0x665C54)),
        PaletteTheme(id: "onedark", name: "One Dark",
                     background: .hex(0x282C34), surface: .hex(0x3A3F4B), surfaceSelected: .hex(0x474E5D),
                     text: .hex(0xABB2BF), subtext: .hex(0x8B93A1), accent: .hex(0x61AFEF), border: .hex(0x4B5263))
    ]

    static func named(_ id: String) -> PaletteTheme {
        all.first { $0.id == id } ?? all[0]
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

extension Notification.Name {
    /// The palette theme changed: panels that paint with it repaint (T20).
    static let makiDeskThemeChanged = Notification.Name("makiDeskThemeChanged")
}
