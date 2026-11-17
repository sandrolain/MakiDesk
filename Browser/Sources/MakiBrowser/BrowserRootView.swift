import AppKit
import SwiftUI
import WebKit

struct BrowserRootView: View {
    @Bindable var store: BrowserStore

    var body: some View {
        BrowserSplitView(store: store,
                         sidebarWidth: store.sidebarWidth,
                         compactTabs: store.settings.compactTabs)
        .padding(.top, 32)
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea()
        .background(store.theme.background)
        .tint(store.theme.accent)
        .preferredColorScheme(store.theme.preferredColorScheme)
        .sheet(isPresented: $store.isSettingsVisible) {
            BrowserSettingsView(store: store)
        }
        .sheet(item: $store.externalOpenRequest, onDismiss: store.finishExternalOpenRequest) { request in
            ExternalLinkChooser(store: store, request: request)
        }
        .confirmationDialog("Clear website data?",
                            isPresented: Binding(
                                get: { store.siteDataConfirmationTabID != nil },
                                set: { if !$0 { store.cancelSiteDataClear() } }
                            ),
                            titleVisibility: .visible) {
            Button("Clear Site Data", role: .destructive) {
                Task { await store.clearConfirmedSiteData() }
            }
            Button("Cancel", role: .cancel) { store.cancelSiteDataClear() }
        } message: {
            Text("Cookies and site storage for \(store.siteDataConfirmationHost ?? "this site") will be removed. You may be signed out.")
        }
        .onChange(of: store.windowTitle) { _, title in
            if let window = NSApp.keyWindow,
               window.windowController is BrowserWindowController {
                window.title = title
            }
        }
    }
}

private struct BrowserSplitView: NSViewRepresentable {
    let store: BrowserStore
    let sidebarWidth: Double
    let compactTabs: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let sidebar = NSHostingView(rootView: BrowserSidebar(store: store)
            .foregroundStyle(store.theme.text)
            .tint(store.theme.accent)
            .preferredColorScheme(store.theme.preferredColorScheme))
        sidebar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sidebar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = NSHostingView(rootView: BrowserContent(store: store)
            .foregroundStyle(store.theme.text)
            .tint(store.theme.accent)
            .preferredColorScheme(store.theme.preferredColorScheme))
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(content)
        context.coordinator.update(width: sidebarWidth, compactTabs: compactTabs, in: splitView)
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.update(width: sidebarWidth, compactTabs: compactTabs, in: splitView)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var store: BrowserStore?
        private var requestedWidth = 264.0
        private var requestedCompactTabs = false
        private var lastAppliedWidth: Double?
        private var lastAppliedCompactTabs: Bool?
        private var didRestoreWidth = false
        private var isApplyingWidth = false

        init(store: BrowserStore) {
            self.store = store
        }

        func update(width: Double, compactTabs: Bool, in splitView: NSSplitView) {
            requestedWidth = width
            requestedCompactTabs = compactTabs
            guard splitView.bounds.width > 0,
                  splitView.arrangedSubviews.count > 1 else { return }

            if !didRestoreWidth
                || lastAppliedCompactTabs != compactTabs
                || lastAppliedWidth.map({ abs($0 - width) > 0.5 }) == true {
                applyRequestedWidth(in: splitView)
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView,
                  splitView.arrangedSubviews.count > 1,
                  !isApplyingWidth else { return }
            if !didRestoreWidth {
                applyRequestedWidth(in: splitView)
                return
            }

            let width = Double(splitView.arrangedSubviews[0].frame.width)
            lastAppliedWidth = width
            lastAppliedCompactTabs = requestedCompactTabs
            if abs((store?.sidebarWidth ?? 0) - width) > 0.5 {
                store?.sidebarWidth = width
            }
        }

        func splitView(_ splitView: NSSplitView,
                       constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard dividerIndex == 0 else { return proposedMinimumPosition }
            return max(proposedMinimumPosition, requestedCompactTabs ? 97 : 240)
        }

        func splitView(_ splitView: NSSplitView,
                       constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard dividerIndex == 0 else { return proposedMaximumPosition }
            let maximum = requestedCompactTabs
                ? 97
                : min(480, splitView.bounds.width - 520 - splitView.dividerThickness)
            return min(proposedMaximumPosition, max(requestedCompactTabs ? 97 : 240, maximum))
        }

        private func applyRequestedWidth(in splitView: NSSplitView) {
            guard splitView.bounds.width > 0,
                  splitView.arrangedSubviews.count > 1 else { return }
            isApplyingWidth = true
            splitView.setPosition(CGFloat(requestedWidth), ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
            isApplyingWidth = false
            didRestoreWidth = true

            let width = Double(splitView.arrangedSubviews[0].frame.width)
            lastAppliedWidth = width
            lastAppliedCompactTabs = requestedCompactTabs
            if abs(width - requestedWidth) > 0.5 {
                store?.sidebarWidth = width
            }
        }
    }
}

private struct ExternalLinkChooser: View {
    @Bindable var store: BrowserStore
    let request: BrowserStore.BrowserExternalOpenRequest
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open link")
                .font(.system(size: 16, weight: .semibold))
            Text(request.url.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(store.theme.subtext)
                .textSelection(.enabled)
                .lineLimit(2)
            Button {
                store.openExternalURLInBrowser()
                dismiss()
            } label: {
                Label("Open in MakiDesk Browser", systemImage: "safari")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!store.isStarted)
            if !request.apps.isEmpty {
                Divider()
                Text("Open with another app")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.theme.subtext)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(request.apps) { app in
                            Button {
                                store.openExternalURL(in: app)
                                dismiss()
                            } label: {
                                VStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                        .resizable()
                                        .frame(width: 48, height: 48)
                                        .accessibilityHidden(true)
                                    Text(app.name)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: .infinity, minHeight: 90)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .help("Open link in \(app.name)")
                            .accessibilityLabel("Open link in \(app.name)")
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct BrowserSidebar: View {
    @Bindable var store: BrowserStore

    var body: some View {
        HStack(spacing: 0) {
            BrowserIconRail(store: store)
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: store.settings.compactTabs ? .center : .leading, spacing: 2) {
                        section(.pinned, tabs: store.pinnedTabs)
                        section(.active, tabs: store.activeTabs)
                        section(.old, tabs: store.oldTabs)
                    }
                    .padding(.horizontal, store.settings.compactTabs ? 7 : 8)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background {
            if store.theme.followsSystemAppearance {
                Rectangle().fill(.regularMaterial)
            } else {
                store.theme.surface
            }
        }
    }

    @ViewBuilder
    private func section(_ phase: BrowserTabPhase, tabs: [BrowserTab]) -> some View {
        if !tabs.isEmpty {
            if store.settings.compactTabs == false {
                HStack(spacing: 6) {
                    Text(phase.sectionTitle)
                    Spacer()
                    Text("\(tabs.count)")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(store.theme.subtext.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.top, phase == .pinned ? 2 : 12)
                .padding(.bottom, 3)
            }

            ForEach(tabs) { tab in
                BrowserTabRow(store: store, tab: tab)
                    .id("\(tab.id.uuidString)-\(store.settings.compactTabs ? "compact" : "expanded")")
            }
            if store.settings.compactTabs {
                Divider().opacity(0.25).padding(.vertical, 2)
            }
        }
    }
}

private struct BrowserIconRail: View {
    @Bindable var store: BrowserStore
    @State private var hovering: String?

    private var inspectorEnabled: Bool {
        guard let tabID = store.selectedTabID else { return false }
        return store.isWebInspectorEnabled(for: tabID)
    }

    var body: some View {
        VStack(spacing: 4) {
            icon("sidebar.left",
                 id: "compact", help: store.settings.compactTabs ? "Expand tab column" : "Compact tab column",
                 isActive: store.settings.compactTabs, animatePress: false) {
                store.toggleCompactTabs()
            }
            Divider().frame(width: 22).padding(.vertical, 2)

            icon("chevron.left", id: "back", help: "Back", isActive: false) { store.goBack() }
                .disabled(store.canGoBack == false)
            icon("chevron.right", id: "forward", help: "Forward", isActive: false) { store.goForward() }
                .disabled(store.canGoForward == false)
            icon(store.isLoading ? "xmark" : "arrow.clockwise",
                 id: "reload", help: store.isLoading ? "Stop loading" : "Reload page",
                 isActive: store.isLoading) {
                store.isLoading ? store.stopLoading() : store.reload()
            }
            icon("link", id: "address", help: "Address and search (⌘L)",
                 isActive: store.isAddressVisible) { store.showAddress() }
            icon("doc.on.doc", id: "copy-url", help: "Copy page URL") {
                store.copyURL()
            }
            .disabled(store.selectedTab?.url == nil)
            icon("magnifyingglass", id: "find", help: "Find in Page (⌘F)",
                 isActive: store.isFindVisible) {
                store.showFind()
            }
            .disabled(store.selectedTab?.url == nil)
            icon("plus", id: "new", help: "New Tab (⌘T); private tab (⌥⌘T)") { store.newTab() }
                .contextMenu {
                    Button("New Private Tab (⌥⌘T)") { store.newPrivateTab() }
                }

            Divider().frame(width: 20).padding(.vertical, 3)

            icon(store.selectedTab?.isPinned == true ? "pin.fill" : "pin",
                 id: "pin", help: store.selectedTab?.isPinned == true
                    ? "Unpin tab (⇧⌘P)" : "Pin tab (⇧⌘P)",
                 isActive: store.selectedTab?.isPinned == true) {
                if let id = store.selectedTabID { store.togglePin(id) }
            }
            .disabled(store.selectedTab == nil)

            icon("doc.text", id: "reader", help: "Reader mode") {
                store.openReaderMode()
            }
            .disabled(store.selectedTab?.url == nil || store.isLoading)

            icon("sparkles", id: "summary", help: "Summarize page (⇧⌘S)") {
                store.requestSummary()
            }
            .disabled(store.selectedTab == nil || store.settings.summaryEnabled == false)

            icon("bubble.left.and.text.bubble.right", id: "chatgpt-summary",
                 help: "Summarize in ChatGPT") {
                _ = store.summarizeInChatGPT()
            }
            .disabled(store.selectedTab?.url == nil)

            icon("curlybraces", id: "web-inspector",
                 help: inspectorEnabled
                    ? "Disable Web Inspector for this tab"
                    : "Enable Web Inspector for this tab; inspect it in Safari > Develop",
                 isActive: inspectorEnabled) {
                store.toggleWebInspectorForSelectedTab()
            }
            .disabled(store.selectedTab?.url == nil)

            icon(store.selectedTab.map { store.isBlockerEnabled(for: $0) } == true
                 ? "shield.fill" : "shield.slash",
                 id: "blocker",
                 help: store.selectedTab.map { store.isBlockerEnabled(for: $0) } == true
                    ? "Disable blocker for this site" : "Enable blocker for this site",
                 isActive: store.selectedTab.map { store.isBlockerEnabled(for: $0) } == true) {
                store.toggleBlockerForSelectedDomain()
            }
            .disabled(store.selectedTab?.url == nil)

            Spacer(minLength: 8)

            icon("gearshape", id: "settings", help: "Browser settings") {
                store.isSettingsVisible = true
            }
        }
        .frame(width: 48)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func icon(_ symbol: String, id: String, help: String, isActive: Bool = false,
                      animatePress: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: isActive ? .semibold : .medium))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(BrowserRailButtonStyle(theme: store.theme,
                                            isActive: isActive,
                                            isHovered: hovering == id,
                                            animatePress: animatePress))
        .accessibilityLabel(help)
        .help(help)
        .onHover { hovering = $0 ? id : (hovering == id ? nil : hovering) }
    }
}

private struct BrowserRailButtonStyle: ButtonStyle {
    let theme: BrowserUITheme
    let isActive: Bool
    let isHovered: Bool
    let animatePress: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled
                             ? (isActive ? theme.accent : theme.text.opacity(0.82))
                             : theme.subtext.opacity(0.45))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(backgroundColor(isEnabled: isEnabled,
                                          isPressed: configuration.isPressed))
            }
            .overlay {
                if isActive && isEnabled {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.28), lineWidth: 1)
                }
            }
            .scaleEffect(animatePress && configuration.isPressed ? 0.94 : 1)
            .animation(animatePress ? .easeOut(duration: 0.12) : nil,
                       value: configuration.isPressed)
    }

    private func backgroundColor(isEnabled: Bool, isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if isPressed { return theme.accent.opacity(isActive ? 0.24 : 0.16) }
        if isActive { return theme.accent.opacity(0.13) }
        if isHovered { return theme.text.opacity(0.08) }
        return .clear
    }
}

private struct BrowserAddressOverlay: View {
    @Bindable var store: BrowserStore
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: store.selectedTab?.url?.scheme == "https"
                      ? "lock.fill" : "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.theme.text)

                TextField("Search or enter address", text: $store.addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(store.theme.text)
                    .focused($isAddressFocused)
                    .onSubmit { store.navigate(store.addressText) }
                    .onExitCommand { dismiss() }
                    .onChange(of: store.addressFocusToken) { _, _ in
                        isAddressFocused = true
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                    .onChange(of: store.addressText) { _, _ in
                        store.resetAddressSelection()
                    }
                    .onKeyPress { press in
                        let modifiers = press.modifiers.subtracting(.numericPad)
                        guard modifiers.isEmpty, !store.addressSuggestions.isEmpty else { return .ignored }
                        switch press.key {
                        case .downArrow:
                            store.moveAddressSelection(by: 1)
                            return .handled
                        case .upArrow:
                            store.moveAddressSelection(by: -1)
                            return .handled
                        case .return:
                            return store.acceptAddressSelection() ? .handled : .ignored
                        default:
                            return .ignored
                        }
                    }

                Button {
                    store.toggleBlockerForSelectedDomain()
                } label: {
                    Image(systemName: (store.selectedTab.map { store.isBlockerEnabled(for: $0) } ?? false)
                          ? "shield.fill" : "shield.slash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help((store.selectedTab.map { store.isBlockerEnabled(for: $0) } ?? false)
                      ? "Disable blocker for this site" : "Enable blocker for this site")
            }
            .padding(.horizontal, 12)
            .frame(height: 46)

            if !store.addressSuggestions.isEmpty {
                Divider().overlay(store.theme.text.opacity(0.18))
                VStack(spacing: 0) {
                    ForEach(Array(store.addressSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button {
                            store.acceptAddressSuggestion(at: index)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: suggestion.systemImage)
                                    .font(.system(size: 10))
                                    .foregroundStyle(store.theme.subtext)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(suggestion.detail)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(store.theme.subtext)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(index == store.addressSelectionIndex
                                          ? store.theme.accent.opacity(0.24) : Color.clear)
                            }
                            .overlay {
                                if index == store.addressSelectionIndex {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(store.theme.accent.opacity(0.58), lineWidth: 1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(store.theme.text.opacity(0.14))
                    }
                }
            }

            HStack(spacing: 12) {
                Text(store.addressRequiresNavigation
                     ? "Enter an address or search · Return opens · ⌘Return new tab"
                     : "⌘L opens · ↑↓ choose · Return opens · ⌘Return new tab · Esc closes")
                    .font(.system(size: 10))
                    .foregroundStyle(store.theme.subtext)
                Spacer()
                if let host = store.selectedTab?.url?.host {
                    Text(host)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(store.theme.subtext)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: 640)
        .background(store.theme.surface.opacity(0.98),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .padding(.top, 12)
        .onAppear {
            isAddressFocused = true
        }
        .onExitCommand { dismiss() }
    }

    private func dismiss() {
        guard !store.addressRequiresNavigation else { return }
        store.hideAddress()
        DispatchQueue.main.async {
            if let webView = store.selectedSession?.webView {
                NSApp.keyWindow?.makeFirstResponder(webView)
            }
        }
    }
}

private struct BrowserTabRow: View {
    @Bindable var store: BrowserStore
    let tab: BrowserTab
    @State private var hovering = false

    private var compact: Bool { store.settings.compactTabs }
    private var selected: Bool { store.selectedTabID == tab.id }
    private var color: Color {
        let value = store.fallbackColor(for: tab)
        return Color(red: value.red, green: value.green, blue: value.blue)
    }

    var body: some View {
        HStack(spacing: compact ? 0 : 7) {
            favicon

            if compact == false {
                Text(tab.displayTitle)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? store.theme.text : store.theme.subtext)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(store.theme.subtext.opacity(0.75))
                }

                if store.isPrivateTab(tab.id) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(store.theme.subtext)
                        .help("Private session")
                }

                Text(BrowserTimeLabel.string(since: tab.lastUsed, now: store.now))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(store.theme.subtext.opacity(0.75))
                    .lineLimit(1)

                if hovering || selected {
                    Button {
                        store.close(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }
            }
        }
        .padding(.leading, compact ? 0 : 7)
        .padding(.trailing, compact ? 0 : 6)
        .frame(width: compact ? 34 : nil, height: compact ? 34 : 38)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(selected ? 0.20 : (hovering ? 0.13 : 0.08)))
        }
        .contentShape(Rectangle())
        .help(tab.displayTitle)
        .onTapGesture { store.select(tab.id) }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var favicon: some View {
        if let image = store.faviconImage(for: tab) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.8))
                Text(String(tab.displayTitle.prefix(1)).uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 15, height: 15)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
        Button("Reload") {
            store.select(tab.id)
            store.reload()
        }
        Button("Copy URL") {
            store.copyURL(for: tab.id)
        }
        .disabled(tab.url == nil)
        Button("Clear Website Data…") { store.requestSiteDataClear(for: tab.id) }
            .disabled(tab.url?.host == nil)
        Divider()
        Button(store.isBlockerEnabled(for: tab) ? "Disable Blocker for This Site" : "Enable Blocker for This Site") {
            store.select(tab.id)
            store.toggleBlockerForSelectedDomain()
        }
        .disabled(tab.url == nil)
        Button(store.isBlockerEnabled(for: tab) ? "Disable Blocker for This Tab" : "Enable Blocker for This Tab") {
            store.select(tab.id)
            store.toggleBlockerForSelectedTab()
        }
        Divider()
        Button("Summarize Page") {
            store.select(tab.id)
            store.requestSummary()
        }
        .disabled(store.settings.summaryEnabled == false)
        Divider()
        Button("Close Tab") { store.close(tab.id) }
    }

    private var accessibilityLabel: String {
        var parts = [tab.displayTitle]
        if let host = tab.url?.host { parts.append(host) }
        parts.append("last used \(BrowserTimeLabel.string(since: tab.lastUsed, now: store.now))")
        if tab.isPinned { parts.append("pinned") }
        if store.isPrivateTab(tab.id) { parts.append("private session") }
        if !store.isBlockerEnabled(for: tab) { parts.append("blocker off") }
        return parts.joined(separator: ", ")
    }
}

private struct BrowserContent: View {
    @Bindable var store: BrowserStore

    var body: some View {
        ZStack(alignment: .top) {
            let _ = store.sessionRevision
            webContent
            if store.isReaderVisible {
                BrowserReaderPanel(store: store)
                    .zIndex(2)
            }
            if store.isAddressVisible {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissAddress() }
                BrowserAddressOverlay(store: store)
            }
            if store.summaryTabID != nil, store.summary != .idle {
                HStack {
                    Spacer()
                    BrowserSummaryPanel(store: store)
                        .padding(12)
                }
            }
            if store.isFindVisible {
                BrowserFindOverlay(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
                    .zIndex(3)
            }
            if let message = store.noticeText {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    }
                    .accessibilityLabel("URL copied to clipboard")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(12)
                    .allowsHitTesting(false)
            }
            if let message = store.errorText {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 11.5))
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Button {
                        store.dismissNavigationError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss error")
                }
                .padding(10)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.theme.pageBackground)
    }

    private func dismissAddress() {
        guard !store.addressRequiresNavigation else { return }
        store.hideAddress()
        DispatchQueue.main.async {
            if let webView = store.selectedSession?.webView {
                NSApp.keyWindow?.makeFirstResponder(webView)
            }
        }
    }

    @ViewBuilder
    private var webContent: some View {
        if let session = store.selectedSession {
            BrowserWebViewContainer(webView: session.webView)
                .id(ObjectIdentifier(session))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isStarted {
            store.theme.pageBackground
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Preparing browser…")
                    .font(.caption)
                    .foregroundStyle(store.theme.subtext)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BrowserFindOverlay: View {
    @Bindable var store: BrowserStore
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find in Page", text: $store.findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($isFocused)
                .onSubmit { store.findInPage() }
                .onExitCommand { store.hideFind() }
                .onChange(of: store.findText) { _, _ in
                    store.findInPage()
                }

            if store.isFindSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44)
            } else if let matchCount = store.findMatchCount, matchCount > 0 {
                Text(matchCount == 1 ? "1 match" : "\(matchCount) matches")
                    .font(.system(size: 11))
                    .foregroundStyle(store.theme.subtext)
                    .frame(width: 72, alignment: .leading)
            } else if store.findMatchFound == true {
                Text("Match found")
                    .font(.system(size: 11))
                    .foregroundStyle(store.theme.subtext)
                    .frame(width: 72, alignment: .leading)
            } else if store.findMatchFound == false {
                Text("No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(store.theme.subtext)
                    .frame(width: 72, alignment: .leading)
            } else {
                Color.clear.frame(width: 72, height: 1)
            }

            Button {
                store.findInPage(backwards: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("Find Previous")
            .accessibilityLabel("Find Previous")
            .disabled(store.findText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                store.findInPage()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Find Next")
            .accessibilityLabel("Find Next")
            .disabled(store.findText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                store.hideFind()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close Find")
            .accessibilityLabel("Close Find")
        }
        .padding(10)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .fixedSize()
        .onAppear { isFocused = true }
    }
}

private struct BrowserWebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct BrowserReaderPanel: View {
    @Bindable var store: BrowserStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Reader", systemImage: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("A−") { store.changeReaderTextSize(by: -1) }
                    .help("Decrease text size")
                Button("A+") { store.changeReaderTextSize(by: 1) }
                    .help("Increase text size")
                Button("Summarize") {
                    store.closeReaderMode()
                    store.requestSummary()
                }
                Button {
                    store.closeReaderMode()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close reader")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .frame(height: 48)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let page = store.readerPage {
                        if !page.title.isEmpty {
                            Text(page.title)
                                .font(.system(size: 31, weight: .bold, design: .serif))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let url = page.url {
                            Text(url.host ?? url.absoluteString)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text(page.text)
                            .font(.system(size: store.readerTextSize, design: .serif))
                            .lineSpacing(8)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let error = store.readerError {
                        ContentUnavailableView("Reader mode unavailable",
                                               systemImage: "doc.text.magnifyingglass",
                                               description: Text(error))
                    } else {
                        ProgressView("Preparing article…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct BrowserSettingsView: View {
    @Bindable var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BrowserSettings
    @State private var defaultBrowserMessage: String?
    @State private var settingDefaultBrowser = false

    init(store: BrowserStore) {
        self.store = store
        _draft = State(initialValue: store.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MakiDesk Browser")
                .font(.system(size: 15, weight: .semibold))

            Form {
                TextField("Default page", text: $draft.defaultPageURL,
                          prompt: Text("https://www.google.com"))
                Picker("Search engine", selection: $draft.searchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Toggle("Block ads and trackers by default",
                       isOn: $draft.blockerEnabledByDefault)
                Toggle("On-device page summaries",
                       isOn: $draft.summaryEnabled)
                Toggle("Allow Safari Web Inspector",
                       isOn: $draft.webInspectorEnabled)
                Button("Set MakiDesk Browser as default") {
                    settingDefaultBrowser = true
                    Task {
                        do {
                            try await store.requestAsDefaultBrowser()
                            defaultBrowserMessage = "Default browser updated in macOS settings."
                        } catch {
                            defaultBrowserMessage = "Could not set the default browser: \(error.localizedDescription)"
                        }
                        settingDefaultBrowser = false
                    }
                }
                .disabled(settingDefaultBrowser)
                if let defaultBrowserMessage {
                    Text(defaultBrowserMessage).font(.caption).foregroundStyle(store.theme.subtext)
                }
            }
            .formStyle(.grouped)

            Text("The default page is prefilled in the address bar when a new tab opens; it is not loaded automatically.")
                .font(.system(size: 10.5))
                .foregroundStyle(store.theme.subtext)
            Text("When enabled, inspect this browser from Safari ▸ Develop ▸ MakiDesk Browser.")
                .font(.system(size: 10.5))
                .foregroundStyle(store.theme.subtext)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    store.updateSettings(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

private struct BrowserSummaryPanel: View {
    @Bindable var store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Page summary", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("ON-DEVICE")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(store.theme.subtext)
                Button("Open in ChatGPT") {
                    _ = store.summarizeInChatGPT()
                }
                .font(.system(size: 10))
                Button {
                    store.cancelSummary()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
            }

            switch store.summary {
            case .idle:
                EmptyView()
            case .extracting:
                progress("Reading the page…")
            case .loading:
                progress("Asking the on-device model…")
            case .streaming(let text), .ready(let text):
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("Regenerate") { store.requestSummary() }
                    Spacer()
                    if store.summary.isBusy {
                        Button("Stop") { store.cancelSummary() }
                    }
                }
                .controlSize(.small)
            case .unavailable(let message), .failed(let message):
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(store.theme.subtext)
                Button("Close") { store.cancelSummary() }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.system(size: 11.5)).foregroundStyle(store.theme.subtext)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
