import Foundation

/// Turns what a finished run produced into files or text for the clipboard and
/// the Shelf (T47).
///
/// Pure apart from reading the output folder: the caller decides what to do
/// with the result (pasteboard, shelf) and owns the presentation.
enum DropzoneOutput {
    struct Payload: Equatable {
        var fileURLs: [URL]
        var text: String?
    }

    /// `nil` when there is nothing to deliver: a failed run, an empty output
    /// folder and no stdout.
    ///
    /// The declared output path wins when the zone set one (presets that write
    /// next to the source); otherwise the files under `{outdir}`, in a stable
    /// name order. stdout is the last fallback (T47).
    static func payload(result: CommandResult,
                        expectedOutput: String?,
                        fileManager: FileManager = .default) -> Payload? {
        guard result.succeeded else { return nil }
        var files: [URL] = []
        if let expectedOutput, expectedOutput.isEmpty == false {
            let url = URL(fileURLWithPath: expectedOutput)
            if fileManager.fileExists(atPath: url.path) { files.append(url) }
        }
        if files.isEmpty {
            let output = result.workDirectory.appendingPathComponent("output", isDirectory: true)
            let contents = (try? fileManager.contentsOfDirectory(
                at: output,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            files = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        if files.isEmpty == false {
            return Payload(fileURLs: files, text: nil)
        }
        guard let stdout = result.stdoutExcerpt,
              stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return Payload(fileURLs: [], text: stdout)
    }
}
