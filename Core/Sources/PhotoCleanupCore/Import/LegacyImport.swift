import CryptoKit
import Foundation
import GRDB

public enum LegacyImportError: LocalizedError {
    case notAnOutputFolder(String)
    case libraryHasState

    public var errorDescription: String? {
        switch self {
        case .notAnOutputFolder(let path): "\(path) is not an output folder of the old photo cleanup scripts (no analysis.jsonl)."
        case .libraryHasState: "This library already has choices, names or edits. Importing would replace them."
        }
    }
}

public struct LegacyImportReport: Sendable, Equatable {
    public var oldPhotos = 0
    public var matched = 0  // old photos found in this library
    public var gone = 0  // written off by the old tool: no longer anywhere in the photo folder
    public var inRemoveFolder = 0  // sitting in _to_remove, which a scan does not read
    public var notFound = 0  // everything else that has no photo here
    public var filed = 0  // photos the old tool had filed into a folder; they can be put back from here
    public var decisions = 0
    public var reviewed = 0
    public var picks = 0
    public var names = 0
    public var folders = 0
    public var merges = 0
    public var moves = 0
    public var notCollections = 0
    public var referencePhoto: String?  // the photo of you the old tool used, for the caller to set
}

/// The id the old scripts gave a photo: the first 8 bytes of the SHA-1 of its path inside the photo folder.
func legacyId(_ rel: String) -> String {
    Insecure.SHA1.hash(data: Data(rel.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// Brings the review done with the old scripts (their output folder of JSON files) into a library
/// that was scanned by the app: your choices, reviewed marks, second-opinion picks, names, folder
/// switches and collection edits. Photos are matched by where they are now, following the old
/// tool's move log; the photos themselves are never touched.
public func importLegacyReview(from out: URL, into library: Library, replace: Bool = false) throws -> LegacyImportReport {
    func json(_ name: String) -> Any? {
        (try? Data(contentsOf: out.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
    guard let analysis = try? String(contentsOf: out.appendingPathComponent("analysis.jsonl"), encoding: .utf8) else {
        throw LegacyImportError.notAnOutputFolder(out.path)
    }
    var report = LegacyImportReport()

    // The old tool's photos: the last record per path wins.
    struct Old { let id: String; let path: String; let rel: String; let size: Int }
    var latest: [String: Old] = [:]
    for line in analysis.split(separator: "\n") {
        guard let r = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = r["id"] as? String, let path = r["path"] as? String, let rel = r["rel"] as? String else { continue }
        latest[path] = Old(id: id, path: path, rel: rel, size: r["size"] as? Int ?? 0)
    }
    report.oldPhotos = latest.count
    let oldRoot = latest.values.first { $0.path.hasSuffix("/" + $0.rel) }.map { String($0.path.dropLast($0.rel.count + 1)) } ?? ""
    func relative(_ path: String) -> String? {
        path.hasPrefix(oldRoot + "/") ? String(path.dropFirst(oldRoot.count + 1)) : nil
    }

    // Its move log: per photo, every move since the last time it was put back. "back" undoes only the
    // last move, "restore" all of them, "gone" writes the photo off.
    var chains: [String: [[String: Any]]] = [:]
    var writtenOff = Set<String>()
    if let log = try? String(contentsOf: out.appendingPathComponent("moves.jsonl"), encoding: .utf8) {
        for line in log.split(separator: "\n") {
            guard let m = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = m["id"] as? String, let op = m["op"] as? String else { continue }
            switch op {
            case "restore": chains[id] = nil
            case "gone": chains[id] = nil; writtenOff.insert(id)
            case "back":
                chains[id]?.removeLast()
                if chains[id]?.isEmpty == true { chains[id] = nil }
            default:
                chains[id, default: []].append(m)
                writtenOff.remove(id)
            }
        }
    }

    // Match every old photo to a photo of this library by where it is now.
    let rows = try library.store.db.read { try Row.fetchAll($0, sql: "SELECT id, rel_path, size FROM photo WHERE missing = 0") }
    var byPath: [String: Int64] = [:], byNameAndSize: [String: [Int64]] = [:]
    for row in rows {
        let rel: String = row["rel_path"]
        byPath[rel] = row["id"]
        byNameAndSize["\((rel as NSString).lastPathComponent)|\(row["size"] as Int)", default: []].append(row["id"])
    }
    var map: [String: Int64] = [:]  // old id -> photo here
    var taken = Set<Int64>()
    var filed: [(photo: Int64, original: String, chain: [[String: Any]])] = []
    var unmatched: [Old] = []
    for old in latest.values.sorted(by: { $0.path < $1.path }) {
        if writtenOff.contains(old.id) {
            report.gone += 1
            continue
        }
        let chain = chains[old.id] ?? []
        let now = (chain.last?["to"] as? String).flatMap(relative) ?? old.rel
        if chain.last?["op"] as? String == "move" {
            report.inRemoveFolder += 1
            continue
        }
        guard let photo = byPath[now] else {
            unmatched.append(old)
            continue
        }
        map[old.id] = photo
        taken.insert(photo)
        if chain.last?["op"] as? String == "file", now != old.rel { filed.append((photo, old.rel, chain)) }
    }
    // A photo that is not where the log says (moved by hand since): the one file with its name and size.
    for old in unmatched {
        let candidates = (byNameAndSize["\((old.rel as NSString).lastPathComponent)|\(old.size)"] ?? []).filter { !taken.contains($0) }
        if candidates.count == 1 {
            map[old.id] = candidates[0]
            taken.insert(candidates[0])
            if let chain = chains[old.id], chain.last?["op"] as? String == "file" { filed.append((candidates[0], old.rel, chain)) }
        } else {
            report.notFound += 1
        }
    }
    report.matched = map.count
    // Ids the old tool wrote ahead for filed photos (the id a rerun would give them at their new path).
    for (rel, photo) in byPath where map[legacyId(rel)] == nil { map[legacyId(rel)] = photo }

    func photos(_ ids: Any?) -> [String] {
        var seen = Set<Int64>(), out: [String] = []
        for case let id as String in ids as? [Any] ?? [] {
            if let p = map[id], seen.insert(p).inserted { out.append(String(p)) }
        }
        return out
    }

    try library.store.db.write { db in
        let stateTables = ["decision", "reviewed", "ai_pick", "collection_name", "folder_switch", "edit_merge", "edit_move", "edit_not_collection"]
        let existing = try stateTables.reduce(0) { try $0 + (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($1)") ?? 0) }
        if existing > 0 {
            guard replace else { throw LegacyImportError.libraryHasState }
            for table in ["decision", "reviewed", "ai_pick", "collection_name", "folder_switch", "edit_merge_part", "edit_merge", "edit_move",
                          "edit_not_collection", "anchor_set_photo", "anchor_set"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }

        // Photos the old tool filed keep knowing where they came from, so organize and its undo work.
        for f in filed {
            try db.execute(sql: "UPDATE photo SET original_rel_path = ?, location = 'filed' WHERE id = ? AND rel_path <> ?", arguments: [f.original, f.photo, f.original])
            var videos: [String: String] = [:]  // where a Live Photo video is now -> where it came from
            for move in f.chain {
                for c in move["companions"] as? [[String: String]] ?? [] {
                    guard let from = c["from"].flatMap(relative), let to = c["to"].flatMap(relative) else { continue }
                    videos[to] = videos.removeValue(forKey: from) ?? from
                }
            }
            for (now, original) in videos where FileManager.default.fileExists(atPath: library.url(forRelPath: now).path) {
                try db.execute(sql: "INSERT INTO companion (photo_id, rel_path, original_rel_path) VALUES (?, ?, ?)", arguments: [f.photo, now, original])
            }
            report.filed += 1
        }

        for (id, state) in json("decisions.json") as? [String: String] ?? [:] {
            guard let photo = map[id], PhotoState(rawValue: state) != nil else { continue }
            try db.execute(sql: "INSERT OR REPLACE INTO decision (photo_id, state) VALUES (?, ?)", arguments: [photo, state])
        }
        for case let id as String in json("reviewed.json") as? [Any] ?? [] {
            if let photo = map[id] { try db.execute(sql: "INSERT OR IGNORE INTO reviewed (photo_id) VALUES (?)", arguments: [photo]) }
        }
        let haiku = out.appendingPathComponent("haiku")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: haiku.path)) ?? []).filter({ $0.hasSuffix(".json") }).sorted() {
            for (id, pick) in json("haiku/\(name)") as? [String: [String: Any]] ?? [:] {
                guard let photo = map[id], let state = pick["state"] as? String, PhotoState(rawValue: state) != nil else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO ai_pick (photo_id, state, why, batch) VALUES (?, ?, ?, ?)",
                               arguments: [photo, state, pick["why"] as? String ?? "", "imported \((name as NSString).deletingPathExtension)"])
            }
        }

        func addName(_ entry: [String: Any], heldBy: Int64? = nil) throws {
            let set = photos(entry["photos"])
            guard !set.isEmpty, let name = entry["name"] as? String, !name.isEmpty else { return }
            try db.execute(sql: "INSERT INTO collection_name (set_id, name, held_by) VALUES (?, ?, ?)", arguments: [try StoredEdits.insertSet(db, set), name, heldBy])
        }
        func addFolder(_ ids: Any?, heldBy: Int64? = nil) throws {
            let set = photos(ids)
            guard !set.isEmpty else { return }
            try db.execute(sql: "INSERT INTO folder_switch (set_id, held_by) VALUES (?, ?)", arguments: [try StoredEdits.insertSet(db, set), heldBy])
        }
        var names = json("names.json")
        if let old = names as? [String: String] {  // the oldest format: {first photo: name}
            names = old.map { ["photos": [$0.key], "name": $0.value] as [String: Any] }
        }
        for entry in names as? [[String: Any]] ?? [] { try addName(entry) }
        for ids in json("folders.json") as? [Any] ?? [] { try addFolder(ids) }

        let edits = json("collection_edits.json") as? [String: Any] ?? [:]
        for merge in edits["merges"] as? [[Any]] ?? [] {
            let parts = merge.map { photos($0) }.filter { !$0.isEmpty }
            if parts.count >= 2 { try StoredEdits.insertMerge(db, parts: parts) }
        }
        for mark in edits["not_collections"] as? [[String: Any]] ?? [] {
            let set = photos(mark["photos"])
            guard !set.isEmpty else { continue }
            try db.execute(sql: "INSERT INTO edit_not_collection (set_id) VALUES (?)", arguments: [try StoredEdits.insertSet(db, set)])
            let id = db.lastInsertedRowID
            for entry in mark["names"] as? [[String: Any]] ?? [] { try addName(entry, heldBy: id) }
            for ids in mark["folders"] as? [Any] ?? [] { try addFolder(ids, heldBy: id) }
        }
        for move in edits["moves"] as? [[String: Any]] ?? [] {
            let moving = photos(move["photos"]), into = photos(move["into"])
            guard !moving.isEmpty, !into.isEmpty else { continue }
            try db.execute(sql: "INSERT INTO edit_move (photos_set, into_set) VALUES (?, ?)",
                           arguments: [try StoredEdits.insertSet(db, moving), try StoredEdits.insertSet(db, into)])
        }

        func count(_ table: String) throws -> Int { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
        report.decisions = try count("decision")
        report.reviewed = try count("reviewed")
        report.picks = try count("ai_pick")
        report.names = try count("collection_name")
        report.folders = try count("folder_switch")
        report.merges = try count("edit_merge")
        report.moves = try count("edit_move")
        report.notCollections = try count("edit_not_collection")
    }
    report.referencePhoto = (try? String(contentsOf: out.appendingPathComponent("reference_path.txt"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return report
}
