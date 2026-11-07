import XCTest
import MakiShared
@testable import MakiDesk

/// F1: the utility bar's buttons in `utility-bar.json`. The catalog still owns
/// behaviour; the file carries visibility, order and the optional words.
final class BarConfigurationTests: XCTestCase {
    func testDefaultsShowEveryPlannedButtonInCatalogOrder() {
        let configuration = BarConfiguration.defaults
        XCTAssertEqual(configuration.version, BarConfiguration.currentVersion)
        XCTAssertEqual(configuration.items.map(\.id), BarItemCatalog.planned.map(\.id))
        XCTAssertTrue(configuration.items.allSatisfy(\.visible))
        XCTAssertEqual(configuration.resolvedItems().map(\.id),
                       BarItemCatalog.planned.map(\.id))
    }

    func testAnEmptyFileReadsAsTheDefaults() throws {
        let configuration = try JSONDecoder().decode(BarConfiguration.self,
                                                     from: Data("{}".utf8))
        XCTAssertEqual(configuration.version, BarConfiguration.currentVersion)
        XCTAssertEqual(configuration.resolvedItems().map(\.id),
                       BarItemCatalog.planned.map(\.id))
    }

    func testMissingVersionAndVisibilityReadLeniently() throws {
        let json = #"{"items":[{"id":"notes"},{"id":"measure","visible":false}]}"#
        let configuration = try JSONDecoder().decode(BarConfiguration.self,
                                                     from: Data(json.utf8))
        XCTAssertEqual(configuration.version, BarConfiguration.currentVersion)
        XCTAssertTrue(configuration.isVisible("notes"))
        XCTAssertFalse(configuration.isVisible("measure"))
    }

    func testHiddenButtonsStayInTheFileButLeaveTheBar() {
        var configuration = BarConfiguration.defaults
        configuration.setVisible(false, for: "measure")
        XCTAssertFalse(configuration.isVisible("measure"))
        XCTAssertEqual(configuration.resolvedItems().count,
                       BarItemCatalog.planned.count - 1)
        XCTAssertFalse(configuration.resolvedItems().map(\.id).contains("measure"))
        // Settings still needs the row to turn it back on.
        XCTAssertTrue(configuration.resolvedItems(includingHidden: true)
            .map(\.id).contains("measure"))
    }

    func testUnknownIdsAreDroppedAndMissingOnesAppear() {
        var configuration = BarConfiguration(version: 1, items: [
            BarConfiguration.Item(id: "nope"),
            BarConfiguration.Item(id: "measure", visible: false),
        ])
        configuration.setVisible(true, for: "clipboard")
        let resolved = configuration.resolvedItems()
        XCTAssertFalse(resolved.contains { $0.id == "nope" })
        XCTAssertFalse(resolved.contains { $0.id == "measure" })
        XCTAssertTrue(resolved.contains { $0.id == "notes" })
        XCTAssertEqual(resolved.count, BarItemCatalog.planned.count - 1)
    }

    func testDuplicatesKeepTheFirstEntry() {
        let configuration = BarConfiguration(items: [
            BarConfiguration.Item(id: "notes", visible: true),
            BarConfiguration.Item(id: "notes", visible: false),
        ])
        XCTAssertTrue(configuration.isVisible("notes"))
        XCTAssertEqual(configuration.resolvedItems().filter { $0.id == "notes" }.count, 1)
    }

    func testTheFileOrdersInsideAZoneButZonesKeepTheirOrder() {
        var configuration = BarConfiguration.defaults
        guard let index = configuration.items.firstIndex(where: { $0.id == "measure" }) else {
            return XCTFail("measure is not in the catalog")
        }
        let moved = configuration.items.remove(at: index)
        configuration.items.insert(moved, at: 0)

        let resolved = configuration.resolvedItems()
        XCTAssertEqual(resolved.first?.id, "measure")
        // The zones still run utility, toggle, info: moving an entry to the
        // front cannot put an info value beside the panels.
        let zones = resolved.map(\.zone)
        XCTAssertEqual(zones, zones.sorted { rank($0) < rank($1) })
    }

    func testOverridesChangeOnlyThePresentation() {
        var configuration = BarConfiguration.defaults
        guard let index = configuration.items.firstIndex(where: { $0.id == "notes" }) else {
            return XCTFail("notes is not in the catalog")
        }
        configuration.items[index].title = "  Ideas  "
        configuration.items[index].symbol = "lightbulb"

        let item = configuration.resolvedItems().first { $0.id == "notes" }
        XCTAssertEqual(item?.title, "Ideas")
        XCTAssertEqual(item?.symbol, "lightbulb")
        XCTAssertEqual(item?.kind, BarItemCatalog.item(id: "notes")?.kind)
        XCTAssertEqual(item?.zone, BarItemCatalog.item(id: "notes")?.zone)
        XCTAssertEqual(item?.priority, BarItemCatalog.item(id: "notes")?.priority)
    }

    func testBlankOverridesKeepTheCatalogValues() {
        var configuration = BarConfiguration.defaults
        guard let index = configuration.items.firstIndex(where: { $0.id == "notes" }) else {
            return XCTFail("notes is not in the catalog")
        }
        configuration.items[index].title = "   "
        configuration.items[index].symbol = ""

        let item = configuration.resolvedItems().first { $0.id == "notes" }
        XCTAssertEqual(item?.title, BarItemCatalog.item(id: "notes")?.title)
        XCTAssertEqual(item?.symbol, BarItemCatalog.item(id: "notes")?.symbol)
    }

    func testTheOldHiddenListMigratesOnce() {
        let migrated = BarConfiguration.migrated(fromLegacyHidden: "measure, ports, pin, nope")
        XCTAssertNotNil(migrated)
        XCTAssertFalse(migrated?.isVisible("measure") ?? true)
        XCTAssertFalse(migrated?.isVisible("ports") ?? true)
        // The right-hand controls are not hideable, and unknown ids do nothing.
        XCTAssertEqual(migrated?.items.map(\.id), BarItemCatalog.planned.map(\.id))
        XCTAssertNil(BarConfiguration.migrated(fromLegacyHidden: nil))
        XCTAssertNil(BarConfiguration.migrated(fromLegacyHidden: ""))
        XCTAssertNil(BarConfiguration.migrated(fromLegacyHidden: "   "))
    }

    func testAConfigurationRoundTripsThroughJSON() throws {
        var configuration = BarConfiguration.defaults
        guard let index = configuration.items.firstIndex(where: { $0.id == "timer" }) else {
            return XCTFail("timer is not in the catalog")
        }
        configuration.items[index].visible = false
        configuration.items[index].title = "Countdown"

        let data = try StoredJSONFile.encoder().encode(configuration)
        let decoded = try StoredJSONFile.decoder().decode(BarConfiguration.self, from: data)
        XCTAssertEqual(decoded, configuration)
    }

    private func rank(_ zone: BarItem.Zone) -> Int {
        switch zone {
        case .utility: return 0
        case .toggle: return 1
        case .info: return 2
        case .right: return 3
        }
    }
}

/// The file itself: one atomically written JSON, a corrupt file set aside, a
/// newer one read-only. The store is given a temporary file, never Application
/// Support.
final class BarConfigurationStoreTests: XCTestCase {
    private var directory: URL!
    private var store: BarConfigurationStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskBarConfiguration-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = BarConfigurationStore(fileURL: directory.appendingPathComponent("utility-bar.json"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAMissingFileReturnsTheDefaults() {
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .missing)
        XCTAssertEqual(snapshot.configuration, .defaults)
        XCTAssertTrue(snapshot.canSave)
        XCTAssertNil(store.modificationDate())
    }

    func testSaveAndLoadRoundTrip() throws {
        var configuration = BarConfiguration.defaults
        configuration.setVisible(false, for: "measure")
        XCTAssertTrue(store.save(configuration))

        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertEqual(snapshot.configuration.resolvedItems().map(\.id),
                       configuration.resolvedItems().map(\.id))
        XCTAssertNotNil(store.modificationDate())
    }

    func testACorruptFileIsSetAsideAndTheDefaultsAreUsed() throws {
        try Data("{ not json".utf8).write(to: store.fileURL)
        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .corrupt)
        XCTAssertEqual(snapshot.configuration, .defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.fileURL.appendingPathExtension("bak").path))
    }

    func testANewerFileIsReadOnly() throws {
        let json = #"{"version":99,"items":[{"id":"notes","visible":false}]}"#
        try Data(json.utf8).write(to: store.fileURL)

        let snapshot = store.load()
        XCTAssertEqual(snapshot.state, .futureVersion(99))
        XCTAssertFalse(snapshot.canSave)
        XCTAssertFalse(snapshot.configuration.isVisible("notes"))

        XCTAssertFalse(store.save(.defaults))
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), json)
        XCTAssertFalse(store.remove())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testRemoveDeletesTheFile() throws {
        XCTAssertTrue(store.save(.defaults))
        XCTAssertTrue(store.remove())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        // Removing a file that is not there is already the goal.
        XCTAssertTrue(store.remove())
    }

    func testTheModificationDateIsTheFiles() throws {
        try Data("{}".utf8).write(to: store.fileURL)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: store.fileURL.path)
        let read = try XCTUnwrap(store.modificationDate())
        XCTAssertEqual(read.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }
}
