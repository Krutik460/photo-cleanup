import Foundation
import GRDB

/// A library at a glance, for the home screen. Kept in the library's database so the list of
/// libraries can be shown without opening and grouping each one.
public struct LibrarySummary: Codable, Sendable, Equatable {
    public var photos = 0
    public var videos = 0
    public var collections = 0
    public var groups = 0
    public var reviewedGroups = 0
    public var you = 0  // photos you are in
    public var filed = 0  // photos sitting in a collection folder the app made
    public var toRemove = 0  // marked remove and still among your photos
    public var toRemoveBytes = 0
    public var removed = 0  // moved out by a clean-up
    public var removedBytes = 0
    public var waitingBytes = 0  // of those, still on disk in _to_remove until you empty it
    public var covers: [Int64] = []  // a few of the best photos, for the library's card
    public var updated = 0.0

    public init() {}

    /// A summary stored by an earlier version lacks what was added since: those count as zero.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ key: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        photos = n(.photos); videos = n(.videos); collections = n(.collections); groups = n(.groups)
        reviewedGroups = n(.reviewedGroups); you = n(.you); filed = n(.filed); toRemove = n(.toRemove)
        toRemoveBytes = n(.toRemoveBytes); removed = n(.removed); removedBytes = n(.removedBytes); waitingBytes = n(.waitingBytes)
        covers = (try? c.decodeIfPresent([Int64].self, forKey: .covers)) ?? []
        updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)) ?? 0
    }

    /// Space the clean-up has taken out of your photos: freed already, or waiting in _to_remove.
    public var savedBytes: Int { removedBytes }
    public var freedBytes: Int { removedBytes - waitingBytes }
}

extension Library {
    public var summary: LibrarySummary? {
        guard let text = try? store.meta("summary"), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LibrarySummary.self, from: data)
    }

    /// When the library was last opened in the app, for ordering the home screen.
    public var lastOpened: Date? {
        (try? store.meta("last_opened")).flatMap { $0 }.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    public func markOpened(_ date: Date = Date()) {
        try? store.setMeta("last_opened", String(date.timeIntervalSince1970))
    }
}

extension Catalog {
    public func summary() throws -> LibrarySummary {
        try locked {
            var s = LibrarySummary()
            let states = try effectiveStates()
            let reviewed = Set(try library.store.db.read { try Int64.fetchAll($0, sql: "SELECT photo_id FROM reviewed") }.map(String.init))
            s.videos = rows.values.filter { $0.media == .video }.count
            s.photos = rows.count - s.videos
            s.collections = grouping.collections.count
            s.groups = grouping.groups.count
            s.reviewedGroups = grouping.groups.filter { reviewed.isSuperset(of: $0.members) }.count
            let folderThere = library.isPhotoFolderAvailable
            for (id, p) in rows {
                if (p.meSim ?? -1) >= youThreshold { s.you += 1 }
                switch p.location {
                case .toRemove:
                    s.removed += 1
                    s.removedBytes += p.size
                    if folderThere, exists(p.relPath) { s.waitingBytes += p.size }
                case .filed:
                    s.filed += 1
                    fallthrough
                case .inPlace:
                    if states[id] == .remove {
                        s.toRemove += 1
                        s.toRemoveBytes += p.size
                    }
                }
            }
            // Photos that were removed and whose file is gone are no longer rows the page shows, but
            // they are space saved all the same.
            let gone = try library.store.db.read {
                try Row.fetchOne($0, sql: "SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM photo WHERE location = 'to_remove' AND missing = 1")
            }
            s.removed += gone?["n"] ?? 0
            s.removedBytes += gone?["bytes"] ?? 0
            if !folderThere { s.waitingBytes = library.summary?.waitingBytes ?? 0 }  // unknown while the drive is away

            // The best few photos you are keeping, spread over the library.
            let keepers = grouping.order.filter { states[$0] != .remove && rows[$0]?.location != .toRemove }
            let best = keepers.sorted { (grouping.photos[$0]?.score ?? 0) > (grouping.photos[$1]?.score ?? 0) }.prefix(40)
            let chosen = Set(best)
            let spread = keepers.filter { chosen.contains($0) }  // back in time order
            let step = max(1, spread.count / 4)
            s.covers = stride(from: 0, to: spread.count, by: step).prefix(4).compactMap { Int64(spread[$0]) }
            s.updated = Date().timeIntervalSince1970
            return s
        }
    }

    /// Stores the summary with the library. Called whenever the library was regrouped; call it too
    /// when leaving a library, since choices and reviewed marks change the numbers.
    @discardableResult
    public func saveSummary() throws -> LibrarySummary {
        let s = try summary()
        try library.store.setMeta("summary", String(decoding: try JSONEncoder().encode(s), as: UTF8.self))
        return s
    }
}
