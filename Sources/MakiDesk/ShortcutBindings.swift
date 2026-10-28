import AppKit
import Carbon.HIToolbox
import Foundation

/// One key combination, in the Carbon terms `RegisterEventHotKey` wants (T53).
///
/// The value is what the user records and what `shortcuts.json` stores; the
/// display string is derived, so a remapped row cannot drift from its text.
struct ShortcutBinding: Codable, Hashable, Sendable {
    var keyCode: Int
    var modifiers: Int

    /// The four modifiers Carbon registers; anything else is dropped.
    static let modifierMask = controlKey | optionKey | shiftKey | cmdKey

    var normalized: ShortcutBinding {
        ShortcutBinding(keyCode: keyCode, modifiers: modifiers & Self.modifierMask)
    }

    var display: String {
        ShortcutDisplay.string(keyCode: keyCode, modifiers: normalized.modifiers)
    }

    /// A global hot key needs ⌃ or ⌥: ⌘ alone would take a standard shortcut
    /// from the front app, and ⇧ alone would take ordinary typing.
    var hasGlobalModifier: Bool {
        normalized.modifiers & (controlKey | optionKey) != 0
    }

    /// Carbon masks from an AppKit event, so the recorder and the table speak
    /// the same language.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return result
    }
}

/// What a stored override says about one row: a new combination, or "off".
struct ShortcutOverride: Codable, Hashable, Sendable {
    var key: Int?
    var modifiers: Int?
    var disabled: Bool?

    init(binding: ShortcutBinding) {
        key = binding.keyCode
        modifiers = binding.modifiers
        disabled = nil
    }

    init(disabled: Bool) {
        key = nil
        modifiers = nil
        self.disabled = disabled ? true : nil
    }

    /// `nil` when the row is turned off: a disabled command has no combination.
    var binding: ShortcutBinding? {
        guard disabled != true, let key, let modifiers else { return nil }
        return ShortcutBinding(keyCode: key, modifiers: modifiers)
    }

    var isDisabled: Bool { disabled == true }
}

/// Why a combination cannot be used, in the words the recorder shows.
enum ShortcutValidationError: Equatable {
    case noKey
    case needsGlobalModifier
    case reserved(String)
    case conflict(String)
    case unavailableBySystem
    case notSaved

    var message: String {
        switch self {
        case .noKey:
            return "Press a key after the modifiers."
        case .needsGlobalModifier:
            return "Use ⌃ or ⌥: ⌘ alone would take a shortcut from the front app."
        case let .reserved(reason):
            return reason
        case let .conflict(title):
            return "Already used by “\(title)”. The previous shortcut is still in use."
        case .unavailableBySystem:
            return "Another app already owns this combination. The previous shortcut is still in use."
        case .notSaved:
            return "The shortcuts file could not be written. The previous shortcut is still in use."
        }
    }
}

enum ShortcutEditResult: Equatable {
    case applied
    case rejected(ShortcutValidationError)

    var error: ShortcutValidationError? {
        if case let .rejected(error) = self { return error }
        return nil
    }
}

/// The effective shortcut table: the defaults from `ShortcutDefinitions` plus
/// the user's overrides (T53 phase 2). Pure and value-typed, so the recorder,
/// the catalog, the menu and the tests all read the same thing.
struct ShortcutBindings: Equatable, Sendable {
    var overrides: [String: ShortcutOverride]

    init(overrides: [String: ShortcutOverride] = [:]) {
        self.overrides = overrides
    }

    static let defaults = ShortcutBindings()

    /// Default combination of every global row, built once from the table.
    static let defaultTable: [String: ShortcutBinding] = {
        var table: [String: ShortcutBinding] = [:]
        for definition in ShortcutDefinitions.all where definition.isGlobal {
            guard let key = definition.keyCode else { continue }
            table[definition.id] = ShortcutBinding(keyCode: key, modifiers: definition.modifiers)
        }
        return table
    }()

    /// The peek's hold key is registered on demand, outside the table, so no
    /// command may take it (T16/T53).
    static let reserved: [ShortcutBinding] = [
        ShortcutBinding(keyCode: kVK_ANSI_H, modifiers: ShortcutDefinitions.ctrlOpt),
    ]

    static let reservedReason = "⌃⌥H is held for the peek: press and hold it to look at the designated window."

    // MARK: - Reading

    func binding(for id: String) -> ShortcutBinding? {
        guard let definition = ShortcutDefinitions.definition(id: id), definition.isGlobal else {
            return nil
        }
        if let override = overrides[id] {
            return override.binding
        }
        return Self.defaultTable[id]
    }

    func isDisabled(_ id: String) -> Bool {
        overrides[id]?.isDisabled == true
    }

    func isModified(_ id: String) -> Bool {
        overrides[id] != nil
    }

    var modifiedCount: Int { overrides.count }

    /// What a row shows: the recorded combination, nothing when it is off, or
    /// the informational text of a row that has no key.
    func display(for id: String) -> String? {
        guard let definition = ShortcutDefinitions.definition(id: id) else { return nil }
        guard definition.isGlobal else { return definition.display }
        return binding(for: id)?.display
    }

    func display(forAction action: WindowController.ShortcutAction) -> String? {
        guard let definition = ShortcutDefinitions.all.first(where: {
            $0.action == action && $0.isGlobal
        }) else { return nil }
        return binding(for: definition.id)?.display
    }

    /// The row that already uses this combination, if any. Compared on the
    /// normalized mask, so a stray flag cannot hide a duplicate.
    func conflict(for binding: ShortcutBinding, excluding id: String) -> ShortcutDefinition? {
        let wanted = binding.normalized
        return ShortcutDefinitions.all.first { definition in
            definition.isGlobal && definition.id != id
                && self.binding(for: definition.id)?.normalized == wanted
        }
    }

    func validationError(for binding: ShortcutBinding, for id: String) -> ShortcutValidationError? {
        let wanted = binding.normalized
        guard wanted.keyCode > 0 else { return .noKey }
        guard wanted.hasGlobalModifier else { return .needsGlobalModifier }
        if Self.reserved.contains(wanted) { return .reserved(Self.reservedReason) }
        if let other = conflict(for: wanted, excluding: id) { return .conflict(other.title) }
        return nil
    }

    // MARK: - Editing

    /// Records a combination; one equal to the default simply removes the
    /// override, so *Restore Defaults* and "same as default" mean the same file.
    mutating func set(_ binding: ShortcutBinding?, for id: String) {
        guard let definition = ShortcutDefinitions.definition(id: id), definition.isGlobal else {
            return
        }
        guard let binding else {
            overrides[id] = nil
            return
        }
        let normalized = binding.normalized
        if normalized == Self.defaultTable[id] {
            overrides[id] = nil
        } else {
            overrides[id] = ShortcutOverride(binding: normalized)
        }
    }

    mutating func disable(_ id: String) {
        guard let definition = ShortcutDefinitions.definition(id: id), definition.isGlobal else {
            return
        }
        overrides[id] = ShortcutOverride(disabled: true)
    }

    mutating func restore(_ id: String) {
        overrides[id] = nil
    }

    mutating func restoreAll() {
        overrides.removeAll()
    }

    /// A file is never trusted to be well formed: unknown rows, invalid
    /// combinations and rows that only repeat the default are dropped here, so
    /// a hand-edited or older file cannot break the app (T53).
    static func sanitized(_ overrides: [String: ShortcutOverride]) -> [String: ShortcutOverride] {
        var result: [String: ShortcutOverride] = [:]
        for (id, override) in overrides {
            guard let definition = ShortcutDefinitions.definition(id: id), definition.isGlobal else {
                continue
            }
            if override.isDisabled {
                result[id] = ShortcutOverride(disabled: true)
                continue
            }
            guard let binding = override.binding,
                  binding.keyCode > 0,
                  binding.hasGlobalModifier else { continue }
            let normalized = binding.normalized
            guard normalized != defaultTable[id] else { continue }
            result[id] = ShortcutOverride(binding: normalized)
        }
        return result
    }
}
