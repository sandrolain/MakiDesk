import XCTest
@testable import MakiDesk

/// T44: which dropzone accepts what. Pure matching: no pasteboard, no files.
final class DropzoneMatcherTests: XCTestCase {
    private func zone(_ accepts: DropzoneAccept,
                      enabled: Bool = true) -> DropzoneConfig {
        DropzoneConfig(name: "Zone", enabled: enabled, accepts: accepts,
                       command: CommandSpec(line: "echo hi"))
    }

    private func file(_ name: String, _ uti: String?) -> DropItemInfo {
        DropItemInfo(kind: .file, uti: uti, name: name)
    }

    func testAnyImageFileMatchesAnImagesOnlyZone() {
        let match = DropzoneMatcher.match(
            [file("photo.png", "public.png")],
            zone: zone(DropzoneAccept(kinds: [.files], utis: ["public.image"])))
        XCTAssertTrue(match.isAccepted)
        XCTAssertEqual(match.acceptedItems.count, 1)
    }

    func testAPDFDoesNotMatchAnImagesOnlyZone() {
        let match = DropzoneMatcher.match(
            [file("contract.pdf", "com.adobe.pdf")],
            zone: zone(DropzoneAccept(kinds: [.files], utis: ["public.image"])))
        guard case let .rejected(reason) = match else { return XCTFail("expected a rejection") }
        XCTAssertEqual(reason, .wrongType("contract.pdf"))
    }

    func testFoldersMatchPublicFolder() {
        let folder = file("Archive", "public.folder")
        let accepted = DropzoneMatcher.match([folder],
                                             zone: zone(DropzoneAccept(kinds: [.files], utis: ["public.folder"])))
        XCTAssertTrue(accepted.isAccepted)

        let rejected = DropzoneMatcher.match([folder],
                                             zone: zone(DropzoneAccept(kinds: [.files], utis: ["public.image"])))
        XCTAssertFalse(rejected.isAccepted)
    }

    func testNoDeclaredTypesAcceptsAnyFileIncludingAnUnknownOne() {
        let match = DropzoneMatcher.match([file("mystery", nil)],
                                          zone: zone(DropzoneAccept(kinds: [.files], utis: [])))
        XCTAssertTrue(match.isAccepted)
    }

    func testDeclaredTypesRejectAnUnknownFileType() {
        let match = DropzoneMatcher.match([file("mystery", nil)],
                                          zone: zone(DropzoneAccept(kinds: [.files], utis: ["public.image"])))
        guard case let .rejected(reason) = match else { return XCTFail("expected a rejection") }
        XCTAssertEqual(reason, .unknownType("mystery"))
    }

    func testTextAndLinksFollowTheKinds() {
        let text = DropItemInfo(kind: .text, name: "text")
        let url = DropItemInfo(kind: .url, name: "link")

        XCTAssertTrue(DropzoneMatcher.match([text], zone: zone(DropzoneAccept(kinds: [.text])))
            .isAccepted)
        XCTAssertTrue(DropzoneMatcher.match([url], zone: zone(DropzoneAccept(kinds: [.urls])))
            .isAccepted)
        XCTAssertFalse(DropzoneMatcher.match([text], zone: zone(DropzoneAccept(kinds: [.urls])))
            .isAccepted)
    }

    func testImagesFollowTheImageKindAndDeclaredTypes() {
        let image = DropItemInfo(kind: .image, name: "clipboard image")
        XCTAssertTrue(DropzoneMatcher.match([image], zone: zone(DropzoneAccept(kinds: [.images])))
            .isAccepted)
        XCTAssertTrue(DropzoneMatcher.match(
            [image], zone: zone(DropzoneAccept(kinds: [.images], utis: ["public.image"])))
            .isAccepted)
    }

    func testAllRequiresEveryItem() {
        let imagesOnly = zone(DropzoneAccept(kinds: [.files], utis: ["public.image"], match: .all))
        let mixed = [file("photo.png", "public.png"), file("notes.txt", "public.plain-text")]
        guard case let .rejected(reason) = DropzoneMatcher.match(mixed, zone: imagesOnly) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(reason, .wrongType("notes.txt"))
    }

    func testAnyPassesOnlyTheCompatibleItems() {
        let imagesOnly = zone(DropzoneAccept(kinds: [.files], utis: ["public.image"], match: .any))
        let mixed = [file("photo.png", "public.png"), file("notes.txt", "public.plain-text")]
        let match = DropzoneMatcher.match(mixed, zone: imagesOnly)
        XCTAssertEqual(match.acceptedItems.map(\.name), ["photo.png"])
    }

    func testCountLimitsApplyToTheItemsTheCommandReceives() {
        let files = [file("a.png", "public.png"), file("b.png", "public.png"), file("c.png", "public.png")]

        XCTAssertEqual(DropzoneMatcher.match(files,
                                             zone: zone(DropzoneAccept(kinds: [.files], maxItems: 2))),
                       .rejected(.tooMany(2)))
        XCTAssertEqual(DropzoneMatcher.match(files,
                                             zone: zone(DropzoneAccept(kinds: [.files], minItems: 4))),
                       .rejected(.tooFew(4)))

        // The text file is incompatible and is not counted: if it were, three
        // items against a maximum of two would reject the drop.
        let anyZone = zone(DropzoneAccept(kinds: [.files], utis: ["public.image"],
                                          match: .any, maxItems: 2))
        let mixed = [file("a.png", "public.png"), file("b.png", "public.png"),
                     file("notes.txt", "public.plain-text")]
        XCTAssertEqual(DropzoneMatcher.match(mixed, zone: anyZone).acceptedItems.count, 2)
    }

    func testDisabledZoneRejectsEverything() {
        XCTAssertEqual(DropzoneMatcher.match([file("a.png", "public.png")],
                                             zone: zone(DropzoneAccept(), enabled: false)),
                       .rejected(.disabled))
    }

    func testInvalidUTIInTheConfigurationRejectsInsteadOfCrashing() {
        let unhealthy = zone(DropzoneAccept(kinds: [.files], utis: ["not a uti"]))
        guard case let .rejected(reason) = DropzoneMatcher.match([file("a.png", "public.png")],
                                                                 zone: unhealthy) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(reason, .invalidConfiguration("not a uti is not a UTI"))
    }

    func testEmptyPayloadIsRejected() {
        XCTAssertEqual(DropzoneMatcher.match([], zone: zone(DropzoneAccept())),
                       .rejected(.emptyPayload))
    }

    func testNoAcceptedKindsIsAnInvalidConfiguration() {
        let unhealthy = zone(DropzoneAccept(kinds: []))
        guard case let .rejected(reason) = DropzoneMatcher.match([file("a.png", "public.png")],
                                                                 zone: unhealthy) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(reason, .invalidConfiguration("no accepted kinds"))
    }

    // MARK: - Payload preview (T47)

    func testSummaryCountsEveryKindWithPluralNames() {
        let items = [
            DropItemInfo(kind: .file, name: "a", index: 0),
            DropItemInfo(kind: .file, name: "b", index: 1),
            DropItemInfo(kind: .image, name: "c", index: 2),
            DropItemInfo(kind: .text, name: "Text", index: 3),
        ]
        XCTAssertEqual(DropzoneMatcher.summary(for: items), "2 files · 1 image · 1 text")
        XCTAssertEqual(DropzoneMatcher.summary(for: [DropItemInfo(kind: .url, index: 0)]), "1 link")
        XCTAssertEqual(DropzoneMatcher.summary(for: []), "")
    }
}
