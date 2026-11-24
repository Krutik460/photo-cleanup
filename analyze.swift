// On-device photo analyzer. Uses Apple's Vision framework (free, local) to compute, per photo:
//   - an image feature print (embedding) for similarity grouping
//   - face count and per-face capture quality (sharpness, eyes, expression)
//   - an overall aesthetic score and a "utility" flag (screenshots, receipts, documents)
//   - a Laplacian-variance sharpness estimate
// It also writes a small JPEG thumbnail per photo (browsers cannot display HEIC/RAW).
//
// Usage: analyze <photo-folder> <output-folder>
// Output: <output-folder>/analysis.jsonl (one JSON object per photo, appended; reruns skip unchanged files)
//         <output-folder>/thumbs/<id>.jpg

import Accelerate
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let imageExtensions: Set<String> = [
    "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp", "gif", "bmp",
    "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
]
let skippedDirectoryNames: Set<String> = ["_to_remove"]
let thumbMaxPixels = 480
let analysisMaxPixels = 1024
let schemaVersion = 3  // bump when Record gains fields, so older records are re-analyzed
let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

struct Face: Codable {
    let quality: Float?
    let box: [Double]  // x, y, w, h in normalized image coordinates (origin bottom-left)
    var crop: String? = nil  // aligned 112x112 face crop (faces/<file>) for face recognition
}

struct Record: Codable {
    let id: String
    let path: String
    let rel: String
    let size: Int
    let mtime: Double
    let taken: Double?  // capture time (EXIF), seconds since 1970, local wall clock
    let width: Int
    let height: Int
    let faces: [Face]
    let aesthetic: Float?
    let utility: Bool?
    let sharpness: Double
    let feature: String  // base64 Float32 feature print
    let gps: [Double]?  // latitude, longitude (signed degrees)
    let version: Int?
    let error: String?
}

func shortId(_ s: String) -> String {
    Insecure.SHA1.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

func listImages(root: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    var out: [URL] = []
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
        if isFile, imageExtensions.contains(url.pathExtension.lowercased()) {
            out.append(url)
        }
    }
    return out.sorted { $0.path < $1.path }
}

func thumbnail(_ src: CGImageSource, maxPixels: Int) -> CGImage? {
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,  // apply EXIF orientation
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.82) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "analyze", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "analyze", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

func gpsLocation(_ props: [CFString: Any]) -> [Double]? {
    guard let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
          let lat = g[kCGImagePropertyGPSLatitude] as? Double,
          let lon = g[kCGImagePropertyGPSLongitude] as? Double else { return nil }
    let signedLat = (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
    let signedLon = (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
    if signedLat == 0 && signedLon == 0 { return nil }  // "null island": a missing fix, not a place
    return [signedLat, signedLon]
}

func captureDate(_ props: [CFString: Any]) -> Double? {
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
        ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
        ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
    guard let raw else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    guard var t = f.date(from: raw)?.timeIntervalSince1970 else { return nil }
    if let sub = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String, let frac = Double("0." + sub) { t += frac }
    return t
}

/// Variance of the Laplacian on a grayscale downsample: a standard blur estimate (higher = sharper).
func sharpness(_ image: CGImage) -> Double {
    let w = image.width, h = image.height
    guard w > 2, h > 2 else { return 0 }
    var px = [UInt8](repeating: 0, count: w * h)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return 0 }
    var sum = 0.0, sumSq = 0.0
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            let v = Double(px[i - 1]) + Double(px[i + 1]) + Double(px[i - w]) + Double(px[i + w]) - 4 * Double(px[i])
            sum += v
            sumSq += v * v
        }
    }
    let n = Double((w - 2) * (h - 2))
    let mean = sum / n
    return sumSq / n - mean * mean
}

// MARK: - Face alignment for recognition

/// ArcFace's canonical 5-point template in a 112x112 crop (top-left origin): eyes, nose tip, mouth corners.
let arcfaceTemplate: [CGPoint] = [
    CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
    CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
]
let cropSize = 112
let faceDecodePixels = 2560
let minFacePixels = 36.0  // faces narrower than this in the high-res decode are too small to recognize
let maxCropsPerPhoto = 12

/// Least-squares similarity transform (rotation, uniform scale, translation) mapping src onto dst.
func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
    let n = Double(src.count)
    let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
    let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
    var a = 0.0, b = 0.0, den = 0.0
    for (p, q) in zip(src, dst) {
        let px = p.x - ms.x, py = p.y - ms.y, qx = q.x - md.x, qy = q.y - md.y
        a += px * qx + py * qy
        b += px * qy - py * qx
        den += px * px + py * py
    }
    a /= den; b /= den
    return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: md.x - (a * ms.x - b * ms.y), ty: md.y - (b * ms.x + a * ms.y))
}

/// The five landmark points of a face, in normalized image coordinates (origin bottom-left).
func fivePoints(_ face: VNFaceObservation) -> [CGPoint]? {
    guard let lm = face.landmarks, let le = lm.leftPupil ?? lm.leftEye, let re = lm.rightPupil ?? lm.rightEye,
          let nose = lm.nose, let lips = lm.outerLips else { return nil }
    let box = face.boundingBox
    func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: box.minX + p.x * box.width, y: box.minY + p.y * box.height) }
    func center(_ r: VNFaceLandmarkRegion2D) -> CGPoint {
        let pts = r.normalizedPoints.map(toImage)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / Double(pts.count), y: pts.map(\.y).reduce(0, +) / Double(pts.count))
    }
    let eyes = [center(le), center(re)].sorted { $0.x < $1.x }  // image-left eye first, as in the template
    let lipPts = lips.normalizedPoints.map(toImage)
    guard let ml = lipPts.min(by: { $0.x < $1.x }), let mr = lipPts.max(by: { $0.x < $1.x }) else { return nil }
    let nosePts = nose.normalizedPoints.map(toImage)
    // Nose tip: the lowest nose point (smallest y in bottom-left coordinates), centered horizontally.
    let tip = CGPoint(x: nosePts.map(\.x).reduce(0, +) / Double(nosePts.count), y: nosePts.map(\.y).min()!)
    return [eyes[0], eyes[1], tip, ml, mr]
}

func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    if i.isNull { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter)
}

/// Detects face landmarks, warps each face onto the ArcFace template from a high-resolution decode,
/// and writes faces/<id>_<k>.jpg. Returns the crop file name per matched quality face index.
func alignedCrops(src: CGImageSource, work: CGImage, faces: [Face], id: String, outDir: URL) -> [Int: String] {
    let req = VNDetectFaceLandmarksRequest()
    let handler = VNImageRequestHandler(cgImage: work, options: [:])
    guard (try? handler.perform([req])) != nil, let found = req.results, !found.isEmpty,
          let hi = thumbnail(src, maxPixels: faceDecodePixels) else { return [:] }
    let W = Double(hi.width), H = Double(hi.height)
    let template = arcfaceTemplate.map { CGPoint(x: $0.x, y: Double(cropSize) - $0.y) }  // to bottom-left origin
    var out: [Int: String] = [:]
    let usable = found.filter { $0.boundingBox.width * W >= minFacePixels }
        .sorted { $0.boundingBox.width > $1.boundingBox.width }.prefix(maxCropsPerPhoto)
    for (k, face) in usable.enumerated() {
        guard let pts = fivePoints(face) else { continue }
        let srcPts = pts.map { CGPoint(x: $0.x * W, y: $0.y * H) }
        let t = similarity(from: srcPts, to: template)
        guard let ctx = CGContext(data: nil, width: cropSize, height: cropSize, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
        ctx.interpolationQuality = .high
        ctx.concatenate(t)
        ctx.draw(hi, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let crop = ctx.makeImage() else { continue }
        let name = "\(id)_\(k).jpg"
        guard (try? writeJPEG(crop, to: outDir.appendingPathComponent("faces/\(name)"), quality: 0.92)) != nil else { continue }
        // Attach the crop to the capture-quality face it overlaps most.
        let best = faces.indices.max { a, b in
            iou(CGRect(x: faces[a].box[0], y: faces[a].box[1], width: faces[a].box[2], height: faces[a].box[3]), face.boundingBox)
                < iou(CGRect(x: faces[b].box[0], y: faces[b].box[1], width: faces[b].box[2], height: faces[b].box[3]), face.boundingBox)
        }
        if let best, out[best] == nil,
           iou(CGRect(x: faces[best].box[0], y: faces[best].box[1], width: faces[best].box[2], height: faces[best].box[3]), face.boundingBox) > 0.2 {
            out[best] = name
        }
    }
    return out
}

/// Canonical path of a file inside the photo folder, plus its path relative to the folder. Folders are
/// resolved (so /tmp and /private/tmp agree) but the file itself is not: a symlinked photo stays the
/// link inside the folder, so moving it never touches a file elsewhere on disk.
func locate(_ url: URL, root: URL) -> (path: String, rel: String) {
    let dir = url.deletingLastPathComponent().resolvingSymlinksInPath().path
    let path = (dir as NSString).appendingPathComponent(url.lastPathComponent)
    let rootPath = root.resolvingSymlinksInPath().path
    let rel = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    return (path, rel)
}

func analyze(url: URL, root: URL, outDir: URL) async -> Record {
    let (path, rel) = locate(url, root: root)
    let id = shortId(rel)
    let attrs = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)) ?? [:]
    let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

    func failed(_ msg: String) -> Record {
        Record(id: id, path: path, rel: rel, size: size, mtime: mtime, taken: nil, width: 0, height: 0, faces: [],
               aesthetic: nil, utility: nil, sharpness: 0, feature: "", gps: nil, version: schemaVersion, error: msg)
    }

    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return failed("cannot open") }
    let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    var width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
    var height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
    if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&width, &height) }

    guard let work = thumbnail(src, maxPixels: analysisMaxPixels) else { return failed("cannot decode") }
    guard let thumb = thumbnail(src, maxPixels: thumbMaxPixels) else { return failed("cannot decode thumbnail") }
    do {
        try writeJPEG(thumb, to: outDir.appendingPathComponent("thumbs/\(id).jpg"))
    } catch {
        return failed("thumbnail write: \(error.localizedDescription)")
    }

    let handler = ImageRequestHandler(work)
    var faces: [Face] = []
    var aesthetic: Float? = nil
    var utility: Bool? = nil
    var feature = ""
    var errors: [String] = []

    do {
        let fp = try await handler.perform(GenerateImageFeaturePrintRequest())
        feature = fp.data.base64EncodedString()
    } catch { errors.append("featureprint: \(error.localizedDescription)") }

    do {
        let obs = try await handler.perform(DetectFaceCaptureQualityRequest())
        faces = obs.map { f in
            let b = f.boundingBox
            return Face(quality: f.captureQuality?.score, box: [b.origin.x, b.origin.y, b.width, b.height])
        }
    } catch { errors.append("faces: \(error.localizedDescription)") }
    if !faces.isEmpty {
        for (i, name) in alignedCrops(src: src, work: work, faces: faces, id: id, outDir: outDir) { faces[i].crop = name }
    }

    do {
        let a = try await handler.perform(CalculateImageAestheticsScoresRequest())
        aesthetic = a.overallScore
        utility = a.isUtility
    } catch { errors.append("aesthetics: \(error.localizedDescription)") }

    let sharpImage = thumbnail(src, maxPixels: 512) ?? thumb
    return Record(id: id, path: path, rel: rel, size: size, mtime: mtime, taken: captureDate(props),
                  width: width, height: height, faces: faces, aesthetic: aesthetic, utility: utility,
                  sharpness: sharpness(sharpImage), feature: feature, gps: gpsLocation(props), version: schemaVersion, error: errors.isEmpty ? nil : errors.joined(separator: "; "))
}

let neighborMaxDistance: Float = 0.8
let neighborMaxCount = 40

/// For every analyzed photo, find its closest photos by feature-print distance (Euclidean on
/// unit vectors, so d^2 = 2 - 2*dot). One BLAS matrix multiply per block keeps this fast for
/// tens of thousands of photos. Writes neighbors.json: {id: [[otherId, distance], ...]}.
func writeNeighbors(outDir: URL) throws {
    let text = (try? String(contentsOf: outDir.appendingPathComponent("analysis.jsonl"), encoding: .utf8)) ?? ""
    let dec = JSONDecoder()
    var latest: [String: Record] = [:]  // the file is append-only; the last record per path wins
    for line in text.split(separator: "\n") {
        if let r = try? dec.decode(Record.self, from: Data(line.utf8)) { latest[r.path] = r }
    }
    var ids: [String] = []
    var rows: [[Float]] = []
    for r in latest.values where FileManager.default.fileExists(atPath: r.path) {
        guard let data = Data(base64Encoded: r.feature), !data.isEmpty else { continue }
        let v = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        if let dim = rows.first?.count, v.count != dim { continue }
        ids.append(r.id)
        rows.append(v)
    }
    let n = ids.count
    var result: [String: [[Any]]] = [:]
    if n > 1 {
        let dim = rows[0].count
        let matrix = rows.flatMap { $0 }
        let minDot = 1 - neighborMaxDistance * neighborMaxDistance / 2
        let block = 512
        var out = [Float](repeating: 0, count: block * n)
        var start = 0
        while start < n {
            let m = min(block, n - start)
            matrix.withUnsafeBufferPointer { a in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(m), Int32(n), Int32(dim), 1,
                            a.baseAddress! + start * dim, Int32(dim), a.baseAddress!, Int32(dim), 0, &out, Int32(n))
            }
            for i in 0..<m {
                var near: [(Int, Float)] = []
                for j in 0..<n where j != start + i {
                    let dot = out[i * n + j]
                    if dot >= minDot { near.append((j, sqrt(max(0, 2 - 2 * dot)))) }
                }
                near.sort { $0.1 < $1.1 }
                result[ids[start + i]] = near.prefix(neighborMaxCount).map { [ids[$0.0], Double(($0.1 * 10000).rounded() / 10000)] }
            }
            start += m
        }
    }
    let json = try JSONSerialization.data(withJSONObject: result)
    try json.write(to: outDir.appendingPathComponent("neighbors.json"), options: .atomic)
    print("neighbors: \(n) photos indexed")
}

@main
struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write("usage: analyze <photo-folder> <output-folder>\n".data(using: .utf8)!)
            exit(2)
        }
        let root = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath).standardizedFileURL
        let outDir = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath).standardizedFileURL
        try FileManager.default.createDirectory(at: outDir.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir.appendingPathComponent("faces"), withIntermediateDirectories: true)
        let outFile = outDir.appendingPathComponent("analysis.jsonl")

        // Skip files already analyzed with the same size and mtime.
        var done = Set<String>()
        if let text = try? String(contentsOf: outFile, encoding: .utf8) {
            let dec = JSONDecoder()
            for line in text.split(separator: "\n") {
                if let r = try? dec.decode(Record.self, from: Data(line.utf8)), r.error == nil, r.version == schemaVersion {
                    done.insert("\(r.path)|\(r.size)|\(r.mtime)")
                }
            }
        }

        let all = listImages(root: root)
        let todo = all.filter { url in
            let a = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)) ?? [:]
            let size = (a[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return !done.contains("\(locate(url, root: root).path)|\(size)|\(mtime)")
        }
        print("found \(all.count) images, \(all.count - todo.count) already analyzed, \(todo.count) to go (concurrency \(maxConcurrent))")
        if todo.isEmpty {
            try writeNeighbors(outDir: outDir)
            return
        }

        if !FileManager.default.fileExists(atPath: outFile.path) {
            FileManager.default.createFile(atPath: outFile.path, contents: nil)
        }
        let out = try FileHandle(forWritingTo: outFile)
        try out.seekToEnd()
        let enc = JSONEncoder()
        let start = Date()
        var finished = 0, failures = 0

        await withTaskGroup(of: Record.self) { group in
            var next = 0
            while next < min(maxConcurrent, todo.count) {
                let u = todo[next]; next += 1
                group.addTask { await analyze(url: u, root: root, outDir: outDir) }
            }
            for await rec in group {
                if let data = try? enc.encode(rec) {
                    out.write(data)
                    out.write("\n".data(using: .utf8)!)
                }
                finished += 1
                if rec.error != nil { failures += 1 }
                if finished % 50 == 0 || finished == todo.count {
                    let rate = Double(finished) / max(Date().timeIntervalSince(start), 0.001)
                    print(String(format: "%d/%d  (%.1f photos/s, %d with errors)", finished, todo.count, rate, failures))
                    fflush(stdout)
                }
                if next < todo.count {
                    let u = todo[next]; next += 1
                    group.addTask { await analyze(url: u, root: root, outDir: outDir) }
                }
            }
        }
        try out.close()
        try writeNeighbors(outDir: outDir)
    }
}
