import GRDB
import ImageIO
import XCTest
@testable import PhotoCleanupCore

/// The interface's requests above a single library: the list of folders, opening one, and what is
/// passed on to the open library.
final class AppRouterTests: XCTestCase {
    var base: URL!
    var workspace: Workspace!
    var router: AppRouter!
    var photo = ""

    final class Picker: WorkspaceUI {
        var revealed: [URL] = []
        var windowActions: [String] = []
        func choose(_ kind: String) -> [URL] { [URL(fileURLWithPath: "/picked/\(kind)")] }
        func reveal(_ url: URL) { revealed.append(url) }
        func openSettings() {}
        func openTerminal() {}
        func window(_ action: String) { windowActions.append(action) }
    }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        let photos = base.appendingPathComponent("photos"), ui = base.appendingPathComponent("ui"), libraries = base.appendingPathComponent("libraries")
        for dir in [photos, ui, libraries] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("<h1>page</h1>".utf8).write(to: ui.appendingPathComponent("index.html"))
        try writeJPEG(makePicture(seed: 1, size: 1600), to: photos.appendingPathComponent("a.jpg"))
        let library = try Library.create(at: libraries.appendingPathComponent("one"), photoFolder: photos, name: "Holiday")
        photo = try library.store.db.write { db in
            try db.execute(sql: """
                INSERT INTO photo (rel_path, original_rel_path, size, mtime, width, height, sharpness, analysis_version)
                VALUES ('a.jpg', 'a.jpg', 1, 1000, 1600, 1600, 400, ?)
                """, arguments: [analysisVersion])
            return String(db.lastInsertedRowID)
        }
        try writeJPEG(makePicture(seed: 1, size: 64), to: library.thumbURL(Int64(photo)!))
        workspace = Workspace(librariesDir: libraries, uiDir: ui)
        router = AppRouter(workspace: workspace)
    }

    override func tearDownWithError() throws {
        workspace?.close()
        router = nil
        workspace = nil
        try? FileManager.default.removeItem(at: base)
    }

    func json(_ r: RouterResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
    }

    func post(_ path: String, _ body: [String: Any] = [:]) -> RouterResponse {
        router.handle(method: "POST", path: path, body: try! JSONSerialization.data(withJSONObject: body))
    }

    func testStateListsFoldersAndOpeningOneServesItsData() throws {
        var state = json(router.handle(method: "GET", path: "/app/state"))
        let folders = state["folders"] as! [[String: Any]]
        XCTAssertEqual(folders.map { $0["id"] as! String }, ["one"])
        XCTAssertEqual(folders[0]["name"] as? String, "Holiday")
        XCTAssertEqual(folders[0]["photos"] as? Int, 1)
        XCTAssertEqual(folders[0]["connected"] as? Bool, true)
        XCTAssertTrue(state["open"] is NSNull)

        // Nothing of a library is served until one is open.
        XCTAssertEqual(router.handle(method: "GET", path: "/api/data").status, 409)
        XCTAssertEqual(router.handle(method: "GET", path: "/thumb/\(photo)").status, 409)

        let opened = post("/app/open", ["id": "one"])
        XCTAssertEqual(opened.status, 200)
        state = json(opened)["state"] as! [String: Any]
        XCTAssertEqual(state["open"] as? String, "one")
        let data = json(router.handle(method: "GET", path: "/api/data"))
        XCTAssertEqual((data["photos"] as? [String: Any])?.count, 1)
        XCTAssertEqual(router.handle(method: "GET", path: "/thumb/\(photo)").file?.lastPathComponent, "\(photo).jpg")

        state = json(post("/app/close"))["state"] as! [String: Any]
        XCTAssertTrue(state["open"] is NSNull)
        XCTAssertEqual(router.handle(method: "GET", path: "/api/data").status, 409)
    }

    func testTheMiddleSizeIsMadeOnceAndIsSmallerThanThePhoto() throws {
        _ = post("/app/open", ["id": "one"])
        let first = router.handle(method: "GET", path: "/mid/\(photo)")
        let file = try XCTUnwrap(first.file)
        XCTAssertEqual(file.lastPathComponent, "\(photo).mid.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 1280)
        let made = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(try router.handle(method: "GET", path: "/mid/\(photo)").file?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, made)
        XCTAssertEqual(router.handle(method: "GET", path: "/mid/999").status, 404)
    }

    func testFolderCoversAndPageFilesComeFromTheirOwnPlaces() {
        XCTAssertEqual(router.handle(method: "GET", path: "/app/thumb/one/\(photo)").file?.path, base.appendingPathComponent("libraries/one/thumbs/\(photo).jpg").path)
        for path in ["/app/thumb/../\(photo)", "/app/thumb/one/x", "/app/thumb/.hidden/1", "/app/nothing"] {
            XCTAssertEqual(router.handle(method: "GET", path: path).status, 404, path)
        }
        XCTAssertEqual(router.handle(method: "GET", path: "/").file?.lastPathComponent, "index.html")
        XCTAssertEqual(router.handle(method: "GET", path: "/library.sqlite").status, 404)
        XCTAssertEqual(router.handle(method: "POST", path: "/index.html").status, 405)
    }

    func testWhatNeedsTheMacSaysSoAndUnknownRequestsAreRefused() {
        XCTAssertEqual(post("/app/choose", ["kind": "folder"]).status, 400)  // no app behind this workspace
        XCTAssertEqual(post("/app/nonsense").status, 400)
        XCTAssertEqual(post("/app/open", ["id": "../one"]).status, 400)
        XCTAssertEqual(post("/app/add", ["path": base.appendingPathComponent("missing").path]).status, 400)

        let picker = Picker()
        workspace.ui = picker
        XCTAssertEqual(json(post("/app/choose", ["kind": "me"]))["paths"] as? [String], ["/picked/me"])
        XCTAssertEqual(post("/app/reveal", ["id": "one"]).status, 200)
        XCTAssertEqual(picker.revealed.map(\.lastPathComponent), ["photos"])
        // Moving the window answers at once, without the state.
        let moved = json(post("/app/window", ["action": "drag"]))
        XCTAssertNil(moved["state"])
        XCTAssertEqual(picker.windowActions, ["drag"])
    }

    func testRemovingAFolderTakesItsLibraryAwayAndLeavesThePhotos() throws {
        workspace.discard = { try FileManager.default.removeItem(at: $0) }  // the app uses the Trash; a test must not fill it
        _ = post("/app/open", ["id": "one"])
        let state = json(post("/app/remove", ["id": "one"]))["state"] as! [String: Any]
        XCTAssertTrue(state["open"] is NSNull)
        XCTAssertEqual((state["folders"] as! [[String: Any]]).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("libraries/one").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("photos/a.jpg").path))
    }
}
