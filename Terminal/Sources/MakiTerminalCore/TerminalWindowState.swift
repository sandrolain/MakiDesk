import CoreGraphics
import Foundation
import MakiShared

/// Where the helper's main window reopens (F4 restore polish).
///
/// A saved frame is only used when enough of it still meets a display: an
/// unplugged monitor must not leave the window unreachable. Too many windows
/// have been lost to a saved coordinate on a screen that no longer exists.
public enum TerminalWindowGeometry {
    /// The window's own minimum size.
    public static let minimumSize = CGSize(width: 560, height: 320)
    /// How much of the frame must be on a display to count as reachable.
    /// A title bar's width and height is enough to grab the window.
    public static let minimumVisible = CGSize(width: 120, height: 40)

    /// The frame to restore, or nil to fall back to a centered window.
    public static func restoredFrame(_ frame: CGRect, screens: [CGRect]) -> CGRect? {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0 else { return nil }
        let normalized = CGRect(x: frame.minX, y: frame.minY,
                                width: max(frame.width, minimumSize.width),
                                height: max(frame.height, minimumSize.height))
        let reachable = screens.contains { screen in
            let intersection = screen.intersection(normalized)
            return intersection.isNull == false
                && intersection.width >= minimumVisible.width
                && intersection.height >= minimumVisible.height
        }
        return reachable ? normalized : nil
    }
}

/// The bits of the main window worth remembering between launches.
public struct TerminalWindowState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(version: Int = TerminalWindowState.currentVersion, frame: CGRect) {
        self.version = version
        self.x = frame.origin.x
        self.y = frame.origin.y
        self.width = frame.width
        self.height = frame.height
    }

    public var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// `Terminal/window.json`: the main window's last frame. A missing or corrupt
/// file is simply no saved frame; the caller centers the window.
public struct TerminalWindowStateStore {
    public let fileURL: URL

    public init(fileURL: URL = TerminalWindowStateStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        TerminalSocketLocation.directory.appendingPathComponent("window.json")
    }

    public func load() -> TerminalWindowState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = StoredJSONFile.decoder()
        guard let state = try? decoder.decode(TerminalWindowState.self, from: data) else {
            StoredJSONFile.quarantine(fileURL, label: "terminal window state")
            return nil
        }
        guard state.version <= TerminalWindowState.currentVersion else { return nil }
        return state
    }

    @discardableResult
    public func save(_ state: TerminalWindowState) -> Bool {
        var payload = state
        payload.version = TerminalWindowState.currentVersion
        guard let data = try? StoredJSONFile.encoder().encode(payload) else { return false }
        do {
            try StoredJSONFile.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }
}
