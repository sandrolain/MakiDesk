import AppKit
import MakiShared
import SwiftUI

struct BrowserUITheme: Equatable {
    let document: TerminalThemeDocument

    init(document: TerminalThemeDocument) {
        self.document = document.normalized()
    }

    var followsSystemAppearance: Bool { document.id == "system" }

    @MainActor
    var isDark: Bool {
        if followsSystemAppearance {
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        guard let color = NSColor(browserHex: document.background)?.usingColorSpace(.sRGB) else {
            return true
        }
        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance < 0.5
    }

    @MainActor
    var preferredColorScheme: ColorScheme? {
        followsSystemAppearance ? nil : (isDark ? .dark : .light)
    }

    @MainActor
    var windowAppearance: NSAppearance? {
        followsSystemAppearance ? nil : NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    @MainActor
    var windowBackground: NSColor {
        followsSystemAppearance
            ? .windowBackgroundColor
            : (NSColor(browserHex: document.background) ?? .windowBackgroundColor)
    }

    @MainActor
    var background: Color {
        Color(nsColor: windowBackground)
    }

    @MainActor
    var pageBackground: Color {
        followsSystemAppearance ? Color(nsColor: .textBackgroundColor) : background
    }

    @MainActor
    var surface: Color {
        Color(nsColor: followsSystemAppearance
              ? .controlBackgroundColor
              : (NSColor(browserHex: document.surface ?? document.background)
                 ?? windowBackground))
    }

    @MainActor
    var text: Color {
        Color(nsColor: followsSystemAppearance
              ? .labelColor
              : (NSColor(browserHex: document.foreground) ?? .labelColor))
    }

    @MainActor
    var subtext: Color {
        Color(nsColor: followsSystemAppearance
              ? .secondaryLabelColor
              : (NSColor(browserHex: document.subtext ?? document.foreground)
                 ?? .secondaryLabelColor))
    }

    @MainActor
    var accent: Color {
        Color(nsColor: followsSystemAppearance
              ? .controlAccentColor
              : (NSColor(browserHex: document.accent ?? document.cursor)
                 ?? .controlAccentColor))
    }
}

enum BrowserThemeStore {
    static var fileURL: URL {
        StoredJSONFile.defaultURL(named: BrowserThemeSync.fileName)
    }

    static func load() -> TerminalThemeDocument {
        guard let data = try? Data(contentsOf: fileURL) else { return .fallback }
        do {
            return try StoredJSONFile.decoder()
                .decode(TerminalThemeDocument.self, from: data).normalized()
        } catch {
            StoredJSONFile.quarantine(fileURL, label: "browser theme")
            return .fallback
        }
    }
}

private extension NSColor {
    convenience init?(browserHex value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.hasPrefix("#"),
              let number = UInt32(trimmed.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
                  green: CGFloat((number >> 8) & 0xFF) / 255,
                  blue: CGFloat(number & 0xFF) / 255,
                  alpha: 1)
    }
}
