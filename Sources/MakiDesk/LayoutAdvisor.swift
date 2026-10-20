import Foundation

/// What kind of thing a window is showing, as far as the intelligent layout
/// needs to know (T18). Deduced from the bundle id, the app name and the title —
/// never from reading the content itself.
enum WindowKind: String, Equatable, CaseIterable, Hashable {
    case editor
    case terminal
    case browser
    case chat
    case document
    case video
    case other

    /// The label in Settings ▸ Layouts.
    var label: String {
        switch self {
        case .editor: return "Editor"
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .chat: return "Chat"
        case .document: return "Document"
        case .video: return "Video"
        case .other: return "Other"
        }
    }

    /// The word used in the reason, when a set is all of one kind.
    var noun: String? {
        switch self {
        case .editor: return "editor"
        case .terminal: return "terminal"
        case .browser: return "browser"
        case .chat: return "chat"
        case .document: return "document"
        case .video: return "video"
        case .other: return nil
        }
    }
}

/// A window the advisor can look at, reduced to what is knowable before any
/// capture: who it belongs to, what it is called, how big it is.
struct LayoutSubject: Equatable {
    var id: String
    var appName: String
    var bundleId: String?
    var title: String
    /// The window's current area; the score falls back to it when the capture
    /// could not reach the window.
    var area: Double

    var kind: WindowKind {
        LayoutAdvisor.kind(bundleId: bundleId, appName: appName, title: title)
    }
}

/// The content measure, when the capture could provide one (M1). An empty
/// dictionary means "not measured": no Screen Recording permission, or no window
/// with an on-screen number to look up.
struct ContentMeasure: Equatable {
    var scores: [String: Double] = [:]
    var measured: Bool { !scores.isEmpty }
}

/// What the advisor proposes, and why. The reason is what the HUD shows, and
/// what makes the choice reviewable rather than magic.
struct LayoutAdvice: Equatable {
    var layout: LayoutPreset
    /// The window that should take the largest slot — the golden spiral's first
    /// slot. `nil` for the grid and for the content layout, which sorts by weight.
    var leadID: String?
    var reason: String
    /// The per-window weights, only for `.content` (T30).
    var weights: [String: Double]?

    init(layout: LayoutPreset, leadID: String?, reason: String,
         weights: [String: Double]? = nil) {
        self.layout = layout
        self.leadID = leadID
        self.reason = reason
        self.weights = weights
    }
}

/// Picks between the two available presets — grid and golden spiral — from the
/// number of windows, the content measure of M1, the kind of app/window and how
/// big the windows are (T18). The frontmost window is deliberately **not** a
/// signal.
///
/// Pure: the same subjects always give the same advice, so every rule can be
/// read off a table of cases. The golden spiral is proposed when one window
/// clearly deserves the big slot, and for exactly three windows (where the
/// grid's equal cells would leave a quarter of the screen empty); equal,
/// unmeasured or too numerous windows are given equal cells.
enum LayoutAdvisor {
    /// How much denser the busiest window must be than the runner-up before it
    /// deserves the big slot of the spiral.
    static let dominanceRatio = 1.5

    /// How unbalanced the content must be before the weighted layout is worth
    /// it (T30): one window with twice the score of the next, or a weight ratio
    /// of at least 1.6.
    static let contentScoreRatio = 2.0
    static let contentWeightRatio = 1.6

    /// Starting priors for the content layout, overridable in Settings ▸ Layouts.
    static let defaultPriors: [WindowKind: Double] = [
        .editor: 1.4,
        .browser: 1.2,
        .video: 1.2,
        .document: 1.0,
        .terminal: 0.9,
        .chat: 0.7,
        .other: 1.0
    ]

    static func advise(_ subjects: [LayoutSubject], measure: ContentMeasure,
                       priors: [WindowKind: Double] = LayoutAdvisor.defaultPriors) -> LayoutAdvice {
        let count = subjects.count
        if count == 0 {
            return LayoutAdvice(layout: .grid, leadID: nil, reason: "nothing to arrange")
        }
        if count == 1 {
            return LayoutAdvice(layout: .grid, leadID: nil, reason: "one window fills the screen")
        }
        if count == 2 {
            return LayoutAdvice(layout: .grid, leadID: nil, reason: "two windows: equal halves")
        }

        // Content-weighted layout (T30): only with a measurement, at least
        // three windows, and a clearly uneven spread of content or weights.
        // It comes before the spiral cap: a treemap has no slot limit.
        if measure.measured {
            let weighted = weights(subjects, measure: measure, priors: priors)
            if let content = contentAdvice(subjects, measure: measure, weights: weighted) {
                return content
            }
        }

        if count > TilingEngine.maxGoldenSpiralSlots {
            return LayoutAdvice(layout: .grid, leadID: nil,
                                reason: "\(count) windows: the golden spiral stops at "
                                    + "\(TilingEngine.maxGoldenSpiralSlots), so equal cells")
        }
        // Without a measurement there is nothing to be intelligent about: the
        // fallback is the current default, the grid.
        guard measure.measured else {
            return LayoutAdvice(layout: .grid, leadID: nil, reason: "no content measurement: equal cells")
        }

        let ranked = rankedByContent(subjects, measure: measure)
        if let lead = ranked.first, let next = ranked.dropFirst().first {
            let leadScore = measure.scores[lead.id]
            let nextScore = measure.scores[next.id]
            if let leadScore, let nextScore {
                // Both were measured: compare the densities themselves.
                if leadScore >= dominanceRatio * max(nextScore, 1) {
                    return LayoutAdvice(
                        layout: .goldenSpiral, leadID: lead.id,
                        reason: "\(lead.appName) holds the densest content: the spiral gives it the widest slot"
                    )
                }
            } else if lead.area >= 2 * next.area {
                // One window could not be captured: its size is the only thing
                // left to go on.
                return LayoutAdvice(
                    layout: .goldenSpiral, leadID: lead.id,
                    reason: "\(lead.appName) is much bigger than the rest: the spiral gives it the widest slot"
                )
            }
        }
        // A video is watched rather than read, so it takes the big slot even
        // when its frames measure low (film is smooth). Chaotic by nature: a
        // video among several windows is exactly the case the spiral serves.
        if let video = ranked.first(where: { $0.kind == .video }) {
            return LayoutAdvice(
                layout: .goldenSpiral, leadID: video.id,
                reason: "\(video.appName) is playing video: the spiral gives it the widest slot"
            )
        }
        // Three windows: the grid's equal cells would leave a quarter of the
        // screen empty (its 2×2 has no fourth window), while the spiral fills it
        // — and master + stack is the shape the focus spec proposes for 3–4
        // windows. The busiest of the three takes the master slot.
        if count == 3, let lead = ranked.first {
            return LayoutAdvice(
                layout: .goldenSpiral, leadID: lead.id,
                reason: "three windows: the spiral lays a master with a stack, "
                    + "where equal cells would leave a quarter of the screen empty"
            )
        }
        return LayoutAdvice(layout: .grid, leadID: nil, reason: uniformReason(subjects))
    }

    /// The score behind the advice: the capture's edge energy when there is one,
    /// otherwise the window's area — the same convention the golden-spiral
    /// ordering already uses (`WorkspaceStore.byContentScore`), so the two never
    /// disagree about which window has the most to look at.
    static func score(of subject: LayoutSubject, measure: ContentMeasure) -> Double {
        measure.scores[subject.id] ?? subject.area
    }

    /// Per-window weights for the content layout (T30):
    /// `prior(app kind) × clamp(0.7 + 0.6 × score / median, 0.5 … 2.0)`.
    /// A window without a score keeps factor 1, so without Screen Recording the
    /// layout still follows the priors.
    static func weights(_ subjects: [LayoutSubject], measure: ContentMeasure,
                        priors: [WindowKind: Double] = LayoutAdvisor.defaultPriors) -> [String: Double] {
        let measured = subjects.compactMap { subject -> Double? in
            guard let score = measure.scores[subject.id], score > 0 else { return nil }
            return score
        }.sorted()
        let median: Double? = {
            guard measured.isEmpty == false else { return nil }
            let middle = measured.count / 2
            if measured.count.isMultiple(of: 2) {
                return (measured[middle - 1] + measured[middle]) / 2
            }
            return measured[middle]
        }()

        var result: [String: Double] = [:]
        for subject in subjects {
            let prior = priors[subject.kind] ?? 1.0
            var factor = 1.0
            if let score = measure.scores[subject.id], score > 0, let median, median > 0 {
                factor = min(max(0.7 + 0.6 * (score / median), 0.5), 2.0)
            }
            result[subject.id] = max(0.05, prior * factor)
        }
        return result
    }

    /// Content is worth a weighted layout only when it is clearly uneven: the
    /// busiest window has twice the score of the runner-up, or the heaviest
    /// weight is 1.6× the lightest. Returns nil when the normal rules should
    /// decide instead.
    private static func contentAdvice(_ subjects: [LayoutSubject], measure: ContentMeasure,
                                      weights: [String: Double]) -> LayoutAdvice? {
        let scored = subjects.compactMap { subject -> (LayoutSubject, Double)? in
            guard let score = measure.scores[subject.id] else { return nil }
            return (subject, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.id < rhs.0.id
        }
        let scoreRatio: Double
        if scored.count >= 2 {
            scoreRatio = scored[0].1 / max(scored[1].1, 1)
        } else {
            scoreRatio = 0
        }
        let weightValues = subjects.compactMap { weights[$0.id] }.filter { $0 > 0 }
        let weightRatio: Double
        if let largest = weightValues.max(), let smallest = weightValues.min(), smallest > 0 {
            weightRatio = largest / smallest
        } else {
            weightRatio = 0
        }

        let scoreImbalance = scored.count >= 2 && scoreRatio >= contentScoreRatio
        let weightImbalance = weightValues.count >= 2 && weightRatio >= contentWeightRatio
        guard scoreImbalance || weightImbalance else { return nil }

        let reason: String
        if scoreImbalance, let leader = scored.first, let next = scored.dropFirst().first {
            reason = "\(leader.0.appName) holds \(number(scoreRatio))× the content of "
                + "\(next.0.appName): area follows the content"
        } else if let heaviest = subjects.max(by: {
            (weights[$0.id] ?? 0) < (weights[$1.id] ?? 0)
        }), let lightest = subjects.min(by: {
            (weights[$0.id] ?? 0) < (weights[$1.id] ?? 0)
        }) {
            reason = "\(heaviest.appName) weighs \(number(weightRatio))× "
                + "\(lightest.appName): area follows the weights"
        } else {
            reason = "the content is unevenly spread: area follows the weights"
        }
        return LayoutAdvice(layout: .content, leadID: nil, reason: reason, weights: weights)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func rankedByContent(_ subjects: [LayoutSubject], measure: ContentMeasure) -> [LayoutSubject] {
        subjects.sorted { lhs, rhs in
            let left = score(of: lhs, measure: measure), right = score(of: rhs, measure: measure)
            if left != right { return left > right }
            if lhs.area != rhs.area { return lhs.area > rhs.area }
            return lhs.id < rhs.id
        }
    }

    /// What to say when nothing stands out: name the kind when the set is all of
    /// one, so "4 editor windows: equal cells" beats a generic sentence.
    private static func uniformReason(_ subjects: [LayoutSubject]) -> String {
        let kinds = Set(subjects.map(\.kind))
        if kinds.count == 1, let kind = kinds.first, let noun = kind.noun {
            return "\(subjects.count) \(noun) windows: equal cells"
        }
        return "\(subjects.count) windows of similar density: equal cells"
    }

    // MARK: - What kind of window is this

    /// Reads the kind off the bundle id, the app name, and the title's file
    /// extension. Deliberately a small, ordered list of known names rather than
    /// any guessing from the pixels: the kind is a hint for the reason and the
    /// video rule, and being wrong about it never breaks a layout.
    static func kind(bundleId: String?, appName: String, title: String) -> WindowKind {
        let hay = "\((bundleId ?? "")) \(appName)".lowercased()
        if contains(hay, terminalHints) { return .terminal }
        if contains(hay, videoHints) { return .video }
        if contains(hay, chatHints) { return .chat }
        if contains(hay, editorHints) { return .editor }
        if contains(hay, browserHints) { return .browser }
        if contains(hay, documentHints) { return .document }
        if let kind = kindFromTitle(title) { return kind }
        return .other
    }

    /// An unknown app still shows its file: the extension is the last clue.
    private static func kindFromTitle(_ title: String) -> WindowKind? {
        let lowered = title.lowercased()
        guard let dot = lowered.lastIndex(of: "."), dot < lowered.index(before: lowered.endIndex) else {
            return nil
        }
        let ext = String(lowered[lowered.index(after: dot)...])
        if codeExtensions.contains(ext) { return .editor }
        if documentExtensions.contains(ext) { return .document }
        return nil
    }

    private static func contains(_ hay: String, _ hints: [String]) -> Bool {
        hints.contains { hay.contains($0) }
    }

    private static let terminalHints = [
        "apple.terminal", "iterm", "alacritty", "kitty", "wezterm", "warp", "hyper",
        "ghostty", "tabby", "terminal.app"
    ]
    private static let editorHints = [
        "xcode", "vscode", "visual studio code", "sublime", "jetbrains", "intellij",
        "pycharm", "webstorm", "goland", "clion", "rubymine", "phpstorm", "rider",
        "datagrip", "textedit", "zed", "panic.nova", "cursor", "emacs", "neovim",
        "macvim", "bbedit", "textmate"
    ]
    private static let browserHints = [
        "safari", "chrome", "chromium", "firefox", "thebrowser", "brave", "edgemac",
        "microsoft edge", "orion", "vivaldi", "opera"
    ]
    private static let chatHints = [
        "slack", "discord", "messages", "whatsapp", "telegram", "signal", "teams",
        "messenger", "skype", "zulip", "element", "mattermost"
    ]
    private static let documentHints = [
        "preview", "pages", "numbers", "keynote", "microsoft word", "excel", "powerpoint",
        "skim", "acrobat", "notes", "obsidian", "bear", "notion", "craft", "pdf"
    ]
    private static let videoHints = [
        "quicktime", "vlc", "iina", "apple.tv", "apple.photos", "movist", "elmedia", "mpv"
    ]

    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "py", "js", "jsx", "ts",
        "tsx", "rb", "go", "rs", "java", "kt", "kts", "scala", "sh", "zsh", "bash",
        "fish", "json", "yaml", "yml", "toml", "plist", "xml", "sql", "cs", "php",
        "lua", "r", "css", "scss", "html", "vue", "sv", "v", "hs", "elm", "dart"
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "txt", "md",
        "markdown", "pages", "numbers", "key", "csv", "epub", "log"
    ]
}
