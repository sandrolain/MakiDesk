import AppKit
import SwiftUI

/// The strip itself (F1): utility commands, toggles, info, and the pin.
///
/// It reads the controllers that own the values and runs the existing
/// shortcuts; the only state of its own is hover and the keyboard selection.
struct UtilityBarView: View {
    @Bindable var controller: UtilityBarController
    @Bindable var model: UtilityBarModel
    @Bindable var store: WorkspaceStore

    @State private var hovered: String?
    @State private var selected: String?
    @State private var width: CGFloat = 0
    @FocusState private var hasKeyboardFocus: Bool

    private var theme: PaletteTheme { store.theme }

    var body: some View {
        GeometryReader { proxy in
            let labels = model.showsLabels(at: proxy.size.width)
            let plan = plan(for: proxy.size.width, labels: labels)
            HStack(spacing: 2) {
                zone(.utility, plan: plan, labels: labels)
                divider
                zone(.toggle, plan: plan, labels: labels)
                Spacer(minLength: 6)
                infoZone(plan: plan, labels: labels)
                divider
                rightZone(plan: plan)
            }
            .padding(.horizontal, 8)
            .frame(width: proxy.size.width, height: model.height)
            .background(theme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.border.opacity(0.75)).frame(height: 1)
            }
            .onAppear {
                width = proxy.size.width
                focusIfNeeded()
            }
            .onChange(of: proxy.size.width) { _, value in width = value }
            .onChange(of: model.isKeyboardDriven) { _, driven in
                if driven { focusIfNeeded() } else { selected = nil }
            }
        }
        .frame(height: model.height)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { runSelected(); return .handled }
        .onKeyPress(.escape) { controller.dismiss(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Utility bar")
    }

    // MARK: - Zones

    private func zone(_ zone: BarItem.Zone, plan: BarLayout.Plan, labels: Bool) -> some View {
        ForEach(BarItemCatalog.all.filter { $0.zone == zone && plan.visible.contains($0.id) }) { item in
            control(item, labels: labels)
        }
    }

    private func infoZone(plan: BarLayout.Plan, labels: Bool) -> some View {
        ForEach(BarItemCatalog.info.filter { plan.visible.contains($0.id) }) { item in
            TimelineView(.periodic(from: .now, by: 1)) { context in
                info(item, labels: labels, now: context.date)
            }
        }
    }

    private func rightZone(plan: BarLayout.Plan) -> some View {
        // The chevron appears only when something actually overflowed; an empty
        // menu is not worth a control.
        let items = BarItemCatalog.right.filter {
            $0.id != "overflow" || plan.overflow.isEmpty == false
        }
        return ForEach(items) { item in
            control(item, labels: false, overflowCount: plan.overflow.count)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.border.opacity(0.65))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

    // MARK: - Controls

    private func control(_ item: BarItem, labels: Bool, overflowCount: Int = 0) -> some View {
        Button {
            selected = item.id
            controller.activate(item)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol(for: item))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tint(for: item))
                if labels, showsTitle(item) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint(for: item))
                        .lineLimit(1)
                }
                if let badge = badge(for: item, overflowCount: overflowCount) {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(theme.surfaceSelected))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(background(for: item))
            )
            .overlay {
                if model.isKeyboardDriven, selected == item.id {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.accent.opacity(0.9), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
        }
        .help(help(item))
        .accessibilityLabel(item.title)
        .accessibilityValue(isOn(item) ? "on" : "")
    }

    private func info(_ item: BarItem, labels: Bool, now: Date) -> some View {
        Button {
            controller.activate(item)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(theme.subtext)
                if case let .info(info) = item.kind {
                    Text(model.value(for: info, now: now))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.text)
                }
                if labels {
                    Text(item.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.subtext.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(background(for: item)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
        }
        .help(help(item))
        .accessibilityLabel(item.title)
    }

    // MARK: - Item state

    private func showsTitle(_ item: BarItem) -> Bool {
        switch item.kind {
        case .pin, .overflow, .customize: return false
        default: return true
        }
    }

    private func symbol(for item: BarItem) -> String {
        if item.id == "pin", model.isPinned { return "pin.fill" }
        return item.symbol
    }

    private func isOn(_ item: BarItem) -> Bool {
        item.id == "pin" ? model.isPinned : model.isOn(item)
    }

    private func tint(for item: BarItem) -> Color {
        if item.id == "pin" { return model.isPinned ? theme.accent : theme.subtext }
        guard item.zone == .toggle else { return theme.text }
        return isOn(item) ? theme.accent : theme.subtext
    }

    private func background(for item: BarItem) -> Color {
        if hovered == item.id || (model.isKeyboardDriven && selected == item.id) {
            return theme.surfaceSelected
        }
        return .clear
    }

    private func badge(for item: BarItem, overflowCount: Int) -> String? {
        switch item.id {
        case "clipboard":
            let count = ClipboardHistory.shared.entries.count
            return count > 0 ? "\(count)" : nil
        case "checklist":
            let remaining = ChecklistStore.shared.remaining
            return remaining > 0 ? "\(remaining)" : nil
        case "overflow":
            return overflowCount > 0 ? "\(overflowCount)" : nil
        default:
            return nil
        }
    }

    private func help(_ item: BarItem) -> String {
        var text = item.title
        if let action = item.shortcutAction,
           let keys = ShortcutManager.display(for: action, bindings: store.shortcutBindings),
           keys.isEmpty == false {
            text += " (\(keys))"
        }
        return text
    }

    // MARK: - Plan and keyboard

    private func plan(for width: CGFloat, labels: Bool) -> BarLayout.Plan {
        let items = BarItemCatalog.planned.map {
            BarLayoutItem(id: $0.id, priority: $0.priority, width: $0.width(labels: labels))
        }
        // The right-hand controls are never planned away, so their width, the
        // spacing, the two dividers and the side padding are taken out first.
        let right = BarItemCatalog.right.reduce(0) { $0 + $1.width(labels: false) }
        let count = CGFloat(BarItemCatalog.planned.count + BarItemCatalog.right.count)
        let reserve = right + count * 2 + 18 + 6 + 16
        return BarLayout.plan(items, available: width, reserve: reserve)
    }

    private func orderedIDs(labels: Bool) -> [String] {
        let plan = plan(for: width, labels: labels)
        return plan.visible + BarItemCatalog.right.map(\.id)
    }

    private func focusIfNeeded() {
        guard model.isKeyboardDriven else { return }
        hasKeyboardFocus = true
        if selected == nil {
            selected = orderedIDs(labels: model.showsLabels(at: width)).first
        }
    }

    private func move(_ step: Int) {
        let ids = orderedIDs(labels: model.showsLabels(at: width))
        guard ids.isEmpty == false else { return }
        let current = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = (current + step + ids.count) % ids.count
        selected = ids[next]
    }

    private func runSelected() {
        guard let selected, let item = BarItemCatalog.item(id: selected) else { return }
        if case .overflow = item.kind {
            let plan = plan(for: width, labels: model.showsLabels(at: width))
            controller.popOverflow(plan.overflow.compactMap(BarItemCatalog.item(id:)))
        } else {
            controller.activate(item)
        }
    }
}
