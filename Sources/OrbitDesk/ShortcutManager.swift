import AppKit
import Carbon.HIToolbox

// Carbon hot keys: consume the event, need no Input Monitoring permission.
final class ShortcutManager {
    private var hotKeys: [EventHotKeyRef] = []
    fileprivate var actions: [UInt32: WindowController.ShortcutAction] = [:]
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

    private static let ctrlOpt = controlKey | optionKey

    private static let bindings: [Binding] = [
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
        .init(key: kVK_ANSI_F, modifiers: ctrlOpt, action: .toggleFullScreen),
        .init(key: kVK_ANSI_M, modifiers: ctrlOpt, action: .minimize),
        .init(key: kVK_Tab, modifiers: optionKey, action: .switchWindows),
        .init(key: kVK_Tab, modifiers: optionKey | shiftKey, action: .switchWindowsBack),
        .init(key: kVK_Space, modifiers: optionKey, action: .searchWindows),
    ]

    func start() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
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
                if let action = manager.actions[hotKeyID.id] {
                    manager.handler(action)
                }
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        for (index, binding) in Self.bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.key), UInt32(binding.modifiers),
                EventHotKeyID(signature: OSType(0x4F524244), id: id),
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
        orbitLog.notice("hotkeys registered=\(self.registeredCount, privacy: .public) blocked=\(self.failedCount, privacy: .public)")
    }

    deinit {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
