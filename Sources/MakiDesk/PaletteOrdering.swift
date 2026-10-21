import Foundation

enum PaletteOrdering {
    static func stableOrder(existing: [String], incoming: [String]) -> [String] {
        let live = Set(incoming)
        let previous = Set(existing)
        return existing.filter { live.contains($0) } + incoming.filter { !previous.contains($0) }
    }

    static func initialSelection(ids: [String], origin: String?, backwards: Bool) -> Int {
        guard !ids.isEmpty else { return 0 }
        guard let origin, let index = ids.firstIndex(of: origin) else {
            return backwards ? ids.count - 1 : 0
        }
        return (index + (backwards ? -1 : 1) + ids.count) % ids.count
    }
}
