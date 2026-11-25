import GRDB
import XCTest
@testable import PhotoCleanupCore

final class MeTests: XCTestCase {
    var dir: URL!
    var store: Store!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try Store(path: dir.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// A unit vector along one axis, tilted towards another: `along` with similarity `cos` to axis 0.
    func vector(cos: Float, other: Int = 1) -> Data {
        var v = [Float](repeating: 0, count: 512)
        v[0] = cos
        v[other] = (1 - cos * cos).squareRoot()
        return v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testAReferenceFromAnotherFaceModelIsNotComparedAndIsKnownToBeStale() throws {
        // A reference of 512 numbers (the earlier model) against faces of 128 numbers.
        var short = [Float](repeating: 0, count: 128)
        short[0] = 1
        let id = try addPhoto("a.jpg", faces: [short.withUnsafeBufferPointer { Data(buffer: $0) }])
        try setReference([vector(cos: 1)])
        let me = Me(store: store)
        XCTAssertTrue(me.referenceIsStale(dimensions: 128))
        XCTAssertFalse(me.referenceIsStale(dimensions: 512))
        XCTAssertEqual(me.referencePaths, ["me.jpg"])
        try me.match()
        XCTAssertNil(try match(id).sim)
    }

    func addPhoto(_ rel: String, faces: [Data?]) throws -> Int64 {
        try store.db.write { db in
            try db.execute(sql: """
                INSERT INTO photo (rel_path, original_rel_path, size, mtime, width, height, sharpness, analysis_version)
                VALUES (?, ?, 1, 0, 10, 10, 1, ?)
                """, arguments: [rel, rel, analysisVersion])
            let id = db.lastInsertedRowID
            for (i, e) in faces.enumerated() {
                try db.execute(sql: "INSERT INTO face (photo_id, idx, x, y, w, h, embedding) VALUES (?, ?, 0, 0, 1, 1, ?)", arguments: [id, i, e])
            }
            return id
        }
    }

    func setReference(_ vectors: [Data]) throws {
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM reference_face")
            for v in vectors { try db.execute(sql: "INSERT INTO reference_face (source_path, embedding) VALUES ('me.jpg', ?)", arguments: [v]) }
        }
    }

    func match(_ id: Int64) throws -> (sim: Double?, face: Int?) {
        try store.db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT me_sim, me_face FROM photo WHERE id = ?", arguments: [id])!
            return (row["me_sim"], row["me_face"])
        }
    }

    func testBestMatchingFaceOfEachPhotoIsStored() throws {
        let group = try addPhoto("group.jpg", faces: [vector(cos: 0.1), vector(cos: 0.8), nil])
        let stranger = try addPhoto("stranger.jpg", faces: [vector(cos: 0.05)])
        let landscape = try addPhoto("landscape.jpg", faces: [])
        let tooSmall = try addPhoto("far-away.jpg", faces: [nil])
        try setReference([vector(cos: 1)])
        try Me(store: store).match()

        XCTAssertEqual(try match(group).sim ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(try match(group).face, 1)
        XCTAssertEqual(try match(stranger).sim ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertNil(try match(landscape).sim)
        XCTAssertNil(try match(tooSmall).sim)
        let you = try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo WHERE me_sim >= ?", arguments: [youThreshold]) }
        XCTAssertEqual(you, 1)
    }

    func testSeveralReferencePhotosUseTheClosest() throws {
        let id = try addPhoto("a.jpg", faces: [vector(cos: 0.2, other: 2)])
        // The second reference points along axis 2, where this face mostly is.
        var second = [Float](repeating: 0, count: 512)
        second[2] = 1
        try setReference([vector(cos: 1), second.withUnsafeBufferPointer { Data(buffer: $0) }])
        try Me(store: store).match()
        XCTAssertEqual(try match(id).sim ?? 0, Double((1 - 0.2 * 0.2 as Float).squareRoot()), accuracy: 0.0001)
    }

    func testRemovingTheReferenceClearsEveryMatch() throws {
        let id = try addPhoto("a.jpg", faces: [vector(cos: 0.9)])
        try setReference([vector(cos: 1)])
        try Me(store: store).match()
        XCTAssertNotNil(try match(id).sim)
        try setReference([])
        try Me(store: store).match()
        XCTAssertNil(try match(id).sim)
        XCTAssertFalse(Me(store: store).hasReference)
    }

    func testReferencePhotoWithoutAFaceIsRejectedAndKeepsTheOldOne() async throws {
        let model = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../models/SFace.mlmodelc").standardizedFileURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path), "run scripts/convert_face_model.py to test with the face model")
        let embedder = try CoreMLFaceEmbedder(compiledModelAt: model)

        // The embedder itself: unit length, right size, same answer twice.
        let crop = makePicture(seed: 5, size: faceCropSize)
        let e = try embedder.embed(crop)
        XCTAssertEqual(e.count, 128)
        XCTAssertEqual(embedder.dimensions, 128)
        XCTAssertEqual(e.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1, accuracy: 0.0001)
        XCTAssertEqual(e, try embedder.embed(crop))

        try setReference([vector(cos: 1)])
        let noFace = dir.appendingPathComponent("shapes.jpg")
        try writeJPEG(makePicture(seed: 6), to: noFace)
        do {
            try await Me(store: store).setReference(photos: [noFace], embedder: embedder)
            XCTFail("a photo without a face cannot be the reference")
        } catch FacesError.noUsableFace {}
        XCTAssertTrue(Me(store: store).hasReference)
    }
}
