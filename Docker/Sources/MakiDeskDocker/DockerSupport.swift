import AppKit
import Foundation
import MakiDockerCore
import MakiShared
import SwiftUI

struct DockerUITheme: Equatable {
    let document: TerminalThemeDocument

    init(document: TerminalThemeDocument = .fallback) {
        self.document = document.normalized()
    }

    var background: Color { Color(hex: document.background) ?? .black }
    var surface: Color { Color(hex: document.surface ?? document.background) ?? .black }
    var surfaceSelected: Color { Color(hex: document.surfaceSelected
                                        ?? document.selectionBackground) ?? surface }
    var text: Color { Color(hex: document.foreground) ?? .white }
    var subtext: Color { Color(hex: document.subtext ?? document.foreground) ?? text }
    var accent: Color { Color(hex: document.accent ?? document.cursor) ?? .accentColor }
    var border: Color { Color(hex: document.border
                              ?? document.selectionBackground) ?? surface }
    var nsBackground: NSColor { NSColor(hex: document.background) ?? .windowBackgroundColor }
    var nsSurface: NSColor { NSColor(hex: document.surface ?? document.background) ?? nsBackground }

    var isDark: Bool {
        guard let colour = NSColor(hex: document.background)?.usingColorSpace(.sRGB) else {
            return true
        }
        return 0.2126 * colour.redComponent + 0.7152 * colour.greenComponent
            + 0.0722 * colour.blueComponent < 0.5
    }
}

enum DockerThemeStore {
    static var fileURL: URL {
        DockerSocketLocation.directory.appendingPathComponent("theme.json")
    }

    static func load() -> TerminalThemeDocument {
        TerminalThemeStore(fileURL: fileURL).load()
    }
}

enum DockerSettingsStore {
    static var fileURL: URL {
        DockerSocketLocation.directory.appendingPathComponent("settings.json")
    }

    static func load() -> DockerSettingsDocument {
        guard let data = try? Data(contentsOf: fileURL) else { return .defaults }
        do {
            return try StoredJSONFile.decoder()
                .decode(DockerSettingsDocument.self, from: data).normalized()
        } catch {
            StoredJSONFile.quarantine(fileURL, label: "docker settings")
            return .defaults
        }
    }

    @discardableResult
    static func save(_ document: DockerSettingsDocument) -> Bool {
        var payload = document.normalized()
        payload.version = DockerSettingsDocument.currentVersion
        guard let data = try? StoredJSONFile.encoder().encode(payload) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }
}

struct DockerWindowState: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(frame: NSRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.width
        height = frame.height
    }

    var frame: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }

    /// Restore only when a title-bar-sized part still meets a screen.
    func restoredFrame() -> NSRect? {
        let candidate = frame
        guard candidate.width >= 400, candidate.height >= 300 else { return nil }
        let title = NSRect(x: candidate.minX, y: candidate.maxY - 30,
                           width: candidate.width, height: 30)
        return NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(title)
        } ? candidate : nil
    }
}

enum DockerWindowStateStore {
    static var fileURL: URL {
        DockerSocketLocation.directory.appendingPathComponent("window.json")
    }

    static func load() -> DockerWindowState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try StoredJSONFile.decoder().decode(DockerWindowState.self, from: data)
        } catch {
            StoredJSONFile.quarantine(fileURL, label: "docker window")
            return nil
        }
    }

    static func save(_ state: DockerWindowState) {
        guard let data = try? StoredJSONFile.encoder().encode(state) else { return }
        try? StoredJSONFile.write(data, to: fileURL)
    }
}

extension Color {
    init?(hex: String) {
        guard let colour = NSColor(hex: hex) else { return nil }
        self.init(nsColor: colour)
    }
}

extension NSColor {
    convenience init?(hex value: String) {
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
