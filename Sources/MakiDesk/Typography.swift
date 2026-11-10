import SwiftUI

/// The small type scale the panels share.
///
/// MakiDesk is dense by design; what it lacked was a fixed set of steps for
/// the labels around the content. Sizes that belong to a scaled surface — the
/// switcher, the HUD, the editor — keep deriving from their own metrics.
enum MakiType {
    /// A badge, a keycap or the smallest annotation.
    static let micro = Font.system(size: 9.5)
    static let microMedium = Font.system(size: 9.5, weight: .medium)
    static let microStrong = Font.system(size: 9.5, weight: .semibold)

    /// Counts, hints and secondary lines.
    static let meta = Font.system(size: 10.5)
    static let metaMedium = Font.system(size: 10.5, weight: .medium)
    static let metaStrong = Font.system(size: 10.5, weight: .semibold)

    /// Dense supporting text.
    static let body = Font.system(size: 11.5)
    static let bodyMedium = Font.system(size: 11.5, weight: .medium)
    static let bodyStrong = Font.system(size: 11.5, weight: .semibold)

    /// Reading size for card and list content.
    static let content = Font.system(size: 13)
    static let contentMedium = Font.system(size: 13, weight: .medium)
    static let contentStrong = Font.system(size: 13, weight: .semibold)

    /// A panel header.
    static let title = Font.system(size: 13, weight: .semibold)

    /// The slightly larger body used by Settings, whose small print is long.
    static let reading = Font.system(size: 14)

    /// A sub-section header inside Settings.
    static let subtitle = Font.system(size: 14, weight: .semibold)

    /// A Settings group header.
    static let section = Font.system(size: 15, weight: .semibold)

    /// Long explanatory copy.
    static let caption = Font.system(size: 12.5)
}
