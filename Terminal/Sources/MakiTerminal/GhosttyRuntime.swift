import AppKit
import GhosttyKit

/// Owns the single Ghostty app and the surface callbacks (F0).
///
/// The real terminal helper will keep one runtime for its lifetime and many
/// surfaces; the spike keeps one surface so the keyboard, IME and rendering
/// path can be judged without the workspace model in the way.
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?
    /// The spike's only surface, needed by the clipboard callbacks.
    var surface: ghostty_surface_t?

    private var tickScheduled = false
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

    init() throws {
        GhosttyRuntime.shared = self
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == 0 else { throw RuntimeError.initialization(status) }

        guard let config = ghostty_config_new() else { throw RuntimeError.configuration }
        let text = Self.spikeConfig
        text.withCString { pointer in
            ghostty_config_load_string(config, pointer, UInt(text.utf8.count), "makidesk-terminal")
        }
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
            runtime.scheduleTick()
        }
        runtime.action_cb = { _, _, action in
            GhosttyRuntime.shared?.handle(action) ?? false
        }
        runtime.read_clipboard_cb = { _, _, state in
            guard let runtime = GhosttyRuntime.shared,
                  let surface = runtime.surface,
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
                  let surface = runtime.surface,
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
        runtime.close_surface_cb = { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }

        guard let app = ghostty_app_new(&runtime, config) else { throw RuntimeError.application }
        self.app = app
    }

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

    private func handle(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title else { return true }
            let text = String(cString: title)
            DispatchQueue.main.async {
                (NSApp.keyWindow ?? NSApp.windows.first)?.title = text
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
        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        default:
            return false
        }
    }

    // MARK: - Spike appearance

    /// MakiDesk's Mocha palette mapped to a Ghostty config. The real helper
    /// will generate this from `terminal-theme.json`; the ANSI palette here is
    /// a placeholder, because `PaletteTheme` has no ANSI colours yet.
    private static let spikeConfig = """
    background = #1E1E2E
    foreground = #CDD6F4
    cursor-color = #CBA6F7
    cursor-text = #1E1E2E
    selection-background = #585B70
    selection-foreground = #CDD6F4
    font-family = SF Mono
    font-size = 13
    macos-option-as-alt = true
    window-padding-x = 8
    window-padding-y = 8
    confirm-close-surface = false
    palette = 0=#45475A
    palette = 1=#F38BA8
    palette = 2=#A6E3A1
    palette = 3=#F9E2AF
    palette = 4=#89B4FA
    palette = 5=#F5C2E7
    palette = 6=#94E2D5
    palette = 7=#BAC2DE
    palette = 8=#585B70
    palette = 9=#F38BA8
    palette = 10=#A6E3A1
    palette = 11=#F9E2AF
    palette = 12=#89B4FA
    palette = 13=#F5C2E7
    palette = 14=#94E2D5
    palette = 15=#A6ADC8
    """
}
