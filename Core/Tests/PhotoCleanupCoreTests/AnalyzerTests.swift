import CoreGraphics
import GRDB
import XCTest
@testable import PhotoCleanupCore

/// A deterministic test picture: a colored background with shapes placed from `seed`.
func makePicture(seed: Int, size: Int = 640) -> CGImage {
    var state = UInt64(seed) &* 0x9E3779B97F4A7C15 &+ 1
    func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(1 << 31)
    }
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    for _ in 0..<12 {
        ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
        let r = CGRect(x: next() * Double(size), y: next() * Double(size), width: 40 + next() * 200, height: 40 + next() * 200)
        if next() > 0.5 { ctx.fillEllipse(in: r) } else { ctx.fill(r) }
    }
    return ctx.makeImage()!
}

final class AnalyzerTests: XCTestCase {
    var base: URL!
    var photos: URL!
    var library: Library!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        photos = base.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        library = try Library.create(at: base.appendingPathComponent("library"), photoFolder: photos)
    }

    override func tearDownWithError() throws {
        library = nil
        try? FileManager.default.removeItem(at: base)
    }

    func write(_ rel: String, seed: Int) throws {
        let url = photos.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJPEG(makePicture(seed: seed), to: url, quality: 0.9)
    }

    func move(_ from: String, _ to: String) throws {
        let dst = photos.appendingPathComponent(to)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: photos.appendingPathComponent(from), to: dst)
    }

    func scan() async throws -> ScanSummary { try await Analyzer(library: library).run() }

    func id(_ rel: String) throws -> Int64? {
        try library.store.db.read { try Int64.fetchOne($0, sql: "SELECT id FROM photo WHERE rel_path = ?", arguments: [rel]) }
    }

    func count(_ sql: String) throws -> Int { try library.store.db.read { try Int.fetchOne($0, sql: sql) ?? 0 } }

    func testScanStoresPhotosThumbnailsAndNeighbors() async throws {
        try write("a.jpg", seed: 1)
        try FileManager.default.copyItem(at: photos.appendingPathComponent("a.jpg"), to: photos.appendingPathComponent("a 2.jpg"))
        try write("trip/b.jpg", seed: 2)
        try write("trip/c.jpg", seed: 3)

        let s = try await scan()
        XCTAssertEqual(s.found, 4)
        XCTAssertEqual(s.analyzed, 4)
        XCTAssertEqual(s.failed, [])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE feature IS NOT NULL AND width = 640 AND height = 640 AND fingerprint IS NOT NULL"), 4)
        for pid in try await library.store.db.read({ try Int64.fetchAll($0, sql: "SELECT id FROM photo") }) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: library.thumbURL(pid).path))
        }
        // The byte-identical copy is its neighbor, at (almost) no distance.
        let a = try XCTUnwrap(try id("a.jpg")), copy = try XCTUnwrap(try id("a 2.jpg"))
        let d = try await library.store.db.read {
            try Double.fetchOne($0, sql: "SELECT distance FROM neighbor WHERE a = ? AND b = ?", arguments: [min(a, copy), max(a, copy)])
        }
        XCTAssertLessThan(try XCTUnwrap(d), 0.06)
    }

    func testSecondScanAnalyzesNothing() async throws {
        try write("a.jpg", seed: 1)
        try write("b.jpg", seed: 2)
        _ = try await scan()
        let s = try await scan()
        XCTAssertEqual(s, ScanSummary(found: 2))
    }

    func testChangedFileIsAnalyzedAgainAsTheSamePhoto() async throws {
        try write("a.jpg", seed: 1)
        _ = try await scan()
        let before = try id("a.jpg")
        try write("a.jpg", seed: 9)
        let s = try await scan()
        XCTAssertEqual(s.analyzed, 1)
        XCTAssertEqual(try id("a.jpg"), before)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo"), 1)
    }

    func testFileMovedOutsideTheAppKeepsItsIdentity() async throws {
        try write("a.jpg", seed: 1)
        try write("b.jpg", seed: 2)
        _ = try await scan()
        let before = try id("a.jpg")
        try move("a.jpg", "2026 Seattle/renamed.jpg")

        let s = try await scan()
        XCTAssertEqual(s.relinked, 1)
        XCTAssertEqual(s.analyzed, 0)
        XCTAssertEqual(s.missing, 0)
        XCTAssertEqual(try id("2026 Seattle/renamed.jpg"), before)
        let original = try await library.store.db.read { try String.fetchOne($0, sql: "SELECT original_rel_path FROM photo WHERE id = ?", arguments: [before]) }
        XCTAssertEqual(original, "a.jpg")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo"), 2)
    }

    func testIdenticalCopiesMovedTogetherAreMatchedByName() async throws {
        try write("x/IMG_1.jpg", seed: 1)
        try FileManager.default.copyItem(at: photos.appendingPathComponent("x/IMG_1.jpg"), to: photos.appendingPathComponent("x/IMG_1 2.jpg"))
        _ = try await scan()
        let original = try id("x/IMG_1.jpg"), copy = try id("x/IMG_1 2.jpg")
        try move("x/IMG_1 2.jpg", "y/IMG_1 2.jpg")
        try move("x/IMG_1.jpg", "y/IMG_1.jpg")

        let s = try await scan()
        XCTAssertEqual(s.relinked, 2)
        XCTAssertEqual(try id("y/IMG_1.jpg"), original)
        XCTAssertEqual(try id("y/IMG_1 2.jpg"), copy)
    }

    func testDeletedFileIsFlaggedAndComesBack() async throws {
        try write("a.jpg", seed: 1)
        try write("b.jpg", seed: 2)
        _ = try await scan()
        let before = try id("a.jpg")
        let parked = base.appendingPathComponent("parked.jpg")
        try FileManager.default.moveItem(at: photos.appendingPathComponent("a.jpg"), to: parked)

        let gone = try await scan()
        XCTAssertEqual(gone.missing, 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE missing = 1"), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM neighbor WHERE a = \(before!) OR b = \(before!)"), 0)

        try FileManager.default.moveItem(at: parked, to: photos.appendingPathComponent("a.jpg"))
        let back = try await scan()
        XCTAssertEqual(back.missing, 0)
        XCTAssertEqual(back.analyzed, 0)
        XCTAssertEqual(try id("a.jpg"), before)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE missing = 1"), 0)
    }

    func testUnavailablePhotoFolderChangesNothing() async throws {
        try write("a.jpg", seed: 1)
        _ = try await scan()
        let away = base.appendingPathComponent("unplugged")
        try FileManager.default.moveItem(at: photos, to: away)
        do {
            _ = try await scan()
            XCTFail("a scan without the photo folder must fail")
        } catch LibraryError.photoFolderUnavailable {}
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE missing = 0"), 1)
        try FileManager.default.moveItem(at: away, to: photos)
    }

    func testRemoveFolderIsNotScannedAndItsPhotosAreNotMissing() async throws {
        try write("a.jpg", seed: 1)
        try write("b.jpg", seed: 2)
        _ = try await scan()
        let a = try XCTUnwrap(try id("a.jpg"))
        // What the clean-up step does: move the file and update the row together.
        try move("a.jpg", "_to_remove/a.jpg")
        try await library.store.db.write { try $0.execute(sql: "UPDATE photo SET rel_path = '_to_remove/a.jpg', location = 'to_remove' WHERE id = ?", arguments: [a]) }

        let s = try await scan()
        XCTAssertEqual(s, ScanSummary(found: 1))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo"), 2)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE missing = 1"), 0)
    }

    func testUnreadableFileIsReportedNotGuessed() async throws {
        try write("a.jpg", seed: 1)
        try Data("not a picture".utf8).write(to: photos.appendingPathComponent("broken.jpg"))
        let s = try await scan()
        XCTAssertEqual(s.failed, ["broken.jpg"])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE rel_path = 'broken.jpg' AND width = 0 AND error IS NOT NULL AND feature IS NULL"), 1)
        // It is tried again next time, in case the file was still being copied.
        let again = try await scan()
        XCTAssertEqual(again.analyzed, 1)
    }

    func testSymlinkedPhotoFolderIsOneLibrary() async throws {
        try write("a.jpg", seed: 1)
        _ = try await scan()
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: photos)
        let viaLink = try Library.create(at: base.appendingPathComponent("library2"), photoFolder: link)
        XCTAssertEqual(viaLink.root.path, library.root.path)
    }
}
