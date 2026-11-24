import Foundation
import GRDB

/// ArcFace cosine similarity: the same person is typically above 0.4, different people below 0.2.
public let youThreshold = 0.36

public enum FacesError: LocalizedError {
    case noUsableFace

    public var errorDescription: String? {
        switch self {
        case .noUsableFace: "No usable face found in the reference photo(s). Use a clear, front-facing photo of you."
        }
    }
}

/// Finds the photos you are in, fully on device: every face embedding in the library is compared
/// with the face of your reference photo(s).
public struct Me {
    let store: Store

    public init(store: Store) { self.store = store }

    public var hasReference: Bool {
        (try? store.db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM reference_face)") }) ?? false
    }

    /// Replaces the reference with the largest face of each given photo, then matches the library.
    /// Returns how many reference photos had a usable face.
    @discardableResult
    public func setReference(photos: [URL], embedder: FaceEmbedder) async throws -> Int {
        var found: [(String, [Float])] = []
        for url in photos {
            let a = await analyzeImage(at: url, embedder: embedder)
            let usable = a.faces.filter { $0.embedding != nil }
            guard let biggest = usable.max(by: { $0.box.width * $0.box.height < $1.box.width * $1.box.height }) else { continue }
            found.append((url.path, biggest.embedding!))
        }
        guard !found.isEmpty else { throw FacesError.noUsableFace }
        let reference = found
        try await store.db.write { db in
            try db.execute(sql: "DELETE FROM reference_face")
            for (path, v) in reference {
                try db.execute(sql: "INSERT INTO reference_face (source_path, embedding) VALUES (?, ?)",
                               arguments: [path, v.withUnsafeBufferPointer { Data(buffer: $0) }])
            }
        }
        try match()
        return found.count
    }

    /// Stores, per photo with faces, the best similarity to you and which face it was. Run after a
    /// scan and after the reference changes. Without a reference every match is cleared.
    public func match() throws {
        try store.db.write { db in
            let reference = try Data.fetchAll(db, sql: "SELECT embedding FROM reference_face").map(Self.floats)
            try db.execute(sql: "UPDATE photo SET me_sim = NULL, me_face = NULL WHERE me_sim IS NOT NULL")
            guard !reference.isEmpty else { return }
            var best: [Int64: (sim: Float, face: Int)] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT photo_id, idx, embedding FROM face WHERE embedding IS NOT NULL ORDER BY photo_id, idx")
            while let row = try rows.next() {
                let v = Self.floats(row["embedding"])
                let sim = reference.map { r in zip(r, v).reduce(Float(0)) { $0 + $1.0 * $1.1 } }.max()!
                let pid: Int64 = row["photo_id"]
                if best[pid] == nil || sim > best[pid]!.sim { best[pid] = (sim, row["idx"]) }
            }
            let update = try db.makeStatement(sql: "UPDATE photo SET me_sim = ?, me_face = ? WHERE id = ?")
            for (pid, b) in best {
                try update.execute(arguments: [(Double(b.sim) * 10000).rounded() / 10000, b.face, pid])
            }
        }
    }

    private static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
