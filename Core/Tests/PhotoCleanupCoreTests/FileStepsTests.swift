import GRDB
import XCTest
@testable import PhotoCleanupCore

/// The file steps on a real folder of files in a temporary directory: a three-day trip (with a Live
/// Photo and a pair of near-identical shots), a 20-photo event at home, quiet days, and an exact copy.
final class FileStepsTests: XCTestCase {
    var base: URL!
    var photos: URL!
    var library: Library!
    var catalog: Catalog!
    var ids: [String: String] = [:]  // original relative path -> photo id

    let home = (40.70, -74.00), seattle = (47.60, -122.33)
    let utc = TimeZone(identifier: "UTC")!

    func at(_ day: Int, _ hour: Double = 12) -> Double {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: c)!.timeIntervalSince1970 + hour * 3600
    }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        photos = base.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        library = try Library.create(at: base.appendingPathComponent("library"), photoFolder: photos)

        var seed = 0
        func add(_ rel: String, _ time: Double, _ gps: (Double, Double), copyOf: String? = nil) throws {
            let url = photos.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let copyOf {
                try FileManager.default.copyItem(at: photos.appendingPathComponent(copyOf), to: url)
            } else {
                seed += 1
                try writeJPEG(makePicture(seed: seed, size: 96), to: url)
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            try library.store.db.write { db in
                try db.execute(sql: """
                    INSERT INTO photo (rel_path, original_rel_path, fingerprint, size, mtime, taken, width, height, aesthetic, sharpness, lat, lon, analysis_version)
                    VALUES (?, ?, ?, ?, ?, ?, 4000, 3000, 0.2, 400, ?, ?, ?)
                    """, arguments: [rel, rel, fingerprint(of: url), (attrs[.size] as! NSNumber).intValue,
                                     (attrs[.modificationDate] as! Date).timeIntervalSince1970, time, gps.0, gps.1, analysisVersion])
                ids[rel] = String(db.lastInsertedRowID)
            }
        }
        func near(_ a: String, _ b: String, _ d: Double) throws {
            let x = Int64(ids[a]!)!, y = Int64(ids[b]!)!
            try library.store.db.write { try $0.execute(sql: "INSERT INTO neighbor (a, b, distance) VALUES (?, ?, ?)", arguments: [min(x, y), max(x, y), d]) }
        }
        for day in [1, 2, 3] { try add("Camera/home\(day).jpg", at(day), home) }
        try add("Camera/home1 2.jpg", at(1), home, copyOf: "Camera/home1.jpg")
        for i in 0..<20 { try add("Camera/party\(i).jpg", at(10, 18 + Double(i) / 60), home) }
        try add("Trip/IMG_10.jpg", at(16, 10), seattle)
        try Data("live photo video".utf8).write(to: photos.appendingPathComponent("Trip/IMG_10.MOV"))
        try add("Trip/IMG_11.jpg", at(16, 10.001), seattle)
        for day in 17...18 { for i in 0..<2 { try add("Trip/sea\(day)-\(i).jpg", at(day, 10 + Double(i)), seattle) } }
        try near("Camera/home1.jpg", "Camera/home1 2.jpg", 0.01)  // an exact copy
        try near("Trip/IMG_10.jpg", "Trip/IMG_11.jpg", 0.2)  // two shots of one moment
        catalog = try Catalog(library: library, timeZone: utc)
    }

    override func tearDownWithError() throws {
        catalog = nil
        library = nil
        try? FileManager.default.removeItem(at: base)
    }

    func has(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: photos.appendingPathComponent(rel).path) }

    func row(_ original: String) throws -> PhotoRecord {
        try library.store.db.read { try PhotoRecord.fetchOne($0, sql: "SELECT * FROM photo WHERE id = ?", arguments: [Int64(ids[original]!)!])! }
    }

    func count(_ sql: String) throws -> Int { try library.store.db.read { try Int.fetchOne($0, sql: sql) ?? 0 } }

    /// Every file under the photo folder, as sorted relative paths.
    func files() -> [String] {
        let e = FileManager.default.enumerator(at: photos, includingPropertiesForKeys: [.isRegularFileKey])!
        var out: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out.append(String(url.resolvingSymlinksInPath().path.dropFirst(library.root.path.count + 1)))
        }
        return out.sorted()
    }

    func folders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: photos.path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
    }

    let tripPhotos = ["Trip/IMG_10.jpg", "Trip/IMG_11.jpg", "Trip/sea17-0.jpg", "Trip/sea17-1.jpg", "Trip/sea18-0.jpg", "Trip/sea18-1.jpg"]

    func nameTripAndSwitchFolderOn(_ name: String = "Seattle") throws {
        try catalog.rename(collectionOf: ids["Trip/IMG_10.jpg"], to: name)
        try catalog.setFolder(collectionOf: ids["Trip/IMG_10.jpg"], on: true)
    }

    // MARK: - Organize

    func testOrganizeFilesACollectionWithItsLiveVideoAndKeepsEveryPhotoTheSamePhoto() throws {
        let before = files()
        try nameTripAndSwitchFolderOn()
        XCTAssertEqual(files(), before, "naming and switching change no file")

        let r = try catalog.organize()
        XCTAssertEqual(r, OrganizeResult(filed: 6, back: 0, folders: 1, errors: []))
        // Your own Trip folder is empty now but stays: the app only removes folders it made.
        XCTAssertEqual(folders(), ["Camera", "Seattle", "Trip"])
        XCTAssertEqual(files().filter { $0.hasPrefix("Trip/") }, [])
        XCTAssertTrue(has("Seattle/IMG_10.jpg") && has("Seattle/IMG_10.MOV") && has("Seattle/sea18-1.jpg"))
        let p = try row("Trip/IMG_10.jpg")
        XCTAssertEqual([p.relPath, p.originalRelPath, p.location.rawValue], ["Seattle/IMG_10.jpg", "Trip/IMG_10.jpg", "filed"])

        let page = try JSONSerialization.jsonObject(with: catalog.pageData()) as! [String: Any]
        XCTAssertEqual((page["filed"] as! [String: String])[ids["Trip/IMG_10.jpg"]!], "Seattle/IMG_10.jpg")
        XCTAssertEqual((page["photos"] as! [String: [String: Any]])[ids["Trip/IMG_10.jpg"]!]?["path"] as? String, library.root.path + "/Seattle/IMG_10.jpg")
        XCTAssertEqual((page["photos"] as! [String: Any]).count, 30)  // nothing dropped, nothing doubled

        XCTAssertEqual(try catalog.organize(), OrganizeResult(), "a second run has nothing to do")
    }

    func testAFolderOfYoursIsACollectionAndStaysWhereItIs() throws {
        let page = try JSONSerialization.jsonObject(with: catalog.pageData()) as! [String: Any]
        let collections = page["collections"] as! [[String: Any]]
        XCTAssertEqual(collections.map { $0["name"] as! String }, ["Camera", "Trip"])
        XCTAssertEqual(collections.map { $0["source"] as? String }, ["Camera", "Trip"])
        XCTAssertEqual(collections.map { $0["kind"] as! String }, ["everyday", "trip"])
        XCTAssertEqual(collections.map { ($0["members"] as! [String]).count }, [24, 6])
        XCTAssertEqual(collections.map { $0["folderOn"] as! Bool }, [false, false])

        // Switched on under its own name, the folder is where its photos already are.
        let before = files()
        try catalog.setFolder(collectionOf: ids["Trip/IMG_10.jpg"], on: true)
        XCTAssertEqual(try catalog.organize(), OrganizeResult())
        XCTAssertEqual(files(), before)

        // Renamed, the photos follow; with the name taken back, they return to the folder they came from.
        try catalog.rename(collectionOf: ids["Trip/IMG_10.jpg"], to: "Seattle")
        XCTAssertEqual(try catalog.organize().filed, 6)
        try catalog.rename(collectionOf: ids["Trip/IMG_10.jpg"], to: "")
        XCTAssertEqual(try catalog.organize(), OrganizeResult(filed: 0, back: 6, folders: 0, errors: []))
        XCTAssertEqual(files(), before)
        XCTAssertEqual(folders(), ["Camera", "Trip"])
        XCTAssertEqual(try row("Trip/IMG_10.jpg").location, .inPlace)
    }

    func testOrganizeAgainFollowsARenameAMoveAndASwitchedOffFolder() throws {
        try nameTripAndSwitchFolderOn()
        _ = try catalog.organize()

        // Renamed: the folder follows, the old one disappears.
        try catalog.rename(collectionOf: ids["Trip/IMG_10.jpg"], to: "Seattle Fall")
        XCTAssertEqual(try catalog.organize().filed, 6)
        XCTAssertEqual(folders(), ["Camera", "Seattle Fall", "Trip"])  // "Seattle" was the app's and is gone
        XCTAssertTrue(has("Seattle Fall/IMG_10.MOV"))
        XCTAssertEqual(try row("Trip/IMG_10.jpg").originalRelPath, "Trip/IMG_10.jpg")

        // One photo moved to a collection without a folder: it goes back where it came from.
        try catalog.editCollections(.move, ids: [ids["Trip/sea18-1.jpg"]!], into: ids["Camera/home2.jpg"])
        let moved = try catalog.organize()
        XCTAssertEqual([moved.filed, moved.back], [0, 1])
        XCTAssertTrue(has("Trip/sea18-1.jpg") && !has("Seattle Fall/sea18-1.jpg"))
        XCTAssertEqual(try row("Trip/sea18-1.jpg").location, .inPlace)

        // Folder switched off: everything goes back, Live Photo video too.
        try catalog.setFolder(collectionOf: ids["Trip/IMG_10.jpg"], on: false)
        XCTAssertEqual(try catalog.organize().back, 5)
        XCTAssertEqual(folders(), ["Camera", "Trip"])
        XCTAssertTrue(has("Trip/IMG_10.jpg") && has("Trip/IMG_10.MOV"))
        XCTAssertEqual(try count("SELECT (SELECT COUNT(*) FROM companion) + (SELECT COUNT(*) FROM photo WHERE location <> 'in_place')"), 0)
    }

    func testNothingIsEverOverwritten() throws {
        try nameTripAndSwitchFolderOn()
        // A file of yours already sits where a photo would go.
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("Seattle"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: photos.appendingPathComponent("Seattle/IMG_11.jpg"))
        _ = try catalog.organize()
        XCTAssertEqual(try String(contentsOf: photos.appendingPathComponent("Seattle/IMG_11.jpg"), encoding: .utf8), "mine")
        XCTAssertEqual(try row("Trip/IMG_11.jpg").relPath, "Seattle/IMG_11 (2).jpg")

        // And where a photo would go back to.
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("Trip"), withIntermediateDirectories: true)
        try Data("also mine".utf8).write(to: photos.appendingPathComponent("Trip/IMG_11.jpg"))
        let undo = try catalog.undo(.organize)
        XCTAssertEqual(undo.restored, 5)
        XCTAssertEqual(undo.errors, ["Seattle/IMG_11 (2).jpg: a file already exists at the original location"])
        XCTAssertEqual(try String(contentsOf: photos.appendingPathComponent("Trip/IMG_11.jpg"), encoding: .utf8), "also mine")
        XCTAssertTrue(has("Seattle/IMG_11 (2).jpg"))
        XCTAssertEqual(try row("Trip/IMG_11.jpg").location, .filed)
    }

    // MARK: - Clean up

    func testCleanUpMovesWhatIsMarkedRemoveAndUndoPutsItBack() throws {
        let before = files()
        let remove = try catalog.effectiveStates().filter { $0.value == .remove }.keys
        XCTAssertEqual(remove.count, 2)  // the copy and the weaker of the two trip shots

        let r = try catalog.cleanUp()
        XCTAssertEqual([r.moved, r.reviewed, r.errors.count], [2, 0, 0])
        XCTAssertEqual(r.folder, library.root.path + "/_to_remove")
        XCTAssertTrue(has("_to_remove/Camera/home1 2.jpg"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE location = 'to_remove'"), 2)
        let page = try JSONSerialization.jsonObject(with: catalog.pageData()) as! [String: Any]
        XCTAssertEqual(Set(page["moved"] as! [String]), Set(remove))
        XCTAssertEqual(try catalog.cleanUp().moved, 0)

        XCTAssertEqual(try catalog.undo(.cleanup), UndoResult(restored: 2, skipped: 0, errors: []))
        XCTAssertEqual(files(), before)
        XCTAssertEqual(folders(), ["Camera", "Trip"])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE location <> 'in_place' OR removed_from_rel IS NOT NULL"), 0)
    }

    func testDuplicateCopiesCanGoFirstAndTheirGroupsCountAsReviewed() throws {
        let r = try catalog.cleanUp(duplicatesOnly: true)
        XCTAssertEqual([r.moved, r.reviewed], [1, 1])
        XCTAssertTrue(has("_to_remove/Camera/home1 2.jpg") && has("Camera/home1.jpg"))
        XCTAssertTrue(has("Trip/IMG_10.jpg") && has("Trip/IMG_11.jpg"), "the other group still needs your eyes")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM reviewed"), 2)
        let again = try catalog.cleanUp(duplicatesOnly: true)
        XCTAssertEqual([again.moved, again.reviewed], [0, 0])
    }

    func testCleanUpAfterOrganizeAndUndoInEitherOrder() throws {
        let before = files()
        try nameTripAndSwitchFolderOn()
        _ = try catalog.organize()
        let removed = try catalog.effectiveStates().first { $0.value == .remove && catalog.record(of: $0.key)!.location == .filed }!.key
        let original = catalog.record(of: removed)!.originalRelPath
        let name = (original as NSString).lastPathComponent
        XCTAssertEqual(try catalog.cleanUp().moved, 2)
        XCTAssertTrue(has("_to_remove/\(original)") && !has("Seattle/\(name)"), "taken out of its folder")

        // Undo organize first: the photo in _to_remove is left for the other undo.
        let organize = try catalog.undo(.organize)
        XCTAssertEqual([organize.restored, organize.skipped], [5, 1])
        // Undo clean-up puts it back where it was just before: its folder.
        XCTAssertEqual(try catalog.undo(.cleanup).restored, 2)
        XCTAssertTrue(has("Seattle/\(name)"))
        XCTAssertEqual(catalog.record(of: removed)?.location, .filed)
        XCTAssertEqual(try catalog.undo(.organize).restored, 1)
        XCTAssertEqual(files(), before)
        XCTAssertEqual(folders(), ["Camera", "Trip"])
    }

    func testYourChoiceDecidesWhatGoes() throws {
        try catalog.decide([ids["Camera/party3.jpg"]!: .remove, ids["Camera/home1 2.jpg"]!: .keep])
        _ = try catalog.cleanUp()
        XCTAssertTrue(has("_to_remove/Camera/party3.jpg"))
        XCTAssertTrue(has("Camera/home1 2.jpg"))
    }

    // MARK: - Things going wrong

    func testAnUnavailablePhotoFolderStopsEveryStepBeforeItStarts() throws {
        try nameTripAndSwitchFolderOn()
        let away = base.appendingPathComponent("unplugged")
        try FileManager.default.moveItem(at: photos, to: away)
        for step in [{ _ = try self.catalog.organize() }, { _ = try self.catalog.cleanUp() }, { _ = try self.catalog.undo(.cleanup) }] {
            XCTAssertThrowsError(try step()) { error in
                guard case CatalogError.unavailable = error else { return XCTFail("\(error)") }
            }
        }
        let router = Router(catalog: catalog, appDir: base)
        XCTAssertEqual(router.handle(method: "POST", path: "/api/organize", body: Data("{}".utf8)).status, 503)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM file_move"), 0)
        try FileManager.default.moveItem(at: away, to: photos)
    }

    func testAMoveInterruptedByACrashIsSettledAtTheNextOpen() throws {
        let a = Int64(ids["Trip/sea17-0.jpg"]!)!, b = Int64(ids["Trip/sea17-1.jpg"]!)!
        try library.store.db.write { db in
            // The app wrote down two moves and died: the first file had moved, the second had not.
            try db.execute(sql: "INSERT INTO file_move (photo_id, op, from_rel, to_rel, at) VALUES (?, 'file', 'Trip/sea17-0.jpg', 'Seattle/sea17-0.jpg', 0)", arguments: [a])
            try db.execute(sql: "INSERT INTO file_move (photo_id, op, from_rel, to_rel, at) VALUES (?, 'remove', 'Trip/sea17-1.jpg', '_to_remove/Trip/sea17-1.jpg', 0)", arguments: [b])
        }
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("Seattle"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: photos.appendingPathComponent("Trip/sea17-0.jpg"), to: photos.appendingPathComponent("Seattle/sea17-0.jpg"))

        catalog = try Catalog(library: library, timeZone: utc)
        let moved = try row("Trip/sea17-0.jpg"), stayed = try row("Trip/sea17-1.jpg")
        XCTAssertEqual([moved.relPath, moved.location.rawValue], ["Seattle/sea17-0.jpg", "filed"])
        XCTAssertEqual([stayed.relPath, stayed.location.rawValue], ["Trip/sea17-1.jpg", "in_place"])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM file_move WHERE done = 0"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM file_move"), 1)
        XCTAssertEqual(try catalog.undo(.organize).restored, 1)  // and it can still be undone
        XCTAssertTrue(has("Trip/sea17-0.jpg"))
    }

    func testEveryMoveIsWrittenDown() throws {
        try nameTripAndSwitchFolderOn()
        _ = try catalog.organize()
        _ = try catalog.cleanUp()
        _ = try catalog.undo(.cleanup)
        let ops = try library.store.db.read { try Row.fetchAll($0, sql: "SELECT op, COUNT(*) AS n, MIN(done) AS done FROM file_move GROUP BY op ORDER BY op") }
        XCTAssertEqual(ops.map { "\($0["op"] as String) \($0["n"] as Int) \($0["done"] as Int)" }, ["file 7", "remove 2", "unremove 2"].map { $0 + " 1" })
    }

    // MARK: - You moved things yourself

    func testAFolderRenamedInFinderIsFollowedByTheNextScan() async throws {
        try nameTripAndSwitchFolderOn()
        _ = try catalog.organize()
        try FileManager.default.moveItem(at: photos.appendingPathComponent("Seattle"), to: photos.appendingPathComponent("Seattle 2026"))

        let s = try await Analyzer(library: library).run()
        XCTAssertEqual([s.relinked, s.analyzed, s.missing], [6, 0, 0])
        try catalog.regroup()
        let p = try row("Trip/IMG_10.jpg")
        XCTAssertEqual([p.relPath, p.originalRelPath, p.location.rawValue], ["Seattle 2026/IMG_10.jpg", "Trip/IMG_10.jpg", "filed"])
        XCTAssertEqual(catalog.photoCount, 30)

        // Undo still knows where everything came from, the Live Photo video included.
        XCTAssertEqual(try catalog.undo(.organize).restored, 6)
        XCTAssertTrue(has("Trip/IMG_10.jpg") && has("Trip/IMG_10.MOV"))
        XCTAssertEqual(folders(), ["Camera", "Trip"])
    }

    func testAnEmptiedRemoveFolderJustMeansThosePhotosAreGone() async throws {
        _ = try catalog.cleanUp()
        try FileManager.default.removeItem(at: photos.appendingPathComponent("_to_remove"))
        let s = try await Analyzer(library: library).run()
        XCTAssertEqual(s.missing, 2)
        try catalog.regroup()
        XCTAssertEqual(catalog.photoCount, 28)
        XCTAssertEqual(try catalog.undo(.cleanup), UndoResult())
    }

    func testAPhotoFolderReachedThroughALinkWorksTheSame() throws {
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: photos)
        try library.store.setMeta("root", link.path)  // as an older library might have stored it
        library = try Library.open(at: library.dir)
        catalog = try Catalog(library: library, timeZone: utc)
        try nameTripAndSwitchFolderOn()
        XCTAssertEqual(try catalog.organize().filed, 6)
        XCTAssertEqual(try catalog.organize().filed, 0, "already in its folder, however the path is spelled")
        XCTAssertEqual(try catalog.undo(.organize).restored, 6)
    }
}
