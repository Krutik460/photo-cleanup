import Foundation
import GRDB

/// One library's SQLite database. Schema changes go through numbered migrations only.
public final class Store {
    public let db: DatabasePool

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        db = try DatabasePool(path: path, configuration: config)
        try Store.migrator.migrate(db)
    }

    public func meta(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.write { try $0.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", arguments: [key, value]) }
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1 meta") { db in
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // Analysis results. A photo's identity is its row: the path can change (filing, clean-up, a
        // move in Finder) without the id changing. Paths are relative to the library's photo folder,
        // which lives in meta, so a drive mounted somewhere else is still the same library.
        m.registerMigration("v2 analysis") { db in
            try db.create(table: "photo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rel_path", .text).notNull().unique()
                t.column("original_rel_path", .text).notNull()
                t.column("fingerprint", .text)
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("taken", .double)
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("aesthetic", .double)
                t.column("utility", .boolean)
                t.column("sharpness", .double).notNull()
                t.column("feature", .blob)
                t.column("lat", .double)
                t.column("lon", .double)
                t.column("analysis_version", .integer).notNull()
                t.column("error", .text)
                t.column("location", .text).notNull().defaults(to: "in_place")
                    .check(sql: "location IN ('in_place', 'filed', 'to_remove')")
                // The file was not found by the last scan. The row and everything decided about the
                // photo stay, so it is whole again when the file comes back.
                t.column("missing", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "photo_fingerprint", on: "photo", columns: ["fingerprint"])
            try db.create(table: "face") { t in
                t.column("photo_id", .integer).notNull().references("photo", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("quality", .double)
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("w", .double).notNull()
                t.column("h", .double).notNull()
                t.column("crop", .text)
                t.column("embedding", .blob)
                t.primaryKey(["photo_id", "idx"])
            }
            try db.create(table: "neighbor") { t in
                t.column("a", .integer).notNull().references("photo", onDelete: .cascade)
                t.column("b", .integer).notNull().references("photo", onDelete: .cascade)
                t.column("distance", .double).notNull()
                t.primaryKey(["a", "b"])
                t.check(sql: "a < b")
            }
            try db.create(index: "neighbor_b", on: "neighbor", columns: ["b"])
        }
        // Finding you: the face(s) of your reference photo, and per photo the best match with them.
        m.registerMigration("v3 me") { db in
            try db.create(table: "reference_face") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_path", .text).notNull()
                t.column("embedding", .blob).notNull()
            }
            try db.alter(table: "photo") { t in
                t.add(column: "me_sim", .double)
                t.add(column: "me_face", .integer)
            }
        }
        // Everything you decide in the page. Collections are rebuilt on every regroup and get new
        // ids, so a name, a folder switch or an edit is stored with the photos of the collection it
        // was made on (an anchor set) and applies to the collection holding most of them now.
        m.registerMigration("v4 your state") { db in
            let states = "('fav', 'keep', 'remove')"
            try db.create(table: "decision") { t in
                t.column("photo_id", .integer).primaryKey().references("photo", onDelete: .cascade)
                t.column("state", .text).notNull().check(sql: "state IN \(states)")
            }
            try db.create(table: "reviewed") { t in
                t.column("photo_id", .integer).primaryKey().references("photo", onDelete: .cascade)
            }
            try db.create(table: "ai_pick") { t in
                t.column("photo_id", .integer).primaryKey().references("photo", onDelete: .cascade)
                t.column("state", .text).notNull().check(sql: "state IN \(states)")
                t.column("why", .text).notNull().defaults(to: "")
                t.column("batch", .text)
            }
            try db.create(table: "anchor_set") { t in
                t.autoIncrementedPrimaryKey("id")
            }
            try db.create(table: "anchor_set_photo") { t in
                t.column("set_id", .integer).notNull().references("anchor_set", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("photo_id", .integer).notNull().references("photo", onDelete: .cascade)
                t.primaryKey(["set_id", "position"])
            }
            // A trip or event you marked as not one. Its name and folder switch are held by the mark
            // (held_by) so they do not show on the month it joins, and are released when it is restored.
            try db.create(table: "edit_not_collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("set_id", .integer).notNull().references("anchor_set")
            }
            try db.create(table: "collection_name") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("set_id", .integer).notNull().references("anchor_set")
                t.column("name", .text).notNull()
                t.column("held_by", .integer).references("edit_not_collection", onDelete: .setNull)
            }
            try db.create(table: "folder_switch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("set_id", .integer).notNull().references("anchor_set")
                t.column("held_by", .integer).references("edit_not_collection", onDelete: .setNull)
            }
            try db.create(table: "edit_merge") { t in
                t.autoIncrementedPrimaryKey("id")
            }
            try db.create(table: "edit_merge_part") { t in
                t.column("merge_id", .integer).notNull().references("edit_merge", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("set_id", .integer).notNull().references("anchor_set")
                t.primaryKey(["merge_id", "position"])
            }
            try db.create(table: "edit_move") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("photos_set", .integer).notNull().references("anchor_set")
                t.column("into_set", .integer).notNull().references("anchor_set")
            }
        }
        // Moving files. A photo that went to _to_remove remembers where it was just before; the
        // video half of a Live Photo that moved with its photo remembers where it came from.
        // file_move is written before a file is moved and marked done after the database caught up,
        // so a move interrupted by a crash is finished or dropped at the next launch. Done rows
        // stay as the record of what the app moved.
        m.registerMigration("v5 file steps") { db in
            try db.alter(table: "photo") { t in
                t.add(column: "removed_from_rel", .text)
            }
            try db.create(table: "companion") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("photo_id", .integer).notNull().references("photo", onDelete: .cascade)
                t.column("rel_path", .text).notNull()
                t.column("original_rel_path", .text).notNull()
            }
            try db.create(table: "file_move") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("photo_id", .integer).notNull().references("photo", onDelete: .cascade)
                t.column("companion_id", .integer)
                t.column("op", .text).notNull().check(sql: "op IN ('file', 'remove', 'put_back', 'unremove')")
                t.column("from_rel", .text).notNull()
                t.column("to_rel", .text).notNull()
                t.column("at", .double).notNull()
                t.column("done", .boolean).notNull().defaults(to: false)
            }
        }
        return m
    }
}
