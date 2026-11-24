import Foundation
import GRDB

public enum CatalogError: LocalizedError {
    case invalid(String)  // the request makes no sense for the library as it is now
    case unavailable(String)  // the photo folder is not there

    public var errorDescription: String? {
        switch self {
        case .invalid(let m), .unavailable(let m): m
        }
    }
}

let nameMaxLength = 80

/// A library as the review page sees it: photos grouped into collections and groups, with your names,
/// choices and edits applied. Groups and collections are derived, never stored: they are rebuilt
/// from the photos and your edits whenever either changes, so they cannot go stale.
public final class Catalog {
    public let library: Library
    let lock = NSRecursiveLock()
    var rows: [String: PhotoRecord] = [:]
    private var faces: [Int64: [Double?]] = [:]
    var grouping = GroupingResult(home: nil, collections: [], groups: [], photos: [:], order: [])
    var edits = StoredEdits()
    let timeZone: TimeZone

    public init(library: Library, timeZone: TimeZone = .current) throws {
        self.library = library
        self.timeZone = timeZone
        try finishInterruptedMoves()
        try regroup()
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Rebuilds collections and groups from the database. Call after a scan, after the reference
    /// photo changes, and after any collection edit.
    public func regroup() throws {
        try locked {
            let (photos, faceRows, pairs, knowsYou, stored) = try library.store.db.read { db in
                (try PhotoRecord.fetchAll(db, sql: "SELECT * FROM photo WHERE missing = 0 AND width > 0"),
                 try Row.fetchAll(db, sql: "SELECT photo_id, quality FROM face ORDER BY photo_id, idx"),
                 try Row.fetchAll(db, sql: "SELECT a, b, distance FROM neighbor"),
                 try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM reference_face)") ?? false,
                 try StoredEdits.load(db))
            }
            faces = [:]
            for row in faceRows { faces[row["photo_id"], default: []].append(row["quality"] as Double?) }
            rows = Dictionary(uniqueKeysWithValues: photos.map { (String($0.id!), $0) })
            edits = stored
            let input = photos.map { p in
                let taken = (p.taken ?? 0) != 0
                return GroupingPhoto(
                    id: String(p.id!), rel: p.originalRelPath, time: taken ? p.taken! : p.mtime, timeKnown: taken,
                    width: p.width, height: p.height, size: p.size, faceQualities: faces[p.id!] ?? [], meFace: p.meFace,
                    aesthetic: p.aesthetic, sharpness: p.sharpness, utility: p.utility ?? false,
                    gps: p.lat.flatMap { lat in p.lon.map { (lat, $0) } }, me: (p.meSim ?? -1) >= youThreshold)
            }
            let neighbors = pairs.map { (a: String($0["a"] as Int64), b: String($0["b"] as Int64), distance: $0["distance"] as Double) }
            grouping = groupPhotos(input, neighbors: neighbors, edits: stored.grouping, knowsYou: knowsYou, timeZone: timeZone)
        }
    }

    // MARK: - Reading

    public var photoCount: Int { locked { rows.count } }
    public var result: GroupingResult { locked { grouping } }

    var owner: [String: String] { grouping.photos.mapValues(\.collection) }

    private func collection(of photo: String?) -> GroupedCollection? {
        guard let photo, let id = grouping.photos[photo]?.collection else { return nil }
        return grouping.collections.first { $0.id == id }
    }

    /// {collection id: name}. A name applies to the collection holding most of its photos; when a
    /// merge brings several names together, the earliest part's name wins.
    func collectionNames() -> [String: String] {
        let owner = owner
        var best: [String: (first: Double, name: String)] = [:]
        for e in edits.names {
            guard let home = homeOf(e.photos, owner) else { continue }
            let first = e.photos.filter { owner[$0] == home }.compactMap { photoTime($0) }.min() ?? .infinity
            if best[home] == nil || first < best[home]!.first { best[home] = (first, e.name) }
        }
        return best.mapValues(\.name)
    }

    func folderCollections() -> Set<String> {
        let owner = owner
        return Set(edits.folders.compactMap { homeOf($0.photos, owner) })
    }

    private func photoTime(_ id: String) -> Double? {
        rows[id].map { ($0.taken ?? 0) != 0 ? $0.taken! : $0.mtime }
    }

    /// Everything the page needs, as the JSON of `GET /api/data`.
    public func pageData() throws -> Data {
        try locked {
            let names = collectionNames(), on = folderCollections()
            let (decisions, picks, reviewed) = try library.store.db.read { db in
                (try Row.fetchAll(db, sql: "SELECT photo_id, state FROM decision"),
                 try Row.fetchAll(db, sql: "SELECT photo_id, state, why FROM ai_pick"),
                 try Int64.fetchAll(db, sql: "SELECT photo_id FROM reviewed ORDER BY photo_id"))
            }
            var photos: [String: Any] = [:]
            for (id, g) in grouping.photos {
                guard let p = rows[id] else { continue }
                let taken = (p.taken ?? 0) != 0
                let q = faces[p.id!] ?? []
                photos[id] = [
                    "rel": p.originalRelPath, "path": library.url(forRelPath: p.relPath).path,
                    "time": taken ? p.taken! : p.mtime, "timeKnown": taken, "w": p.width, "h": p.height, "size": p.size,
                    "faces": q.count, "faceQ": q.compactMap { $0 }.map { rounded($0, 3) },
                    "aes": p.aesthetic.map { rounded($0, 3) as Any } ?? NSNull(), "sharp": rounded(p.sharpness, 1),
                    "score": g.score, "tags": g.tags, "group": g.group as Any? ?? NSNull(), "collection": g.collection,
                    "gps": p.lat.flatMap { lat in p.lon.map { [rounded(lat, 5), rounded($0, 5)] as Any } } ?? NSNull(),
                    "auto": g.auto.rawValue, "reason": g.reason, "me": (p.meSim ?? -1) >= youThreshold,
                    "meSim": p.meSim as Any? ?? NSNull(),
                ] as [String: Any]
            }
            let collections: [[String: Any]] = grouping.collections.map { c in
                var d: [String: Any] = [
                    "id": c.id, "kind": c.kind.rawValue, "start": c.start, "end": c.end, "timeKnown": c.timeKnown, "days": c.days,
                    "center": c.center as Any? ?? NSNull(), "homeKm": c.homeKm as Any? ?? NSNull(), "members": c.members,
                    "groups": c.groups, "name": names[c.id] ?? "", "folder": folderName(c, name: names[c.id]), "folderOn": on.contains(c.id),
                ]
                if let parts = c.parts { d["parts"] = parts }
                if !c.folded.isEmpty {
                    d["folded"] = c.folded.map {
                        ["anchors": $0.anchors, "kind": $0.kind.rawValue, "start": $0.start, "end": $0.end,
                         "timeKnown": $0.timeKnown, "photos": $0.photos] as [String: Any]
                    }
                }
                return d
            }
            let known = { (row: Row) in self.rows[String(row["photo_id"] as Int64)] != nil }
            let data: [String: Any] = [
                "generated": ISO8601DateFormatter().string(from: Date()),
                "home": grouping.home as Any? ?? NSNull(),
                "root": library.root.path,
                "collections": collections,
                "groups": grouping.groups.map {
                    ["id": $0.id, "members": $0.members, "kind": $0.kind.rawValue, "close": $0.close, "you": $0.you, "collection": $0.collection] as [String: Any]
                },
                "photos": photos,
                "order": grouping.order,
                "decisions": Dictionary(uniqueKeysWithValues: decisions.filter(known).map { (String($0["photo_id"] as Int64), $0["state"] as String) }),
                "haiku": Dictionary(uniqueKeysWithValues: picks.filter(known).map {
                    (String($0["photo_id"] as Int64), ["state": $0["state"] as String, "why": $0["why"] as String])
                }),
                "reviewed": reviewed.map(String.init).filter { rows[$0] != nil },
                "moved": rows.filter { $0.value.location == .toRemove }.keys.sorted(),
                "filed": rows.filter { $0.value.location == .filed }.mapValues(\.relPath),
            ]
            return try JSONSerialization.data(withJSONObject: data)
        }
    }

    /// Effective state of every photo: your choice, else the second opinion, else the automatic pick.
    public func effectiveStates() throws -> [String: PhotoState] {
        try locked {
            let (decisions, picks) = try library.store.db.read { db in
                (try Row.fetchAll(db, sql: "SELECT photo_id, state FROM decision"), try Row.fetchAll(db, sql: "SELECT photo_id, state FROM ai_pick"))
            }
            var out = grouping.photos.mapValues(\.auto)
            for source in [picks, decisions] {
                for row in source {
                    let id = String(row["photo_id"] as Int64)
                    if out[id] != nil, let s = PhotoState(rawValue: row["state"]) { out[id] = s }
                }
            }
            return out
        }
    }

    /// Where a photo's file is now, and the collection folder name it would be filed under.
    public func currentURL(of photo: String) -> URL? {
        locked { rows[photo].map { library.url(forRelPath: $0.relPath) } }
    }

    public func record(of photo: String) -> PhotoRecord? { locked { rows[photo] } }

    // MARK: - Your choices

    /// Sets or clears (nil) your choice for photos. Returns all choices.
    @discardableResult
    public func decide(_ changes: [String: PhotoState?]) throws -> [String: String] {
        try locked {
            try library.store.db.write { db in
                for (id, state) in changes {
                    guard rows[id] != nil, let pid = Int64(id) else { continue }
                    if let state {
                        try db.execute(sql: "INSERT INTO decision (photo_id, state) VALUES (?, ?) ON CONFLICT (photo_id) DO UPDATE SET state = excluded.state",
                                       arguments: [pid, state.rawValue])
                    } else {
                        try db.execute(sql: "DELETE FROM decision WHERE photo_id = ?", arguments: [pid])
                    }
                }
                return Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT photo_id, state FROM decision").map {
                    (String($0["photo_id"] as Int64), $0["state"] as String)
                })
            }
        }
    }

    /// Marks photos (the members of a group) as reviewed or not. Returns all reviewed photos.
    @discardableResult
    public func setReviewed(_ ids: [String], _ on: Bool) throws -> [String] {
        try locked {
            try library.store.db.write { db in
                for id in ids {
                    guard rows[id] != nil, let pid = Int64(id) else { continue }
                    try db.execute(sql: on ? "INSERT OR IGNORE INTO reviewed (photo_id) VALUES (?)" : "DELETE FROM reviewed WHERE photo_id = ?", arguments: [pid])
                }
                return try Int64.fetchAll(db, sql: "SELECT photo_id FROM reviewed ORDER BY photo_id").map(String.init)
            }
        }
    }

    /// Names the collection holding `photo`; an empty name removes it.
    public func rename(collectionOf photo: String?, to raw: String) throws {
        try locked {
            guard let c = collection(of: photo) else { throw CatalogError.invalid("unknown collection") }
            let name = String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").unicodeScalars.prefix(nameMaxLength).map(Character.init))
            let owner = owner
            let here = edits.names.filter { homeOf($0.photos, owner) == c.id }.map(\.id)
            try library.store.db.write { db in
                try StoredEdits.delete(db, from: "collection_name", ids: here, setColumns: ["set_id"])
                if !name.isEmpty {
                    try db.execute(sql: "INSERT INTO collection_name (set_id, name) VALUES (?, ?)", arguments: [try StoredEdits.insertSet(db, c.members), name])
                }
            }
            edits = try library.store.db.read { try StoredEdits.load($0) }
        }
    }

    /// Switches "make a folder for these photos" for the collection holding `photo`.
    public func setFolder(collectionOf photo: String?, on: Bool) throws {
        try locked {
            guard let c = collection(of: photo) else { throw CatalogError.invalid("unknown collection") }
            let owner = owner
            let here = edits.folders.filter { homeOf($0.photos, owner) == c.id }.map(\.id)
            try library.store.db.write { db in
                try StoredEdits.delete(db, from: "folder_switch", ids: here, setColumns: ["set_id"])
                if on {
                    try db.execute(sql: "INSERT INTO folder_switch (set_id) VALUES (?)", arguments: [try StoredEdits.insertSet(db, c.members)])
                }
            }
            edits = try library.store.db.read { try StoredEdits.load($0) }
        }
    }

    // MARK: - Collection edits

    public enum CollectionEdit: String {
        case merge, split, move, dissolve, restore
    }

    /// Merge, split, move photos, mark as not a trip/event, or restore; then regroup. Returns a photo
    /// of the resulting collection, so the page can open it.
    @discardableResult
    public func editCollections(_ op: CollectionEdit, ids: [String], into: String? = nil) throws -> String {
        try locked {
            let owner = owner
            var targets: [GroupedCollection] = []
            for id in ids {
                if let c = collection(of: id), !targets.contains(where: { $0.id == c.id }) { targets.append(c) }
            }
            targets.sort { $0.start < $1.start }
            func mergedInto(_ m: StoredEdits.Merge, _ c: GroupedCollection) -> Bool {
                m.parts.contains { homeOf($0, owner) == c.id }
            }
            var anchor: String

            switch op {
            case .merge:
                guard targets.count >= 2 else { throw CatalogError.invalid("pick at least two collections to merge") }
                // Merging an already merged collection keeps its original parts.
                let absorbed = edits.merges.filter { m in targets.contains { mergedInto(m, $0) } }
                var parts = absorbed.flatMap(\.parts)
                let covered = Set(parts.compactMap { homeOf($0, owner) })
                parts += targets.filter { !covered.contains($0.id) }.map(\.members)
                try library.store.db.write { db in
                    try StoredEdits.deleteMerges(db, ids: absorbed.map(\.id))
                    try StoredEdits.insertMerge(db, parts: parts)
                }
                anchor = targets[0].members[0]

            case .move:
                guard let dest = collection(of: into) else { throw CatalogError.invalid("nothing to move") }
                let inDest = Set(dest.members)
                let moving = ids.filter { rows[$0] != nil && !inDest.contains($0) }
                guard !moving.isEmpty else { throw CatalogError.invalid("nothing to move") }
                // A newer move of a photo replaces its older one.
                let newer = Set(moving)
                try library.store.db.write { db in
                    for m in edits.moves where !newer.isDisjoint(with: m.photos) {
                        let rest = m.photos.filter { !newer.contains($0) }
                        try StoredEdits.delete(db, from: "edit_move", ids: [m.id], setColumns: ["photos_set", "into_set"])
                        if !rest.isEmpty {
                            try db.execute(sql: "INSERT INTO edit_move (id, photos_set, into_set) VALUES (?, ?, ?)",
                                           arguments: [m.id, try StoredEdits.insertSet(db, rest), try StoredEdits.insertSet(db, m.into)])
                        }
                    }
                    try db.execute(sql: "INSERT INTO edit_move (photos_set, into_set) VALUES (?, ?)",
                                   arguments: [try StoredEdits.insertSet(db, moving), try StoredEdits.insertSet(db, dest.members)])
                }
                anchor = dest.members[0]

            case .split:
                guard let c = targets.first else { throw CatalogError.invalid("unknown collection") }
                let gone = edits.merges.filter { mergedInto($0, c) }.map(\.id)
                try library.store.db.write { try StoredEdits.deleteMerges($0, ids: gone) }
                anchor = c.members[0]

            case .dissolve:
                guard let c = targets.first, c.kind != .everyday else {
                    throw CatalogError.invalid("only a trip, day trip or event can be marked as not one")
                }
                // Its name and folder switch go with the mark, so they come back on restore and do
                // not show up on the everyday month it joins.
                let names = edits.names.filter { homeOf($0.photos, owner) == c.id }.map(\.id)
                let folders = edits.folders.filter { homeOf($0.photos, owner) == c.id }.map(\.id)
                try library.store.db.write { db in
                    try db.execute(sql: "INSERT INTO edit_not_collection (set_id) VALUES (?)", arguments: [try StoredEdits.insertSet(db, c.members)])
                    let mark = db.lastInsertedRowID
                    for id in names { try db.execute(sql: "UPDATE collection_name SET held_by = ? WHERE id = ?", arguments: [mark, id]) }
                    for id in folders { try db.execute(sql: "UPDATE folder_switch SET held_by = ? WHERE id = ?", arguments: [mark, id]) }
                }
                anchor = c.members[0]

            case .restore:
                let wanted = Set(ids)
                let restored = edits.notCollections.filter { !wanted.isDisjoint(with: $0.photos) }.map(\.id)
                guard !restored.isEmpty, let first = ids.first else { throw CatalogError.invalid("nothing to restore") }
                // Deleting the mark releases the name and folder switch it held.
                try library.store.db.write { try StoredEdits.delete($0, from: "edit_not_collection", ids: restored, setColumns: ["set_id"]) }
                anchor = first
            }
            try regroup()
            if grouping.photos[anchor] == nil { anchor = grouping.order.first ?? anchor }
            return anchor
        }
    }

    // MARK: - Folder names

    /// Folder for a collection's photos: your name for it as it is ("Bronx 10 Mile"), or the date and
    /// kind when you did not name it ("2026-10-16 Trip", "2026-10 Everyday"), so unnamed trips never
    /// share a folder.
    func folderName(_ c: GroupedCollection, name: String?) -> String {
        var cal = Calendar(identifier: .gregorian)
        // EXIF capture times are wall-clock values stored as if UTC; file times are real instants.
        cal.timeZone = c.timeKnown ? TimeZone(identifier: "UTC")! : timeZone
        let d = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: c.start))
        let date = c.kind == .everyday ? String(format: "%04d-%02d", d.year!, d.month!) : String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
        let label: [CollectionKind: String] = [.trip: "Trip", .daytrip: "Day trip", .event: "Event", .everyday: "Everyday"]
        let raw = (name ?? "").isEmpty ? "\(date) \(label[c.kind]!)" : name!
        return safeFolderName(raw) ?? date
    }
}

/// A name that is safe as a folder: no path separators, no control characters, single spaces, no
/// leading or trailing space or dot, at most 100 characters. Nil when nothing is left.
func safeFolderName(_ raw: String) -> String? {
    var scalars = String.UnicodeScalarView()
    for s in raw.unicodeScalars {
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            if s.properties.isWhitespace { scalars.append(" ") }
        case .spaceSeparator:
            scalars.append(" ")
        default:
            scalars.append("/:\\".unicodeScalars.contains(s) ? "-" : s)
        }
    }
    let words = String(scalars).split(separator: " ").joined(separator: " ")
    let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    let cut = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(100)))
    return cut.isEmpty ? nil : cut
}
