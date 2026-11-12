import AppKit
import SwiftUI
import WebKit

struct BrowserRootView: View {
    @Bindable var store: BrowserStore

    var body: some View {
        HSplitView {
            BrowserSidebar(store: store)
                .frame(minWidth: store.settings.compactTabs ? 90 : 240,
                       idealWidth: store.settings.compactTabs ? 90 : CGFloat(store.sidebarWidth),
                       maxWidth: store.settings.compactTabs ? 90 : 480)
            BrowserContent(store: store)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 32)
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea()
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $store.isSettingsVisible) {
            BrowserSettingsView(store: store)
        }
        .sheet(isPresented: $store.isCredentialsVisible) {
            BrowserCredentialsView(store: store)
        }
        .onChange(of: store.windowTitle) { _, title in
            if let window = NSApp.keyWindow,
               window.windowController is BrowserWindowController {
                window.title = title
            }
        }
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(.regularMaterial)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { store.sidebarWidth = Double(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in
                        store.sidebarWidth = Double(width)
                    }
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
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, phase == .pinned ? 2 : 12)
                .padding(.bottom, 3)
            }

            ForEach(tabs) { tab in
                BrowserTabRow(store: store, tab: tab,
                              compact: store.settings.compactTabs)
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

    var body: some View {
        VStack(spacing: 5) {
            Color.clear.frame(height: 28)

            icon(store.settings.compactTabs ? "sidebar.left" : "rectangle.compress.vertical",
                 id: "compact", help: "Compact tab column") {
                store.toggleCompactTabs()
            }

            icon("chevron.left", id: "back", help: "Back") { store.goBack() }
                .disabled(store.canGoBack == false)
            icon("chevron.right", id: "forward", help: "Forward") { store.goForward() }
                .disabled(store.canGoForward == false)
            icon(store.isLoading ? "xmark" : "arrow.clockwise",
                 id: "reload", help: store.isLoading ? "Stop" : "Reload") {
                store.isLoading ? store.stopLoading() : store.reload()
            }
            icon("link", id: "address", help: "Address (⌘L)") { store.showAddress() }
            icon("plus", id: "new", help: "New Tab (⌘T)") { store.newTab() }

            Divider().frame(width: 20).padding(.vertical, 3)

            icon(store.selectedTab?.isPinned == true ? "pin.fill" : "pin",
                 id: "pin", help: "Pin / unpin tab (⇧⌘P)") {
                if let id = store.selectedTabID { store.togglePin(id) }
            }
            .disabled(store.selectedTab == nil)

            icon("sparkles", id: "summary", help: "Summarize page (⇧⌘S)") {
                store.requestSummary()
            }
            .disabled(store.selectedTab == nil || store.settings.summaryEnabled == false)

            icon("shield.slash", id: "blocker", help: "Toggle blocker for this site") {
                store.toggleBlockerForSelectedDomain()
            }
            .disabled(store.selectedTab?.url == nil)

            Spacer(minLength: 8)

            icon("key.fill", id: "passwords", help: "Passwords from Keychain") {
                store.isCredentialsVisible = true
            }
            .disabled(store.selectedTab?.url == nil)

            icon("gearshape", id: "settings", help: "Browser settings") {
                store.isSettingsVisible = true
            }
        }
        .frame(width: 42)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func icon(_ symbol: String, id: String, help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering == id ? Color.primary.opacity(0.08) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 ? id : (hovering == id ? nil : hovering) }
    }
}

private enum AddressFocus: Hashable {
    case textField
    case suggestion(index: Int)
}

private struct BrowserAddressOverlay: View {
    @Bindable var store: BrowserStore
    @FocusState private var focus: AddressFocus?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: store.selectedTab?.url?.scheme == "https"
                      ? "lock.fill" : "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search or enter address", text: $store.addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focus, equals: .textField)
                    .onSubmit { store.navigate(store.addressText) }
                    .onExitCommand { dismiss() }
                    .onChange(of: store.addressFocusToken) { _, _ in
                        focus = .textField
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                    .onChange(of: store.addressText) { _, _ in
                        store.resetAddressSelection()
                    }
                    .onKeyPress { press in
                        if press.key == .downArrow, !store.addressSuggestions.isEmpty {
                            store.addressSelectionIndex = 0
                            focus = .suggestion(index: 0)
                            return .handled
                        }
                        return .ignored
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
                Divider().opacity(0.4)
                VStack(spacing: 0) {
                    ForEach(Array(store.addressSuggestions.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            store.navigate(to: entry.url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title.isEmpty ? entry.url.host ?? entry.url.absoluteString : entry.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(entry.url.absoluteString)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(index == store.addressSelectionIndex
                                        ? Color.accentColor.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focus, equals: .suggestion(index: index))
                        .onKeyPress { press in
                            handleKeyPress(press, index: index, count: store.addressSuggestions.count)
                        }
                        Divider().opacity(0.35)
                    }
                }
            }

            HStack(spacing: 12) {
                Text("⌘L opens · ↑↓ choose · Esc closes · Return navigates")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let host = store.selectedTab?.url?.host {
                    Text(host)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: 640)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .padding(.top, 12)
        .onAppear {
            focus = .textField
        }
        .onExitCommand { dismiss() }
    }

    private func handleKeyPress(_ press: KeyPress, index: Int, count: Int) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            if index == 0 {
                focus = .textField
            } else {
                store.moveAddressSelection(by: -1)
                focus = .suggestion(index: index - 1)
            }
            return .handled
        case .downArrow:
            if index < count - 1 {
                store.moveAddressSelection(by: 1)
                focus = .suggestion(index: index + 1)
            }
            return .handled
        case .return:
            if store.acceptAddressSelection() { return .handled }
            return .ignored
        default:
            focus = .textField
            return .ignored
        }
    }

    private func dismiss() {
        store.hideAddress()
        DispatchQueue.main.async {
            if let webView = store.selectedSession?.webView {
                NSApp.keyWindow?.makeFirstResponder(webView)
            }
        }
    }
}

private struct BrowserTabRow: View {
    let store: BrowserStore
    let tab: BrowserTab
    var compact = false
    @State private var hovering = false

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
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Text(BrowserTimeLabel.string(since: tab.lastUsed, now: store.now))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
            } else if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, compact ? 0 : 7)
        .padding(.trailing, compact ? 0 : 6)
        .frame(width: compact ? 28 : nil, height: compact ? 28 : 38)
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
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .disabled(tab.url == nil)
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
            if store.isAddressVisible {
                Color.clear
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func dismissAddress() {
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
                .id(session.tabID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isStarted {
            Color(nsColor: .textBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Preparing browser…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BrowserWebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct BrowserSettingsView: View {
    @Bindable var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BrowserSettings

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
            }
            .formStyle(.grouped)

            Text("The default page is prefilled in the address bar when a new tab opens; it is not loaded automatically.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

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

private struct BrowserCredentialsView: View {
    @Bindable var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var credentials: [BrowserCredential] = []

    private var domain: String? {
        store.selectedTab?.url.flatMap(BrowserDomain.registrableDomain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Passwords")
                .font(.system(size: 15, weight: .semibold))

            if let domain {
                Text(domain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                if credentials.isEmpty {
                    Text("No saved password for this site.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(credentials) { credential in
                            HStack {
                                Text(credential.username)
                                    .lineLimit(1)
                                Spacer()
                                Button("Fill") {
                                    store.fillCredential(credential)
                                    dismiss()
                                }
                                .controlSize(.small)
                                Button("Delete", role: .destructive) {
                                    store.deleteCredential(credential)
                                    reload()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .frame(height: 130)
                }

                Divider()

                Text("Add a password")
                    .font(.system(size: 12, weight: .semibold))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                HStack {
                    Spacer()
                    Button("Save") {
                        store.saveCredential(username: username, password: password)
                        username = ""
                        password = ""
                        reload()
                    }
                    .disabled(username.isEmpty || password.isEmpty)
                }
            } else {
                Text("Open a website before using saved passwords.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Text("Stored as Internet Password items in the login Keychain. Safari's own saved passwords are not accessible to this app.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { reload() }
    }

    private func reload() {
        credentials = store.credentialsForCurrentDomain()
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
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
