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
    var height: CGFloat = 176
    var labelMode: BarLabelMode = .auto

    static let defaultHeight: CGFloat = 176
    static let heightRange: ClosedRange<CGFloat> = 156...220
    /// At this width the larger category groups can keep their labels visible.
    static let labelWidth: CGFloat = 1_100

    /// Heights saved by earlier releases were 64–96 pt. Those values cannot
    /// hold the new three-row layout, so start those installations at the new
    /// default instead of silently pinning them to its minimum.
    static func height(fromStored value: Int) -> CGFloat {
        guard value > 0 else { return defaultHeight }
        let height = CGFloat(value)
        guard height >= heightRange.lowerBound else { return defaultHeight }
        return min(height, heightRange.upperBound)
    }

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
        case "pointerEffects": return PointerEffectController.shared.isPresentationActive
        case "clickRipple": return WorkspaceStore.shared.pointerClickRipple
        case "keyboardSounds": return KeyboardSoundController.shared.isEnabled
        default: return false
        }
    }

    func value(for info: BarItem.Info, now: Date) -> String {
        switch info {
        case .disk:
            return BarInfoText.disk(SystemMonitor.shared.menuBarDiskText)
        case .cpu:
            return BarInfoText.cpu(SystemMonitor.shared.cpuPercent)
        case .windows:
            return BarInfoText.windows(WorkspaceStore.shared.windows.count)
        }
    }

    /// The nearest running countdown, shown as the Timer button's badge. The
    /// separate info value was a second control with the same name.
    func timerText(now: Date) -> String? {
        BarInfoText.timer(TimerController.shared.timers, now: now)
    }
}
