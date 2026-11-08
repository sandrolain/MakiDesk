import AppKit
import Carbon.HIToolbox
import GhosttyKit
import MakiTerminalCore
import QuartzCore

/// One Ghostty surface hosted in an AppKit view (F0).
///
/// It exists to answer one question: can libghostty render a real shell and
/// take keyboard, IME and pointer input without a large host layer? The
/// workspace and split model live above this in the real helper.
final class TerminalSurfaceView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private weak var runtime: GhosttyRuntime?
    var paneID: PaneID?
    var onFocus: (() -> Void)?
    /// Set by the pane host before the surface is created; restore uses it to
    /// start the shell in the directory it had.
    var workingDirectory: String?
    /// Empty or nil uses the login shell; otherwise this command runs instead.
    var shellCommand: String?
    /// Extra variables for the child shell, such as the workspace identity.
    var environment: [String: String] = [:]
    /// The needle of the last find session in this pane, so reopening the bar
    /// starts from it instead of empty.
    var lastSearchNeedle = ""
    private var isDetached = false

    private var markedText = NSMutableAttributedString()
    private var trackingArea: NSTrackingArea?

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        fatalError("not used by the spike")
    }

    override func makeBackingLayer() -> CALayer {
        let metal = CAMetalLayer()
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = false
        return metal
    }

    deinit {
        // The delegate detaches explicitly; this is the last line of defence.
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    func attach(runtime: GhosttyRuntime) {
        self.runtime = runtime
        guard surface == nil, window != nil, let app = runtime.app else { return }
        createSurface(app: app)
    }

    func detach() {
        guard isDetached == false else { return }
        isDetached = true
        guard let surface else { return }
        ghostty_surface_set_focus(surface, false)
        ghostty_surface_free(surface)
        if runtime?.focusedSurface == surface {
            runtime?.focusedSurface = nil
        }
        self.surface = nil
    }

    private func createSurface(app: ghostty_app_t) {
        let scale = window?.backingScaleFactor ?? 2
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = scale
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        // The spike normally uses the user's login shell. The clean-shell
        // switch exists so a bundled run can be tested without the user's rc
        // files asking for Downloads or network access.
        var commandStorage: UnsafeMutablePointer<CChar>?
        if ProcessInfo.processInfo.environment["MAKIDESK_SPIKE_CLEAN_SHELL"] == "1" {
            commandStorage = strdup("/bin/zsh --no-rcs")
            config.command = commandStorage.map { UnsafePointer($0) }
        } else if let shellCommand, shellCommand.isEmpty == false {
            commandStorage = strdup(shellCommand)
            config.command = commandStorage.map { UnsafePointer($0) }
        }
        defer { free(commandStorage) }
        var envStorage: [(key: UnsafeMutablePointer<CChar>, value: UnsafeMutablePointer<CChar>)] = []
        var envArray: UnsafeMutablePointer<ghostty_env_var_s>?
        if environment.isEmpty == false {
            envArray = .allocate(capacity: environment.count)
            for (index, entry) in environment.enumerated() {
                guard let key = strdup(entry.key), let value = strdup(entry.value) else {
                    continue
                }
                envStorage.append((key: key, value: value))
                envArray?[index] = ghostty_env_var_s(
                    key: UnsafePointer(key),
                    value: UnsafePointer(value)
                )
            }
            config.env_vars = envArray
            config.env_var_count = envStorage.count
        }
        defer {
            for entry in envStorage {
                free(entry.key)
                free(entry.value)
            }
            envArray?.deallocate()
        }

        var directoryStorage: UnsafeMutablePointer<CChar>?
        if let workingDirectory, workingDirectory.isEmpty == false {
            directoryStorage = strdup(workingDirectory)
            config.working_directory = directoryStorage.map { UnsafePointer($0) }
        }
        defer { free(directoryStorage) }

        guard let created = ghostty_surface_new(app, &config) else {
            NSLog("MakiTerminal: ghostty_surface_new returned nil")
            return
        }
        surface = created
        if runtime?.focusedSurface == nil {
            runtime?.focusedSurface = created
        }
        ghostty_surface_set_content_scale(created, scale, scale)
        updateSurfaceSize()
    }

    // MARK: - Geometry

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let runtime {
            attach(runtime: runtime)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        let width = UInt32(max(1, (bounds.width * scale).rounded()))
        let height = UInt32(max(1, (bounds.height * scale).rounded()))
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, width, height)
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, true)
            runtime?.focusedSurface = surface
            onFocus?()
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, false)
            if runtime?.focusedSurface == surface {
                runtime?.focusedSurface = nil
            }
        }
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Tracking and pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let surface {
            ghostty_surface_set_focus(surface, true)
            runtime?.focusedSurface = surface
        }
        onFocus?()
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface,
                                     event.scrollingDeltaX,
                                     event.scrollingDeltaY,
                                     0)
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods(event))
    }

    private func sendMouseButton(_ event: NSEvent,
                                 state: ghostty_input_mouse_state_e,
                                 button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, mods(event))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        // Command belongs to the app menu (copy, paste, quit); AppKit runs the
        // key equivalents before this method, so reaching it means no menu row
        // matched.
        if event.modifierFlags.contains(.command) {
            NSSound.beep()
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Option is Meta when the config says so: send the key itself and let
        // Ghostty encode the escape prefix. With an active composition, the IME
        // owns the event instead.
        if event.modifierFlags.contains(.option), hasMarkedText() == false {
            var key = ghosttyKey(event, action: action)
            key.consumed_mods = GHOSTTY_MODS_NONE
            if ghostty_surface_key(surface, key) { return }
        }

        if isSpecialKey(event) {
            var key = ghosttyKey(event, action: action)
            key.consumed_mods = GHOSTTY_MODS_NONE
            if ghostty_surface_key(surface, key) { return }
        }

        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        guard let surface, isSpecialKey(event) else { return }
        var key = ghosttyKey(event, action: GHOSTTY_ACTION_RELEASE)
        key.consumed_mods = GHOSTTY_MODS_NONE
        _ = ghostty_surface_key(surface, key)
    }

    private func ghosttyKey(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = mods(event)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = hasMarkedText()
        key.unshifted_codepoint = unshiftedCodepoint(event)
        return key
    }

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        let flags = event.modifierFlags
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func unshiftedCodepoint(_ event: NSEvent) -> UInt32 {
        guard let characters = event.characters(byApplyingModifiers: [])
                ?? event.charactersIgnoringModifiers
                ?? event.characters,
              let scalar = characters.unicodeScalars.first,
              scalar.value >= 0x20,
              (0xF700...0xF8FF).contains(scalar.value) == false else { return 0 }
        return scalar.value
    }

    private func isSpecialKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Delete,
             kVK_ForwardDelete, kVK_Escape, kVK_LeftArrow, kVK_RightArrow,
             kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp,
             kVK_PageDown, kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
             kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            return true
        default:
            return false
        }
    }

    // MARK: - Clipboard and menu

    @objc func copy(_ sender: Any?) {
        performBindingAction("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    @objc override func selectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    /// Runs a Ghostty binding action, such as the find-bar ones. The surface
    /// reports results back through the runtime's action callback.
    func performBindingAction(_ name: String) {
        guard let surface else { return }
        name.withCString {
            _ = ghostty_surface_binding_action(surface, $0, UInt(name.utf8.count))
        }
    }

    func performSearch(_ needle: String) {
        performBindingAction(TerminalSearchNavigation.needleAction(needle))
    }

    func navigateSearch(_ direction: TerminalSearchNavigation) {
        performBindingAction(direction.bindingAction)
    }

    func endSearch() {
        performBindingAction(TerminalSearchNavigation.endAction)
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard text.isEmpty == false else { return }
        if hasMarkedText() {
            markedText = NSMutableAttributedString()
            ghostty_surface_preedit(surface, nil, 0)
        }
        text.withCString {
            ghostty_surface_text_input(surface, $0, UInt(text.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let surface else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString(string: text)
        text.withCString {
            ghostty_surface_preedit(surface, $0, UInt(text.utf8.count))
        }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length)
                        : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: markedText.length, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let inView = NSRect(x: x, y: bounds.height - y - height,
                            width: max(width, 1), height: max(height, 1))
        let inWindow = convert(inView, to: nil)
        return window?.convertToScreen(inWindow) ?? .zero
    }

    override func doCommand(by selector: Selector) {
        guard let surface else { return }
        let keyCode: Int?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): keyCode = kVK_Return
        case #selector(NSResponder.insertTab(_:)): keyCode = kVK_Tab
        case #selector(NSResponder.insertBacktab(_:)): keyCode = kVK_Tab
        case #selector(NSResponder.deleteBackward(_:)): keyCode = kVK_Delete
        case #selector(NSResponder.deleteForward(_:)): keyCode = kVK_ForwardDelete
        case #selector(NSResponder.moveLeft(_:)): keyCode = kVK_LeftArrow
        case #selector(NSResponder.moveRight(_:)): keyCode = kVK_RightArrow
        case #selector(NSResponder.moveUp(_:)): keyCode = kVK_UpArrow
        case #selector(NSResponder.moveDown(_:)): keyCode = kVK_DownArrow
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)): keyCode = kVK_Home
        case #selector(NSResponder.scrollToEndOfDocument(_:)): keyCode = kVK_End
        case #selector(NSResponder.pageUp(_:)): keyCode = kVK_PageUp
        case #selector(NSResponder.pageDown(_:)): keyCode = kVK_PageDown
        case #selector(NSResponder.cancelOperation(_:)): keyCode = kVK_Escape
        default: keyCode = nil
        }
        guard let keyCode else { return }

        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = UInt32(keyCode)
        key.mods = currentMods()
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = hasMarkedText()
        key.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, key)
    }

    private func currentMods() -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
}
