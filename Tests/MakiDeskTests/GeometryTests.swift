import XCTest
import AppKit
@testable import MakiDesk

@MainActor
final class GeometryTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let minor = 1 - 1 / TilingEngine.phi

    func testLadderHasSevenStates() {
        let rects = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 0...600)
        XCTAssertEqual(rects.count, 7)
    }

    func testHorizontalLadderFractions() {
        let rects = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 0...600)
        XCTAssertEqual(rects[0].minX, 0, accuracy: 0.5)
        XCTAssertEqual(rects[0].width, minor * area.width, accuracy: 0.5)
        XCTAssertEqual(rects[2].width, area.width / TilingEngine.phi, accuracy: 0.5)
        XCTAssertEqual(rects[3].width, area.width, accuracy: 0.5)
        XCTAssertEqual(rects[6].maxX, area.width, accuracy: 0.5)
        XCTAssertEqual(rects[6].width, minor * area.width, accuracy: 0.5)
    }

    func testLadderKeepsOrthogonalBand() {
        let rects = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 100...400)
        for rect in rects {
            XCTAssertEqual(rect.minY, 100, accuracy: 0.01)
            XCTAssertEqual(rect.height, 300, accuracy: 0.01)
        }
    }

    func testVerticalLadderFitsHeight() {
        let rects = TilingEngine.ladderRects(area: area, axis: .vertical, orthogonal: 0...1000)
        XCTAssertEqual(rects[0].height, minor * area.height, accuracy: 0.5)
        XCTAssertEqual(rects[3].height, area.height, accuracy: 0.5)
        for rect in rects {
            XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
            XCTAssertEqual(rect.width, area.width, accuracy: 0.01)
        }
    }

    func testPendingFrameIsUsedWhenAXStillReportsPreviousVerticalSize() {
        let states = TilingEngine.ladderRects(area: area, axis: .vertical, orthogonal: 0...1000)
        let staleAXFrame = states[2]
        let latestRequestedFrame = states[3]

        let current = WorkspaceStore.tilingFrame(actual: staleAXFrame, pending: latestRequestedFrame)

        XCTAssertEqual(TilingEngine.slot(of: current, area: area, axis: .vertical, states: states), .step(3))
        XCTAssertEqual(WorkspaceStore.tilingFrame(actual: staleAXFrame, pending: nil), staleAXFrame)
    }

    func testMovingBetweenDisplaysPreservesCurrentSizeWhenItFits() {
        let current = CGSize(width: 1496, height: 405)
        let destination = CGRect(x: 0, y: 0, width: 1512, height: 1050)

        XCTAssertEqual(TilingEngine.sizeFitting(current, in: destination), current)
    }

    func testMovingBetweenDisplaysClampsOnlyWhenDestinationIsSmaller() {
        let current = CGSize(width: 1800, height: 1200)
        let destination = CGRect(x: 0, y: 0, width: 1512, height: 1050)

        XCTAssertEqual(TilingEngine.sizeFitting(current, in: destination), CGSize(width: 1512, height: 1050))
    }

    func testEdgeSlotPicksNearestHalfOrGoldenBand() {
        let start = TilingEngine.edgeSlot(at: 0.1)
        XCTAssertEqual(start.anchor, .start)
        XCTAssertEqual(start.fraction, minor, accuracy: 0.001)

        let half = TilingEngine.edgeSlot(at: 0.25)
        XCTAssertEqual(half.anchor, .start)
        XCTAssertEqual(half.fraction, 0.5, accuracy: 0.001)

        let full = TilingEngine.edgeSlot(at: 0.5)
        XCTAssertEqual(full.fraction, 1.0, accuracy: 0.001)

        let end = TilingEngine.edgeSlot(at: 0.9)
        XCTAssertEqual(end.anchor, .end)
        XCTAssertEqual(end.fraction, minor, accuracy: 0.001)
    }

    func testDragZoneSnapsToNearestPosition() {
        // Left-centre -> left golden band, full height.
        let left = TilingEngine.dragZone(area: area, point: CGPoint(x: 100, y: 300))
        XCTAssertEqual(left.minX, 0, accuracy: 0.5)
        XCTAssertEqual(left.width, minor * area.width, accuracy: 1)
        XCTAssertEqual(left.minY, 0, accuracy: 0.5)
        XCTAssertEqual(left.height, area.height, accuracy: 0.5)

        // Centre -> full screen.
        let full = TilingEngine.dragZone(area: area, point: CGPoint(x: 500, y: 300))
        XCTAssertEqual(full, area)

        // Top-left -> top-left golden quarter (full-height/width not chosen).
        let corner = TilingEngine.dragZone(area: area, point: CGPoint(x: 100, y: 60))
        XCTAssertEqual(corner.minX, 0, accuracy: 0.5)
        XCTAssertEqual(corner.minY, 0, accuracy: 0.5)
        XCTAssertLessThan(corner.width, area.width)
        XCTAssertLessThan(corner.height, area.height)

        // Far right -> right golden band.
        let right = TilingEngine.dragZone(area: area, point: CGPoint(x: 900, y: 300))
        XCTAssertEqual(right.maxX, area.width, accuracy: 0.5)
        XCTAssertEqual(right.width, minor * area.width, accuracy: 1)
    }

    func testDragAtTheEdgeStaysOnTheBand() {
        // Dragging to the very left stops at the first golden band: MakiDesk
        // never parks a window off the edge (T19).
        let edge = TilingEngine.dragZone(area: area, point: CGPoint(x: 0, y: 300))
        XCTAssertEqual(edge.minX, 0, accuracy: 0.5)
        XCTAssertEqual(edge.width, minor * area.width, accuracy: 1)
        // And the pointer outside the area clamps to the same band.
        let outside = TilingEngine.dragZone(area: area, point: CGPoint(x: -200, y: 300))
        XCTAssertEqual(outside, edge)
    }

    func testDragActivatorNeverNeedsControl() {
        // The offered activators match their own modifiers.
        XCTAssertTrue(DragActivator.option.matches([.option]))
        XCTAssertTrue(DragActivator.optionShift.matches([.option, .shift]))
        XCTAssertTrue(DragActivator.optionCommand.matches([.option, .command]))
        XCTAssertTrue(DragActivator.commandShift.matches([.command, .shift]))
        XCTAssertTrue(DragActivator.shift.matches([.shift]))
        XCTAssertTrue(DragActivator.command.matches([.command]))

        // None of them fire on ⌃⌥ (which would open context menus)…
        XCTAssertFalse(DragActivator.option.matches([.control, .option]))
        XCTAssertFalse(DragActivator.optionShift.matches([.control, .option]))
        XCTAssertFalse(DragActivator.optionCommand.matches([.control, .option, .command]))
        XCTAssertFalse(DragActivator.commandShift.matches([.control, .command, .shift]))

        // …and none require Control.
        for activator in DragActivator.allCases {
            XCTAssertFalse(activator.matches([.control]))
        }
    }

    func testDefaultDragActivatorIsPlainOption() {
        // Option is the replacement for the macOS "hold ⌥ to tile" gesture…
        XCTAssertEqual(DragActivator.fallback, .option)
        XCTAssertTrue(DragActivator.fallback.usesOption)
        // …while the non-Option activators do not overlap with macOS tiling.
        XCTAssertFalse(DragActivator.commandShift.usesOption)
        XCTAssertFalse(DragActivator.shift.usesOption)
        XCTAssertFalse(DragActivator.command.usesOption)
    }

    func testNearestIndexSnapsToExactState() {
        let rects = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 0...600)
        for (index, rect) in rects.enumerated() {
            XCTAssertEqual(TilingEngine.nearestIndex(to: rect, among: rects), index)
        }
    }

    func testRegionRectNormalised() {
        let rect = TilingEngine.regionRect(area: area, relative: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(rect, CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    func testPalettePositions() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(PalettePosition.topLeft.origin(size: size, in: frame), CGPoint(x: 24, y: 676))
        XCTAssertEqual(PalettePosition.topRight.origin(size: size, in: frame), CGPoint(x: 776, y: 676))
        XCTAssertEqual(PalettePosition.center.origin(size: size, in: frame), CGPoint(x: 400, y: 350))
        XCTAssertEqual(PalettePosition.bottomLeft.origin(size: size, in: frame), CGPoint(x: 24, y: 24))
    }

    func testThemeLookup() {
        XCTAssertEqual(PaletteTheme.named("plum").name, "Plum")
        XCTAssertEqual(PaletteTheme.named("does-not-exist").id, PaletteTheme.all[0].id)
        XCTAssertFalse(PaletteTheme.named("mocha").background == PaletteTheme.named("latte").background)
    }

    // MARK: - Explicit ladder slots (A7)

    func testHorizontalSlotDetectsWindowsPushedOffTheScreen() {
        let states = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 0...600)
        let offLeft = CGRect(x: -500, y: 0, width: 500, height: 600)
        let offRight = CGRect(x: 1000, y: 0, width: 500, height: 600)
        XCTAssertEqual(TilingEngine.slot(of: offLeft, area: area, axis: .horizontal, states: states), .beforeStart)
        XCTAssertEqual(TilingEngine.slot(of: offRight, area: area, axis: .horizontal, states: states), .afterEnd)
    }

    func testVerticalSlotDetectsMinimumAndMinimised() {
        let states = TilingEngine.ladderRects(area: area, axis: .vertical, orthogonal: 0...1000)
        let minimum = CGRect(x: 0, y: 0, width: 1000, height: TilingEngine.minimumHeight)
        let belowScreen = CGRect(x: 0, y: 600, width: 1000, height: 300)
        XCTAssertEqual(TilingEngine.slot(of: minimum, area: area, axis: .vertical, states: states), .beforeStart)
        XCTAssertEqual(TilingEngine.slot(of: belowScreen, area: area, axis: .vertical, states: states), .afterEnd)
    }

    func testSlotFindsExactState() {
        let states = TilingEngine.ladderRects(area: area, axis: .horizontal, orthogonal: 0...600)
        for (index, rect) in states.enumerated() {
            XCTAssertEqual(TilingEngine.slot(of: rect, area: area, axis: .horizontal, states: states), .step(index))
        }
    }

    func testSlotSteppingClampsAtBothEnds() {
        XCTAssertEqual(TilingEngine.LadderSlot.beforeStart.advanced(by: -1), .beforeStart)
        XCTAssertEqual(TilingEngine.LadderSlot.beforeStart.advanced(by: 1), .step(0))
        XCTAssertEqual(TilingEngine.LadderSlot.step(0).advanced(by: -1), .beforeStart)
        XCTAssertEqual(TilingEngine.LadderSlot.step(6).advanced(by: 1), .afterEnd)
        XCTAssertEqual(TilingEngine.LadderSlot.afterEnd.advanced(by: -1), .step(6))
        XCTAssertEqual(TilingEngine.LadderSlot.afterEnd.advanced(by: 1), .afterEnd)
    }

    // MARK: - Shared snapping (A5)

    func testSnappedUsesLadderFractions() {
        XCTAssertEqual(TilingEngine.snapped(500, total: 1000), 500, accuracy: 0.01)
        XCTAssertEqual(TilingEngine.snapped(620, total: 1000), 1000 / TilingEngine.phi, accuracy: 0.5)
        XCTAssertEqual(TilingEngine.snapped(999, total: 1000), 1000, accuracy: 0.01)
        XCTAssertEqual(TilingEngine.snapped(300, total: 1000), 300, accuracy: 0.01)
    }

    func testAppColorsAreStableAndDistinct() {
        let store = WorkspaceStore.shared
        let names = ["Safari", "Finder", "Terminal", "Xcode", "Slack",
                     "Notion", "Figma", "Mail", "Music", "Notes"]
        let colors = names.map { store.color(for: $0) }
        // The same app always maps to the same colour.
        for (index, name) in names.enumerated() {
            XCTAssertEqual(colors[index].description, store.color(for: name).description)
        }
        // Different apps get different colours.
        XCTAssertEqual(Set(colors.map { $0.description }).count, names.count)

        // ...and those colours are well separated (no clusters of similar
        // hues such as three near-identical yellows).
        let hues = colors.map { colour -> CGFloat in
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            (colour.usingColorSpace(.deviceRGB) ?? colour)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return hue
        }
        var minimumGap: CGFloat = 1
        for i in hues.indices {
            for j in hues.indices where j > i {
                let delta = abs(hues[i] - hues[j])
                minimumGap = min(minimumGap, min(delta, 1 - delta))
            }
        }
        // Evenly spaced wheel (12 steps) guarantees ~30° between open apps.
        XCTAssertGreaterThan(minimumGap, 0.06)
    }

    // MARK: - Auto layout geometry (T14)

    func testGoldenSpiralSlotsReproduceTheThreeWindowSpiral() {
        let slots = TilingEngine.goldenSpiralSlots(area: area, count: 3)
        XCTAssertEqual(slots.count, 3)
        let majorWidth = area.width / TilingEngine.phi
        let majorHeight = area.height / TilingEngine.phi

        // Left major column, full height.
        XCTAssertEqual(slots[0].minX, 0, accuracy: 0.01)
        XCTAssertEqual(slots[0].width, majorWidth, accuracy: 0.5)
        XCTAssertEqual(slots[0].height, area.height, accuracy: 0.01)
        // Top-right minor block.
        XCTAssertEqual(slots[1].minX, majorWidth, accuracy: 0.5)
        XCTAssertEqual(slots[1].minY, 0, accuracy: 0.01)
        XCTAssertEqual(slots[1].width, area.width - majorWidth, accuracy: 0.5)
        XCTAssertEqual(slots[1].height, majorHeight, accuracy: 0.5)
        // The last slot takes whatever is left (the original third position).
        XCTAssertEqual(slots[2].minX, majorWidth, accuracy: 0.5)
        XCTAssertEqual(slots[2].minY, majorHeight, accuracy: 0.5)
        XCTAssertEqual(slots[2].width, area.width - majorWidth, accuracy: 0.5)
        XCTAssertEqual(slots[2].height, area.height - majorHeight, accuracy: 0.5)
    }

    func testGoldenSpiralSlotsCapAtSixAndCoverTheArea() {
        let slots = TilingEngine.goldenSpiralSlots(area: area, count: 20)
        XCTAssertEqual(slots.count, TilingEngine.maxGoldenSpiralSlots)
        // The slots tile the area exactly (the last one absorbs the remainder).
        let covered = slots.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        XCTAssertEqual(covered, area.width * area.height, accuracy: 1)
        for slot in slots {
            XCTAssertGreaterThan(slot.width, 1)
            XCTAssertGreaterThan(slot.height, 1)
        }
    }

    func testGoldenSpiralSlotsAreMonotonicInSize() {
        // Later slots are never larger than earlier ones, so the biggest window
        // (highest entropy) lands in the biggest slot.
        let slots = TilingEngine.goldenSpiralSlots(area: area, count: 6)
        let areas = slots.map { $0.width * $0.height }
        XCTAssertEqual(areas, areas.sorted(by: >))
    }

    func testGridFramesCountAndSpacing() {
        let frames = TilingEngine.gridFrames(count: 5, in: area, gap: 12)
        XCTAssertEqual(frames.count, 5)
        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertLessThanOrEqual(frame.width, area.width)
            XCTAssertLessThanOrEqual(frame.height, area.height)
        }
        // 5 windows -> 3 columns, 2 rows; neighbours are one `gap` apart.
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 12, accuracy: 0.01)
        XCTAssertEqual(abs(frames[3].minY - frames[0].minY) - frames[0].height, 12, accuracy: 0.01)
        XCTAssertEqual(frames[0].minX, area.minX + 12, accuracy: 0.01)
    }

    // MARK: - Palette layout metrics (T12/T13)

    private func paletteMetrics(_ layout: PaletteLayout, count: Int,
                                columns: Int = 0, maxCardWidth: CGFloat = 250,
                                groupColumnWidth: CGFloat = 0,
                                actionColumnWidth: CGFloat = 0,
                                available: CGSize = CGSize(width: 1440, height: 900)) -> PaletteMetrics {
        PaletteLayoutEngine.metrics(itemCount: count, layout: layout,
                                    columns: columns, maxCardWidth: maxCardWidth, available: available,
                                    groupColumnWidth: groupColumnWidth,
                                    actionColumnWidth: actionColumnWidth)
    }

    func testFullScreenMetricsFitTheVisibleFrame() {
        let available = CGSize(width: 1440, height: 900)
        let metrics = paletteMetrics(.fullScreen, count: 8, available: available)
        XCTAssertEqual(metrics.panelSize.width, available.width, accuracy: 0.01)
        XCTAssertEqual(metrics.panelSize.height, available.height, accuracy: 0.01)
        let gridWidth = metrics.gridWidth + 2 * metrics.padding
        let gridHeight = metrics.gridHeight + 2 * metrics.padding + metrics.chrome
        XCTAssertLessThanOrEqual(gridWidth, available.width + 1)
        XCTAssertLessThanOrEqual(gridHeight, available.height + 1)
        // Never wider than the configured maximum, and the text grows a little.
        XCTAssertLessThanOrEqual(metrics.cardWidth, 250 + 0.01)
        XCTAssertGreaterThan(metrics.fontSize, 12)
    }

    func testApplicationShelfGrowsTheCompactPanelByItsHeight() {
        let available = CGSize(width: 1440, height: 900)
        let without = paletteMetrics(.compact, count: 4,
                                     groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                     available: available)
        let withShelf = PaletteLayoutEngine.metrics(
            itemCount: 4, layout: .compact, columns: 0, maxCardWidth: 250,
            available: available, groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
            showsApplicationShelf: true
        )
        let shelf = PaletteLayoutEngine.applicationShelfHeight(for: .compact)
        XCTAssertEqual(withShelf.chrome - without.chrome, shelf, accuracy: 0.01)
        XCTAssertEqual(withShelf.panelSize.height - without.panelSize.height, shelf, accuracy: 0.01)
        XCTAssertEqual(withShelf.panelSize.width, without.panelSize.width, accuracy: 0.01)
        // The compact panel grows by the shelf, so the window grid keeps its room.
        XCTAssertEqual(withShelf.gridAreaHeight, without.gridAreaHeight, accuracy: 0.01)
    }

    func testFullScreenApplicationShelfTakesItsRoomFromTheGrid() {
        let available = CGSize(width: 1440, height: 900)
        let without = paletteMetrics(.fullScreen, count: 8, available: available)
        let withShelf = PaletteLayoutEngine.metrics(
            itemCount: 8, layout: .fullScreen, columns: 0, maxCardWidth: 250,
            available: available, showsApplicationShelf: true
        )
        XCTAssertEqual(withShelf.panelSize, without.panelSize)
        XCTAssertEqual(withShelf.chrome - without.chrome,
                       PaletteLayoutEngine.applicationShelfHeight(for: .fullScreen),
                       accuracy: 0.01)
        XCTAssertEqual(withShelf.gridAreaHeight, without.gridAreaHeight
                       - PaletteLayoutEngine.applicationShelfHeight(for: .fullScreen),
                       accuracy: 0.01)
    }

    func testFullScreenGrowsTheGridToTheDisplay() {
        // A wide display gets more columns than the compact palette uses for the
        // same windows, so the grid does not float in the middle of the screen.
        let available = CGSize(width: 2560, height: 1080)
        let compact = paletteMetrics(.compact, count: 20, available: available)
        let full = paletteMetrics(.fullScreen, count: 20, available: available)
        XCTAssertGreaterThan(full.columns, compact.columns)
        XCTAssertLessThanOrEqual(full.columns, 20)
        // Cards stay within the user's maximum.
        XCTAssertLessThanOrEqual(full.cardWidth, 250 + 0.01)
        let gridWidth = full.gridWidth + 2 * full.padding
        XCTAssertLessThanOrEqual(gridWidth, available.width + 1)
    }

    func testAutomaticFullScreenColumnsPreferLargerCardsThenABalancedGrid() {
        // Raising the maximum buys bigger cards.
        let small = paletteMetrics(.fullScreen, count: 20, maxCardWidth: 250,
                                   available: CGSize(width: 2560, height: 1080))
        let large = paletteMetrics(.fullScreen, count: 20, maxCardWidth: 480,
                                   available: CGSize(width: 2560, height: 1080))
        XCTAssertGreaterThan(large.cardWidth, small.cardWidth)
        XCTAssertLessThanOrEqual(large.cardWidth, 480 + 0.01)
        // Equal-size candidates leave the last row as full as possible, so the
        // grid stays balanced instead of leaving a single card on its own row.
        let seven = paletteMetrics(.fullScreen, count: 7,
                                   groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                   available: CGSize(width: 2012, height: 1150))
        XCTAssertEqual(seven.columns, 4)
        XCTAssertEqual(seven.rows, 2)
    }

    func testFullScreenCardsAreNeverSmallerThanTheWindowedOnes() {
        // The larger canvas may add columns, but it must never shrink a card:
        // the full-screen palette keeps the windowed sizing as its floor.
        for available in [CGSize(width: 1440, height: 900),
                          CGSize(width: 2012, height: 1150),
                          CGSize(width: 2560, height: 1080)] {
            for maxCardWidth in [160.0, 250.0, 480.0] as [CGFloat] {
                for count in [1, 2, 5, 7, 9, 12, 19, 20, 25] {
                    let compact = paletteMetrics(.compact, count: count, maxCardWidth: maxCardWidth,
                                                 groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                                 available: available)
                    let full = paletteMetrics(.fullScreen, count: count, maxCardWidth: maxCardWidth,
                                              groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                              available: available)
                    XCTAssertGreaterThanOrEqual(full.cardWidth, compact.cardWidth * 0.95 - 0.5,
                                                "count \(count), max \(maxCardWidth), \(available)")
                }
            }
        }
    }

    func testFullScreenDoesNotCollapseToOneColumnWhenCardsReachTheMaximum() {
        // A single column divides the windows evenly, but it leaves a wide
        // display empty and grows the labels: the grid must spread instead.
        let available = CGSize(width: 2012, height: 1150)
        let metrics = paletteMetrics(.fullScreen, count: 19,
                                     groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                     available: available)
        XCTAssertGreaterThan(metrics.columns, 1)
        XCTAssertEqual(metrics.cardWidth, 250, accuracy: 0.5)
        XCTAssertLessThan(metrics.fontSize, 15)
        XCTAssertLessThanOrEqual(metrics.rows, 4)
        let usable = available.width - PaletteLayoutEngine.groupColumnWidth
            - 2 * metrics.padding - 1
        XCTAssertGreaterThan(metrics.gridWidth, usable * 0.5)
    }

    func testFullScreenGridAlwaysFitsTheWidth() {
        for available in [CGSize(width: 1440, height: 900),
                          CGSize(width: 2560, height: 1080),
                          CGSize(width: 1280, height: 1024),
                          CGSize(width: 1024, height: 768)] {
            for count in [1, 2, 5, 8, 12, 20, 40] {
                let metrics = paletteMetrics(.fullScreen, count: count,
                                             groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                             available: available)
                let gridWidth = metrics.gridWidth + 2 * metrics.padding
                    + PaletteLayoutEngine.groupColumnWidth
                XCTAssertLessThanOrEqual(gridWidth, available.width + 1,
                                         "count \(count) on \(available)")
                XCTAssertEqual(metrics.thumbnailWidth / metrics.thumbnailHeight,
                               max(0.5, available.width / available.height), accuracy: 0.01)
            }
        }
    }

    func testThumbnailBoxKeepsTheScreenProportions() {
        // The box must never be an over-wide or over-tall ribbon: its ratio is
        // the screen's own ratio, in both layouts and at any window count.
        for available in [CGSize(width: 1440, height: 900),
                          CGSize(width: 1512, height: 944),
                          CGSize(width: 2560, height: 1080),
                          CGSize(width: 1280, height: 1024)] {
            let aspect = available.width / available.height
            for layout in [PaletteLayout.compact, .fullScreen] {
                for count in [1, 2, 8, 20] {
                    let metrics = paletteMetrics(layout, count: count, available: available)
                    XCTAssertEqual(metrics.thumbnailWidth / metrics.thumbnailHeight, aspect, accuracy: 0.01,
                                   "\(layout) count \(count) on \(available)")
                }
            }
        }
    }

    func testThePanelAlwaysLeavesRoomForTheFieldAndTheFooter() {
        // The field and the footer are always present, in both modes, so their
        // height is part of every budget: the whole grid still fits the visible
        // frame on a full-screen palette.
        let available = CGSize(width: 1280, height: 800)
        let metrics = paletteMetrics(.fullScreen, count: 4, available: available)
        let gridHeight = metrics.gridHeight + 2 * metrics.padding + metrics.chrome
        XCTAssertLessThanOrEqual(gridHeight, available.height + 1)
        XCTAssertGreaterThan(metrics.chrome, 0)
    }

    // MARK: - Palette groups column (G3)

    func testGroupsColumnWidensTheCompactPanelByItsOwnWidth() {
        // With the cards already at their wanted size, the column is simply
        // added to the panel: it never overlaps the grid nor eats the screen.
        let available = CGSize(width: 1440, height: 900)
        let column = PaletteLayoutEngine.groupColumnWidth
        let without = paletteMetrics(.compact, count: 1, available: available)
        let with = paletteMetrics(.compact, count: 1, groupColumnWidth: column, available: available)
        XCTAssertEqual(with.columns, without.columns)
        XCTAssertEqual(with.cardWidth, without.cardWidth, accuracy: 0.01)
        XCTAssertEqual(with.panelSize.width - without.panelSize.width, column, accuracy: 0.01)
        XCTAssertLessThanOrEqual(with.panelSize.width, available.width)
    }

    func testGroupsColumnTakesItsWidthOffTheCardsOnANarrowScreen() {
        // On a screen too narrow to keep both the wanted cards and the column,
        // the cards shrink so the panel still fits the visible frame.
        let available = CGSize(width: 640, height: 800)
        let column = PaletteLayoutEngine.groupColumnWidth
        let without = paletteMetrics(.compact, count: 9, available: available)
        let with = paletteMetrics(.compact, count: 9, groupColumnWidth: column, available: available)
        XCTAssertEqual(with.columns, without.columns)
        XCTAssertLessThan(with.cardWidth, without.cardWidth)
        XCTAssertLessThanOrEqual(with.panelSize.width, available.width + 0.01)
    }

    // MARK: - Palette actions column (T63)

    func testTheTwoSideColumnsShareOneWidth() {
        XCTAssertEqual(PaletteLayoutEngine.groupColumnWidth,
                       PaletteLayoutEngine.actionColumnWidth, accuracy: 0.01)
        XCTAssertEqual(PaletteLayoutEngine.groupColumnWidth,
                       PaletteLayoutEngine.sideColumnWidth, accuracy: 0.01)
    }

    func testTheActionsColumnWidensTheCompactPanelByItsOwnWidth() {
        let available = CGSize(width: 1440, height: 900)
        let column = PaletteLayoutEngine.actionColumnWidth
        let without = paletteMetrics(.compact, count: 1, available: available)
        let with = paletteMetrics(.compact, count: 1, actionColumnWidth: column,
                                  available: available)
        XCTAssertEqual(with.columns, without.columns)
        XCTAssertEqual(with.cardWidth, without.cardWidth, accuracy: 0.01)
        XCTAssertEqual(with.panelSize.width - without.panelSize.width, column, accuracy: 0.01)
        // The footer is gone, so the panel is a little shorter than before: the
        // grid gets the room the keys used to take.
        XCTAssertLessThan(with.panelSize.height, 900)
    }

    func testTheActionsColumnTakesItsWidthOffTheCardsOnANarrowScreen() {
        let available = CGSize(width: 1000, height: 800)
        let column = PaletteLayoutEngine.actionColumnWidth
        let without = paletteMetrics(.compact, count: 9,
                                     groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                     available: available)
        let with = paletteMetrics(.compact, count: 9,
                                  groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                  actionColumnWidth: column, available: available)
        XCTAssertEqual(with.actionColumnWidth, column)
        XCTAssertLessThan(with.cardWidth, without.cardWidth)
        XCTAssertLessThanOrEqual(with.panelSize.width, available.width + 0.01)
        XCTAssertGreaterThanOrEqual(with.cardWidth, PaletteCardScale.floor)
    }

    func testBothColumnsFitTheFullScreenGrid() {
        let available = CGSize(width: 1440, height: 900)
        let with = paletteMetrics(.fullScreen, count: 12,
                                  groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                  actionColumnWidth: PaletteLayoutEngine.actionColumnWidth,
                                  available: available)
        XCTAssertEqual(with.panelSize.width, available.width, accuracy: 0.01)
        let used = with.gridWidth + 2 * with.padding
            + PaletteLayoutEngine.groupColumnWidth + PaletteLayoutEngine.actionColumnWidth + 2
        XCTAssertLessThanOrEqual(used, available.width + 1)
        XCTAssertGreaterThanOrEqual(with.cardWidth, PaletteCardScale.floor)
    }

    func testTheActionsColumnBecomesAnIconStripWhenTheCardsWouldShrink() {
        // Too narrow for the words: the column keeps its commands as icons and
        // the cards stay at their floor instead of being squeezed.
        let available = CGSize(width: 640, height: 700)
        let metrics = paletteMetrics(.compact, count: 9,
                                     groupColumnWidth: PaletteLayoutEngine.groupColumnWidth,
                                     actionColumnWidth: PaletteLayoutEngine.actionColumnWidth,
                                     available: available)
        XCTAssertEqual(metrics.actionColumnWidth,
                       PaletteLayoutEngine.compactActionColumnWidth, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(metrics.cardWidth, PaletteCardScale.floor)
        XCTAssertLessThanOrEqual(metrics.panelSize.width, available.width + 0.01)
    }

    func testTheActionsColumnIsNeverDropped() {
        for width in [640.0, 900.0, 1440.0] {
            let available = CGSize(width: width, height: 800)
            let metrics = paletteMetrics(.compact, count: 5,
                                         actionColumnWidth: PaletteLayoutEngine.actionColumnWidth,
                                         available: available)
            XCTAssertGreaterThan(metrics.actionColumnWidth, 0)
            XCTAssertGreaterThan(metrics.cardWidth, 0)
        }
    }

    func testGroupsColumnShrinksTheFullScreenGridNotThePanel() {
        // Full screen keeps covering the screen; only the grid area yields, and
        // the whole grid plus the column still fits the visible frame.
        let available = CGSize(width: 1440, height: 900)
        let column = PaletteLayoutEngine.groupColumnWidth
        let without = paletteMetrics(.fullScreen, count: 8, available: available)
        let with = paletteMetrics(.fullScreen, count: 8, groupColumnWidth: column, available: available)
        XCTAssertEqual(with.panelSize.width, without.panelSize.width, accuracy: 0.01)
        XCTAssertEqual(with.panelSize.height, without.panelSize.height, accuracy: 0.01)
        // The card yields to the cell the column leaves it (a slightly smaller
        // cell can mean a slightly smaller font, so the card is not compared to
        // the no-column case: it must fit its own cell, which is what matters).
        let cellWidth = (available.width - column - 2 * with.padding
            - CGFloat(with.columns - 1) * with.spacing) / CGFloat(with.columns)
        XCTAssertLessThanOrEqual(with.cardWidth, cellWidth + 0.01)
        let gridWidth = with.gridWidth + 2 * with.padding + column
        XCTAssertLessThanOrEqual(gridWidth, available.width + 1)
    }

    func testAutomaticColumnsFollowTheWindowCount() {
        XCTAssertEqual(PaletteLayoutEngine.automaticColumns(for: 2), 2)
        XCTAssertEqual(PaletteLayoutEngine.automaticColumns(for: 7), 3)
        XCTAssertEqual(PaletteLayoutEngine.automaticColumns(for: 16), 4)
        XCTAssertEqual(paletteMetrics(.compact, count: 7, columns: 0).columns, 3)
    }

    func testConfiguredColumnsAreUsedButNeverMoreThanWindows() {
        // A fixed count is honoured...
        XCTAssertEqual(paletteMetrics(.compact, count: 10, columns: 5).columns, 5)
        XCTAssertEqual(paletteMetrics(.fullScreen, count: 12, columns: 6).columns, 6)
        // ...but never more columns than there are windows to fill them.
        XCTAssertEqual(paletteMetrics(.compact, count: 3, columns: 5).columns, 3)
        XCTAssertEqual(paletteMetrics(.compact, count: 1, columns: 4).columns, 1)
    }

    func testMaxCardWidthCapsTheCardSize() {
        let small = paletteMetrics(.compact, count: 4, maxCardWidth: 200)
        let large = paletteMetrics(.compact, count: 4, maxCardWidth: 400)
        XCTAssertEqual(small.cardWidth, 200, accuracy: 0.01)
        XCTAssertEqual(large.cardWidth, 400, accuracy: 0.01)
        XCTAssertGreaterThan(large.thumbnailWidth, small.thumbnailWidth)
        // The compact panel is still capped to the screen.
        XCTAssertLessThanOrEqual(large.panelSize.width, 1400)
    }

    func testExcessiveColumnsShrinkTheCardsToFitTheWidth() {
        // Many columns on a small screen: cards must shrink below the configured
        // maximum so the whole grid still fits the screen's width.
        let available = CGSize(width: 1024, height: 768)
        let metrics = paletteMetrics(.compact, count: 56, columns: 8, maxCardWidth: 480, available: available)
        XCTAssertEqual(metrics.columns, 8)
        XCTAssertLessThan(metrics.cardWidth, 480)
        let gridWidth = metrics.gridWidth + 2 * metrics.padding
        XCTAssertLessThanOrEqual(gridWidth, available.width + 1)
    }

    // MARK: - Window groups (G0)

    private func identity(_ id: String, bundle: String?, app: String, title: String?,
                          document: String? = nil) -> WindowIdentity {
        WindowIdentity(id: id, bundleId: bundle, appName: app, title: title, document: document)
    }

    func testGroupMatcherPrefersTheExactSessionWindow() {
        let saved = WindowRef(identity: identity("271-cg9", bundle: "com.apple.Safari",
                                                 app: "Safari", title: "News"))
        // Two Safari windows; only the one with the matching runtime id is picked.
        let live = [
            identity("271-cg1", bundle: "com.apple.Safari", app: "Safari", title: "Shop"),
            identity("271-cg9", bundle: "com.apple.Safari", app: "Safari", title: "News"),
        ]
        XCTAssertEqual(GroupMatcher.match([saved], to: live).first!, 1)
    }

    func testGroupMatcherFallsBackToDocumentThenTitle() {
        let byDocument = WindowRef(identity: identity("1-cg1", bundle: "com.apple.Preview",
                                                      app: "Preview", title: "a.pdf",
                                                      document: "file:///tmp/report.pdf"))
        let byTitle = WindowRef(identity: identity("2-cg1", bundle: "com.apple.TextEdit",
                                                   app: "TextEdit", title: "notes.txt"))
        let live = [
            // Same app, same document, changed title.
            identity("9-cg4", bundle: "com.apple.Preview", app: "Preview", title: "report.pdf",
                     document: "file:///tmp/report.pdf"),
            identity("8-cg5", bundle: "com.apple.TextEdit", app: "TextEdit", title: "notes.txt"),
        ]
        let matches = GroupMatcher.match([byDocument, byTitle], to: live)
        XCTAssertEqual(matches[0], 0)
        XCTAssertEqual(matches[1], 1)
    }

    func testGroupMatcherNeverReusesAWindow() {
        // A stale duplicate reference cannot claim a sibling window after its
        // exact runtime identity has already been used.
        let ref = WindowRef(identity: identity("5-cg1", bundle: "com.apple.TextEdit",
                                               app: "TextEdit", title: "Untitled"))
        let live = [
            identity("5-cg1", bundle: "com.apple.TextEdit", app: "TextEdit", title: "Untitled"),
            identity("5-cg2", bundle: "com.apple.TextEdit", app: "TextEdit", title: "Untitled"),
        ]
        let matches = GroupMatcher.match([ref, ref], to: live)
        XCTAssertEqual(matches, [0, nil])
    }

    func testGroupMatcherLooseFallbackOnlyWhenUnambiguous() {
        // A single-member app may be re-found by app alone (title changed).
        let alone = WindowRef(identity: identity("7-cg1", bundle: "com.apple.Notes",
                                                 app: "Notes", title: "Old"))
        // A new process id signals that the saved runtime id is from an older
        // app session, so the single-member app fallback is safe.
        let live = [identity("8-cg9", bundle: "com.apple.Notes", app: "Notes", title: "Renamed")]
        XCTAssertEqual(GroupMatcher.match([alone], to: live).first!, 0)

        // Two members of the same app: no loose match, so the missing titles
        // leave both unmatched instead of both grabbing window 0.
        let a = WindowRef(identity: identity("3-cg1", bundle: "com.apple.Notes", app: "Notes", title: "A"))
        let b = WindowRef(identity: identity("3-cg2", bundle: "com.apple.Notes", app: "Notes", title: "B"))
        let matches = GroupMatcher.match([a, b], to: live)
        XCTAssertEqual(matches, [nil, nil])
    }

    func testWindowRefMatchesTheWindowItWasTakenFrom() {
        let ref = WindowRef(identity: identity("4-cg2", bundle: "com.apple.Safari",
                                               app: "Safari", title: "Docs"))
        XCTAssertTrue(ref.matches(ref))
        let sameTitleOtherWindow = WindowRef(identity: identity("4-cg7", bundle: "com.apple.Safari",
                                                                app: "Safari", title: "Docs"))
        XCTAssertFalse(ref.matches(sameTitleOtherWindow))
        let afterRestart = WindowRef(identity: identity("8-cg7", bundle: "com.apple.Safari",
                                                        app: "Safari", title: "Docs"))
        XCTAssertTrue(ref.matches(afterRestart))
        let other = WindowRef(identity: identity("4-cg8", bundle: "com.apple.Safari",
                                                 app: "Safari", title: "Mail"))
        XCTAssertFalse(ref.matches(other))
    }

    func testGroupGridFramesCoverEveryMember() {
        let frames = TilingEngine.gridFrames(count: 5, in: area, gap: 12)
        XCTAssertEqual(frames.count, 5)
        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
        // No two members land on the same cell.
        XCTAssertEqual(Set(frames.map { "\($0.minX)-\($0.minY)" }).count, 5)
    }

    // MARK: - Group recall layout (G1)

    func testGroupGridStrategyIsTheGridEngine() {
        // The group grid is exactly the tiler the keyboard uses, so a recall and
        // a manual tiling can never disagree.
        XCTAssertEqual(TilingEngine.frames(for: .grid, count: 5, in: area, gap: 12),
                       TilingEngine.gridFrames(count: 5, in: area, gap: 12))
    }

    func testGroupGridColumnsFollowTheMemberCount() {
        // 4 members -> 2 columns; 11 members -> 4 columns (ceil(sqrt)), so the
        // grid never degenerates into a single long row.
        let four = TilingEngine.frames(for: .grid, count: 4, in: area, gap: 12)
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(Set(four.map(\.minX)).count, 2)
        let eleven = TilingEngine.frames(for: .grid, count: 11, in: area, gap: 12)
        XCTAssertEqual(eleven.count, 11)
        XCTAssertEqual(Set(eleven.map(\.minX)).count, 4)
        // The fifth member opens the second row, under the first.
        XCTAssertEqual(eleven[4].minX, eleven[0].minX, accuracy: 0.01)
        XCTAssertGreaterThan(eleven[4].minY, eleven[0].minY)
    }

    func testGroupFramesStayInsideTheArea() {
        // Every member of a reasonably sized group is fully on screen.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for count in 1...12 {
            let frames = TilingEngine.frames(for: .grid, count: count, in: screen, gap: 12)
            XCTAssertEqual(frames.count, count)
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.minX, screen.minX, "count \(count)")
                XCTAssertGreaterThanOrEqual(frame.minY, screen.minY, "count \(count)")
                XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 0.01, "count \(count)")
                XCTAssertLessThanOrEqual(frame.maxY, screen.maxY + 0.01, "count \(count)")
            }
        }
    }

    func testLargeGridShrinksCellsToStayInsideTheArea() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frames = TilingEngine.gridFrames(count: 36, in: screen, gap: 12)
        XCTAssertEqual(frames.count, 36)
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
            XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 0.01)
            XCTAssertLessThanOrEqual(frame.maxY, screen.maxY + 0.01)
        }
    }

    // MARK: - Content-weighted treemap (T30)

    func testWeightedFramesAreProportional() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frames = TilingEngine.weightedFrames(weights: [2, 1, 1], in: screen, gap: 0)
        XCTAssertEqual(frames.count, 3)

        let total = frames.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(frames[0].width * frames[0].height / total, 0.5, accuracy: 0.02)
        XCTAssertEqual(frames[1].width * frames[1].height / total, 0.25, accuracy: 0.02)
        XCTAssertEqual(frames[2].width * frames[2].height / total, 0.25, accuracy: 0.02)

        for frame in frames {
            XCTAssertTrue(screen.contains(frame), "\(frame) is outside \(screen)")
        }
        XCTAssertFalse(frames[0].intersects(frames[1]))
        XCTAssertFalse(frames[0].intersects(frames[2]))
        XCTAssertFalse(frames[1].intersects(frames[2]))
    }

    func testWeightedFramesRespectTheGapAndStayInside() {
        let screen = CGRect(x: 100, y: 50, width: 1440, height: 900)
        let frames = TilingEngine.weightedFrames(weights: [4, 3, 2, 1], in: screen, gap: 12)
        XCTAssertEqual(frames.count, 4)

        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
            XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
            XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
            XCTAssertGreaterThan(frame.width, 10)
            XCTAssertGreaterThan(frame.height, 10)
        }
        for left in 0..<frames.count {
            for right in (left + 1)..<frames.count {
                XCTAssertFalse(frames[left].intersects(frames[right]),
                               "\(frames[left]) overlaps \(frames[right])")
            }
        }
    }

    func testWeightedFramesCoverTheArea() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frames = TilingEngine.weightedFrames(weights: [3, 2, 2, 1, 1], in: screen, gap: 0)
        let covered = frames.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(covered, screen.width * screen.height,
                       accuracy: screen.width * screen.height * 0.01)
    }

    func testWeightedFramesAreDeterministic() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let first = TilingEngine.weightedFrames(weights: [5, 3, 1, 1], in: screen, gap: 10)
        let second = TilingEngine.weightedFrames(weights: [5, 3, 1, 1], in: screen, gap: 10)
        XCTAssertEqual(first, second)
    }

    func testWeightedFrameForOneWindowIsTheInsetArea() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = TilingEngine.weightedFrames(weights: [1], in: screen, gap: 12).first
        XCTAssertEqual(frame, screen.insetBy(dx: 6, dy: 6).integral)
    }

    func testContentPresetRoutesToTheTreemap() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let weighted = TilingEngine.weightedFrames(weights: [2, 1, 1], in: screen, gap: 8)
        XCTAssertEqual(TilingEngine.frames(for: .content, count: 3, in: screen, gap: 8,
                                           weights: [2, 1, 1]), weighted)
        // Without weights the preset has to fall back to the grid.
        XCTAssertEqual(TilingEngine.frames(for: .content, count: 3, in: screen, gap: 8),
                       TilingEngine.frames(for: .grid, count: 3, in: screen, gap: 8))
    }

    func testWeightedFramesHandleTenWindows() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let weights = (1...10).map(Double.init)
        let frames = TilingEngine.weightedFrames(weights: weights, in: screen, gap: 8)
        XCTAssertEqual(frames.count, 10)
        for frame in frames {
            XCTAssertTrue(screen.contains(frame))
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    func testGroupGoldenSpiralInsetsTheSlotsLikeAutoLayout() {
        let frames = TilingEngine.frames(for: .goldenSpiral, count: 4, in: area, gap: 12)
        let slots = TilingEngine.goldenSpiralSlots(area: area, count: 4)
        XCTAssertEqual(frames, slots.map { $0.insetBy(dx: 6, dy: 6).integral })
        // The biggest slot stays the biggest after the inset.
        let areas = frames.map { $0.width * $0.height }
        XCTAssertEqual(areas, areas.sorted(by: >))
    }
}
