import AppKit
import Darwin
import SwiftUI

/// The Ports window (U4): the listening TCP sockets, who holds them, and a
/// deliberate Terminate. It reads on show and on Refresh and never polls.
@MainActor
final class PortsWindowController {
    static let shared = PortsWindowController()

    private var window: NSWindow?
    private var themeObserver: NSObjectProtocol?
    private let model = ListeningPortsModel()

    private init() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: .makiDeskThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.backgroundColor = NSColor(WorkspaceStore.shared.theme.background)
            }
        }
    }

    func show() {
        if window == nil { build() }
        model.refresh()
        if let window, window.isVisible == false {
            UtilityWindowPlacement.placeOnFocusedScreen(window)
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let theme = WorkspaceStore.shared.theme
        let hosting = NSHostingController(rootView: PortsView(
            model: model,
            store: WorkspaceStore.shared,
            onRefresh: { [weak self] in self?.model.refresh() },
            onTerminate: { [weak self] port in self?.terminate(port) }
        ))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ports"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(theme.background)
        window.isOpaque = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 640, height: 480))
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if window.setFrameAutosaveName("MakiDeskPorts") == false {
            window.center()
        }
        self.window = window
    }

    /// A process can hold several listening ports and the list can be stale:
    /// the confirmation names the process, its pid and the port, so the action
    /// is never one click away from the wrong target.
    private func terminate(_ port: ListeningPort) {
        let confirmation = Confirmation(
            title: "Terminate \(port.name)?",
            message: "\(port.name) (pid \(port.pid)) is listening on port \(port.port). Unsaved work may be lost.",
            confirm: "Terminate",
            cancel: "Cancel",
            style: .warning
        )
        guard confirmation.ask() else { return }

        if kill(port.pid, SIGTERM) == 0 {
            HUDController.shared.show(HUDMessage.portTerminated(name: port.name, pid: port.pid))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.model.refresh()
            }
        } else {
            let reason = String(cString: strerror(errno))
            HUDController.shared.show(HUDMessage.portTerminateFailed(reason: reason))
        }
    }
}

// MARK: - View

struct PortsView: View {
    @Bindable var model: ListeningPortsModel
    @Bindable var store: WorkspaceStore
    let onRefresh: () -> Void
    let onTerminate: (ListeningPort) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var theme: PaletteTheme { store.theme }
    private var filtered: [ListeningPort] {
        model.ports.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Rectangle()
                .fill(theme.border.opacity(0.55))
                .frame(height: 1)
            content
            Rectangle()
                .fill(theme.border.opacity(0.55))
                .frame(height: 1)
            footer
        }
        .background(theme.background)
        .onAppear {
            searchFocused = true
            if model.ports.isEmpty { onRefresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)
            Text("Ports")
                .font(MakiType.title)
                .foregroundStyle(theme.text)
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.mini)
            }
            Text(model.ports.count == 1 ? "1 listening" : "\(model.ports.count) listening")
                .font(MakiType.meta)
                .foregroundStyle(theme.subtext)
            Button("Refresh") { onRefresh() }
                .buttonStyle(.plain)
                .font(MakiType.metaMedium)
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.surface))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(theme.raisedSurface.opacity(0.35))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.subtext)
            TextField("Filter ports, processes, pids or addresses", text: $query)
                .textFieldStyle(.plain)
                .font(MakiType.content)
                .foregroundStyle(theme.text)
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .makiField(theme: theme, focused: searchFocused)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.ports.isEmpty {
            status("Reading listening ports…")
        } else if let failure = model.failure, model.ports.isEmpty {
            status(failure.message, color: Color(nsColor: .systemRed))
        } else if filtered.isEmpty {
            status(model.ports.isEmpty ? "No listening TCP ports."
                                       : "No port matches “\(query)”.")
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { port in
                        row(port)
                    }
                }
                .padding(12)
            }
        }
    }

    private func row(_ port: ListeningPort) -> some View {
        HStack(spacing: 12) {
            Text("\(port.port)")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.accent)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(port.name)
                    .font(MakiType.contentMedium)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("pid \(port.pid) · \(port.addresses.joined(separator: ", "))")
                    .font(MakiType.meta.monospaced())
                    .foregroundStyle(theme.subtext)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Terminate") { onTerminate(port) }
                .buttonStyle(.plain)
                .font(MakiType.metaStrong)
                .foregroundStyle(Color(nsColor: .systemRed))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.surface))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.raisedSurface))
    }

    private func status(_ text: String, color: Color? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "network.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(theme.subtext)
            Text(text)
                .font(MakiType.caption)
                .foregroundStyle(color ?? theme.subtext)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let failure = model.failure {
                Text(failure.message)
                    .foregroundStyle(Color(nsColor: .systemRed))
            } else {
                Text("SIGTERM · no sudo")
            }
            Spacer()
            Text("Reads lsof only while this window is open")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(theme.subtext.opacity(0.8))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
