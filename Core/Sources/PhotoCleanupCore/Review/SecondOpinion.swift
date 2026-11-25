import Foundation
import GRDB

/// A group of similar shots as the reviewer sees it: photos numbered from 1, best first.
public struct ReviewGroup: Sendable, Equatable {
    public var id: String
    public var members: [String]  // photo ids; number n is members[n - 1]
    public var you: [Int]  // numbers of the photos you are in

    var sheets: Int { (members.count + SecondOpinion.photosPerSheet - 1) / SecondOpinion.photosPerSheet }
}

/// The reviewer's answer for one group, as constrained by `SecondOpinion.schema`.
public struct ReviewAnswer: Codable, Sendable, Equatable {
    public struct Note: Codable, Sendable, Equatable {
        public var photo: Int
        public var note: String
    }

    public var group: String
    public var fav: [Int]
    public var keep: [Int]
    public var remove: [Int]
    public var why: String
    public var notes: [Note]?
}

public struct ReviewPick: Sendable, Equatable {
    public var state: PhotoState
    public var why: String
}

public enum SecondOpinion {
    public static let photosPerSheet = 16
    public static let sheetsPerBatch = 20

    public static let instructions = """
    You review groups of personal photos to help clean up a photo library. Each group holds shots that an \
    on-device model judged to be the same people in a similar pose (bursts, retakes, duplicates). Every photo \
    on a contact sheet has a red number badge.

    Look at all photos of a group, then decide for every number:
    - fav: the best shot of the group. Judge like a careful person choosing which photo to keep: everyone's \
    eyes open, faces sharp and in focus, natural expressions and smiles, nobody cut off or blocked, no motion \
    blur, good exposure and framing. Faces matter more than background. Usually exactly one fav per group. \
    Pick two only if both are excellent and clearly different (for example a different expression worth keeping).
    - keep: the photo shows something the fav does not: different people, a clearly different pose, expression, \
    scene or moment. Also keep when the photo is not really a repeat of the fav at all.
    - remove: a near-repeat of the fav that adds nothing: blurrier, eyes closed, worse expression, worse framing, \
    darker, a lower-quality copy, OR simply a near-identical copy. The goal is to clean up the library, so do \
    NOT keep near-identical shots "as a backup": if two shots are about equally good and nearly the same, pick \
    one as fav and remove the other.

    The suggested fav is the on-device model's guess. Treat it as a hint only.

    The library owner wants to keep more photos of themself and clean up everything else aggressively. Photos \
    that contain the owner have a blue "YOU" badge (face recognition already ran, do not second-guess it):
    - If any photo in the group has YOU, the fav must be a YOU photo: judge it mainly by the owner's face (eyes \
    open, sharp, good expression), then everyone else. You may also keep ONE more YOU photo when it is good and \
    clearly different (other expression or pose). Other YOU photos are remove.
    - If no photo has YOU, be strict: exactly one fav, everything else remove unless it is clearly a different \
    moment worth having.

    Every number of every group must appear in exactly one of fav / keep / remove. "why" is one short sentence \
    (max 20 words) about the fav. "notes" is optional, only for keep photos.
    """

    /// JSON Schema of the answer for a batch.
    public static let schema: String = {
        let numbers: [String: Any] = ["type": "array", "items": ["type": "integer"]]
        let note: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["photo", "note"],
                                   "properties": ["photo": ["type": "integer"], "note": ["type": "string"]]]
        let group: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["group", "fav", "keep", "remove", "why"],
            "properties": ["group": ["type": "string"], "fav": numbers, "keep": numbers, "remove": numbers, "why": ["type": "string"],
                           "notes": ["type": "array", "items": note]],
        ]
        let root: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["groups"],
                                   "properties": ["groups": ["type": "array", "items": group]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }()

    /// Splits groups into batches of at most `sheetsPerBatch` contact sheets (a group is never split).
    public static func batches(_ groups: [ReviewGroup]) -> [[ReviewGroup]] {
        var out: [[ReviewGroup]] = [], current: [ReviewGroup] = [], count = 0
        for g in groups {
            if !current.isEmpty, count + g.sheets > sheetsPerBatch {
                out.append(current)
                current = []
                count = 0
            }
            current.append(g)
            count += g.sheets
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The batch as one user message in the CLI's stream-json input format: per group a line of
    /// text and its contact sheet(s) as inline images. No file paths, no file names, no GPS.
    public static func message(for batch: [ReviewGroup], thumbnail: (String) -> URL) -> Data {
        var content: [[String: Any]] = []
        for g in batch {
            let you = g.you.isEmpty ? "none" : g.you.map(String.init).joined(separator: ", ")
            content.append(["type": "text", "text": "Group \(g.id): photos 1-\(g.members.count); YOU: \(you); suggested fav: 1"])
            for start in stride(from: 0, to: g.members.count, by: photosPerSheet) {
                let chunk = Array(g.members[start..<min(start + photosPerSheet, g.members.count)])
                guard let jpeg = contactSheet(thumbnails: chunk.map(thumbnail), firstNumber: start + 1, you: Set(g.you)) else { continue }
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
            }
        }
        content.append(["type": "text", "text": "Review every group above and answer with the structured output."])
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        return (try! JSONSerialization.data(withJSONObject: line)) + Data("\n".utf8)
    }

    /// Turns the reviewer's answers into per-photo picks. Safety rules: a group whose answer is
    /// missing or has no favorite is left out entirely (the on-device pick stays); a photo the answer
    /// does not mention is kept, never removed; a group with you always keeps a photo of you.
    public static func picks(for batch: [ReviewGroup], answers: [ReviewAnswer]) -> (picks: [String: ReviewPick], problems: [String]) {
        var picks: [String: ReviewPick] = [:], problems: [String] = []
        for g in batch {
            guard let answer = answers.first(where: { $0.group == g.id }) else {
                problems.append("\(g.id): no answer")
                continue
            }
            let valid = Set(1...g.members.count)
            var fav = Set(answer.fav).intersection(valid), keep = Set(answer.keep).intersection(valid), remove = Set(answer.remove).intersection(valid)
            guard !fav.isEmpty else {
                problems.append("\(g.id): no favorite")
                continue
            }
            let you = Set(g.you)
            if !you.isEmpty, fav.union(keep).isDisjoint(with: you) {
                // Never let a review drop every photo of you: the on-device best shot of you stays.
                let best = you.min()!
                fav.insert(best)
                problems.append("\(g.id): the answer kept no photo of you; kept #\(best)")
            }
            keep.subtract(fav)
            remove.subtract(fav.union(keep))
            var notes: [Int: String] = [:]
            for n in answer.notes ?? [] where notes[n.photo] == nil { notes[n.photo] = n.note }
            for (i, photo) in g.members.enumerated() {
                let n = i + 1
                if fav.contains(n) {
                    picks[photo] = ReviewPick(state: .fav, why: String((notes[n] ?? answer.why).prefix(200)))
                } else if remove.contains(n) {
                    picks[photo] = ReviewPick(state: .remove, why: "")
                } else {
                    picks[photo] = ReviewPick(state: .keep, why: String((notes[n] ?? "").prefix(200)))
                }
            }
        }
        return (picks, problems)
    }
}

extension Catalog {
    /// Groups that still need a second opinion: not exact duplicates (nothing to judge there) and
    /// with no pick on any of their photos yet. Running the review again resumes with these.
    public func groupsNeedingSecondOpinion() throws -> [ReviewGroup] {
        let picked = Set(try library.store.db.read { try Int64.fetchAll($0, sql: "SELECT photo_id FROM ai_pick") }.map(String.init))
        let r = result
        return r.groups.filter { $0.kind != .duplicate && picked.isDisjoint(with: $0.members) }.map { g in
            ReviewGroup(id: g.id, members: g.members, you: g.members.enumerated().filter { record(of: $0.element).map { ($0.meSim ?? -1) >= youThreshold } ?? false }.map { $0.offset + 1 })
        }
    }

    public func saveSecondOpinion(_ picks: [String: ReviewPick], batch: String) throws {
        try library.store.db.write { db in
            for (photo, pick) in picks {
                guard let pid = Int64(photo) else { continue }
                try db.execute(sql: """
                    INSERT INTO ai_pick (photo_id, state, why, batch) VALUES (?, ?, ?, ?)
                    ON CONFLICT (photo_id) DO UPDATE SET state = excluded.state, why = excluded.why, batch = excluded.batch
                    """, arguments: [pid, pick.state.rawValue, pick.why, batch])
            }
        }
    }

    /// Forgets every second opinion, so the next run reviews all groups again.
    public func clearSecondOpinion() throws {
        try library.store.db.write { try $0.execute(sql: "DELETE FROM ai_pick") }
    }
}
