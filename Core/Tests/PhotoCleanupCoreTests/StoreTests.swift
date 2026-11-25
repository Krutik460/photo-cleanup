import GRDB
import XCTest
@testable import PhotoCleanupCore

final class StoreTests: XCTestCase {
    var dir: URL!
    var store: Store!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try Store(path: dir.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    func insertPhoto(_ db: Database, rel: String, location: String = "in_place") throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO photo (rel_path, original_rel_path, size, mtime, width, height, sharpness, analysis_version, location)
            VALUES (?, ?, 1, 0, 10, 10, 1, 3, ?)
            """, arguments: [rel, rel, location])
        return db.lastInsertedRowID
    }

    func testMigrationsCreateAnalysisTables() throws {
        let tables = try store.db.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        for name in ["meta", "photo", "face", "neighbor"] { XCTAssertTrue(tables.contains(name), name) }
    }

    func testReopeningAnExistingDatabaseKeepsData() throws {
        try store.db.write { try insertPhoto($0, rel: "a.jpg") }
        store = nil
        store = try Store(path: dir.appendingPathComponent("library.sqlite").path)
        XCTAssertEqual(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo") }, 1)
    }

    func testPathChangeKeepsIdentity() throws {
        let id = try store.db.write { try insertPhoto($0, rel: "a.jpg") }
        try store.db.write { try $0.execute(sql: "UPDATE photo SET rel_path = ?, location = 'filed' WHERE id = ?", arguments: ["2026-10-16 Trip/a.jpg", id]) }
        let row = try store.db.read { try Row.fetchOne($0, sql: "SELECT id, original_rel_path FROM photo WHERE rel_path = ?", arguments: ["2026-10-16 Trip/a.jpg"]) }
        XCTAssertEqual(row?["id"], id)
        XCTAssertEqual(row?["original_rel_path"], "a.jpg")
    }

    func testTwoPhotosCannotShareAPath() throws {
        try store.db.write { try insertPhoto($0, rel: "a.jpg") }
        XCTAssertThrowsError(try store.db.write { try insertPhoto($0, rel: "a.jpg") })
    }

    func testUnknownLocationIsRejected() throws {
        XCTAssertThrowsError(try store.db.write { try insertPhoto($0, rel: "a.jpg", location: "somewhere") })
    }

    func testDeletingAPhotoRemovesItsFacesAndNeighbors() throws {
        try store.db.write { db in
            let a = try insertPhoto(db, rel: "a.jpg"), b = try insertPhoto(db, rel: "b.jpg")
            try db.execute(sql: "INSERT INTO face (photo_id, idx, x, y, w, h) VALUES (?, 0, 0, 0, 1, 1)", arguments: [a])
            try db.execute(sql: "INSERT INTO neighbor (a, b, distance) VALUES (?, ?, 0.1)", arguments: [a, b])
            try db.execute(sql: "DELETE FROM photo WHERE id = ?", arguments: [a])
        }
        XCTAssertEqual(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM face") }, 0)
        XCTAssertEqual(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM neighbor") }, 0)
    }

    func testNeighborPairsAreStoredOnce() throws {
        try store.db.write { db in
            let a = try insertPhoto(db, rel: "a.jpg"), b = try insertPhoto(db, rel: "b.jpg")
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO neighbor (a, b, distance) VALUES (?, ?, 0.1)", arguments: [b, a]))
        }
    }
}
