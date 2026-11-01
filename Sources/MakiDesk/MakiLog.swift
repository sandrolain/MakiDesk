import os

/// The log categories (R11).
///
/// One `Logger` per part of the app, so a session can be filtered by what was
/// being looked at instead of reading everything at once. The rules are the
/// same in every category, and they are what keeps the log shareable:
///
/// - durations, counts, revisions and technical ids; never a window title, a
///   note's text, a clipboard payload, a file path or a screenshot;
/// - `privacy: .public` only on numbers and ids this file chose itself.
enum MakiLog {
    private static let subsystem = "com.makidesk.app"

    /// Lifecycle and anything that does not belong to one part.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Window discovery, accessibility and frame writes.
    static let index = Logger(subsystem: subsystem, category: "index")
    /// Screenshot capture, the caches and the library.
    static let capture = Logger(subsystem: subsystem, category: "capture")
    /// The switcher and the applications shelf.
    static let palette = Logger(subsystem: subsystem, category: "palette")
    /// Notes, drafts and the editor.
    static let notes = Logger(subsystem: subsystem, category: "notes")
    /// Text recognition and the colour sampler.
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    /// The shortcut table, its file and the Carbon registration.
    static let shortcuts = Logger(subsystem: subsystem, category: "shortcuts")
    /// The files on disk: groups, dropzones, checklist, timers.
    static let store = Logger(subsystem: subsystem, category: "store")
}
