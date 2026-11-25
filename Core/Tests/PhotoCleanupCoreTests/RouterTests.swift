import GRDB
import XCTest
@testable import PhotoCleanupCore

final class RouterTests: XCTestCase {
    var base: URL!
    var library: Library!
    var router: Router!
    var a = "", b = ""

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        let photos = base.appendingPathComponent("photos"), app = base.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("<h1>page</h1>".utf8).write(to: app.appendingPathComponent("index.html"))
        try Data("secret".utf8).write(to: base.appendingPathComponent("outside.html"))
        library = try Library.create(at: base.appendingPathComponent("library"), photoFolder: photos)

        // One JPEG the web view can show as it is, one TIFF it cannot.
        try writeJPEG(makePicture(seed: 1, size: 320), to: photos.appendingPathComponent("a.jpg"))
        let tiff = CGImageDestinationCreateWithURL(photos.appendingPathComponent("b.tiff") as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(tiff, makePicture(seed: 2, size: 320), nil)
        XCTAssertTrue(CGImageDestinationFinalize(tiff))
        (a, b) = try library.store.db.write { db in
            var ids: [String] = []
            for rel in ["a.jpg", "b.tiff"] {
                try db.execute(sql: """
                    INSERT INTO photo (rel_path, original_rel_path, size, mtime, width, height, sharpness, analysis_version)
                    VALUES (?, ?, 1, 1000, 320, 320, 400, ?)
                    """, arguments: [rel, rel, analysisVersion])
                ids.append(String(db.lastInsertedRowID))
            }
            return (ids[0], ids[1])
        }
        try writeJPEG(makePicture(seed: 1, size: 64), to: library.thumbURL(Int64(a)!))
        router = Router(catalog: try Catalog(library: library), appDir: app)
    }

    override func tearDownWithError() throws {
        router = nil
        library = nil
        try? FileManager.default.removeItem(at: base)
    }

    func json(_ r: RouterResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
    }

    func post(_ path: String, _ body: [String: Any]) -> RouterResponse {
        router.handle(method: "POST", path: path, body: try! JSONSerialization.data(withJSONObject: body))
    }

    func testPageFilesAreServedAndNothingElse() {
        let index = router.handle(method: "GET", path: "/")
        XCTAssertEqual(index.file?.lastPathComponent, "index.html")
        XCTAssertEqual(index.cache, "no-cache")
        for path in ["/../outside.html", "/%2e%2e/outside.html", "/sub/index.html", "/.hidden.html", "/library.sqlite", "/index.exe", ""] {
            XCTAssertEqual(router.handle(method: "GET", path: path).status, 404, path)
        }
        XCTAssertEqual(router.handle(method: "DELETE", path: "/api/data").status, 405)
    }

    func testImagesAreServedFromWhereThePhotoIsNow() throws {
        XCTAssertEqual(router.handle(method: "GET", path: "/thumb/\(a)").file, library.thumbURL(Int64(a)!))
        XCTAssertEqual(router.handle(method: "GET", path: "/thumb/999").status, 404)
        XCTAssertEqual(router.handle(method: "GET", path: "/thumb/../library.sqlite").status, 404)

        let full = router.handle(method: "GET", path: "/full/\(a)")
        XCTAssertEqual(full.file?.path, library.root.appendingPathComponent("a.jpg").path)
        XCTAssertEqual(full.contentType, "image/jpeg")

        // A format the web view cannot show gets a JPEG preview, made once and not upscaled.
        let preview = router.handle(method: "GET", path: "/full/\(b)")
        XCTAssertEqual(preview.file?.deletingLastPathComponent().lastPathComponent, "previews")
        let src = CGImageSourceCreateWithURL(try XCTUnwrap(preview.file) as CFURL, nil)!
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(src, 0, nil)?.width, 320)
        let made = try FileManager.default.attributesOfItem(atPath: preview.file!.path)[.modificationDate] as? Date
        _ = router.handle(method: "GET", path: "/full/\(b)")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: preview.file!.path)[.modificationDate] as? Date, made)
    }

    func testRequestsAreValidated() {
        XCTAssertEqual(json(post("/api/decide", ["changes": [a: "remove", b: "sideways", "nope": "keep"]]))["decisions"] as? [String: String], [a: "remove"])
        XCTAssertEqual(json(post("/api/decide", ["changes": [a: NSNull()]]))["decisions"] as? [String: String], [:])
        XCTAssertEqual(json(post("/api/reviewed", ["ids": [a, "nope"], "reviewed": true]))["reviewed"] as? [String], [a])
        XCTAssertEqual(post("/api/name", ["id": "nope", "name": "x"]).status, 400)
        XCTAssertEqual(post("/api/collections", ["op": "explode", "ids": [a]]).status, 400)
        XCTAssertEqual(json(post("/api/collections", ["op": "merge", "ids": [a]]))["error"] as? String, "pick at least two collections to merge")
        XCTAssertEqual(router.handle(method: "POST", path: "/api/decide", body: Data("not json".utf8)).status, 200)
        XCTAssertEqual(post("/api/elsewhere", [:]).status, 404)
        XCTAssertEqual(json(router.handle(method: "GET", path: "/api/data"))["root"] as? String, library.root.path)
    }
}
