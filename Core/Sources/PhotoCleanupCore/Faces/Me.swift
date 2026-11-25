import Foundation
import GRDB

/// SFace cosine similarity, at the threshold its authors publish. On 2,374 real faces of one library
/// the photos of its owner scored 0.49 and up (5th percentile) and other people's faces 0.31 and
/// down (99.5th percentile).
public let youThreshold = 0.363

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

    /// The photos of you the reference was made from.
    public var referencePaths: [String] {
        (try? store.db.read { try String.fetchAll($0, sql: "SELECT source_path FROM reference_face ORDER BY rowid") }) ?? []
    }

    /// True when the reference was made with another face model than the one in use: its numbers
    /// mean nothing to this one, so it has to be made again from the same photos.
    public func referenceIsStale(dimensions: Int) -> Bool {
        let sizes = (try? store.db.read { try Int.fetchAll($0, sql: "SELECT length(embedding) FROM reference_face") }) ?? []
        return sizes.contains { $0 != dimensions * MemoryLayout<Float>.size }
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
                // Embeddings of different models cannot be compared: only same-length ones count.
                guard let sim = reference.filter({ $0.count == v.count }).map({ r in zip(r, v).reduce(Float(0)) { $0 + $1.0 * $1.1 } }).max() else { continue }
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
