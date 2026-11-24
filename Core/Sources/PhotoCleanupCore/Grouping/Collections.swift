import Foundation

/// A photo while grouping: the input plus what is derived once (its calendar day and month).
final class Shot {
    let p: GroupingPhoto
    let day: Int  // yyyymmdd
    let month: String  // "yyyy-MM"
    var score = 0.0

    init(_ p: GroupingPhoto, localCalendar: Calendar, utcCalendar: Calendar) {
        self.p = p
        // EXIF capture times are wall-clock values stored as if UTC; file times are real instants.
        let c = (p.timeKnown ? utcCalendar : localCalendar).dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: p.time))
        day = c.year! * 10000 + c.month! * 100 + c.day!
        month = String(format: "%04d-%02d", c.year!, c.month!)
    }

    var id: String { p.id }
}

/// Orders photos by time, then path: the order of a camera roll.
func chronological(_ a: Shot, _ b: Shot) -> Bool {
    a.p.time != b.p.time ? a.p.time < b.p.time : scalarLess(a.p.rel, b.p.rel)
}

/// A collection while it is being built and edited.
final class Draft {
    var kind: CollectionKind
    var photos: [Shot]
    var parts: Int?
    var folded: [(key: String, note: FoldedNote)] = []

    init(kind: CollectionKind, photos: [Shot] = [], parts: Int? = nil) {
        self.kind = kind
        self.photos = photos
        self.parts = parts
    }

    var days: Int { Set(photos.map(\.day)).count }
}

/// The collection holding most of the listed photos now, or nil when none of them are left.
/// Ties go to the collection met first in the list.
func homeOf(_ listed: some Sequence<String>, _ owner: [String: Int]) -> Int? {
    var counts: [Int: Int] = [:]
    var order: [Int] = []
    for id in listed {
        guard let c = owner[id] else { continue }
        if counts[c] == nil { order.append(c) }
        counts[c, default: 0] += 1
    }
    var best: Int?
    for c in order where best == nil || counts[c]! > counts[best!]! { best = c }
    return best
}

/// Home = the ~10 km area photographed on the most distinct days.
func findHome(_ ordered: [Shot]) -> (lat: Double, lon: Double)? {
    struct Cell: Hashable { let lat: Double, lon: Double }
    func cell(_ g: (lat: Double, lon: Double)) -> Cell {
        Cell(lat: (g.lat / Tuning.homeGridDegrees).rounded(.toNearestOrEven), lon: (g.lon / Tuning.homeGridDegrees).rounded(.toNearestOrEven))
    }
    var days: [Cell: Set<Int>] = [:]
    var order: [Cell] = []
    for s in ordered {
        guard let g = s.p.gps else { continue }
        let c = cell(g)
        if days[c] == nil { order.append(c) }
        days[c, default: []].insert(s.day)
    }
    var best: Cell?
    for c in order where best == nil || days[c]!.count > days[best!]!.count { best = c }
    guard let best else { return nil }
    return centroid(ordered.compactMap(\.p.gps).filter { cell($0) == best })
}

/// Splits the timeline into trips (away from home), events (busy days at home) and everyday months,
/// then applies your edits.
func buildCollections(_ shots: [Shot], edits: GroupingEdits) -> (collections: [GroupedCollection], home: (lat: Double, lon: Double)?) {
    let ordered = shots.sorted(by: chronological)
    let home = findHome(ordered)

    // 1. Moments: runs of photos without a long pause or a big move.
    final class Moment {
        var photos: [Shot] = []
        var end: Double
        var lastGPS: (lat: Double, lon: Double)?
        var away = false
        init(end: Double) { self.end = end }
    }
    var moments: [Moment] = []
    for s in ordered {
        var cur = moments.last
        var new = cur == nil || s.p.time - cur!.end > Tuning.momentGapHours * 3600
        if !new, let g = s.p.gps, let last = cur!.lastGPS, km(g, last) > Tuning.momentMaxKm { new = true }
        if new {
            cur = Moment(end: s.p.time)
            moments.append(cur!)
        }
        cur!.photos.append(s)
        cur!.end = s.p.time
        if let g = s.p.gps { cur!.lastGPS = g }
    }
    for m in moments {
        let pts = m.photos.compactMap(\.p.gps)
        if let home, !pts.isEmpty {
            m.away = pts.filter { km($0, home) > Tuning.awayKm }.count * 2 > pts.count
        }
    }

    // 2. Away moments close together in time become one trip; home moments fold into their day.
    final class Run {
        let away: Bool
        let day: Int
        var photos: [Shot]
        var end: Double
        init(away: Bool, day: Int, photos: [Shot], end: Double) { self.away = away; self.day = day; self.photos = photos; self.end = end }
    }
    var runs: [Run] = []
    for m in moments {
        let prev = runs.last
        let start = m.photos[0].p.time
        if m.away {
            if let prev, prev.away, start - prev.end <= Tuning.tripMaxGapHours * 3600 {
                prev.photos += m.photos
                prev.end = m.end
            } else {
                runs.append(Run(away: true, day: 0, photos: m.photos, end: m.end))
            }
        } else {
            let day = m.photos[0].day
            if let prev, !prev.away, prev.day == day {
                prev.photos += m.photos
                prev.end = m.end
            } else {
                runs.append(Run(away: false, day: day, photos: m.photos, end: m.end))
            }
        }
    }

    // 3. Name them. Quiet home days collapse into one "everyday" collection per month.
    var drafts: [Draft] = []
    var everyday: [String: Draft] = [:]
    for r in runs {
        if r.away {
            drafts.append(Draft(kind: Set(r.photos.map(\.day)).count > 1 ? .trip : .daytrip, photos: r.photos))
        } else if r.photos.count >= Tuning.eventMinPhotos {
            drafts.append(Draft(kind: .event, photos: r.photos))
        } else {
            let key = r.photos[0].month
            if everyday[key] == nil {
                everyday[key] = Draft(kind: .everyday)
                drafts.append(everyday[key]!)
            }
            everyday[key]!.photos += r.photos
        }
    }

    drafts = applyEdits(drafts, edits)

    for d in drafts { d.photos.sort(by: chronological) }
    drafts.sort { chronological($0.photos[0], $1.photos[0]) }
    var out: [GroupedCollection] = []
    for (i, d) in drafts.enumerated() {
        let ps = d.photos
        let center = centroid(ps.compactMap(\.p.gps))
        // A stable sort by start: notes that start together keep the order they were folded in.
        let folded = d.folded.enumerated().sorted { a, b in
            a.element.note.start != b.element.note.start ? a.element.note.start < b.element.note.start : a.offset < b.offset
        }.map(\.element.note)
        out.append(GroupedCollection(
            id: "c\(i + 1)", kind: d.kind, start: ps[0].p.time, end: ps[ps.count - 1].p.time,
            timeKnown: ps.allSatisfy(\.p.timeKnown), days: d.days,
            center: center.map { [rounded($0.lat, 4), rounded($0.lon, 4)] },
            homeKm: center.flatMap { c in home.map { Int(km(c, $0).rounded(.toNearestOrEven)) } },
            members: ps.map(\.id), parts: (d.parts ?? 1) > 1 ? d.parts : nil, folded: folded, groups: []))
    }
    return (out, home)
}

/// Applies your fixes to the detected collections, in this order:
/// 1. merges: each part's collection joins the merge, and photos of a part that drifted into another
///    collection (say an everyday month) are pulled back on their own, never dragging that
///    collection along;
/// 2. not a trip / not an event: a trip, day trip or event holding most of the listed photos folds
///    into the everyday collection of its photos' months, which remembers what was folded in so it
///    can be restored;
/// 3. moves: the listed photos go into the collection holding most of the `into` photos. Moves come
///    last, so the target is the collection you picked as it looks now (an everyday month that took
///    in a folded event is still that month), and nothing after them sends the photos elsewhere.
func applyEdits(_ input: [Draft], _ edits: GroupingEdits) -> [Draft] {
    var collections = input
    func owners() -> [String: Int] {
        var owner: [String: Int] = [:]
        for (i, c) in collections.enumerated() { for s in c.photos { owner[s.id] = i } }
        return owner
    }

    for parts in edits.merges {
        let owner = owners()
        var homes = Set<Int>(), drifted = Set<String>(), found = 0
        for part in parts {
            guard let home = homeOf(part, owner) else { continue }
            found += 1
            homes.insert(home)
            drifted.formUnion(part.filter { owner[$0] != nil && owner[$0] != home })
        }
        drifted = drifted.filter { !homes.contains(owner[$0]!) }
        if homes.count < 2 && drifted.isEmpty { continue }
        let merged = homes.sorted().map { collections[$0] }
        var ps = merged.flatMap(\.photos)
        if !drifted.isEmpty {
            for (i, c) in collections.enumerated() where !homes.contains(i) {
                ps += c.photos.filter { drifted.contains($0.id) }
                c.photos.removeAll { drifted.contains($0.id) }
            }
        }
        let kinds = Set(merged.map(\.kind))
        let kind: CollectionKind
        if kinds.contains(.trip) || kinds.contains(.daytrip) {
            kind = Set(ps.map(\.day)).count > 1 ? .trip : .daytrip
        } else if kinds.contains(.event) {
            kind = .event
        } else {
            kind = .everyday
        }
        collections = collections.enumerated().filter { !homes.contains($0.offset) && !$0.element.photos.isEmpty }.map(\.element)
        collections.append(Draft(kind: kind, photos: ps, parts: found))
    }

    let owner = owners()
    var hits: [Int: [String]] = [:]  // collection index -> one photo per mark on it (used to restore it)
    for mark in edits.notCollections {
        guard let home = homeOf(mark, owner), collections[home].kind != .everyday,
              let anchor = mark.first(where: { owner[$0] == home }) else { continue }
        hits[home, default: []].append(anchor)
    }
    var everyday: [String: Draft] = [:]
    for (i, c) in collections.enumerated() where c.kind == .everyday && hits[i] == nil {
        for s in c.photos where everyday[s.month] == nil { everyday[s.month] = c }
    }
    var kept = collections.enumerated().filter { hits[$0.offset] == nil }.map(\.element)
    for (i, anchors) in hits.sorted(by: { $0.key < $1.key }) {
        let ps = collections[i].photos.sorted(by: chronological)
        let note = FoldedNote(anchors: anchors, kind: collections[i].kind, start: ps[0].p.time, end: ps[ps.count - 1].p.time,
                              timeKnown: ps.allSatisfy(\.p.timeKnown), photos: ps.count)
        for s in ps {
            if everyday[s.month] == nil {
                everyday[s.month] = Draft(kind: .everyday)
                kept.append(everyday[s.month]!)
            }
            let month = everyday[s.month]!
            if let at = month.folded.firstIndex(where: { $0.key == anchors[0] }) {
                month.folded[at].note = note
            } else {
                month.folded.append((anchors[0], note))
            }
            month.photos.append(s)
        }
    }
    collections = kept

    for move in edits.moves {
        let owner = owners()
        let listed = Set(move.photos)
        guard let target = homeOf(move.into.filter { !listed.contains($0) }, owner) else { continue }
        let moving = listed.filter { owner[$0] != nil && owner[$0] != target }
        if moving.isEmpty { continue }
        let dest = collections[target]
        for c in collections where c !== dest {
            dest.photos += c.photos.filter { moving.contains($0.id) }
            c.photos.removeAll { moving.contains($0.id) }
        }
        if dest.kind == .trip || dest.kind == .daytrip {
            dest.kind = Set(dest.photos.map(\.day)).count > 1 ? .trip : .daytrip
        }
        collections.removeAll { $0.photos.isEmpty }
    }
    return collections
}
