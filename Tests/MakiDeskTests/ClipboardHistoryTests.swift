import AppKit
import XCTest
@testable import MakiDesk

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    private func makePasteboard() throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("makidesk-clipboard-\(UUID().uuidString)"))
        pasteboard.clearContents()
        guard pasteboard.setString("probe", forType: .string) else {
            throw XCTSkip("Named pasteboards are unavailable in this test environment")
        }
        return pasteboard
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw XCTSkip("Pasteboard write was unavailable in this test environment")
        }
    }

    private func pngData(width: Int = 10, height: Int = 10) -> Data {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let representation = NSBitmapImageRep(cgImage: context.makeImage()!)
        return representation.representation(using: .png, properties: [:]) ?? Data()
    }

    private func makeImage(data: Data = Data([0, 1, 2]), cost: Int,
                           digest: String) -> ClipboardImage {
        let context = CGContext(data: nil, width: 4, height: 4,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let thumbnail = context.makeImage()!
        return ClipboardImage(data: data, type: .png, thumbnail: thumbnail,
                              pixelWidth: 40, pixelHeight: 20, byteCost: cost, digest: digest)
    }

    func testCollectsNewestFirstAndDeduplicates() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        try write("first", to: pasteboard); history.poll()
        try write("second", to: pasteboard); history.poll()
        try write("first", to: pasteboard); history.poll()

        XCTAssertEqual(history.entries.map(\.text), ["first", "second"])
        XCTAssertEqual(history.count, 2)
    }

    func testKeepsOnlyTheNewestEntries() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 2, secureInput: { false })
        history.poll()

        for index in 1...4 {
            try write("text \(index)", to: pasteboard)
            history.poll()
        }

        XCTAssertEqual(history.entries.map(\.text), ["text 4", "text 3"])
    }

    func testConcealedCopiesAreIgnored() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.clearContents()
        guard pasteboard.declareTypes([.string, concealed], owner: nil) > 0,
              pasteboard.setString("a password", forType: .string) else {
            throw XCTSkip("Pasteboard types could not be declared in this environment")
        }
        history.poll()

        XCTAssertTrue(history.entries.isEmpty)
    }

    func testSecureInputIsNeverRecorded() throws {
        let pasteboard = try makePasteboard()
        var secure = true
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { secure })
        history.poll()

        try write("a password", to: pasteboard)
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)

        // Turning secure input off does not reveal what was copied meanwhile.
        secure = false
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)

        try write("a normal text", to: pasteboard)
        history.poll()
        XCTAssertEqual(history.entries.map(\.text), ["a normal text"])
    }

    func testOurOwnPasteIsNotRecordedAgain() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()

        try write("one", to: pasteboard); history.poll()
        XCTAssertEqual(history.count, 1)

        // Pasting writes the chosen text back to the pasteboard.
        try write("one", to: pasteboard)
        history.markPasteboardSeen()
        history.poll()
        XCTAssertEqual(history.count, 1)
    }

    func testPromoteMovesAnEntryBackToTheTop() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()
        try write("first", to: pasteboard); history.poll()
        try write("second", to: pasteboard); history.poll()

        let older = try XCTUnwrap(history.entries.last)
        history.promote(older)

        XCTAssertEqual(history.entries.map(\.text), ["first", "second"])
    }

    func testPreviewCollapsesLinesAndDetailCounts() {
        let entry = ClipboardEntry(id: UUID(), text: "   \nFirst   line\ttabs\nsecond line",
                                   date: Date())
        XCTAssertEqual(entry.preview, "First line tabs")
        XCTAssertTrue(entry.detail.hasPrefix("3 lines"))
        XCTAssertTrue(entry.detail.contains("characters"))

        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(ClipboardEntry(id: UUID(), text: long, date: Date()).preview.count, 121)
    }

    func testInsertAddsWithoutTouchingThePasteboardAndDedupes() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 2, secureInput: { false })
        let before = pasteboard.changeCount

        history.insert("a")
        history.insert("b")
        history.insert("a")

        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(history.entries.map(\.text), ["a", "b"])

        history.insert("c")
        XCTAssertEqual(history.entries.map(\.text), ["c", "a"], "the ring keeps the limit")
        XCTAssertEqual(pasteboard.changeCount, before)

        history.insert("")
        XCTAssertEqual(history.entries.count, 2)
    }

    func testTextsOverTheLimitAreRejectedByUTF16Length() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 5, secureInput: { false })

        history.insert(String(repeating: "a", count: 1_000_001))
        history.insert(String(repeating: "😀", count: 500_001))
        XCTAssertTrue(history.entries.isEmpty)

        history.insert(String(repeating: "a", count: 1_000_000))
        XCTAssertEqual(history.entries.count, 1)
    }

    func testClearEmptiesTheList() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10, secureInput: { false })
        history.poll()
        try write("something", to: pasteboard); history.poll()
        XCTAssertEqual(history.count, 1)

        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }

    // MARK: - Images and pins (U3)

    func testInsertImageAddsAndDeduplicatesByDigest() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10,
                                       secureInput: { false }, imageBudgetMB: 1)
        XCTAssertTrue(history.insertImage(makeImage(cost: 100, digest: "a")))
        XCTAssertTrue(history.insertImage(makeImage(cost: 100, digest: "b")))
        XCTAssertTrue(history.insertImage(makeImage(cost: 100, digest: "a")))

        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.first?.image?.digest, "a")
    }

    func testImageBudgetEvictsTheOldestUnpinnedImage() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10,
                                       secureInput: { false }, imageBudgetMB: 1)
        XCTAssertTrue(history.insertImage(makeImage(cost: 400_000, digest: "a")))
        XCTAssertTrue(history.insertImage(makeImage(cost: 400_000, digest: "b")))
        XCTAssertTrue(history.insertImage(makeImage(cost: 400_000, digest: "c")))

        XCTAssertEqual(history.entries.compactMap { $0.image?.digest }, ["c", "b"])
    }

    func testTooLargeImageIsRejectedWithoutTouchingTheList() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10,
                                       secureInput: { false }, imageBudgetMB: 1)
        var rejected = false
        history.onImageRejected = { rejected = true }

        XCTAssertFalse(history.insertImage(makeImage(cost: 2_000_000, digest: "big")))
        XCTAssertTrue(rejected)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPinnedImageSurvivesBudgetAndClear() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10,
                                       secureInput: { false }, imageBudgetMB: 1)
        XCTAssertTrue(history.insertImage(makeImage(cost: 400_000, digest: "keep")))
        let pinned = try XCTUnwrap(history.entries.first)
        history.togglePin(pinned.id)
        XCTAssertTrue(history.entries[0].isPinned)

        XCTAssertTrue(history.insertImage(makeImage(cost: 400_000, digest: "b")))
        XCTAssertTrue(history.insertImage(makeImage(cost: 400_000, digest: "c")))
        XCTAssertTrue(history.insertImage(makeImage(cost: 400_000, digest: "d")))

        XCTAssertTrue(history.entries.contains { $0.image?.digest == "keep" },
                      "a pinned image is never evicted by the budget")
        history.clear()
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.image?.digest, "keep")
        history.clear(includingPins: true)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPinnedEntriesSurviveTheCountLimit() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 2,
                                       secureInput: { false }, imageBudgetMB: 1)
        history.insert("keep")
        history.togglePin(history.entries[0].id)
        history.insert("b")
        history.insert("c")

        XCTAssertEqual(history.entries.map(\.text), ["c", "keep"])
        XCTAssertEqual(history.pinnedCount, 1)
    }

    func testPromoteKeepsTheImageAndItsPin() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10,
                                       secureInput: { false }, imageBudgetMB: 1)
        let image = makeImage(cost: 100, digest: "a")
        XCTAssertTrue(history.insertImage(image))
        history.togglePin(history.entries[0].id)
        history.insert("newer")

        let older = try XCTUnwrap(history.entries.last)
        history.promote(older)
        XCTAssertEqual(history.entries.first?.image?.digest, "a")
        XCTAssertTrue(history.entries.first?.isPinned == true)
    }

    func testDisablingImagesDropsUnpinnedButKeepsPins() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10,
                                       secureInput: { false }, imageBudgetMB: 1)
        XCTAssertTrue(history.insertImage(makeImage(cost: 100, digest: "keep")))
        history.togglePin(history.entries[0].id)
        XCTAssertTrue(history.insertImage(makeImage(cost: 100, digest: "drop")))

        history.configure(keepsImages: false, budgetMB: 32)
        XCTAssertEqual(history.entries.map { $0.image?.digest }, ["keep"])
        XCTAssertFalse(history.keepsImages)
    }

    func testTextWinsWhenThePasteboardHasTextAndAnImage() throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10,
                                       secureInput: { false }, imageBudgetMB: 1)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("caption", forType: .string))
        XCTAssertTrue(pasteboard.setData(pngData(), forType: .png))
        history.poll()

        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.text, "caption")
        XCTAssertNil(history.entries.first?.image)
    }

    func testPollCollectsACopiedImage() async throws {
        let pasteboard = try makePasteboard()
        let history = ClipboardHistory(pasteboard: pasteboard, limit: 10,
                                       secureInput: { false }, imageBudgetMB: 1)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData(), forType: .png))

        let collected = expectation(description: "image collected")
        history.onChange = { collected.fulfill() }
        history.poll()
        await fulfillment(of: [collected], timeout: 3)

        XCTAssertEqual(history.entries.count, 1)
        let image = try XCTUnwrap(history.entries.first?.image)
        XCTAssertEqual(image.pixelWidth, 10)
        XCTAssertEqual(image.pixelHeight, 10)
        XCTAssertEqual(image.type, .png)
        XCTAssertEqual(history.entries.first?.preview, "Image 10 × 10")
    }

    func testImagePreviewAndDetail() {
        let entry = ClipboardEntry(image: makeImage(cost: 2_000_000, digest: "x"),
                                   date: Date())
        XCTAssertEqual(entry.text, "")
        XCTAssertEqual(entry.preview, "Image 40 × 20")
        XCTAssertTrue(entry.detail.hasPrefix("40 × 20 · "))
        XCTAssertNotNil(entry.image)
        guard case .storedImage = entry.previewKind else {
            return XCTFail("expected a stored image preview")
        }
    }

    // MARK: - Writing back to the pasteboard (U3)

    func testWriterPutsTextOnThePasteboard() {
        let pasteboard = try? makePasteboard()
        guard let pasteboard else { return XCTFail("no pasteboard") }
        let entry = ClipboardEntry(text: "written", date: Date())

        XCTAssertTrue(ClipboardPasteboardWriter.write(entry, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "written")
    }

    func testWriterPutsTheImageBytesAndTypeOnThePasteboard() {
        let pasteboard = try? makePasteboard()
        guard let pasteboard else { return XCTFail("no pasteboard") }
        let data = pngData(width: 8, height: 8)
        let entry = ClipboardEntry(image: makeImage(data: data, cost: data.count, digest: "png"),
                                   date: Date())

        XCTAssertTrue(ClipboardPasteboardWriter.write(entry, to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), data)
    }

    // MARK: - Row previews (T36)

    func testColourTextsAreRecognisedForTheSwatch() {
        guard case let .color(hex) = ClipboardPreview(text: " #a1b2c3 ") else {
            return XCTFail("expected a colour preview")
        }
        XCTAssertEqual(hex.hex, "#A1B2C3")
        guard case .color = ClipboardPreview(text: "hsl(210, 50%, 33%)") else {
            return XCTFail("expected an HSL colour preview")
        }
        guard case .color = ClipboardPreview(text: "rgba(10, 20, 30, 0.5)") else {
            return XCTFail("expected an RGBA colour preview")
        }
    }

    func testImagePathsAreRecognisedForTheThumbnail() {
        guard case let .image(url) = ClipboardPreview(text: "/Users/example/Desktop/Shot.png") else {
            return XCTFail("expected an image preview")
        }
        XCTAssertEqual(url.lastPathComponent, "Shot.png")
        guard case let .image(tilde) = ClipboardPreview(text: "~/Pictures/photo.jpeg") else {
            return XCTFail("expected a tilde image preview")
        }
        XCTAssertFalse(tilde.path.hasPrefix("~"))
        guard case let .image(fileURL) = ClipboardPreview(text: "file:///tmp/capture.heic") else {
            return XCTFail("expected a file URL preview")
        }
        XCTAssertEqual(fileURL.path, "/tmp/capture.heic")
    }

    func testOrdinaryTextAndRemoteLinksStayText() {
        XCTAssertEqual(ClipboardPreview(text: "hello"), .text)
        XCTAssertEqual(ClipboardPreview(text: "https://example.com/photo.png"), .text)
        XCTAssertEqual(ClipboardPreview(text: "/tmp/notes.txt"), .text)
        XCTAssertEqual(ClipboardPreview(text: ""), .text)
    }

    func testEntryExposesThePreviewKind() {
        let entry = ClipboardEntry(id: UUID(), text: "#00FF00", date: Date())
        XCTAssertEqual(entry.previewKind, .color(SampledColor(red: 0, green: 255, blue: 0)))
    }
}
