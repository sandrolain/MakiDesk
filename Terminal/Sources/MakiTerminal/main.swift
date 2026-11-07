import AppKit

// F0 spike entry point: a plain AppKit app with one window and one Ghostty
// surface. The real helper will own workspaces, the sidebar and the quake
// panel; none of that exists yet.
let application = NSApplication.shared
let delegate = TerminalAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
