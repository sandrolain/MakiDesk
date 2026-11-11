import os

/// The browser helper's own log. It never records page titles, URLs, text or
/// favicon bytes; only counts and technical identifiers.
enum BrowserLog {
    static let store = Logger(subsystem: "com.makidesk.app.browser", category: "store")
    static let window = Logger(subsystem: "com.makidesk.app.browser", category: "window")
}
