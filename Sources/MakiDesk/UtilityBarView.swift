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

    /// The buttons grow with the bar, within limits: a taller bar should feel
    /// roomier, not merely padded.
    private var controlHeight: CGFloat {
        min(max((model.height - 18) / 2, 22), 38)
    }

    var body: some View {
        GeometryReader { proxy in
            let labels = model.showsLabels(at: proxy.size.width)
            let plan = plan(for: proxy.size.width, labels: labels)
            let shown = store.barConfiguration.resolvedItems()
                .filter { plan.visible.contains($0.id) }
            let utility = shown.filter { $0.zone == .utility }
            let toggles = shown.filter { $0.zone == .toggle }
            let infoItems = shown.filter { $0.zone == .info }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    groupLabel("Panels & tools")
                    zone(utility, plan: plan, labels: labels)
                    Spacer(minLength: 4)
                    rightZone(plan: plan)
                }
                HStack(spacing: 4) {
                    groupLabel("Window controls")
                    zone(toggles, plan: plan, labels: labels)
                    if toggles.isEmpty == false, infoItems.isEmpty == false { divider }
                    if infoItems.isEmpty == false { groupLabel("System status") }
                    infoZone(infoItems, plan: plan, labels: labels)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: proxy.size.width, height: model.height, alignment: .leading)
            .makiSurface(.chrome, theme: theme, fill: theme.raisedSurface)
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

    private func zone(_ items: [BarItem], plan: BarLayout.Plan, labels: Bool) -> some View {
        ForEach(items.filter { plan.visible.contains($0.id) }) { item in
            // The Timer button carries the nearest countdown as a badge, so it
            // has to refresh itself; the other controls change with their store.
            if item.id == "timer" {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    control(item, labels: labels, now: context.date)
                }
            } else {
                control(item, labels: labels)
            }
        }
    }

    private func infoZone(_ items: [BarItem], plan: BarLayout.Plan, labels: Bool) -> some View {
        ForEach(items.filter { plan.visible.contains($0.id) }) { item in
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
            .frame(width: 1, height: min(controlHeight - 10, 20))
            .padding(.horizontal, 4)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.subtext.opacity(0.8))
            .lineLimit(1)
            .padding(.horizontal, 4)
    }

    // MARK: - Controls

    private func control(_ item: BarItem, labels: Bool, overflowCount: Int = 0,
                         now: Date = Date()) -> some View {
        Button {
            selected = item.id
            if case .overflow = item.kind {
                showOverflowMenu()
            } else {
                controller.activate(item)
            }
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
                if let badge = badge(for: item, overflowCount: overflowCount, now: now) {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(theme.selectionSurface))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: MakiRadius.control)
                    .fill(background(for: item))
            )
            .overlay {
                if model.isKeyboardDriven, selected == item.id {
                    RoundedRectangle(cornerRadius: MakiRadius.control)
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
            .frame(height: controlHeight)
            .background(RoundedRectangle(cornerRadius: MakiRadius.control)
                .fill(background(for: item)))
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
        // A symbol typed into the buttons file may not exist: show the
        // catalog's icon rather than a blank space.
        if NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) == nil {
            return BarItemCatalog.item(id: item.id)?.symbol ?? item.symbol
        }
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
            return theme.selectionSurface
        }
        return .clear
    }

    private func badge(for item: BarItem, overflowCount: Int = 0,
                       now: Date = Date()) -> String? {
        switch item.id {
        case "clipboard":
            let count = ClipboardHistory.shared.entries.count
            return count > 0 ? "\(count)" : nil
        case "checklist":
            let remaining = ChecklistStore.shared.remaining
            return remaining > 0 ? "\(remaining)" : nil
        case "timer":
            return model.timerText(now: now)
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
        let configured = store.barConfiguration.resolvedItems()
        func layout(_ items: [BarItem], reserve: CGFloat) -> BarLayout.Plan {
            let measured = items.map {
                BarLayoutItem(id: $0.id, priority: $0.priority,
                              width: $0.width(labels: labels, badge: badge(for: $0)))
            }
            return BarLayout.plan(measured, available: width, reserve: reserve)
        }
        // The wider, two-row bar gives each contextual group its own width
        // budget. Reserve the right controls on row one and the group labels on
        // both rows; the overflow indicator is reserved before its count is known.
        let utility = layout(configured.filter { $0.zone == .utility }, reserve: 180)
        let status = layout(configured.filter { $0.zone == .toggle || $0.zone == .info }, reserve: 210)
        return BarLayout.Plan(visible: utility.visible + status.visible,
                              overflow: utility.overflow + status.overflow)
    }

    private func showOverflowMenu() {
        let items = store.barConfiguration.resolvedItems()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let plan = plan(for: width, labels: model.showsLabels(at: width))
        controller.popOverflow(plan.overflow.compactMap { byID[$0] })
    }

    private func orderedIDs(labels: Bool) -> [String] {
        let plan = plan(for: width, labels: labels)
        // The chevron is only drawn when something overflowed, so the keyboard
        // must not stop on a control that is not there.
        let right = BarItemCatalog.right
            .filter { $0.id != "overflow" || plan.overflow.isEmpty == false }
            .map(\.id)
        return plan.visible + right
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
        guard let selected else { return }
        let items = store.barConfiguration.resolvedItems()
        guard let item = items.first(where: { $0.id == selected })
                ?? BarItemCatalog.right.first(where: { $0.id == selected }) else { return }
        if case .overflow = item.kind {
            showOverflowMenu()
        } else {
            controller.activate(item)
        }
    }
}
