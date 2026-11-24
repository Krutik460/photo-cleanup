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
        return m
    }
}
