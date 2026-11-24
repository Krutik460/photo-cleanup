import XCTest
@testable import PhotoCleanupCore

/// Compares the Swift grouping with group.py on a folder holding that script's input files
/// (analysis.jsonl, neighbors.json, optionally me.json and collection_edits.json) and its output
/// (groups.json). Runs only when PHOTOCLEANUP_PARITY_DIR names such folders (separated by ":"), since
/// the data is a real library's and does not belong in the repository.
final class GroupingParityTests: XCTestCase {
    struct Legacy {
        var photos: [GroupingPhoto] = []
        var pairs: [(a: String, b: String, distance: Double)] = []
        var listed = Set<String>()  // "a|b" when a lists b among its nearest
        var edits = GroupingEdits()
        var knowsYou = false
        var golden: [String: Any] = [:]
    }

    func load(_ dir: URL) throws -> Legacy {
        func json(_ name: String) throws -> Any? {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        }
        var out = Legacy()
        let me = try json("me.json") as? [String: Any]
        let mePhotos = me?["photos"] as? [String: [String: Any]] ?? [:]
        let threshold = me?["threshold"] as? Double ?? 0
        out.knowsYou = me != nil

        var latest: [String: [String: Any]] = [:]  // append-only file: the last record per path wins
        var order: [String] = []
        for line in try String(contentsOf: dir.appendingPathComponent("analysis.jsonl"), encoding: .utf8).split(separator: "\n") {
            let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let path = r["path"] as! String
            if latest[path] == nil { order.append(path) }
            latest[path] = r
        }
        for path in order {
            let r = latest[path]!
            let id = r["id"] as! String
            let taken = r["taken"] as? Double
            let faces = r["faces"] as? [[String: Any]] ?? []
            let match = mePhotos[id]
            let meCrop = match?["crop"] as? String
            let gps = r["gps"] as? [Double]
            out.photos.append(GroupingPhoto(
                id: id, rel: r["rel"] as! String, time: (taken ?? 0) != 0 ? taken! : r["mtime"] as! Double, timeKnown: (taken ?? 0) != 0,
                width: r["width"] as! Int, height: r["height"] as! Int, size: r["size"] as! Int,
                faceQualities: faces.map { $0["quality"] as? Double },
                meFace: out.knowsYou ? faces.firstIndex { ($0["crop"] as? String) == meCrop } : nil,
                aesthetic: r["aesthetic"] as? Double, sharpness: r["sharpness"] as! Double, utility: r["utility"] as? Bool ?? false,
                gps: gps.map { ($0[0], $0[1]) }, me: match.map { ($0["sim"] as! Double) >= threshold } ?? false))
        }

        let known = Set(out.photos.map(\.id))
        var seen = Set<String>()
        for (a, near) in try json("neighbors.json") as! [String: [[Any]]] {
            for entry in near {
                let b = entry[0] as! String, d = (entry[1] as! NSNumber).doubleValue
                out.listed.insert(a + "|" + b)
                guard known.contains(a), known.contains(b) else { continue }
                if seen.insert(a < b ? a + "|" + b : b + "|" + a).inserted { out.pairs.append((a, b, d)) }
            }
        }

        if let e = try json("collection_edits.json") as? [String: Any] {
            out.edits.merges = e["merges"] as? [[[String]]] ?? []
            out.edits.notCollections = (e["not_collections"] as? [[String: Any]] ?? []).map { $0["photos"] as! [String] }
            out.edits.moves = (e["moves"] as? [[String: Any]] ?? []).map { ($0["photos"] as! [String], $0["into"] as! [String]) }
        }
        out.golden = try json("groups.json") as! [String: Any]
        return out
    }

    /// Everything the page shows that grouping decides, as plain values that compare with the JSON.
    func differences(_ r: GroupingResult, _ golden: [String: Any]) -> [String] {
        var diffs: [String] = []
        func check(_ what: String, _ mine: Any?, _ theirs: Any?) {
            let a = mine.map { "\($0)" } ?? "nil", b = theirs.flatMap { $0 is NSNull ? nil : "\($0)" } ?? "nil"
            if a != b { diffs.append("\(what): \(a) vs \(b)") }
        }
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

        check("home", r.home, (golden["home"] as? [Double]))
        check("order", r.order, golden["order"] as? [String])

        let gc = golden["collections"] as! [[String: Any]]
        check("collections", r.collections.count, gc.count)
        for (c, g) in zip(r.collections, gc) {
            let name = "collection \(c.id)"
            check("\(name) id", c.id, g["id"])
            check("\(name) kind", c.kind.rawValue, g["kind"])
            check("\(name) start", c.start, number(g["start"]))
            check("\(name) end", c.end, number(g["end"]))
            check("\(name) timeKnown", c.timeKnown, g["timeKnown"] as? Bool)
            check("\(name) days", c.days, g["days"] as? Int)
            check("\(name) center", c.center, g["center"] as? [Double])
            check("\(name) homeKm", c.homeKm, g["homeKm"] as? Int)
            check("\(name) members", c.members, g["members"] as? [String])
            check("\(name) parts", c.parts, g["parts"] as? Int)
            check("\(name) groups", c.groups, g["groups"] as? [String])
            let folded = g["folded"] as? [[String: Any]] ?? []
            check("\(name) folded count", c.folded.count, folded.count)
            for (f, gf) in zip(c.folded, folded) {
                check("\(name) folded anchors", f.anchors, gf["anchors"] as? [String])
                check("\(name) folded kind", f.kind.rawValue, gf["kind"])
                check("\(name) folded start", f.start, number(gf["start"]))
                check("\(name) folded end", f.end, number(gf["end"]))
                check("\(name) folded timeKnown", f.timeKnown, gf["timeKnown"] as? Bool)
                check("\(name) folded photos", f.photos, gf["photos"] as? Int)
            }
        }

        let gg = golden["groups"] as! [[String: Any]]
        check("groups", r.groups.count, gg.count)
        for (x, g) in zip(r.groups, gg) {
            check("group \(x.id) id", x.id, g["id"])
            check("group \(x.id) members", x.members, g["members"] as? [String])
            check("group \(x.id) kind", x.kind.rawValue, g["kind"])
            check("group \(x.id) close", x.close, g["close"] as? Bool)
            check("group \(x.id) you", x.you, g["you"] as? Bool)
            check("group \(x.id) collection", x.collection, g["collection"])
        }

        let gp = golden["photos"] as! [String: [String: Any]]
        check("photos", r.photos.count, gp.count)
        for (id, p) in r.photos.sorted(by: { $0.key < $1.key }) {
            guard let g = gp[id] else {
                diffs.append("photo \(id): not in group.py's output")
                continue
            }
            check("photo \(id) score", p.score, number(g["score"]))
            check("photo \(id) tags", p.tags, g["tags"] as? [String])
            check("photo \(id) group", p.group, g["group"])
            check("photo \(id) collection", p.collection, g["collection"])
            check("photo \(id) auto", p.auto.rawValue, g["auto"])
            check("photo \(id) reason", p.reason, g["reason"])
        }
        return diffs
    }

    func testSwiftGroupingMatchesGroupPy() throws {
        let env = ProcessInfo.processInfo.environment["PHOTOCLEANUP_PARITY_DIR"] ?? ""
        try XCTSkipIf(env.isEmpty, "set PHOTOCLEANUP_PARITY_DIR to compare with group.py on real data")
        for path in env.split(separator: ":") {
            let legacy = try load(URL(fileURLWithPath: String(path)))
            // group.py's rule for which close pairs may link two photos (see groupPhotos).
            let same = groupPhotos(legacy.photos, neighbors: legacy.pairs, edits: legacy.edits, knowsYou: legacy.knowsYou, timeZone: .current) {
                legacy.listed.contains($0 + "|" + $1)
            }
            let diffs = differences(same, legacy.golden)
            print("parity \(path): \(legacy.photos.count) photos, \(same.collections.count) collections, \(same.groups.count) groups, \(diffs.count) differences")
            XCTAssertEqual(diffs.count, 0, "\(path)\n" + diffs.prefix(25).joined(separator: "\n"))

            // What changes when every close pair may link, as the app does.
            let all = groupPhotos(legacy.photos, neighbors: legacy.pairs, edits: legacy.edits, knowsYou: legacy.knowsYou)
            let regrouped = all.photos.filter { id, p in
                Set(all.groups.first { $0.id == p.group }?.members ?? [id]) != Set(same.groups.first { $0.id == same.photos[id]!.group }?.members ?? [id])
            }.count
            let autoChanged = all.photos.filter { $0.value.auto != same.photos[$0.key]!.auto }.count
            let removes = (all.photos.values.filter { $0.auto == .remove }.count, same.photos.values.filter { $0.auto == .remove }.count)
            print("  every pair may link: \(all.groups.count) groups (was \(same.groups.count)); \(regrouped) photos in a different group; "
                + "\(autoChanged) automatic picks changed; to remove \(removes.0) (was \(removes.1))")
        }
    }
}
