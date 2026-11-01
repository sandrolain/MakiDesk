import AppKit

/// The store's presentation helpers: the per-app colours and the mini-map
/// overlay (R01).
///
/// Split out for navigation only; the state they touch is the theme and the
/// mini-map preference, both already on the class.
extension WorkspaceStore {

    // MARK: - Colors

    func tint(for appName: String) -> String {
        let palette = ["blue", "purple", "green", "orange", "pink"]
        return palette[Self.stableIndex(appName, count: palette.count)]
    }

    /// A per-app colour. Hues are assigned in first-seen order on an evenly
    /// spaced wheel derived from the theme's accent, so **any two open apps are
    /// at least ~30° apart** (no more clusters of similar yellows). A second
    /// tier (lighter/desaturated) covers the rare case of more than 12 apps.
    func color(for appName: String) -> NSColor {
        let base = (NSColor(theme.accent).usingColorSpace(.deviceRGB)) ?? .systemBlue
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let hueSteps = 12
        let index = colorIndex(for: appName)
        let slot = index % hueSteps
        let tier = (index / hueSteps) % 2
        let shifted = (hue + CGFloat(slot) / CGFloat(hueSteps)).truncatingRemainder(dividingBy: 1)
        let baseSaturation = min(1, max(0.55, saturation))
        let baseBrightness = min(1, max(0.68, brightness))
        // Tier 1 is pale/faded, clearly distinct from tier 0 at the same hue.
        let saturationOut = tier == 0 ? baseSaturation : baseSaturation * 0.6
        let brightnessOut = tier == 0 ? baseBrightness : min(1, baseBrightness * 1.2)
        return NSColor(hue: shifted, saturation: saturationOut, brightness: brightnessOut, alpha: 1)
    }

    /// Stable per-app slot, handed out in first-seen order.
    private func colorIndex(for appName: String) -> Int {
        if let existing = appColorOrder[appName] { return existing }
        let index = appColorOrder.count
        appColorOrder[appName] = index
        return index
    }

    private static func stableIndex(_ text: String, count: Int) -> Int {
        var hash = 5381
        for scalar in text.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return abs(hash) % max(1, count)
    }

    // MARK: - Mini-map

    func showMiniMapIfEnabled(motionFrom: [UUID: CGRect] = [:]) {
        guard showMiniMap else { return }
        let focusedID = mostRecentFocusedWindowID.flatMap { focusedSystemID in
            windows.first(where: { $0.systemID == focusedSystemID })?.id
        }
        MiniMapController.shared.show(
            windows: windows,
            highlightedIDs: Set(focusedID.map { [$0] } ?? []),
            motionFrom: motionFrom
        )
    }

    func showMiniMapIfEnabled(for target: WindowController.WindowInfo, frame: CGRect) {
        guard showMiniMap else { return }
        var mapWindows = windows
        var highlightedID: UUID?
        if let index = mapWindows.firstIndex(where: { $0.systemID == target.id }) {
            highlightedID = mapWindows[index].id
            mapWindows[index].x = frame.minX
            mapWindows[index].y = frame.minY
            mapWindows[index].width = frame.width
            mapWindows[index].height = frame.height
        } else if let index = matchingIndex(for: target) {
            highlightedID = mapWindows[index].id
            mapWindows[index].x = frame.minX
            mapWindows[index].y = frame.minY
            mapWindows[index].width = frame.width
            mapWindows[index].height = frame.height
        } else {
            let mapped = WorkspaceWindow(title: target.title, appName: target.appName,
                                         x: frame.minX, y: frame.minY,
                                         width: frame.width, height: frame.height,
                                         systemID: target.id)
            highlightedID = mapped.id
            mapWindows.append(mapped)
        }
        MiniMapController.shared.show(windows: mapWindows, highlightedIDs: Set(highlightedID.map { [$0] } ?? []))
    }
}
