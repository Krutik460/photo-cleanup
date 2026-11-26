import Accelerate
import Foundation
import GRDB

let neighborMaxDistance: Float = 0.8
let neighborMaxCount = 40

/// For every photo, its closest photos by feature-print distance (Euclidean on unit vectors, so
/// d^2 = 2 - 2*dot): at most `neighborMaxCount` each, within `neighborMaxDistance`. One matrix
/// multiply per block keeps this fast for tens of thousands of photos. Features live in the
/// database, so this needs no file access and covers photos wherever they are now. Videos are
/// left out: a video is only ever grouped with exact copies of itself.
func nearestNeighbors(ids: [Int64], features: [[Float]]) -> [(a: Int64, b: Int64, distance: Double)] {
    let n = ids.count
    guard n > 1, let dim = features.first?.count, dim > 0 else { return [] }
    let matrix = features.flatMap { $0 }
    var transposed = [Float](repeating: 0, count: n * dim)
    vDSP_mtrans(matrix, 1, &transposed, 1, vDSP_Length(dim), vDSP_Length(n))
    let minDot = 1 - neighborMaxDistance * neighborMaxDistance / 2
    let block = 512
    var dots = [Float](repeating: 0, count: block * n)
    var pairs: [Int64: [Int64: Double]] = [:]  // smaller id -> larger id -> distance
    var start = 0
    while start < n {
        let m = min(block, n - start)
        matrix.withUnsafeBufferPointer { a in
            vDSP_mmul(a.baseAddress! + start * dim, 1, transposed, 1, &dots, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(dim))
        }
        for i in 0..<m {
            var near: [(Int, Float)] = []
            for j in 0..<n where j != start + i {
                let dot = dots[i * n + j]
                if dot >= minDot { near.append((j, sqrt(max(0, 2 - 2 * dot)))) }
            }
            near.sort { $0.1 != $1.1 ? $0.1 < $1.1 : ids[$0.0] < ids[$1.0] }
            for (j, d) in near.prefix(neighborMaxCount) {
                let x = ids[start + i], y = ids[j]
                pairs[min(x, y), default: [:]][max(x, y)] = Double((d * 10000).rounded() / 10000)
            }
        }
        start += m
    }
    return pairs.flatMap { a, others in others.map { (a: a, b: $0.key, distance: $0.value) } }
        .sorted { ($0.a, $0.b) < ($1.a, $1.b) }
}

func rebuildNeighbors(in store: Store) throws {
    let rows = try store.db.read { db in
        try Row.fetchAll(db, sql: "SELECT id, feature FROM photo WHERE missing = 0 AND feature IS NOT NULL AND media = 'photo' ORDER BY id")
    }
    var ids: [Int64] = []
    var features: [[Float]] = []
    for row in rows {
        let data: Data = row["feature"]
        let v = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        if let dim = features.first?.count, v.count != dim { continue }
        ids.append(row["id"])
        features.append(v)
    }
    let pairs = nearestNeighbors(ids: ids, features: features)
    try store.db.write { db in
        try db.execute(sql: "DELETE FROM neighbor")
        let insert = try db.makeStatement(sql: "INSERT INTO neighbor (a, b, distance) VALUES (?, ?, ?)")
        for p in pairs { try insert.execute(arguments: [p.a, p.b, p.distance]) }
    }
}
