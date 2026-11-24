import GRDB
import XCTest
@testable import PhotoCleanupCore

/// Importing the old scripts' output folder into a library the app scanned after the old tool had
/// already filed some photos, moved one to _to_remove and written one off.
final class LegacyImportTests: XCTestCase {
    var base: URL!
    var photos: URL!
    var out: URL!
    var library: Library!
    let oldRoot = "/Volumes/Old Drive/Pictures"  // the old tool saw the folder at another path

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        photos = base.appendingPathComponent("photos")
        out = base.appendingPathComponent("old-out")
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("Seattle"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out.appendingPathComponent("haiku"), withIntermediateDirectories: true)
        library = try Library.create(at: base.appendingPathComponent("library"), photoFolder: photos)

        // What the app's scan found: two photos still in place, two the old tool filed (one of them
        // then moved by hand to another folder), plus a Live Photo video next to a filed photo.
        try Data("video".utf8).write(to: photos.appendingPathComponent("Seattle/b.MOV"))
        try library.store.db.write { db in
            for (rel, size) in [("a.jpg", 10), ("e.jpg", 50), ("Seattle/b.jpg", 20), ("Elsewhere/c.jpg", 30)] {
                try db.execute(sql: """
                    INSERT INTO photo (rel_path, original_rel_path, size, mtime, taken, width, height, sharpness, analysis_version)
                    VALUES (?, ?, ?, 0, 1800000000, 100, 100, 400, ?)
                    """, arguments: [rel, rel, size, analysisVersion])
            }
        }

        // The old tool's view: five photos at the folder's top level, then its moves.
        func old(_ rel: String, _ size: Int) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: ["id": legacyId(rel), "path": "\(oldRoot)/\(rel)", "rel": rel, "size": size]), as: UTF8.self)
        }
        try [old("a.jpg", 10), old("b.jpg", 20), old("c.jpg", 30), old("d.jpg", 40), old("e.jpg", 50), old("f.jpg", 60)].joined(separator: "\n")
            .write(to: out.appendingPathComponent("analysis.jsonl"), atomically: true, encoding: .utf8)
        func move(_ op: String, _ rel: String, to: String? = nil, from: String? = nil, companions: [[String: String]] = []) -> String {
            var m: [String: Any] = ["op": op, "id": legacyId(rel), "from": "\(oldRoot)/\(from ?? rel)", "at": 1]
            if let to { m["to"] = "\(oldRoot)/\(to)" }
            if !companions.isEmpty { m["companions"] = companions }
            return String(decoding: try! JSONSerialization.data(withJSONObject: m), as: UTF8.self)
        }
        try [
            move("file", "b.jpg", to: "2026 Trip/b.jpg", companions: [["from": "\(oldRoot)/b.MOV", "to": "\(oldRoot)/2026 Trip/b.MOV"]]),
            move("file", "b.jpg", to: "Seattle/b.jpg", from: "2026 Trip/b.jpg", companions: [["from": "\(oldRoot)/2026 Trip/b.MOV", "to": "\(oldRoot)/Seattle/b.MOV"]]),
            move("file", "c.jpg", to: "Seattle/c.jpg"),  // since moved by hand to Elsewhere/
            move("move", "d.jpg", to: "_to_remove/d.jpg"),
            move("move", "f.jpg", to: "_to_remove/f.jpg"),
            move("gone", "f.jpg"),
            move("file", "e.jpg", to: "Seattle/e.jpg"),
            move("restore", "e.jpg", to: "e.jpg", from: "Seattle/e.jpg"),
        ].joined(separator: "\n").write(to: out.appendingPathComponent("moves.jsonl"), atomically: true, encoding: .utf8)

        func write(_ name: String, _ object: Any) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: out.appendingPathComponent(name))
        }
        let a = legacyId("a.jpg"), b = legacyId("b.jpg"), c = legacyId("c.jpg"), d = legacyId("d.jpg"), e = legacyId("e.jpg")
        let bCarried = legacyId("Seattle/b.jpg")  // the id the old tool wrote ahead for the filed photo
        try write("decisions.json", [a: "keep", b: "fav", d: "remove", "0000000000000000": "remove", e: "sideways"])
        try write("reviewed.json", [a, b, bCarried, d])
        try write("haiku/batch_001.json", [a: ["state": "remove"], c: ["state": "fav", "why": "Sharp."]])
        try write("haiku/carried.json", [bCarried: ["state": "keep", "why": "Different pose."], a: ["state": "keep", "why": ""]])
        try write("names.json", [["photos": [b, bCarried, c], "name": "Seattle"], ["photos": [d], "name": "Lost"]])
        try write("folders.json", [[b, c], [d]])
        try write("collection_edits.json", [
            "merges": [[[a], [b, c]], [[d], [a]]],
            "moves": [["photos": [e], "into": [a]], ["photos": [d], "into": [a]]],
            "not_collections": [["photos": [a, e], "names": [["photos": [a], "name": "Was an event"]], "folders": [[a, e]]]],
        ])
        try "/Users/me/me.jpg\n".write(to: out.appendingPathComponent("reference_path.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        library = nil
        try? FileManager.default.removeItem(at: base)
    }

    func id(_ rel: String) throws -> String {
        String(try library.store.db.read { try Int64.fetchOne($0, sql: "SELECT id FROM photo WHERE rel_path = ?", arguments: [rel])! })
    }

    func testReviewIsImportedOntoThePhotosWhereTheyAreNow() throws {
        let r = try importLegacyReview(from: out, into: library)
        XCTAssertEqual([r.oldPhotos, r.matched, r.gone, r.inRemoveFolder, r.notFound], [6, 4, 1, 1, 0])
        XCTAssertEqual(r.filed, 2)
        XCTAssertEqual(r.referencePhoto, "/Users/me/me.jpg")

        let a = try id("a.jpg"), b = try id("Seattle/b.jpg"), c = try id("Elsewhere/c.jpg"), e = try id("e.jpg")
        let catalog = try Catalog(library: library, timeZone: TimeZone(identifier: "UTC")!)
        let page = try JSONSerialization.jsonObject(with: catalog.pageData()) as! [String: Any]
        XCTAssertEqual(page["decisions"] as? [String: String], [a: "keep", b: "fav"])
        XCTAssertEqual(Set(page["reviewed"] as! [String]), [a, b])
        let picks = page["haiku"] as! [String: [String: String]]
        XCTAssertEqual(picks[a]?["state"], "keep")  // the later file wins
        XCTAssertEqual(picks[b], ["state": "keep", "why": "Different pose."])
        XCTAssertEqual(picks[c], ["state": "fav", "why": "Sharp."])
        XCTAssertEqual([r.decisions, r.reviewed, r.picks], [2, 2, 3])

        // Filed photos know where they came from, the Live Photo video too.
        let filed = try library.store.db.read { try Row.fetchAll($0, sql: "SELECT rel_path, original_rel_path, location FROM photo ORDER BY rel_path") }
        XCTAssertEqual(filed.map { "\($0["rel_path"] as String) <- \($0["original_rel_path"] as String) \($0["location"] as String)" },
                       ["Elsewhere/c.jpg <- c.jpg filed", "Seattle/b.jpg <- b.jpg filed", "a.jpg <- a.jpg in_place", "e.jpg <- e.jpg in_place"])
        let video = try library.store.db.read { try Row.fetchOne($0, sql: "SELECT photo_id, rel_path, original_rel_path FROM companion")! }
        XCTAssertEqual([String(video["photo_id"] as Int64), video["rel_path"], video["original_rel_path"]], [b, "Seattle/b.MOV", "b.MOV"])

        // Names, folder switches and edits keep only the photos that exist here; empty ones are dropped.
        let edits = try library.store.db.read { try StoredEdits.load($0) }
        XCTAssertEqual(edits.names.map(\.name), ["Seattle"])
        XCTAssertEqual(edits.names[0].photos, [b, c])
        XCTAssertEqual(edits.folders.map(\.photos), [[b, c]])
        XCTAssertEqual(edits.merges.map(\.parts), [[[a], [b, c]]])
        XCTAssertEqual(edits.moves.map(\.photos), [[e]])
        XCTAssertEqual(edits.notCollections.map(\.photos), [[a, e]])
        XCTAssertEqual([r.names, r.folders, r.merges, r.moves, r.notCollections], [2, 2, 1, 1, 1])  // one name and one switch are held by the mark
        let held = try library.store.db.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM collection_name WHERE held_by IS NOT NULL) + (SELECT COUNT(*) FROM folder_switch WHERE held_by IS NOT NULL)") }
        XCTAssertEqual(held, 2)
    }

    func testImportRefusesToOverwriteExistingStateUnlessAsked() throws {
        try library.store.db.write { try $0.execute(sql: "INSERT INTO decision (photo_id, state) SELECT id, 'remove' FROM photo WHERE rel_path = 'e.jpg'") }
        XCTAssertThrowsError(try importLegacyReview(from: out, into: library)) { XCTAssertTrue($0 is LegacyImportError) }
        XCTAssertEqual(try library.store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM decision") }, 1)

        let r = try importLegacyReview(from: out, into: library, replace: true)
        XCTAssertEqual(r.decisions, 2)
        // Importing twice gives the same state, not a doubled one.
        XCTAssertEqual(try importLegacyReview(from: out, into: library, replace: true), r)
    }

    func testAFolderThatIsNotTheOldToolsOutputIsRejected() {
        XCTAssertThrowsError(try importLegacyReview(from: photos, into: library))
    }

    func testOldIdsMatchTheOldScripts() {
        // Values from Python: hashlib.sha1(rel.encode()).hexdigest()[:16], as server.py computed them.
        XCTAssertEqual(legacyId("IMG_1 2.JPG"), "d90555c689442789")
        XCTAssertEqual(legacyId("Trip/Søndag é.heic"), "7aa6328077dd6a10")
    }
}
