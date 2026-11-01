import Foundation

/// The process entry point: a pure documentation mode, then the app (S04).
///
/// `--dump-shortcuts` prints the table in Markdown and leaves; given a path, it
/// rewrites the generated block in that file instead. Neither touches AppKit,
/// so the `task docs:shortcuts` target can run it without a window ever opening.
@main
enum MakiDeskMain {
    static func main() {
        var arguments = CommandLine.arguments.dropFirst()
        guard arguments.first == "--dump-shortcuts" else {
            MakiDeskApp.main()
            return
        }
        arguments = arguments.dropFirst()
        guard let path = arguments.first else {
            print(ShortcutTableDocument.markdown())
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try ShortcutTableDocument.rewrite(fileAt: url)
            print("Rewrote the shortcut block in \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
