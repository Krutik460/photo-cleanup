import Foundation
import GRDB

/// Your names, folder switches and collection edits as stored: each one with the photos (an anchor
/// set) of the collection it was made on.
struct StoredEdits {
    struct Named { let id: Int64; let photos: [String]; let name: String }
    struct Listed { let id: Int64; let photos: [String] }
    struct Merge { let id: Int64; let parts: [[String]] }
    struct Move { let id: Int64; let photos: [String]; let into: [String] }

    var names: [Named] = []
    var folders: [Listed] = []
    var merges: [Merge] = []
    var notCollections: [Listed] = []
    var moves: [Move] = []

    var grouping: GroupingEdits {
        GroupingEdits(merges: merges.map(\.parts), notCollections: notCollections.map(\.photos), moves: moves.map { ($0.photos, $0.into) })
    }

    /// Names and folder switches held by a "not a trip" mark are left out: they come back on restore.
    static func load(_ db: Database) throws -> StoredEdits {
        var sets: [Int64: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT set_id, photo_id FROM anchor_set_photo ORDER BY set_id, position") {
            sets[row["set_id"], default: []].append(String(row["photo_id"] as Int64))
        }
        func photos(_ set: Int64) -> [String] { sets[set] ?? [] }
        var out = StoredEdits()
        out.names = try Row.fetchAll(db, sql: "SELECT id, set_id, name FROM collection_name WHERE held_by IS NULL ORDER BY id")
            .map { Named(id: $0["id"], photos: photos($0["set_id"]), name: $0["name"]) }
        out.folders = try Row.fetchAll(db, sql: "SELECT id, set_id FROM folder_switch WHERE held_by IS NULL ORDER BY id")
            .map { Listed(id: $0["id"], photos: photos($0["set_id"])) }
        out.notCollections = try Row.fetchAll(db, sql: "SELECT id, set_id FROM edit_not_collection ORDER BY id")
            .map { Listed(id: $0["id"], photos: photos($0["set_id"])) }
        out.moves = try Row.fetchAll(db, sql: "SELECT id, photos_set, into_set FROM edit_move ORDER BY id")
            .map { Move(id: $0["id"], photos: photos($0["photos_set"]), into: photos($0["into_set"])) }
        var parts: [Int64: [[String]]] = [:]
        var order: [Int64] = []
        for row in try Row.fetchAll(db, sql: "SELECT merge_id, set_id FROM edit_merge_part ORDER BY merge_id, position") {
            let id: Int64 = row["merge_id"]
            if parts[id] == nil { order.append(id) }
            parts[id, default: []].append(photos(row["set_id"]))
        }
        out.merges = order.map { Merge(id: $0, parts: parts[$0]!) }
        return out
    }

    // MARK: - Writing

    @discardableResult
    static func insertSet(_ db: Database, _ photos: [String]) throws -> Int64 {
        try db.execute(sql: "INSERT INTO anchor_set DEFAULT VALUES")
        let id = db.lastInsertedRowID
        let insert = try db.makeStatement(sql: "INSERT INTO anchor_set_photo (set_id, position, photo_id) VALUES (?, ?, ?)")
        for (i, p) in photos.enumerated() {
            guard let pid = Int64(p) else { continue }
            try insert.execute(arguments: [id, i, pid])
        }
        return id
    }

    /// Deletes rows of a table that owns anchor sets, and those sets with them.
    static func delete(_ db: Database, from table: String, ids: [Int64], setColumns: [String]) throws {
        for id in ids {
            let sets = try setColumns.flatMap { try Int64.fetchAll(db, sql: "SELECT \($0) FROM \(table) WHERE id = ?", arguments: [id]) }
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id])
            for s in sets { try db.execute(sql: "DELETE FROM anchor_set WHERE id = ?", arguments: [s]) }
        }
    }

    static func deleteMerges(_ db: Database, ids: [Int64]) throws {
        for id in ids {
            let sets = try Int64.fetchAll(db, sql: "SELECT set_id FROM edit_merge_part WHERE merge_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM edit_merge WHERE id = ?", arguments: [id])
            for s in sets { try db.execute(sql: "DELETE FROM anchor_set WHERE id = ?", arguments: [s]) }
        }
    }

    static func insertMerge(_ db: Database, parts: [[String]]) throws {
        try db.execute(sql: "INSERT INTO edit_merge DEFAULT VALUES")
        let id = db.lastInsertedRowID
        for (i, part) in parts.enumerated() {
            try db.execute(sql: "INSERT INTO edit_merge_part (merge_id, position, set_id) VALUES (?, ?, ?)",
                           arguments: [id, i, try insertSet(db, part)])
        }
    }
}
