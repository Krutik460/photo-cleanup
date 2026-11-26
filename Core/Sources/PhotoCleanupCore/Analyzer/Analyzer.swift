import Foundation
import GRDB

/// Folders inside the photo folder that a scan never descends into.
let skippedDirectoryNames: Set<String> = [toRemoveFolderName]
public let toRemoveFolderName = "_to_remove"

public struct ScanProgress: Sendable {
    public enum Phase: Sendable { case listing, analyzing, neighbors, done }
    public var phase: Phase
    public var done = 0
    public var total = 0
    public var failed = 0
}

public struct ScanSummary: Sendable, Equatable {
    public var found = 0  // photos and videos in the photo folder
    public var analyzed = 0  // new or changed files analyzed in this scan
    public var analyzedVideos = 0  // how many of those are videos
    public var relinked = 0  // known photos found again at a new path
    public var missing = 0  // known photos whose file is gone
    public var failed: [String] = []  // paths that could not be decoded
    public var cancelled = false
}

/// Brings a library's database in line with its photo folder: analyzes new and changed files,
/// recognises files that were moved outside the app, and flags the ones that are gone.
/// Safe to rerun and to cancel: every photo is written in its own transaction.
public final class Analyzer {
    let library: Library
    let embedder: FaceEmbedder?
    let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

    public init(library: Library, embedder: FaceEmbedder? = nil) {
        self.library = library
        self.embedder = embedder
    }

    struct FoundFile {
        let url: URL
        let rel: String
        let size: Int
        let mtime: Double
        let media: MediaKind
    }

    struct Known {
        let id: Int64
        let relPath: String
        let size: Int
        let mtime: Double
        let version: Int
        let width: Int
        let error: String?
        let fingerprint: String?
        let location: PhotoLocation
        let missing: Bool
    }

    public func run(progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanSummary {
        guard library.isPhotoFolderAvailable else { throw LibraryError.photoFolderUnavailable(library.root.path) }
        progress(ScanProgress(phase: .listing))
        let known = try await library.store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, rel_path, size, mtime, analysis_version, width, error, fingerprint, location, missing FROM photo").map {
                Known(id: $0["id"], relPath: $0["rel_path"], size: $0["size"], mtime: $0["mtime"], version: $0["analysis_version"],
                      width: $0["width"], error: $0["error"], fingerprint: $0["fingerprint"],
                      location: PhotoLocation(rawValue: $0["location"]) ?? .inPlace, missing: $0["missing"])
            }
        }
        let byPath = Dictionary(uniqueKeysWithValues: known.map { ($0.relPath, $0) })
        let files = listFiles(known: Set(byPath.keys))
        var summary = ScanSummary(found: files.count)

        // Sort every file into: nothing to do, analyze again (same photo), or not seen at this path before.
        var todo: [(file: FoundFile, id: Int64?)] = []
        var unknown: [FoundFile] = []
        var present = Set<Int64>()
        for f in files {
            guard let k = byPath[f.rel] else {
                unknown.append(f)
                continue
            }
            present.insert(k.id)
            let current = k.size == f.size && k.mtime == f.mtime && k.version == analysisVersion && k.error == nil
            if !current { todo.append((f, k.id)) }
        }
        // Photos in _to_remove are not listed by the scan; they are present when their file is.
        for k in known where k.location == .toRemove && FileManager.default.fileExists(atPath: library.url(forRelPath: k.relPath).path) {
            present.insert(k.id)
        }

        // A known photo whose file is gone and an unknown file with the same content are one photo
        // that was moved or renamed outside the app: keep its identity and everything decided about it.
        var gone = known.filter { !present.contains($0.id) && $0.fingerprint != nil }
        if !gone.isEmpty {
            var stillUnknown: [FoundFile] = []
            for f in unknown {
                guard let fp = fingerprint(of: f.url) else {
                    stillUnknown.append(f)
                    continue
                }
                let candidates = gone.indices.filter { gone[$0].fingerprint == fp }
                let name = (f.rel as NSString).lastPathComponent
                guard let pick = candidates.first(where: { (gone[$0].relPath as NSString).lastPathComponent == name }) ?? candidates.first else {
                    stillUnknown.append(f)
                    continue
                }
                let k = gone.remove(at: pick)
                let library = self.library
                try await library.store.db.write { db in
                    if k.location == .inPlace {
                        // Moved by hand: its new place is where it belongs from now on.
                        try db.execute(sql: "UPDATE photo SET rel_path = ?, original_rel_path = ?, size = ?, mtime = ?, missing = 0 WHERE id = ?",
                                       arguments: [f.rel, f.rel, f.size, f.mtime, k.id])
                    } else {
                        // Filed by the app and then moved by hand (a renamed folder, a photo taken out of
                        // _to_remove): it still knows where it originally came from, so undo keeps working.
                        try db.execute(sql: """
                            UPDATE photo SET rel_path = ?, size = ?, mtime = ?, missing = 0, removed_from_rel = NULL,
                                location = CASE WHEN original_rel_path = ? THEN 'in_place' ELSE 'filed' END WHERE id = ?
                            """, arguments: [f.rel, f.size, f.mtime, f.rel, k.id])
                        // Its Live Photo video, when it moved along.
                        let dir = (f.rel as NSString).deletingLastPathComponent
                        for row in try Row.fetchAll(db, sql: "SELECT id, rel_path FROM companion WHERE photo_id = ?", arguments: [k.id]) {
                            let old: String = row["rel_path"]
                            let moved = (dir as NSString).appendingPathComponent((old as NSString).lastPathComponent)
                            if moved != old, FileManager.default.fileExists(atPath: library.url(forRelPath: moved).path) {
                                try db.execute(sql: "UPDATE companion SET rel_path = ? WHERE id = ?", arguments: [moved, row["id"] as Int64])
                            }
                        }
                    }
                }
                present.insert(k.id)
                summary.relinked += 1
                if k.version != analysisVersion || k.error != nil { todo.append((f, k.id)) }
            }
            unknown = stillUnknown
        }
        todo += unknown.map { ($0, nil) }

        let missingNow = known.filter { !present.contains($0.id) }.map(\.id)
        let wasMissing = Set(known.filter(\.missing).map(\.id))
        summary.missing = missingNow.count
        let flagsChanged = Set(missingNow) != wasMissing
        if flagsChanged {
            try await library.store.db.write { db in
                try db.execute(sql: "UPDATE photo SET missing = 0 WHERE missing = 1")
                for id in missingNow { try db.execute(sql: "UPDATE photo SET missing = 1 WHERE id = ?", arguments: [id]) }
            }
        }

        // Analyze with bounded concurrency; this task alone writes results.
        var state = ScanProgress(phase: .analyzing, total: todo.count)
        progress(state)
        let embedder = self.embedder
        await withTaskGroup(of: (Int, PhotoAnalysis).self) { group in
            var next = 0
            func add() {
                guard next < todo.count, !Task.isCancelled else { return }
                let i = next, url = todo[i].file.url, video = todo[i].file.media == .video
                next += 1
                group.addTask { (i, video ? await analyzeVideo(at: url, embedder: embedder) : await analyzeImage(at: url, embedder: embedder)) }
            }
            for _ in 0..<maxConcurrent { add() }
            for await (i, result) in group {
                let item = todo[i]
                do {
                    try save(result, file: item.file, id: item.id)
                    if !result.decoded { summary.failed.append(item.file.rel) }
                } catch {
                    summary.failed.append("\(item.file.rel): \(error.localizedDescription)")
                }
                summary.analyzed += 1
                if item.file.media == .video { summary.analyzedVideos += 1 }
                state.done += 1
                state.failed = summary.failed.count
                progress(state)
                add()
            }
        }
        summary.cancelled = Task.isCancelled
        summary.failed.sort()

        let neighborsExist = try await library.store.db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM neighbor)") ?? false }
        if !summary.cancelled, summary.analyzed > 0 || flagsChanged || !neighborsExist {
            progress(ScanProgress(phase: .neighbors, done: state.done, total: state.total, failed: state.failed))
            try rebuildNeighbors(in: library.store)
        }
        progress(ScanProgress(phase: .done, done: state.done, total: state.total, failed: state.failed))
        return summary
    }

    /// Writes one analysis result: the photo row (kept when it exists, so the id never changes), its
    /// faces and its thumbnail.
    func save(_ a: PhotoAnalysis, file: FoundFile, id: Int64?) throws {
        let fp = fingerprint(of: file.url)
        let photoId = try library.store.db.write { db -> Int64 in
            var record: PhotoRecord
            if let id, let existing = try PhotoRecord.fetchOne(db, key: id) {
                record = existing
            } else {
                record = PhotoRecord(id: nil, relPath: file.rel, originalRelPath: file.rel, fingerprint: nil, size: 0, mtime: 0,
                                     taken: nil, width: 0, height: 0, aesthetic: nil, utility: nil, sharpness: 0, feature: nil,
                                     lat: nil, lon: nil, analysisVersion: analysisVersion, error: nil, location: .inPlace, missing: false,
                                     meSim: nil, meFace: nil, removedFromRel: nil, media: file.media, duration: nil)
            }
            record.media = file.media
            record.duration = a.duration
            record.fingerprint = fp
            record.size = a.size
            record.mtime = a.mtime
            record.taken = a.taken
            record.width = a.width
            record.height = a.height
            record.aesthetic = a.aesthetic.map(Double.init)
            record.utility = a.utility
            record.sharpness = a.sharpness
            record.feature = a.feature.isEmpty ? nil : a.feature
            record.lat = a.gps?.lat
            record.lon = a.gps?.lon
            record.analysisVersion = analysisVersion
            record.error = a.error
            record.missing = false
            try record.save(db)
            let pid = record.id!
            try db.execute(sql: "DELETE FROM face WHERE photo_id = ?", arguments: [pid])
            for (i, f) in a.faces.enumerated() {
                let embedding = f.embedding.map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
                try FaceRecord(photoId: pid, idx: i, quality: f.quality.map(Double.init), x: f.box.origin.x, y: f.box.origin.y,
                               w: f.box.width, h: f.box.height, crop: nil, embedding: embedding).insert(db)
            }
            return pid
        }
        if let thumb = a.thumbnail {
            try writeJPEG(thumb, to: library.thumbURL(photoId))
        }
        // Previews made from the previous version of the file are stale now; they are remade on demand.
        for name in ["\(photoId).jpg", "\(photoId).mid.jpg"] {
            try? FileManager.default.removeItem(at: library.previewsDir.appendingPathComponent(name))
        }
    }

    /// Every photo and video in the photo folder. The video half of a Live Photo (a .mov named like
    /// a photo next to it) is left out: it belongs to its photo. A video the library already knows
    /// at its path (`known`) is a video of its own, whatever lies next to it.
    func listFiles(known: Set<String> = []) -> [FoundFile] {
        let root = library.root
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [FoundFile] = []
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedDirectoryNames.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            var isFile = values?.isRegularFile == true
            if values?.isSymbolicLink == true {  // follow links to files (not to folders, to avoid cycles)
                isFile = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            let ext = url.pathExtension.lowercased()
            guard isFile, let media: MediaKind = imageExtensions.contains(ext) ? .photo : videoExtensions.contains(ext) ? .video : nil,
                  let rel = relativePath(of: url) else { continue }
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)) ?? [:]
            out.append(FoundFile(url: url, rel: rel, size: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                                 mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, media: media))
        }
        // "Trip/IMG_10" is a photo: "Trip/IMG_10.MOV" next to it is its Live Photo video.
        let photos = Set(out.filter { $0.media == .photo }.map { ($0.rel as NSString).deletingPathExtension })
        out.removeAll { f in
            f.media == .video && !known.contains(f.rel) && livePhotoVideoExtensions.contains(f.url.pathExtension.lowercased())
                && photos.contains((f.rel as NSString).deletingPathExtension)
        }
        return out.sorted { $0.rel < $1.rel }
    }

    /// Path of a file relative to the photo folder. Folders are resolved (so /tmp and /private/tmp
    /// agree) but the file itself is not: a symlinked photo stays the link inside the folder, so
    /// moving it never touches a file elsewhere on disk.
    func relativePath(of url: URL) -> String? {
        let dir = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let path = (dir as NSString).appendingPathComponent(url.lastPathComponent)
        let prefix = library.root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}
