import XCTest
@testable import MakiDesk

final class LegacyMigrationTests: XCTestCase {
    func testFolderMigrationMovesLegacyDataAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakiDeskMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let old = root.appendingPathComponent("OrbitDesk", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: old.appendingPathComponent("settings.json"))

        XCTAssertTrue(LegacyMigration.migrateFolder(from: "OrbitDesk", to: "MakiDesk", in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("MakiDesk/settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(LegacyMigration.migrateFolder(from: "OrbitDesk", to: "MakiDesk", in: root))
    }
}
