import Foundation
import GRDB

/// The video half of a Live Photo moves with its photo.
let companionExtensions: Set<String> = ["mov"]

public struct OrganizeResult: Sendable, Equatable {
    public var filed = 0  // photos moved into their collection's folder
    public var back = 0  // photos put back because their collection's folder is switched off
    public var folders = 0
    public var errors: [String] = []
}

public struct CleanupResult: Sendable, Equatable {
    public var moved = 0
    public var reviewed = 0  // duplicate groups marked reviewed (duplicates only)
    public var errors: [String] = []
    public var folder = ""
}

public struct UndoResult: Sendable, Equatable {
    public var restored = 0
    public var skipped = 0  // filed, then moved to _to_remove: undo the clean-up first
    public var errors: [String] = []
}

public enum UndoStep: String, Sendable {
    case cleanup, organize
}

/// One file about to move, written down before it does.
struct FileMove {
    enum Op: String {
        case file  // into a collection folder
        case remove  // into _to_remove
        case putBack = "put_back"  // back to where it originally was
        case unremove  // out of _to_remove, back to where it was just before
    }

    var photo: Int64
    var companion: Int64?  // set when the file is a Live Photo's video, not the photo itself
    var op: Op
    var from: String
    var to: String

    /// What the database has to say once the file is at `to`.
    func apply(_ db: Database) throws {
        if let companion {
            if op == .putBack {
                try db.execute(sql: "DELETE FROM companion WHERE id = ?", arguments: [companion])
            } else {
                try db.execute(sql: "UPDATE companion SET rel_path = ? WHERE id = ?", arguments: [to, companion])
            }
            return
        }
        switch op {
        case .file:
            try db.execute(sql: "UPDATE photo SET rel_path = ?, location = 'filed' WHERE id = ?", arguments: [to, photo])
        case .remove:
            try db.execute(sql: "UPDATE photo SET removed_from_rel = ?, rel_path = ?, location = 'to_remove' WHERE id = ?", arguments: [from, to, photo])
        case .putBack:
            try db.execute(sql: "UPDATE photo SET rel_path = ?, location = 'in_place', removed_from_rel = NULL WHERE id = ?", arguments: [to, photo])
        case .unremove:
            try db.execute(sql: """
                UPDATE photo SET rel_path = ?, removed_from_rel = NULL,
                    location = CASE WHEN original_rel_path = ? THEN 'in_place' ELSE 'filed' END WHERE id = ?
                """, arguments: [to, to, photo])
        }
    }
}

/// Moving files. Nothing is ever deleted or overwritten: files only move inside the photo folder, each
/// move is written down before it happens, and every step has an undo.
extension Catalog {
    var fm: FileManager { .default }

    func requirePhotoFolder() throws {
        guard library.isPhotoFolderAvailable else {
            throw CatalogError.unavailable("The photo folder is not available. Connect the drive and try again.")
        }
    }

    func exists(_ rel: String) -> Bool {
        // A symlinked photo counts when the link is there, even if what it points to is not.
        let path = library.url(forRelPath: rel).path
        return fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// A path that is free: "name (2).jpg", "name (3).jpg", ... when "name.jpg" is taken.
    func free(_ rel: String) -> String {
        guard exists(rel) else { return rel }
        let ext = (rel as NSString).pathExtension, base = (rel as NSString).deletingPathExtension
        var i = 2
        while exists(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)") { i += 1 }
        return ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
    }

    /// Moves one file: intent first, then the file, then the database. If the app dies in between,
    /// `finishInterruptedMoves` settles it at the next launch.
    func perform(_ move: FileMove) throws {
        let from = library.url(forRelPath: move.from), to = library.url(forRelPath: move.to)
        guard to.path.hasPrefix(library.root.path + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        guard !exists(move.to) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "a file already exists at \(move.to)"])
        }
        let id = try library.store.db.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO file_move (photo_id, companion_id, op, from_rel, to_rel, at) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [move.photo, move.companion, move.op.rawValue, move.from, move.to, Date().timeIntervalSince1970])
            return db.lastInsertedRowID
        }
        do {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: to)
        } catch {
            try? library.store.db.write { try $0.execute(sql: "DELETE FROM file_move WHERE id = ?", arguments: [id]) }
            throw error
        }
        try library.store.db.write { db in
            try move.apply(db)
            try db.execute(sql: "UPDATE file_move SET done = 1 WHERE id = ?", arguments: [id])
        }
    }

    /// Settles moves that were written down but not finished (the app quit or crashed mid-step): a
    /// file that did arrive is recorded where it is, an intent whose file never moved is dropped.
    /// Returns how many moves it finished.
    @discardableResult
    public func finishInterruptedMoves() throws -> Int {
        try locked {
            guard library.isPhotoFolderAvailable else { return 0 }
            let pending = try library.store.db.read {
                try Row.fetchAll($0, sql: "SELECT id, photo_id, companion_id, op, from_rel, to_rel FROM file_move WHERE done = 0 ORDER BY id")
            }
            var finished = 0
            for row in pending {
                let move = FileMove(photo: row["photo_id"], companion: row["companion_id"], op: FileMove.Op(rawValue: row["op"]) ?? .file,
                                    from: row["from_rel"], to: row["to_rel"])
                let id: Int64 = row["id"]
                if exists(move.to), !exists(move.from) {
                    try library.store.db.write { db in
                        try move.apply(db)
                        try db.execute(sql: "UPDATE file_move SET done = 1 WHERE id = ?", arguments: [id])
                    }
                    finished += 1
                } else {
                    try library.store.db.write { try $0.execute(sql: "DELETE FROM file_move WHERE id = ?", arguments: [id]) }
                }
            }
            return finished
        }
    }

    func companions(of photo: Int64) throws -> [(id: Int64, rel: String, original: String)] {
        try library.store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, rel_path, original_rel_path FROM companion WHERE photo_id = ? ORDER BY id", arguments: [photo])
                .map { ($0["id"], $0["rel_path"], $0["original_rel_path"]) }
        }
    }

    /// Moves a photo into a collection folder, with its Live Photo video if it has one.
    func file(_ p: PhotoRecord, into folder: String) throws {
        let name = (p.relPath as NSString).lastPathComponent, dir = (p.relPath as NSString).deletingLastPathComponent
        let target = free((folder as NSString).appendingPathComponent(name))
        let stem = (name as NSString).deletingPathExtension, targetStem = ((target as NSString).lastPathComponent as NSString).deletingPathExtension
        let known = try companions(of: p.id!)
        var videos: [(rel: String, to: String)] = []
        for other in (try? fm.contentsOfDirectory(atPath: library.url(forRelPath: dir).path)) ?? [] {
            let ext = (other as NSString).pathExtension
            guard (other as NSString).deletingPathExtension == stem, companionExtensions.contains(ext.lowercased()), !other.hasPrefix("._") else { continue }
            videos.append(((dir as NSString).appendingPathComponent(other), free((folder as NSString).appendingPathComponent("\(targetStem).\(ext)"))))
        }
        try perform(FileMove(photo: p.id!, op: .file, from: p.relPath, to: target))
        for v in videos {
            let id = try known.first { $0.rel == v.rel }?.id ?? library.store.db.write { db -> Int64 in
                try db.execute(sql: "INSERT INTO companion (photo_id, rel_path, original_rel_path) VALUES (?, ?, ?)", arguments: [p.id!, v.rel, v.rel])
                return db.lastInsertedRowID
            }
            do {
                try perform(FileMove(photo: p.id!, companion: id, op: .file, from: v.rel, to: v.to))
            } catch {
                // The video stays where it is; a row that never moved says nothing.
                try? library.store.db.write { try $0.execute(sql: "DELETE FROM companion WHERE id = ? AND rel_path = original_rel_path", arguments: [id]) }
                throw error
            }
        }
    }

    /// Puts a filed photo back where it originally was, Live Photo video too.
    func putBack(_ p: PhotoRecord) throws {
        guard !exists(p.originalRelPath) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "a file already exists at the original location"])
        }
        try perform(FileMove(photo: p.id!, op: .putBack, from: p.relPath, to: p.originalRelPath))
        for c in try companions(of: p.id!) {
            if exists(c.rel), !exists(c.original) {
                try perform(FileMove(photo: p.id!, companion: c.id, op: .putBack, from: c.rel, to: c.original))
            } else {
                try library.store.db.write { try $0.execute(sql: "DELETE FROM companion WHERE id = ?", arguments: [c.id]) }
            }
        }
    }

    /// Whether two folders inside the photo folder are the same one, however their names are spelled
    /// (case, Unicode form, links).
    func sameFolder(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func identity(_ rel: String) -> NSObject? {
            (try? library.url(forRelPath: rel).resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        }
        guard let x = identity(a), let y = identity(b) else { return false }
        return x.isEqual(y)
    }

    /// Removes folders the moves left empty, deepest first. A folder holding anything but Finder's
    /// own .DS_Store stays.
    func removeEmpty(_ folders: Set<String>) {
        for top in folders where !top.isEmpty {
            let root = library.url(forRelPath: top)
            var dirs = [root]
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let url as URL in e where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.append(url) }
            }
            for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
                guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                if contents == [".DS_Store"] { try? fm.removeItem(at: dir.appendingPathComponent(".DS_Store")) }
                if contents.isEmpty || contents == [".DS_Store"] { try? fm.removeItem(at: dir) }
            }
        }
    }

    /// The photos as they are in the database right now (the cached rows go stale while files move).
    func freshRows() throws -> [String: PhotoRecord] {
        let all = try library.store.db.read { try PhotoRecord.fetchAll($0, sql: "SELECT * FROM photo WHERE missing = 0 AND width > 0") }
        return Dictionary(uniqueKeysWithValues: all.map { (String($0.id!), $0) })
    }

    // MARK: - The steps of the Finish page

    /// Makes the folders match the collections: every photo of a collection with "make a folder" on
    /// goes into its folder (unless it is in _to_remove), photos filed for a collection that is now
    /// switched off go back to where they came from, and emptied folders are removed.
    public func organize() throws -> OrganizeResult {
        try locked {
            try requirePhotoFolder()
            let names = collectionNames(), on = folderCollections(), photos = try freshRows()
            var result = OrganizeResult(), emptied = Set<String>(), used = Set<String>()
            for c in grouping.collections {
                let folder = on.contains(c.id) ? folderName(c, name: names[c.id]) : nil
                for id in c.members {
                    guard let p = photos[id], p.location != .toRemove, exists(p.relPath) else { continue }
                    let dir = (p.relPath as NSString).deletingLastPathComponent
                    do {
                        if let folder {
                            // Already in its folder, or in a folder of yours inside it.
                            if sameFolder(dir, folder) || dir.hasPrefix(folder + "/") { continue }
                            let home = (p.originalRelPath as NSString).deletingLastPathComponent
                            if p.location == .filed, home == folder || home.hasPrefix(folder + "/") {
                                // Where it came from is inside that folder: going back is all it takes.
                                try putBack(p)
                                result.back += 1
                            } else {
                                try file(p, into: folder)
                                result.filed += 1
                                used.insert(folder)
                            }
                        } else if p.location == .filed {
                            try putBack(p)
                            result.back += 1
                        } else {
                            continue
                        }
                        if p.location == .filed { emptied.insert(dir) }
                    } catch {
                        result.errors.append("\(p.originalRelPath): \(error.localizedDescription)")
                    }
                }
            }
            removeEmpty(emptied)
            result.folders = used.count
            try regroup()
            return result
        }
    }

    /// Photos marked remove go to _to_remove, from wherever they are now (a collection folder too).
    /// With `duplicatesOnly`, just the extra copies in groups of exact duplicates go (nothing to judge
    /// there), and those groups count as reviewed afterwards, which takes them off the review list.
    public func cleanUp(duplicatesOnly: Bool = false) throws -> CleanupResult {
        try locked {
            try requirePhotoFolder()
            let states = try effectiveStates(), photos = try freshRows()
            let duplicates = grouping.groups.filter { $0.kind == .duplicate }
            let copies = Set(duplicates.flatMap(\.members))
            var result = CleanupResult(folder: library.url(forRelPath: toRemoveFolderName).path)
            for id in grouping.order where states[id] == .remove {
                guard let p = photos[id], p.location != .toRemove, !duplicatesOnly || copies.contains(id), exists(p.relPath) else { continue }
                do {
                    try perform(FileMove(photo: p.id!, op: .remove, from: p.relPath,
                                         to: free((toRemoveFolderName as NSString).appendingPathComponent(p.originalRelPath))))
                    result.moved += 1
                } catch {
                    result.errors.append("\(p.originalRelPath): \(error.localizedDescription)")
                }
            }
            if duplicatesOnly {
                let now = try freshRows()
                let done = duplicates.filter { g in g.members.allSatisfy { states[$0] != .remove || now[$0]?.location == .toRemove } }
                let marked = Set(try library.store.db.read { try Int64.fetchAll($0, sql: "SELECT photo_id FROM reviewed") }.map(String.init))
                result.reviewed = done.filter { !marked.isSuperset(of: $0.members) }.count
                try setReviewed(done.flatMap(\.members), true)
            }
            try regroup()
            return result
        }
    }

    /// Undoes one step: `.cleanup` puts photos from _to_remove back where they were just before
    /// (their collection folder, if they were filed); `.organize` puts filed photos back where they
    /// came from.
    public func undo(_ step: UndoStep) throws -> UndoResult {
        try locked {
            try requirePhotoFolder()
            var result = UndoResult(), emptied: Set<String> = [toRemoveFolderName]
            for p in try freshRows().values.sorted(by: { $0.id! < $1.id! }) {
                do {
                    switch (step, p.location) {
                    case (.cleanup, .toRemove):
                        let dest = p.removedFromRel ?? p.originalRelPath
                        guard !exists(dest) else {
                            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "a file already exists where it was"])
                        }
                        try perform(FileMove(photo: p.id!, op: .unremove, from: p.relPath, to: dest))
                        result.restored += 1
                    case (.organize, .filed):
                        let dir = (p.relPath as NSString).deletingLastPathComponent
                        try putBack(p)
                        emptied.insert(dir)
                        result.restored += 1
                    case (.organize, .toRemove) where p.removedFromRel != nil && p.removedFromRel != p.originalRelPath:
                        result.skipped += 1
                    default:
                        break
                    }
                } catch {
                    result.errors.append("\(p.relPath): \(error.localizedDescription)")
                }
            }
            removeEmpty(emptied)
            try regroup()
            return result
        }
    }
}
