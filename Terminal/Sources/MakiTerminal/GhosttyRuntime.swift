import AppKit
import GhosttyKit
import MakiShared

/// Owns the Ghostty app and the surface callbacks (F1).
///
/// One runtime per helper process; any number of surfaces. The runtime knows
/// which surface has the keyboard (for clipboards) and forwards title, cwd and
/// close events to the window controller, which owns the workspace model.
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?

    /// The surface that owns the keyboard. Clipboard read/write callbacks have
    /// no surface argument, so the focused one answers them.
    var focusedSurface: ghostty_surface_t?

    /// The surface config userdata is the hosting view, so the close callback
    /// can name the pane that exited. Called on the main queue.
    var onSurfaceClosed: ((TerminalSurfaceView) -> Void)?
    /// Title and directory actions carry the surface target; the controller
    /// turns them into workspace titles and restore directories.
    var onTitle: ((TerminalSurfaceView, String) -> Void)?
    var onDirectory: ((TerminalSurfaceView, String) -> Void)?

    private var tickScheduled = false
    private var settings: TerminalSettingsDocument
    private var theme: TerminalThemeDocument
    private var config: ghostty_config_t?
    /// Reloads are rare; keeping the old config alive is cheaper than risking a
    /// surface that still points at it.
    private var retiredConfigs: [ghostty_config_t] = []
    /// Filled by the window controller, so a reload can refresh every surface.
    var liveSurfaces: () -> [ghostty_surface_t] = { [] }
    private static weak var shared: GhosttyRuntime?

    enum RuntimeError: Error, LocalizedError {
        case initialization(Int32)
        case configuration
        case application

        var errorDescription: String? {
            switch self {
            case let .initialization(code):
                return "ghostty_init failed with code \(code)"
            case .configuration:
                return "Ghostty could not create a configuration"
            case .application:
                return "Ghostty could not create the application"
            }
        }
    }

    init(settings: TerminalSettingsDocument, theme: TerminalThemeDocument) throws {
        self.settings = settings
        self.theme = theme
        GhosttyRuntime.shared = self
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == 0 else { throw RuntimeError.initialization(status) }

        guard let config = Self.makeConfig(settings: settings, theme: theme) else {
            throw RuntimeError.configuration
        }
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
            runtime.scheduleTick()
        }
        runtime.action_cb = { _, target, action in
            GhosttyRuntime.shared?.handle(target: target, action: action) ?? false
        }
        runtime.read_clipboard_cb = { _, _, state in
            guard let runtime = GhosttyRuntime.shared,
                  let surface = runtime.focusedSurface,
                  let text = NSPasteboard.general.string(forType: .string) else { return false }
            DispatchQueue.main.async {
                text.withCString {
                    ghostty_surface_complete_clipboard_request(surface, $0, state, true)
                }
            }
            return true
        }
        runtime.confirm_read_clipboard_cb = { _, content, state, _ in
            guard let runtime = GhosttyRuntime.shared,
                  let surface = runtime.focusedSurface,
                  let content else { return }
            DispatchQueue.main.async {
                ghostty_surface_complete_clipboard_request(surface, content, state, true)
            }
        }
        runtime.write_clipboard_cb = { _, _, contents, count, _ in
            guard let contents, count > 0, let raw = contents[0].data else { return }
            let text = String(cString: raw)
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                GhosttyRuntime.shared?.onSurfaceClosed?(view)
            }
        }

        guard let app = ghostty_app_new(&runtime, config) else { throw RuntimeError.application }
        self.app = app
    }

    /// Re-reads the two shared documents and applies them to the app config.
    /// Existing surfaces get the new font and colours; new surfaces also get
    /// the shell command.
    func apply(settings: TerminalSettingsDocument, theme: TerminalThemeDocument) {
        self.settings = settings
        self.theme = theme
        guard let app, let newConfig = Self.makeConfig(settings: settings, theme: theme) else {
            return
        }
        ghostty_app_update_config(app, newConfig)
        if let config {
            retiredConfigs.append(config)
        }
        config = newConfig
        for surface in liveSurfaces() {
            ghostty_surface_refresh(surface)
        }
    }

    var shellCommand: String? { settings.shell }

    func scheduleTick() {
        guard tickScheduled == false else { return }
        tickScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            if let app = self.app { ghostty_app_tick(app) }
        }
    }

    // MARK: - Actions

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view = targetView(target)
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title else { return true }
            let text = String(cString: title)
            if let view {
                DispatchQueue.main.async {
                    GhosttyRuntime.shared?.onTitle?(view, text)
                }
            } else {
                DispatchQueue.main.async {
                    (NSApp.keyWindow ?? NSApp.windows.first)?.title = text
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let view, let path = action.action.pwd.pwd else { return true }
            let directory = String(cString: path)
            DispatchQueue.main.async {
                GhosttyRuntime.shared?.onDirectory?(view, directory)
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            NSSound.beep()
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let source = action.action.open_url
            guard let pointer = source.url else { return true }
            let data = Data(bytes: pointer, count: Int(source.len))
            guard let url = URL(string: String(decoding: data, as: UTF8.self)) else { return true }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true
        case GHOSTTY_ACTION_CLOSE_TAB:
            guard let view else { return false }
            DispatchQueue.main.async {
                GhosttyRuntime.shared?.onSurfaceClosed?(view)
            }
            return true
        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        default:
            return false
        }
    }

    private func targetView(_ target: ghostty_target_s) -> TerminalSurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        let surface = target.target.surface
        guard let userdata = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata)
            .takeUnretainedValue()
    }

    // MARK: - Configuration

    private static func makeConfig(settings: TerminalSettingsDocument,
                                   theme: TerminalThemeDocument) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        let text = configurationText(settings: settings, theme: theme)
        text.withCString { pointer in
            ghostty_config_load_string(config, pointer, UInt(text.utf8.count),
                                       "makidesk-terminal")
        }
        ghostty_config_finalize(config)
        return config
    }

    private static func configurationText(settings: TerminalSettingsDocument,
                                          theme: TerminalThemeDocument) -> String {
        let family = settings.fontFamily ?? "SF Mono"
        var lines = [
            "background = \(theme.background)",
            "foreground = \(theme.foreground)",
            "cursor-color = \(theme.cursor)",
            "cursor-text = \(theme.background)",
            "selection-background = \(theme.selectionBackground)",
            "selection-foreground = \(theme.selectionForeground)",
            "font-family = \(family)",
            "font-size = \(settings.fontSize)",
            "macos-option-as-alt = true",
            "window-padding-x = 8",
            "window-padding-y = 8",
            "confirm-close-surface = false",
        ]
        for (index, colour) in theme.ansi.enumerated() {
            lines.append("palette = \(index)=\(colour)")
        }
        return lines.joined(separator: "\n")
    }
}
