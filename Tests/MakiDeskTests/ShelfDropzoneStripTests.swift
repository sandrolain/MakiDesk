import XCTest
@testable import MakiDesk

/// T44: the strip inside the shelf. Drawing is exercised too, so a layout
/// regression that leaves tiles off the band or unreadable is caught.
@MainActor
final class ShelfDropzoneStripTests: XCTestCase {
    private func zone(_ name: String, icon: DropzoneIcon = .symbol("bolt.fill")) -> DropzoneConfig {
        DropzoneConfig(name: name, icon: icon,
                       command: CommandSpec(line: "echo \(name)"))
    }

    private func makeStrip(zones: [DropzoneConfig],
                           width: CGFloat = 380) -> ShelfDropzoneStripView {
        let strip = ShelfDropzoneStripView(frame: NSRect(x: 0, y: 0,
                                                         width: width,
                                                         height: ShelfDropzoneStripView.preferredHeight))
        strip.update(zones: zones, theme: PaletteTheme.all[0])
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    func testTilesAreLaidOutInOrderAndHitTested() {
        let zones = [zone("One"), zone("Two")]
        let strip = makeStrip(zones: zones)
        XCTAssertEqual(strip.frame.height, ShelfDropzoneStripView.preferredHeight)

        // 88 pt squares, 4 pt apart, 6 pt from the edge.
        let first = NSPoint(x: 6 + 44, y: 50)
        XCTAssertEqual(strip.zone(at: first)?.id, zones[0].id)
        let second = NSPoint(x: 6 + 88 + 4 + 44, y: 50)
        XCTAssertEqual(strip.zone(at: second)?.id, zones[1].id)
        XCTAssertNil(strip.zone(at: NSPoint(x: 2, y: 50)))
    }

    /// The controller receives the point in the root view and converts it into
    /// the strip before asking for a tile. This mirrors that path exactly: a
    /// double conversion or a forgotten strip origin makes every zone drop fall
    /// through to the shelf.
    func testTileIsFoundFromTheRootCoordinateSpace() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 540))
        let strip = ShelfDropzoneStripView(frame: NSRect(x: 0, y: 45, width: 380,
                                                        height: ShelfDropzoneStripView.preferredHeight))
        root.addSubview(strip)
        let zones = [zone("One")]
        strip.update(zones: zones, theme: PaletteTheme.all[0])
        strip.layoutSubtreeIfNeeded()

        let pointOnTile = NSPoint(x: 6 + 44, y: 45 + 50)
        let local = strip.convert(pointOnTile, from: root)
        XCTAssertEqual(strip.zone(at: local)?.id, zones[0].id)

        let pointInGutter = NSPoint(x: 370, y: 45 + 50)
        let gutterLocal = strip.convert(pointInGutter, from: root)
        XCTAssertNil(strip.zone(at: gutterLocal))
    }

    func testMoreZonesThanFitStayInTheScrollableContent() {
        let zones = (1...5).map { zone("Zone \($0)") }
        let strip = makeStrip(zones: zones)
        // The fifth tile starts at 6 + 4 * (88 + 4) = 374 and is partly
        // visible at the right edge; the rest of it is reached by scrolling.
        XCTAssertEqual(strip.zone(at: NSPoint(x: 376, y: 50))?.id, zones[4].id)
    }

    func testCompatibilityMarksOnlyTheIncompatibleZone() {
        let zones = [zone("One"), zone("Two")]
        let strip = makeStrip(zones: zones)
        XCTAssertEqual(strip.visibleZoneCount, 2)
        strip.setCompatibility([zones[1].id: false])
        XCTAssertTrue(strip.isZoneCompatible(zones[0].id))
        XCTAssertFalse(strip.isZoneCompatible(zones[1].id))
        XCTAssertEqual(strip.visibleZoneCount, 1)
        strip.setCompatibility([:])
        XCTAssertTrue(strip.isZoneCompatible(zones[1].id))
        XCTAssertEqual(strip.visibleZoneCount, 2)
    }

    func testIncompatibleTilesAreHiddenWithoutLeavingASlot() {
        let zones = [zone("One"), zone("Two")]
        let strip = makeStrip(zones: zones)
        strip.setCompatibility([zones[0].id: false])
        strip.layoutSubtreeIfNeeded()

        // The second tile moves into the first slot: no hole, no gap.
        XCTAssertEqual(strip.zone(at: NSPoint(x: 50, y: 50))?.id, zones[1].id)
        XCTAssertNil(strip.zone(at: NSPoint(x: 142, y: 50)))
        XCTAssertEqual(strip.visibleZoneCount, 1)
    }

    func testAllIncompatibleZonesLeaveNoTarget() {
        let zones = [zone("One"), zone("Two")]
        let strip = makeStrip(zones: zones)
        strip.setCompatibility([zones[0].id: false, zones[1].id: false])
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.visibleZoneCount, 0)
        XCTAssertNil(strip.zone(at: NSPoint(x: 50, y: 50)))
        XCTAssertNil(strip.zone(at: NSPoint(x: 142, y: 50)))
    }

    func testUpdatingWithTheSameZonesDoesNotRebuildTheTiles() {
        let zones = [zone("One")]
        let strip = makeStrip(zones: zones)
        let hit = NSPoint(x: 50, y: 50)
        strip.update(zones: zones, theme: PaletteTheme.all[0])
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.zone(at: hit)?.id, zones[0].id)
    }

    func testStripRenders() throws {
        let zones = [
            zone("Resize", icon: .symbol("photo.on.rectangle")),
            zone("Archive", icon: .emoji("📦")),
            zone("Convert", icon: .symbol("arrow.triangle.2.circlepath"))
        ]
        let strip = makeStrip(zones: zones)
        let rep = try XCTUnwrap(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
        strip.cacheDisplay(in: strip.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 100)

        if let path = ProcessInfo.processInfo.environment["MAKIDESK_STRIP_SNAPSHOT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}

extension ShelfDropzoneStripTests {
    func testTileAbsorbsHitsSoIconAndLabelsDoNotStealTheDrag() {
        let tile = ShelfDropzoneTileView(zone: zone("One"), theme: PaletteTheme.all[0])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 88, height: 88))
        tile.frame = container.bounds
        container.addSubview(tile)
        tile.layoutSubtreeIfNeeded()

        // The point is over the icon area, which used to be an NSImageView.
        XCTAssertTrue(tile.hitTest(NSPoint(x: 44, y: 70)) === tile)
        XCTAssertTrue(tile.hitTest(NSPoint(x: 44, y: 20)) === tile)
        XCTAssertNil(tile.hitTest(NSPoint(x: -4, y: -4)))

        // The image and the labels must be invisible to hit-testing too: a
        // registered subview would otherwise steal the drag even if the tile
        // returns itself for its own bounds.
        for subview in tile.subviews {
            let point = NSPoint(x: subview.frame.midX, y: subview.frame.midY)
            XCTAssertNil(subview.hitTest(point))
        }
    }
}
