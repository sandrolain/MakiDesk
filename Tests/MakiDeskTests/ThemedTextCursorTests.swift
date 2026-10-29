import AppKit
import XCTest
@testable import MakiDesk

/// The caret and the selection follow the theme accent in every field, as they
/// already did in the Notes editor.
@MainActor
final class ThemedTextCursorTests: XCTestCase {
    private func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat)? {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        return (converted.redComponent, converted.greenComponent, converted.blueComponent)
    }

    func testTheCaretAndTheSelectionTakeTheThemeAccent() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        ThemedTextCursor.shared.apply(to: textView)

        let accent = try XCTUnwrap(rgb(NSColor(WorkspaceStore.shared.theme.accent)))
        let caret = try XCTUnwrap(rgb(textView.insertionPointColor))
        XCTAssertEqual(caret.0, accent.0, accuracy: 0.01)
        XCTAssertEqual(caret.1, accent.1, accuracy: 0.01)
        XCTAssertEqual(caret.2, accent.2, accuracy: 0.01)

        let selection = try XCTUnwrap(
            (textView.selectedTextAttributes[.backgroundColor] as? NSColor)
                .flatMap(rgb)
        )
        XCTAssertEqual(selection.0, accent.0, accuracy: 0.01)
        XCTAssertEqual(selection.1, accent.1, accuracy: 0.01)
        XCTAssertEqual(selection.2, accent.2, accuracy: 0.01)
    }

    func testAForeignTextViewIsLeftAloneWhenThereIsNothingToApplyTo() {
        // The hook must tolerate notifications from views that are not text
        // views (AppKit posts from several places).
        ThemedTextCursor.shared.apply(to: nil)
        let view = NSTextView()
        ThemedTextCursor.shared.apply(to: view)
        XCTAssertNotNil(view.insertionPointColor)
    }
}
