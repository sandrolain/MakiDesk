import AppKit

/// A question or a statement the app shows in a modal, as a value (R08).
///
/// Nine alerts were built by hand, and two of them existed twice, word for
/// word: the dropzone overwrite and the "run this command?" — one copy in the
/// settings window, one in the shelf. Rewording a button in one flow left the
/// other saying something else about the same dangerous action.
///
/// Here the wording is a value, so it can be read in one place and checked
/// without a screen; showing it is one function.
struct Confirmation: Equatable {
    var title: String
    var message: String
    /// The label of the button that goes ahead.
    var confirm: String
    /// `nil` for a statement: a single button that only acknowledges.
    var cancel: String?
    var style: NSAlert.Style = .warning

    var isQuestion: Bool { cancel != nil }

    /// The configured alert, for the one caller that adds a field to it.
    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: confirm)
        if let cancel { alert.addButton(withTitle: cancel) }
        return alert
    }

    /// Shows the modal and answers whether the user went ahead. A statement
    /// always answers `true`: there is nothing to refuse.
    @discardableResult
    @MainActor
    func ask() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return makeAlert().runModal() == .alertFirstButtonReturn
    }

    /// Shows the modal attached to `window` when there is one, so a panel that
    /// is already key does not grow a floating alert over it.
    @MainActor
    func tell(asSheetFor window: NSWindow?) {
        if let window {
            makeAlert().beginSheetModal(for: window)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        makeAlert().runModal()
    }
}

extension Confirmation {
    /// A dropzone whose command may overwrite the file it names.
    static func dropzoneOverwrite(zone: String, path: String) -> Confirmation {
        Confirmation(
            title: "Replace an existing file?",
            message: """
            “\(zone)” may replace:

            \(path)

            Continue?
            """,
            confirm: "Run Anyway",
            cancel: "Cancel"
        )
    }

    /// A dropzone whose command is new or changed since it was last confirmed.
    static func dropzoneRun(zone: String, command: String) -> Confirmation {
        Confirmation(
            title: "Run “\(zone)”?",
            message: "This command is new or changed. It will run:\n\n\(command)\n\nOnly continue if you wrote it or trust where it came from.",
            confirm: "Run",
            cancel: "Cancel"
        )
    }

    /// Closing a note that is a draft of a file: the file is not touched.
    static func closeNote(title: String, file: String) -> Confirmation {
        Confirmation(
            title: "Close “\(title)”?",
            message: "The note is a draft of \(file). The file is not deleted; the draft and its link to the file are removed.",
            confirm: "Close Note",
            cancel: "Cancel"
        )
    }

    static func rename(slot: Int, current: String) -> Confirmation {
        Confirmation(
            title: "Rename \(current)",
            message: "Leave the field empty to go back to “Group \(slot)”.",
            confirm: "Rename",
            cancel: "Cancel",
            style: .informational
        )
    }

    /// A statement: something finished badly and the user only needs to know.
    static func statement(title: String, message: String) -> Confirmation {
        Confirmation(title: title, message: message, confirm: "OK", cancel: nil)
    }
}
