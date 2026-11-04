import CoreGraphics

/// One control in the bar, as the layout sees it.
struct BarLayoutItem: Identifiable, Equatable {
    let id: String
    /// 1 is kept longest; larger numbers go to the overflow menu first.
    let priority: Int
    let width: CGFloat
}

/// Chooses what fits in the strip (F3).
///
/// The widths are estimates, and the view uses the same numbers for its
/// buttons, so the answer is deterministic and testable: the bar never clips a
/// control and never needs a second measuring pass. Items are kept in their
/// declared order; empty width means everything overflows except nothing, and
/// a single item always stays so the strip never becomes a blank square.
enum BarLayout {
    struct Plan: Equatable {
        var visible: [String]
        var overflow: [String]

        var isEmpty: Bool { visible.isEmpty }
    }

    /// Where the overflow menu opens: just under the chevron at the right edge
    /// of the panel. Anchoring it there keeps it beside the bar even when the
    /// keyboard opened it and the pointer is on another display.
    static func menuAnchor(in panel: CGRect, inset: CGFloat = 10) -> CGPoint {
        CGPoint(x: panel.maxX - inset, y: panel.minY - 2)
    }

    static func plan(_ items: [BarLayoutItem], available: CGFloat,
                     reserve: CGFloat = 0) -> Plan {
        guard items.isEmpty == false else { return Plan(visible: [], overflow: []) }
        let room = max(0, available - reserve)
        var kept = items

        func total(_ list: [BarLayoutItem]) -> CGFloat {
            list.reduce(0) { $0 + $1.width }
        }

        while kept.count > 1, total(kept) > room {
            // The least important control goes first; on a tie, the one
            // furthest to the right, so labels and menus keep their order.
            var worst = 0
            for index in kept.indices where kept[index].priority >= kept[worst].priority {
                worst = index
            }
            kept.remove(at: worst)
        }

        let keptIDs = Set(kept.map(\.id))
        let order = items.map(\.id)
        return Plan(visible: order.filter(keptIDs.contains),
                    overflow: order.filter { keptIDs.contains($0) == false })
    }
}
