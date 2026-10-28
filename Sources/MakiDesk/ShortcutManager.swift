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

    static let ctrlOpt = ShortcutDefinitions.ctrlOpt

    /// The registered rows: every global definition, in catalog order.
    private static let bindings: [ShortcutDefinition] = ShortcutDefinitions.global

    /// Rows whose hot key could not be registered because another app owns it.
    /// The menu remains the fallback and the catalog says so (T53).
    private(set) var blockedShortcutIDs: Set<String> = []
    /// Rows the user turned off; they own no hot key at all.
    private(set) var disabledShortcutIDs: Set<String> = []
    /// The table in force, for diagnostics and for the menu labels.
    private(set) var currentBindings = ShortcutBindings.defaults

    /// The key a command shows and uses. Menus pass the table in force, so a
    /// remapped row updates as soon as the store changes (T53).
    static func display(for action: WindowController.ShortcutAction,
                        bindings: ShortcutBindings = .defaults) -> String? {
        bindings.display(forAction: action)
    }

    var blockedTitles: [String] {
        ShortcutDefinitions.global
            .filter { blockedShortcutIDs.contains($0.id) }
            .map(\.title)
    }

    func start(bindings: ShortcutBindings) {
        installHandlerIfNeeded()
        reload(bindings)
    }

    /// Re-registers every row from `bindings`. Called once at launch and again
    /// after each change, so a remapped combination works without a restart
    /// (T53). A row that fails here is reported as blocked and keeps the menu
    /// as its way in.
    func reload(_ bindings: ShortcutBindings) {
        installHandlerIfNeeded()
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        actions.removeAll()
        blockedShortcutIDs.removeAll()
        disabledShortcutIDs.removeAll()
        registeredCount = 0
        failedCount = 0
        currentBindings = bindings

        for (index, definition) in Self.bindings.enumerated() {
            let id = UInt32(index + 1)
            if bindings.isDisabled(definition.id) {
                disabledShortcutIDs.insert(definition.id)
                continue
            }
            guard let binding = bindings.binding(for: definition.id),
                  let action = definition.action else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode), UInt32(binding.normalized.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                hotKeys.append(ref)
                actions[id] = action
                registeredCount += 1
            } else {
                failedCount += 1
                blockedShortcutIDs.insert(definition.id)
            }
        }
        makiLog.notice("hotkeys registered=\(self.registeredCount, privacy: .public) blocked=\(self.failedCount, privacy: .public) off=\(self.disabledShortcutIDs.count, privacy: .public)")
    }

    /// Whether the system will let us own this combination right now. It
    /// registers and immediately unregisters, so the answer is the one a
    /// `reload` would get; the recorder asks before saving anything.
    func canRegister(_ binding: ShortcutBinding) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode), UInt32(binding.normalized.modifiers),
            EventHotKeyID(signature: Self.signature, id: 0),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    private func installHandlerIfNeeded() {
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
