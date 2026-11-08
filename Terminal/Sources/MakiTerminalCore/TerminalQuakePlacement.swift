import CoreGraphics
import Foundation

/// Where the quake panel sits on a display (F4 multi-display polish).
///
/// The panel spans the display's visible frame at the top, leaving the menu bar
/// and the Dock alone, and its height is a share of that frame. A very short
/// display still gets a usable panel, and a saved fraction outside the settings
/// range cannot push it over the whole screen.
public enum TerminalQuakePlacement {
    /// The smallest height a short display still gives the panel.
    public static let minimumHeight: CGFloat = 240

    public static func frame(in visibleFrame: CGRect, heightFraction: Double) -> CGRect {
        let fraction = min(max(heightFraction, 0.3), 0.6)
        let height = min(visibleFrame.height,
                         max(minimumHeight, visibleFrame.height * CGFloat(fraction)))
        return CGRect(x: visibleFrame.minX,
                      y: visibleFrame.maxY - height,
                      width: visibleFrame.width,
                      height: height)
    }
}
