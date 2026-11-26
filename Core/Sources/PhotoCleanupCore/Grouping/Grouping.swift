import Foundation

// "IMG_1.JPG" is the original of "IMG_1 2.JPG" (Finder), "IMG_1 copy.JPG" and "IMG_1(1).JPG" (downloads).
private let copyName = try! NSRegularExpression(pattern: #"( \d{1,2}| copy( \d+)?|\(\d+\))$"#, options: [.caseInsensitive])

func isCopyName(_ rel: String) -> Bool {
    let stem = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
    return copyName.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) != nil
}

/// 0..1 quality estimate. Faces dominate when present: a sharp, open-eyed, well-framed face is what
/// makes one shot of a burst better than the next.
func score(_ p: GroupingPhoto) -> Double {
    let aes = ((p.aesthetic ?? 0) + 1) / 2
    let sharp = min(max(log10(max(p.sharpness, 1)) / 3.5, 0), 1)
    if p.me, let i = p.meFace, i < p.faceQualities.count, let mine = p.faceQualities[i] {
        // Your face counts most: your eyes open and sharp matters more than anyone else's.
        let others = p.faceQualities.enumerated().filter { $0.offset != i }.compactMap(\.element)
        let face = 0.7 * mine + 0.3 * (others.min() ?? mine)
        return 0.55 * face + 0.30 * aes + 0.15 * sharp
    }
    let qualities = p.faceQualities.compactMap { $0 }
    if !qualities.isEmpty {
        let face = 0.6 * qualities.min()! + 0.4 * (qualities.reduce(0, +) / Double(qualities.count))
        return 0.55 * face + 0.30 * aes + 0.15 * sharp
    }
    return 0.70 * aes + 0.30 * sharp
}

private struct Pair: Hashable {
    let a: Int, b: Int
    init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
}

/// Groups similar photos, picks a favorite per group and suggests what to keep or remove. Videos
/// take part in collections like photos, but only exact copies of a video form a group.
///
/// - Parameters:
///   - neighbors: close pairs of photos with their feature-print distance, each pair once.
///   - knowsYou: whether the library has a reference photo of you; without one, photos are not
///     pruned for "not having you in them".
///   - timeZone: the zone that turns file times into calendar days (capture times need none).
public func groupPhotos(_ photos: [GroupingPhoto], neighbors: [(a: String, b: String, distance: Double)], edits: GroupingEdits = GroupingEdits(),
                        knowsYou: Bool, timeZone: TimeZone = .current) -> GroupingResult {
    groupPhotos(photos, neighbors: neighbors, edits: edits, knowsYou: knowsYou, timeZone: timeZone, mayLink: { _, _ in true })
}

/// `mayLink(a, b)` (a before b by id) can rule a close pair out as a reason to group two photos; its
/// distance still counts for how spread out a group is. Only the comparison with group.py uses it:
/// that script linked a pair only when the photo with the smaller id listed the other among its 40
/// nearest, so whether two photos could be grouped depended on how their ids happened to sort.
func groupPhotos(_ photos: [GroupingPhoto], neighbors: [(a: String, b: String, distance: Double)], edits: GroupingEdits,
                 knowsYou: Bool, timeZone: TimeZone, mayLink: (String, String) -> Bool) -> GroupingResult {
    var local = Calendar(identifier: .gregorian), utc = Calendar(identifier: .gregorian)
    local.timeZone = timeZone
    utc.timeZone = TimeZone(identifier: "UTC")!
    let shots = photos.map { Shot($0, localCalendar: local, utcCalendar: utc) }
    let index = Dictionary(uniqueKeysWithValues: shots.enumerated().map { ($0.element.id, $0.offset) })

    var (collections, home) = buildCollections(shots, edits: edits)
    var collectionOf = [Int](repeating: 0, count: shots.count)  // photo index -> collection index
    for (ci, c) in collections.enumerated() { for id in c.members { collectionOf[index[id]!] = ci } }

    // Which pairs belong together.
    func linked(_ x: Int, _ y: Int, _ d: Double) -> Bool {
        let a = shots[x].p, b = shots[y].p
        if d < Tuning.duplicateDistance { return true }
        if d < Tuning.eventRepeatDistance, !a.me, !b.me, collectionOf[x] == collectionOf[y], collections[collectionOf[x]].kind != .everyday {
            return true  // without you, one good version of a scene per trip or event is enough
        }
        let fa = a.faceQualities.count, fb = b.faceQualities.count
        if fa > 0, fb > 0, abs(fa - fb) > 1 { return false }  // different set of people
        if fa > 0, fb > 0, a.me != b.me { return false }  // you in one, other people in the other: not the same shot
        let gap = abs(a.time - b.time)
        return (gap <= Tuning.burstSeconds && d < Tuning.burstDistance) || (gap <= Tuning.sceneSeconds && d < Tuning.sceneDistance)
    }
    var dist: [Pair: Double] = [:]
    var edges: [(d: Double, a: String, b: String, x: Int, y: Int)] = []
    for n in neighbors {
        guard let i = index[n.a], let j = index[n.b], i != j, !shots[i].p.video, !shots[j].p.video else { continue }
        dist[Pair(i, j)] = n.distance
        let (x, y) = scalarLess(n.a, n.b) ? (i, j) : (j, i)
        if mayLink(shots[x].id, shots[y].id), linked(x, y, n.distance) { edges.append((n.distance, shots[x].id, shots[y].id, x, y)) }
    }
    edges.sort { l, r in
        if l.d != r.d { return l.d < r.d }
        if l.a != r.a { return scalarLess(l.a, r.a) }
        return scalarLess(l.b, r.b)
    }

    // Agglomerative merge, closest pairs first, refusing any merge that would put two photos further
    // apart than `maxGroupSpread` in the same group (complete linkage).
    var clusterOf = Array(0..<shots.count)
    var members: [Int: [Int]] = Dictionary(uniqueKeysWithValues: (0..<shots.count).map { ($0, [$0]) })
    for e in edges {
        let ca = clusterOf[e.x], cb = clusterOf[e.y]
        if ca == cb { continue }
        let ma = members[ca]!, mb = members[cb]!
        guard ma.allSatisfy({ x in mb.allSatisfy { (dist[Pair(x, $0)] ?? .infinity) <= Tuning.maxGroupSpread } }) else { continue }
        members[ca] = ma + mb
        for x in mb { clusterOf[x] = ca }
        members[cb] = nil
    }

    for s in shots { s.score = rounded(score(s.p), 4) }
    var auto: [Int: (state: PhotoState, reason: String)] = [:]

    struct Building {
        var members: [Int]
        var kind: GroupKind
        var close: Bool
        var you: Bool
        var time: Double
    }
    // Ties (exact copies score the same) go to the original file name, then the shorter path, so
    // regrouping always picks the same favorite.
    func originalFirst(_ l: Int, _ r: Int) -> Bool {
        let cl = isCopyName(shots[l].p.rel), cr = isCopyName(shots[r].p.rel)
        if cl != cr { return !cl }
        let nl = shots[l].p.rel.unicodeScalars.count, nr = shots[r].p.rel.unicodeScalars.count
        if nl != nr { return nl < nr }
        return scalarLess(shots[l].p.rel, shots[r].p.rel)
    }
    var building: [Building] = []
    for cluster in members.values where cluster.count >= 2 {
        let maxPx = max(cluster.map { shots[$0].p.width * shots[$0].p.height }.max()!, 1)
        let maxSize = max(cluster.map { shots[$0].p.size }.max()!, 1)
        func rank(_ m: Int) -> Double {
            let p = shots[m].p
            // Small bonus for the full-resolution original over a downscaled copy.
            return shots[m].score + 0.05 * (Double(p.width * p.height) / Double(maxPx)) + 0.01 * (Double(p.size) / Double(maxSize))
                + (p.me ? Tuning.meRankBonus : 0)
        }
        let ordered = cluster.sorted { l, r in
            let rl = rank(l), rr = rank(r)
            return rl != rr ? rl > rr : originalFirst(l, r)
        }

        var widest = 0.0
        for (i, x) in ordered.enumerated() { for y in ordered[(i + 1)...] { widest = max(widest, dist[Pair(x, y)] ?? .infinity) } }
        let sameDimensions = Set(ordered.map { [shots[$0].p.width, shots[$0].p.height] }).count == 1
        let kind: GroupKind = widest < Tuning.exactDuplicate && sameDimensions ? .duplicate
            : widest < Tuning.duplicateDistance ? .nearDuplicate : .similar
        let close = kind == .duplicate ? false : rank(ordered[0]) - rank(ordered[1]) < Tuning.closeCallMargin

        let fav = ordered[0]
        let favIsYou = shots[fav].p.me
        auto[fav] = (.fav, favIsYou ? "Best shot of you in this group" : "Best shot of this group")
        var second: Int?
        if favIsYou {
            second = ordered.dropFirst().first { m in
                shots[m].p.me && rank(m) >= rank(fav) - Tuning.secondOfYouMargin
                    && (dist[Pair(fav, m)] ?? .infinity) >= Tuning.secondOfYouDistance
            }
        }
        for m in ordered.dropFirst() {
            if m == second {
                auto[m] = (.keep, "Another good, different shot of you")
            } else if shots[m].p.me {
                auto[m] = (.remove, "A weaker repeat of a better shot of you")
            } else {
                auto[m] = (.remove, "A weaker repeat of the favorite")
            }
        }
        building.append(Building(members: ordered, kind: kind, close: close, you: ordered.contains { shots[$0].p.me },
                                 time: ordered.map { shots[$0].p.time }.min()!))
    }
    // Videos: the same file more than once is a group, the original kept. Two takes of a scene are
    // two videos, and stay.
    var copies: [String: [Int]] = [:]
    for (i, s) in shots.enumerated() where s.p.video {
        if let print = s.p.fingerprint { copies[print, default: []].append(i) }
    }
    for cluster in copies.values where cluster.count >= 2 {
        let ordered = cluster.sorted(by: originalFirst)
        auto[ordered[0]] = (.fav, "The original of these copies")
        for m in ordered.dropFirst() { auto[m] = (.remove, "An exact copy of a video you are keeping") }
        building.append(Building(members: ordered, kind: .duplicate, close: false, you: ordered.contains { shots[$0].p.me },
                                 time: ordered.map { shots[$0].p.time }.min()!))
    }
    building.sort { l, r in
        l.time != r.time ? l.time < r.time : scalarLess(shots[l.members[0]].p.rel, shots[r.members[0]].p.rel)
    }

    var groupOf: [Int: String] = [:]
    var groups: [PhotoGroup] = []
    for (i, g) in building.enumerated() {
        let id = "g\(i + 1)"
        for m in g.members { groupOf[m] = id }
        // A group lives in the collection holding most of its photos (ties: the favorite's).
        var votes: [Int: Int] = [:]
        var order: [Int] = []
        for m in g.members {
            let c = collectionOf[m]
            if votes[c] == nil { order.append(c) }
            votes[c, default: 0] += 1
        }
        let top = votes.values.max()!
        let favCollection = collectionOf[g.members[0]]
        let ci = votes[favCollection] == top ? favCollection : order.first { votes[$0] == top }!
        collections[ci].groups.append(id)
        groups.append(PhotoGroup(id: id, members: g.members.map { shots[$0].id }, kind: g.kind, close: g.close, you: g.you,
                                 collection: collections[ci].id))
    }

    // Singles: always keep yours; without you, suggest removing blurry, screenshot/document and
    // (when we know which photos are yours) bottom-quality photos. A video on its own is always
    // kept: one frame says too little about it.
    let others = shots.filter { !$0.p.me && !$0.p.video }.map(\.score).sorted()
    let lowCut = knowsYou && !others.isEmpty ? others[Int(Double(others.count) * Tuning.lowQualityPercentile)] : -1
    var out: [String: GroupedPhoto] = [:]
    for (i, s) in shots.enumerated() {
        var tags: [String] = []
        if s.p.utility, !s.p.video { tags.append("utility") }
        if s.p.sharpness < Tuning.blurrySharpness, !s.p.video { tags.append("blurry") }
        let group = groupOf[i]
        if group == nil {
            if s.p.video {
                auto[i] = (.keep, s.p.me ? "You're in this video" : "")
            } else if s.p.me {
                auto[i] = (.keep, "You're in this photo")
            } else if tags.contains("blurry") {
                auto[i] = (.remove, "Blurry")
            } else if tags.contains("utility") {
                auto[i] = (.remove, "Looks like a screenshot or document")
            } else if s.score < lowCut {
                auto[i] = (.remove, "Below-average quality and you're not in it")
            } else {
                auto[i] = (.keep, "")
            }
        }
        out[s.id] = GroupedPhoto(score: s.score, tags: tags, group: group, collection: collections[collectionOf[i]].id,
                                 auto: auto[i]!.state, reason: auto[i]!.reason)
    }

    return GroupingResult(home: home.map { [rounded($0.lat, 3), rounded($0.lon, 3)] }, collections: collections, groups: groups,
                          photos: out, order: shots.sorted(by: chronological).map(\.id))
}
