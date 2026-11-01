import Foundation

/// What a notice says, before it is drawn (R04).
///
/// A call site used to spell its own title, symbol and severity, so the same
/// situation could read two ways in two files — "A selection is already open"
/// was written three times — and the severity was guessed from the symbol by a
/// heuristic. A message here is a value, so the texts can be read in one place,
/// checked by a test, and announced by VoiceOver exactly as they are shown.
///
/// `kind` is optional on purpose: `nil` keeps the severity that
/// `HUDKind.inferred(for:)` derives from the symbol, which is what every call
/// site had before this type existed. Only the messages that already chose a
/// severity set it.
struct HUDMessage: Equatable {
    let title: String
    let symbol: String
    var detail: String? = nil
    var kind: HUDKind? = nil
}
