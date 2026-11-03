import CoreGraphics
import Foundation
import Observation

/// What the bar shows, and nothing else: the values come from the controllers
/// that already own them, so hiding the bar stops all of its work.
@Observable
@MainActor
final class UtilityBarModel {
    /// Session state: the pin is not written anywhere, so a relaunch never
    /// brings back a bar the user forgot to unblock.
    var isPinned = false
    /// The bar took the keyboard with ⌃⌥B and draws a selection.
    var isKeyboardDriven = false
    var height: CGFloat = 46
    var labelMode: BarLabelMode = .auto

    static let defaultHeight: CGFloat = 46
    static let heightRange: ClosedRange<CGFloat> = 28...64
    /// Below this the words beside the icons would push the info values out.
    static let labelWidth: CGFloat = 1_150

    func showsLabels(at width: CGFloat) -> Bool {
        switch labelMode {
        case .always: return true
        case .never: return false
        case .auto: return width >= Self.labelWidth
        }
    }

    func isOn(_ item: BarItem) -> Bool {
        switch item.id {
        case "focusBorder": return WorkspaceStore.shared.focusBorderEnabled
        case "focusDim": return WorkspaceStore.shared.focusDimEnabled
        case "miniMap": return WorkspaceStore.shared.showMiniMap
        default: return false
        }
    }

    func value(for info: BarItem.Info, now: Date) -> String {
        switch info {
        case .disk:
            return BarInfoText.disk(SystemMonitor.shared.menuBarDiskText)
        case .cpu:
            return BarInfoText.cpu(SystemMonitor.shared.cpuPercent)
        case .timers:
            return BarInfoText.timer(TimerController.shared.timers, now: now) ?? BarInfoText.empty
        case .windows:
            return BarInfoText.windows(WorkspaceStore.shared.windows.count)
        }
    }
}
