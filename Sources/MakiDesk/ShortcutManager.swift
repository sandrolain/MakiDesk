import AppKit
import Carbon.HIToolbox

// Carbon hot keys: consume the event, need no Input Monitoring permission.
//
// Two kinds of binding live here: the fixed table of window / palette / group
// actions, and hot keys registered on demand with separate press and release
// handlers — the peek's hold key (T16).
final class ShortcutManager {
    static let signature = OSType(0x4F524244)   // "ORBD"

    private var hotKeys: [EventHotKeyRef] = []
    fileprivate var actions: [UInt32: WindowController.ShortcutAction] = [:]
    /// Press and release handlers for on-demand hot keys, by id.
    fileprivate var pressHandlers: [UInt32: () -> Void] = [:]
    fileprivate var releaseHandlers: [UInt32: () -> Void] = [:]
    private var dynamicKeys: [UInt32: EventHotKeyRef] = [:]
    private var nextDynamicID: UInt32 = 1000
    private var handlerRef: EventHandlerRef?
    fileprivate let handler: (WindowController.ShortcutAction) -> Void

    private(set) var registeredCount = 0
    private(set) var failedCount = 0

    init(handler: @escaping (WindowController.ShortcutAction) -> Void) {
        self.handler = handler
    }

    private struct Binding {
        let key: Int
        let modifiers: Int
        let action: WindowController.ShortcutAction
    }

    static let ctrlOpt = controlKey | optionKey

    private static let baseBindings: [Binding] = [
        .init(key: kVK_LeftArrow, modifiers: ctrlOpt, action: .leftHalf),
        .init(key: kVK_RightArrow, modifiers: ctrlOpt, action: .rightHalf),
        .init(key: kVK_UpArrow, modifiers: ctrlOpt, action: .topHalf),
        .init(key: kVK_DownArrow, modifiers: ctrlOpt, action: .bottomHalf),
        .init(key: kVK_ANSI_U, modifiers: ctrlOpt, action: .topLeft),
        .init(key: kVK_ANSI_I, modifiers: ctrlOpt, action: .topRight),
        .init(key: kVK_ANSI_J, modifiers: ctrlOpt, action: .bottomLeft),
        .init(key: kVK_ANSI_K, modifiers: ctrlOpt, action: .bottomRight),
        .init(key: kVK_Return, modifiers: ctrlOpt, action: .centerCycle),
        .init(key: kVK_ANSI_C, modifiers: ctrlOpt, action: .center),
        .init(key: kVK_ANSI_P, modifiers: ctrlOpt, action: .phi),
        .init(key: kVK_ANSI_P, modifiers: ctrlOpt | cmdKey, action: .peekDesignate),
        // Focus (T17): what leaves the screen is per window, and undoable.
        .init(key: kVK_ANSI_V, modifiers: ctrlOpt, action: .putAwayFront),
        .init(key: kVK_ANSI_A, modifiers: ctrlOpt | shiftKey, action: .showEverything),
        .init(key: kVK_ANSI_Z, modifiers: ctrlOpt, action: .undoStep),
        .init(key: kVK_ANSI_F, modifiers: ctrlOpt, action: .toggleFullScreen),
        .init(key: kVK_ANSI_M, modifiers: ctrlOpt, action: .minimize),
        // Layouts (T18): one key per preset, acting on what is in view.
        .init(key: kVK_ANSI_G, modifiers: ctrlOpt, action: .gridLayout),
        .init(key: kVK_ANSI_S, modifiers: ctrlOpt, action: .spiralLayout),
        .init(key: kVK_ANSI_A, modifiers: ctrlOpt, action: .suggestLayout),
        .init(key: kVK_ANSI_W, modifiers: ctrlOpt, action: .contentLayout),
        .init(key: kVK_Tab, modifiers: optionKey, action: .switchWindows),
        .init(key: kVK_Tab, modifiers: optionKey | shiftKey, action: .switchWindowsBack),
        .init(key: kVK_Space, modifiers: optionKey, action: .searchWindows),
        // Notes (T20): a panel, not a window, and no Accessibility needed.
        .init(key: kVK_ANSI_N, modifiers: optionKey, action: .toggleNotes),
        // Clipboard history (T21): pasting into the front app needs Accessibility.
        .init(key: kVK_ANSI_V, modifiers: optionKey, action: .clipboardHistory),
        // Shelf (T31): collecting does not need Accessibility.
        .init(key: kVK_ANSI_D, modifiers: ctrlOpt, action: .toggleShelf),
    ]

    /// Group shortcuts (1…9): ⌃⌥⌘N adds/removes the frontmost window, ⌃⌥N
    /// recalls the group. The ANSI digit key codes are consecutive (1 = 18 … 9 = 25).
    private static let groupBindings: [Binding] = (1...9).flatMap { slot -> [Binding] in
        let key = kVK_ANSI_1 + (slot - 1)
        return [
            .init(key: key, modifiers: ctrlOpt | cmdKey, action: .assignToGroup(slot)),
            .init(key: key, modifiers: ctrlOpt, action: .recallGroup(slot)),
        ]
    }

    private static let bindings: [Binding] = baseBindings + groupBindings

    func start() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                switch GetEventKind(event) {
                case UInt32(kEventHotKeyPressed):
                    if let action = manager.actions[hotKeyID.id] {
                        manager.handler(action)
                    } else {
                        manager.pressHandlers[hotKeyID.id]?()
                    }
                case UInt32(kEventHotKeyReleased):
                    manager.releaseHandlers[hotKeyID.id]?()
                default:
                    break
                }
                return noErr
            },
            2, &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        for (index, binding) in Self.bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.key), UInt32(binding.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                hotKeys.append(ref)
                actions[id] = binding.action
                registeredCount += 1
            } else {
                failedCount += 1
            }
        }
        makiLog.notice("hotkeys registered=\(self.registeredCount, privacy: .public) blocked=\(self.failedCount, privacy: .public)")
    }

    // MARK: - On-demand hot keys (press and release)

    /// Registers one more hot key after `start()`, with separate press and
    /// release handling. Returns an id to `unregister(_:)` with, or nil when the
    /// combination is taken (by another app, or by our own table).
    @discardableResult
    func register(key: Int, modifiers: Int, onPress: @escaping () -> Void,
                  onRelease: (() -> Void)? = nil) -> UInt32? {
        var ref: EventHotKeyRef?
        let id = nextDynamicID
        let status = RegisterEventHotKey(
            UInt32(key), UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            failedCount += 1
            return nil
        }
        nextDynamicID += 1
        dynamicKeys[id] = ref
        pressHandlers[id] = onPress
        if let onRelease { releaseHandlers[id] = onRelease }
        registeredCount += 1
        return id
    }

    /// Removes a hot key added with `register(key:modifiers:onPress:onRelease:)`.
    func unregister(_ id: UInt32?) {
        guard let id, let ref = dynamicKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
        pressHandlers[id] = nil
        releaseHandlers[id] = nil
        registeredCount = max(0, registeredCount - 1)
    }

    /// Registers Esc for as long as it is needed — the peek (T16) intercepts it
    /// only while its overlay is on screen, never the rest of the time.
    func registerEscape(_ onPress: @escaping () -> Void) -> UInt32? {
        register(key: kVK_Escape, modifiers: 0, onPress: onPress)
    }

    /// The peek's hold key (T16): ⌃⌥H. Press shows the overlay, release takes it
    /// away, so it is the one binding that needs both halves of the press.
    func registerPeekHold(onPress: @escaping () -> Void,
                          onRelease: @escaping () -> Void) -> UInt32? {
        register(key: kVK_ANSI_H, modifiers: Self.ctrlOpt, onPress: onPress, onRelease: onRelease)
    }

    deinit {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        dynamicKeys.values.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
