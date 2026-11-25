import GRDB
import XCTest
@testable import PhotoCleanupCore

/// The catalog over a library whose photos are inserted directly: quiet days at home, a birthday at
/// home (22 photos), a three-day trip and a day trip. The same shape as GroupingTests.library().
final class CatalogTests: XCTestCase {
    var base: URL!
    var library: Library!
    var catalog: Catalog!
    var ids: [String: String] = [:]  // name -> photo id

    let home = (40.70, -74.00), seattle = (47.60, -122.33), philly = (39.95, -75.16)

    func at(_ day: Int, _ hour: Double = 12) -> Double {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!.timeIntervalSince1970 + hour * 3600
    }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        let photos = base.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        library = try Library.create(at: base.appendingPathComponent("library"), photoFolder: photos)
        try library.store.db.write { db in
            func add(_ name: String, _ time: Double, _ gps: (Double, Double)) throws {
                try db.execute(sql: """
                    INSERT INTO photo (rel_path, original_rel_path, size, mtime, taken, width, height, aesthetic, sharpness, lat, lon, analysis_version)
                    VALUES (?, ?, 2000000, 0, ?, 4000, 3000, 0.2, 400, ?, ?, ?)
                    """, arguments: ["\(name).jpg", "\(name).jpg", time, gps.0, gps.1, analysisVersion])
                ids[name] = String(db.lastInsertedRowID)
            }
            for day in [1, 2, 3, 5, 6, 7, 8] { try add("home\(day)", at(day), home) }
            for i in 0..<22 { try add("party\(i)", at(10, 18 + Double(i) / 60), home) }
            for day in 16...18 { for i in 0..<3 { try add("sea\(day)-\(i)", at(day, 10 + Double(i)), seattle) } }
            for i in 0..<4 { try add("phl\(i)", at(24, 11 + Double(i) / 4), philly) }
            // Two near-identical party shots form a group.
            try db.execute(sql: "INSERT INTO neighbor (a, b, distance) VALUES (?, ?, 0.2)", arguments: [Int64(ids["party0"]!)!, Int64(ids["party1"]!)!])
        }
        catalog = try Catalog(library: library, timeZone: TimeZone(identifier: "UTC")!)
    }

    override func tearDownWithError() throws {
        catalog = nil
        library = nil
        try? FileManager.default.removeItem(at: base)
    }

    func page() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: catalog.pageData()) as! [String: Any]
    }

    func collection(holding name: String) throws -> [String: Any] {
        let id = ids[name]!
        return (try page()["collections"] as! [[String: Any]]).first { ($0["members"] as! [String]).contains(id) }!
    }

    func count(_ sql: String) throws -> Int { try library.store.db.read { try Int.fetchOne($0, sql: sql) ?? 0 } }

    func testPageDataHasEverythingThePageReads() throws {
        let d = try page()
        XCTAssertEqual((d["collections"] as! [[String: Any]]).map { $0["kind"] as! String }, ["everyday", "event", "trip", "daytrip"])
        XCTAssertEqual((d["photos"] as! [String: Any]).count, 42)
        XCTAssertEqual((d["order"] as! [String]).count, 42)
        XCTAssertEqual((d["groups"] as! [[String: Any]]).count, 1)
        XCTAssertEqual(d["root"] as? String, library.root.path)
        for key in ["decisions", "haiku", "reviewed", "moved", "filed", "home", "generated"] { XCTAssertNotNil(d[key], key) }

        let p = (d["photos"] as! [String: [String: Any]])[ids["party0"]!]!
        for key in ["rel", "path", "time", "timeKnown", "w", "h", "size", "faces", "faceQ", "aes", "sharp", "score", "tags", "group",
                    "collection", "gps", "auto", "reason", "me", "meSim"] { XCTAssertNotNil(p[key], key) }
        XCTAssertEqual(p["rel"] as? String, "party0.jpg")
        XCTAssertEqual(p["path"] as? String, library.root.appendingPathComponent("party0.jpg").path)

        let c = try collection(holding: "sea16-0")
        XCTAssertEqual(c["name"] as? String, "")
        XCTAssertEqual(c["folder"] as? String, "2026-10-16 Trip")
        XCTAssertEqual(c["folderOn"] as? Bool, false)
        XCTAssertEqual(try collection(holding: "home1")["folder"] as? String, "2026-10 Everyday")
    }

    func testNameAndFolderSwitchFollowTheCollection() throws {
        try catalog.rename(collectionOf: ids["sea16-0"], to: "  Seattle   Fall ")
        try catalog.setFolder(collectionOf: ids["sea17-1"], on: true)
        var c = try collection(holding: "sea16-0")
        XCTAssertEqual(c["name"] as? String, "Seattle Fall")
        XCTAssertEqual(c["folder"] as? String, "Seattle Fall")
        XCTAssertEqual(c["folderOn"] as? Bool, true)

        // Collections get new ids when the library is regrouped or reopened; the name stays put.
        catalog = try Catalog(library: library, timeZone: TimeZone(identifier: "UTC")!)
        c = try collection(holding: "sea18-2")
        XCTAssertEqual(c["name"] as? String, "Seattle Fall")
        XCTAssertEqual(c["folderOn"] as? Bool, true)

        // Renaming replaces, an empty name removes; no stale rows or anchor sets are left behind.
        try catalog.rename(collectionOf: ids["sea16-0"], to: "Seattle")
        XCTAssertEqual(try collection(holding: "sea16-0")["name"] as? String, "Seattle")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM collection_name"), 1)
        try catalog.rename(collectionOf: ids["sea16-0"], to: "")
        try catalog.setFolder(collectionOf: ids["sea16-0"], on: false)
        XCTAssertEqual(try collection(holding: "sea16-0")["name"] as? String, "")
        XCTAssertEqual(try count("SELECT (SELECT COUNT(*) FROM collection_name) + (SELECT COUNT(*) FROM folder_switch) + (SELECT COUNT(*) FROM anchor_set)"), 0)
    }

    func testMergeKeepsTheEarliestNameAndItsParts() throws {
        try catalog.rename(collectionOf: ids["phl0"], to: "Philly")
        try catalog.rename(collectionOf: ids["sea16-0"], to: "Seattle")
        let anchor = try catalog.editCollections(.merge, ids: [ids["phl0"]!, ids["sea16-0"]!])
        XCTAssertEqual(anchor, ids["sea16-0"])
        var c = try collection(holding: "phl0")
        XCTAssertEqual((c["members"] as! [String]).count, 13)
        XCTAssertEqual(c["parts"] as? Int, 2)
        XCTAssertEqual(c["name"] as? String, "Seattle")

        // Merging the merged collection with the party keeps the original parts: three, not two.
        try catalog.editCollections(.merge, ids: [ids["phl0"]!, ids["party0"]!])
        c = try collection(holding: "phl0")
        XCTAssertEqual((c["members"] as! [String]).count, 35)
        XCTAssertEqual(c["parts"] as? Int, 3)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM edit_merge"), 1)

        try catalog.editCollections(.split, ids: [ids["phl0"]!])
        XCTAssertEqual((try page()["collections"] as! [[String: Any]]).map { ($0["members"] as! [String]).count }, [7, 22, 9, 4])
        XCTAssertEqual(try collection(holding: "phl0")["name"] as? String, "Philly")
        XCTAssertEqual(try count("SELECT (SELECT COUNT(*) FROM edit_merge) + (SELECT COUNT(*) FROM edit_merge_part)"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM anchor_set"), 2)  // the two names
    }

    func testMergeNeedsTwoCollections() throws {
        XCTAssertThrowsError(try catalog.editCollections(.merge, ids: [ids["phl0"]!, ids["phl1"]!]))
    }

    func testNotAnEventHoldsItsNameAndFolderUntilRestored() throws {
        try catalog.rename(collectionOf: ids["party0"], to: "Birthday")
        try catalog.setFolder(collectionOf: ids["party0"], on: true)
        try catalog.editCollections(.dissolve, ids: [ids["party3"]!])

        var month = try collection(holding: "party0")
        XCTAssertEqual(month["kind"] as? String, "everyday")
        XCTAssertEqual((month["members"] as! [String]).count, 29)
        XCTAssertEqual(month["name"] as? String, "")
        XCTAssertEqual(month["folderOn"] as? Bool, false)
        let folded = month["folded"] as! [[String: Any]]
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0]["photos"] as? Int, 22)

        // An everyday month cannot be marked, and marking does not happen twice.
        XCTAssertThrowsError(try catalog.editCollections(.dissolve, ids: [ids["home1"]!]))

        let anchors = folded[0]["anchors"] as! [String]
        try catalog.editCollections(.restore, ids: anchors)
        let party = try collection(holding: "party0")
        XCTAssertEqual(party["kind"] as? String, "event")
        XCTAssertEqual(party["name"] as? String, "Birthday")
        XCTAssertEqual(party["folderOn"] as? Bool, true)
        month = try collection(holding: "home1")
        XCTAssertNil(month["folded"])
        XCTAssertThrowsError(try catalog.editCollections(.restore, ids: anchors))
    }

    func testMovePhotosAndANewerMoveReplacesTheOlderOne() throws {
        let three = ["home1", "home2", "home3"].map { ids[$0]! }
        try catalog.editCollections(.move, ids: three, into: ids["sea16-0"])
        XCTAssertEqual((try collection(holding: "home1")["members"] as! [String]).count, 12)
        XCTAssertEqual((try collection(holding: "home5")["members"] as! [String]).count, 4)

        // Moving one of them on, and another back: each photo has one move at most.
        try catalog.editCollections(.move, ids: [ids["home1"]!], into: ids["phl0"])
        try catalog.editCollections(.move, ids: [ids["home2"]!], into: ids["home5"])
        XCTAssertEqual((try collection(holding: "home1")["members"] as! [String]).count, 5)
        XCTAssertEqual((try collection(holding: "home3")["members"] as! [String]).count, 10)
        XCTAssertEqual((try collection(holding: "home2")["members"] as! [String]).count, 5)
        let stored = try library.store.db.read { try StoredEdits.load($0) }.moves.flatMap(\.photos)
        XCTAssertEqual(stored.sorted(), three.sorted())

        XCTAssertThrowsError(try catalog.editCollections(.move, ids: [ids["home3"]!], into: ids["sea16-0"]))  // already there
    }

    func testMoveIntoAMonthThatAbsorbedAFoldedEventThroughThePage() throws {
        try catalog.editCollections(.dissolve, ids: [ids["party0"]!])
        try catalog.editCollections(.move, ids: [ids["phl0"]!, ids["phl1"]!], into: ids["party5"])
        XCTAssertEqual((try collection(holding: "phl0")["members"] as! [String]).count, 31)
        XCTAssertEqual(try collection(holding: "phl0")["kind"] as? String, "everyday")
        XCTAssertEqual((try collection(holding: "phl2")["members"] as! [String]).count, 2)
    }

    func testChoicesAndReviewedMarksPersist() throws {
        let a = ids["party0"]!, b = ids["party1"]!
        XCTAssertEqual(try catalog.decide([a: .remove, b: .fav, "999999": .keep]), [a: "remove", b: "fav"])
        XCTAssertEqual(try catalog.setReviewed([a, b, "999999"], true).sorted(), [a, b].sorted())
        try catalog.decide([a: nil])
        try catalog.setReviewed([b], false)

        catalog = try Catalog(library: library, timeZone: TimeZone(identifier: "UTC")!)
        let d = try page()
        XCTAssertEqual(d["decisions"] as? [String: String], [b: "fav"])
        XCTAssertEqual(d["reviewed"] as? [String], [a])
    }

    func testYourChoiceWinsOverTheSecondOpinionWhichWinsOverTheAutomaticPick() throws {
        let fav = ids["party0"]!, other = ids["party1"]!
        let auto = try catalog.effectiveStates()
        XCTAssertEqual(Set([auto[fav]!, auto[other]!]), [.fav, .remove])
        let removed = auto[fav] == .remove ? fav : other
        try library.store.db.write { try $0.execute(sql: "INSERT INTO ai_pick (photo_id, state, why) VALUES (?, 'keep', 'Different pose')", arguments: [Int64(removed)!]) }
        XCTAssertEqual(try catalog.effectiveStates()[removed], .keep)
        XCTAssertEqual(((try page()["haiku"] as! [String: [String: String]])[removed])?["why"], "Different pose")
        try catalog.decide([removed: .remove])
        XCTAssertEqual(try catalog.effectiveStates()[removed], .remove)
    }

    func testMissingAndUnreadablePhotosAreLeftOut() throws {
        try library.store.db.write { db in
            try db.execute(sql: "UPDATE photo SET missing = 1 WHERE rel_path = 'home1.jpg'")
            try db.execute(sql: "UPDATE photo SET width = 0, error = 'cannot decode' WHERE rel_path = 'home2.jpg'")
        }
        try catalog.regroup()
        XCTAssertEqual(catalog.photoCount, 40)
        XCTAssertEqual((try collection(holding: "home3")["members"] as! [String]).count, 5)
    }

    func testFolderNamesAreSafe() {
        XCTAssertEqual(safeFolderName("  Mom & Dad's 40th  "), "Mom & Dad's 40th")
        XCTAssertEqual(safeFolderName("NYC/Boston: day 1\\2"), "NYC-Boston- day 1-2")
        XCTAssertEqual(safeFolderName("..hidden.. "), "hidden")
        XCTAssertEqual(safeFolderName("a\u{0007}b\tc\nd"), "ab c d")
        XCTAssertNil(safeFolderName(" . "))
        XCTAssertEqual(safeFolderName(String(repeating: "x", count: 150))?.count, 100)
    }
}
