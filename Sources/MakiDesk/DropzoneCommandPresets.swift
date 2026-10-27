import Foundation

/// A starting point for a zone command. Presets only touch the command and its
/// output feedback: the zone's name, icon, accepted kinds and limits stay as the
/// user configured them. Choosing one never runs anything.
struct DropzoneCommandPreset: Identifiable, Equatable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case files = "Files"
        case images = "Images"
        case clipboard = "Clipboard"
        case inspect = "Inspect"

        var id: String { rawValue }
    }

    let id: String
    let name: String
    let summary: String
    let symbol: String
    let category: Category
    let line: String
    let mode: CommandSpec.Mode
    let showStdout: Bool
    let revealOutput: Bool
    /// Converting a batch of images takes longer than the 60 s default; a
    /// preset carries its own limit (T47).
    let timeoutSeconds: Int
    /// Some commands hand the run folder to another app (Terminal); keeping it
    /// makes their result usable after the command returns.
    let keepsRunFolder: Bool
    /// A path template the app checks before running; when it exists, the run
    /// asks before a command may replace it. `nil` means no check.
    let expectedOutput: String?

    init(id: String, name: String, summary: String, symbol: String,
         category: Category, line: String, mode: CommandSpec.Mode,
         showStdout: Bool, revealOutput: Bool, timeoutSeconds: Int = 60,
         keepsRunFolder: Bool = false,
         expectedOutput: String? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.category = category
        self.line = line
        self.mode = mode
        self.showStdout = showStdout
        self.revealOutput = revealOutput
        self.timeoutSeconds = timeoutSeconds
        self.keepsRunFolder = keepsRunFolder
        self.expectedOutput = expectedOutput
    }

    func apply(to zone: inout DropzoneConfig) {
        zone.command.line = line
        zone.command.mode = mode
        zone.command.stdin = .none
        zone.command.timeoutSeconds = timeoutSeconds
        zone.feedback.showOutput = showStdout ? .stdout : .none
        zone.feedback.revealOutput = revealOutput
        if keepsRunFolder { zone.command.keepWorkdir = true }
        zone.expectedOutput = expectedOutput
        // A preset is a new command, even if its text happens to match what was
        // confirmed before; ask again on the next drop.
        zone.confirmedCommandHash = nil
    }

    static let all: [DropzoneCommandPreset] = [
        DropzoneCommandPreset(
            id: "reveal", name: "Reveal in Finder",
            summary: "Select the dropped files in a Finder window.",
            symbol: "folder", category: .files,
            line: "/usr/bin/open -R {paths}",
            mode: .argv, showStdout: false, revealOutput: false),
        DropzoneCommandPreset(
            id: "open", name: "Open with the default app",
            summary: "Open every dropped file with the app macOS associates with it.",
            symbol: "arrow.up.forward.app", category: .files,
            line: "/usr/bin/open {paths}",
            mode: .argv, showStdout: false, revealOutput: false),
        DropzoneCommandPreset(
            id: "zip", name: "ZIP next to the first file",
            summary: "Create archive.zip in the folder of the first dropped file, without folder paths.",
            symbol: "archivebox", category: .files,
            line: "/usr/bin/zip -j {parent}/archive.zip {paths}",
            mode: .argv, showStdout: false, revealOutput: false,
            expectedOutput: "{parent}/archive.zip"),
        DropzoneCommandPreset(
            id: "unzip", name: "Unzip into the output folder",
            summary: "Expand one dropped archive under output/.",
            symbol: "doc.zipper", category: .files,
            line: "/usr/bin/ditto -x -k {path} {outdir}",
            mode: .argv, showStdout: false, revealOutput: true),
        DropzoneCommandPreset(
            id: "terminal", name: "Open Terminal in the run folder",
            summary: "Start Terminal at {workdir}, where the drop was prepared.",
            symbol: "terminal", category: .files,
            line: "/usr/bin/open -a Terminal {workdir}",
            mode: .argv, showStdout: false, revealOutput: false, keepsRunFolder: true),

        DropzoneCommandPreset(
            id: "png", name: "Convert images to PNG",
            summary: "Write PNG copies to output/ with sips.",
            symbol: "photo", category: .images,
            line: "/usr/bin/sips -s format png {paths} --out {outdir}",
            mode: .argv, showStdout: false, revealOutput: true, timeoutSeconds: 300),
        DropzoneCommandPreset(
            id: "jpeg", name: "Convert images to JPEG",
            summary: "Write JPEG copies to output/ with sips.",
            symbol: "photo.on.rectangle", category: .images,
            line: "/usr/bin/sips -s format jpeg {paths} --out {outdir}",
            mode: .argv, showStdout: false, revealOutput: true, timeoutSeconds: 300),
        DropzoneCommandPreset(
            id: "resize", name: "Resize images to 1600 px",
            summary: "Fit the long edge to 1600 px and write the copies to output/.",
            symbol: "arrow.up.left.and.arrow.down.right", category: .images,
            line: "/usr/bin/sips -Z 1600 {paths} --out {outdir}",
            mode: .argv, showStdout: false, revealOutput: true, timeoutSeconds: 300),

        DropzoneCommandPreset(
            id: "copy-paths", name: "Copy paths",
            summary: "Put one dropped path per line on the clipboard.",
            symbol: "doc.on.clipboard", category: .clipboard,
            line: "printf '%s\\n' {paths} | /usr/bin/pbcopy",
            mode: .shell, showStdout: false, revealOutput: false),
        DropzoneCommandPreset(
            id: "copy-names", name: "Copy file names",
            summary: "Put one file name per line on the clipboard.",
            symbol: "textformat", category: .clipboard,
            line: "printf '%s\\n' {paths} | /usr/bin/sed 's#.*/##' | /usr/bin/pbcopy",
            mode: .shell, showStdout: false, revealOutput: false),
        DropzoneCommandPreset(
            id: "copy-text", name: "Copy dropped text",
            summary: "Put the dropped text on the clipboard.",
            symbol: "text.quote", category: .clipboard,
            line: "/bin/cat {textfile} | /usr/bin/pbcopy",
            mode: .shell, showStdout: false, revealOutput: false),

        DropzoneCommandPreset(
            id: "sha256", name: "SHA-256",
            summary: "Print the SHA-256 checksum of every dropped file.",
            symbol: "number", category: .inspect,
            line: "/usr/bin/shasum -a 256 {paths}",
            mode: .argv, showStdout: true, revealOutput: false),
        DropzoneCommandPreset(
            id: "line-count", name: "Line count",
            summary: "Count the lines in the dropped text files.",
            symbol: "list.number", category: .inspect,
            line: "/usr/bin/wc -l {paths}",
            mode: .argv, showStdout: true, revealOutput: false),
        DropzoneCommandPreset(
            id: "echo-paths", name: "Show paths",
            summary: "Print the dropped paths in the result notice.",
            symbol: "text.alignleft", category: .inspect,
            line: "/bin/echo {paths}",
            mode: .argv, showStdout: true, revealOutput: false),
        DropzoneCommandPreset(
            id: "manifest", name: "Show the manifest",
            summary: "Print the JSON manifest MakiDesk prepares for the drop.",
            symbol: "curlybraces", category: .inspect,
            line: "/bin/cat {manifest}",
            mode: .argv, showStdout: true, revealOutput: false)
    ]
}
