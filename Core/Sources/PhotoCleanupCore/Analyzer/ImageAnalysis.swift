// On-device photo analysis with Apple's Vision framework (free, local). Per photo:
//   - an image feature print (embedding) for similarity grouping
//   - face count, per-face capture quality (sharpness, eyes, expression) and an aligned face crop
//   - an overall aesthetic score and a "utility" flag (screenshots, receipts, documents)
//   - a Laplacian-variance sharpness estimate, capture time, GPS and a thumbnail

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let imageExtensions: Set<String> = [
    "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp", "gif", "bmp",
    "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
]
let thumbMaxPixels = 480
let analysisMaxPixels = 1024

/// Bump when the analysis gains or changes fields, so photos analyzed by an older version are redone.
public let analysisVersion = 4

/// Turns an aligned 112x112 face crop into an identity embedding. Called from several analysis tasks
/// at once, so implementations must be safe to call concurrently.
public protocol FaceEmbedder: Sendable {
    func embed(_ crop: CGImage) throws -> [Float]
}

public struct FaceAnalysis: Sendable {
    public var quality: Float?
    public var box: CGRect  // normalized image coordinates, origin bottom-left
    public var embedding: [Float]?
}

public struct PhotoAnalysis: @unchecked Sendable {
    public var size = 0
    public var mtime = 0.0
    public var taken: Double?  // capture time (EXIF), seconds since 1970, local wall clock
    public var width = 0
    public var height = 0
    public var faces: [FaceAnalysis] = []
    public var aesthetic: Float?
    public var utility: Bool?
    public var sharpness = 0.0
    public var feature = Data()  // Float32 feature print
    public var gps: (lat: Double, lon: Double)?
    public var error: String?
    public var thumbnail: CGImage?

    /// False when the file could not be opened or decoded at all: there is nothing to group or show.
    public var decoded: Bool { thumbnail != nil }
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
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

func gpsLocation(_ props: [CFString: Any]) -> (lat: Double, lon: Double)? {
    guard let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
          let lat = g[kCGImagePropertyGPSLatitude] as? Double,
          let lon = g[kCGImagePropertyGPSLongitude] as? Double else { return nil }
    let signedLat = (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
    let signedLon = (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
    if signedLat == 0 && signedLon == 0 { return nil }  // "null island": a missing fix, not a place
    return (signedLat, signedLon)
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
public let faceCropSize = 112
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

/// Detects face landmarks and warps each face onto the ArcFace template from a high-resolution
/// decode. Returns the aligned crop per index of the capture-quality face it overlaps most.
func alignedCrops(src: CGImageSource, work: CGImage, faces: [FaceAnalysis]) -> [Int: CGImage] {
    let req = VNDetectFaceLandmarksRequest()
    let handler = VNImageRequestHandler(cgImage: work, options: [:])
    guard (try? handler.perform([req])) != nil, let found = req.results, !found.isEmpty,
          let hi = thumbnail(src, maxPixels: faceDecodePixels) else { return [:] }
    let W = Double(hi.width), H = Double(hi.height)
    let template = arcfaceTemplate.map { CGPoint(x: $0.x, y: Double(faceCropSize) - $0.y) }  // to bottom-left origin
    var out: [Int: CGImage] = [:]
    let usable = found.filter { $0.boundingBox.width * W >= minFacePixels }
        .sorted { $0.boundingBox.width > $1.boundingBox.width }.prefix(maxCropsPerPhoto)
    for face in usable {
        guard let pts = fivePoints(face) else { continue }
        let srcPts = pts.map { CGPoint(x: $0.x * W, y: $0.y * H) }
        let t = similarity(from: srcPts, to: template)
        guard let ctx = CGContext(data: nil, width: faceCropSize, height: faceCropSize, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
        ctx.interpolationQuality = .high
        ctx.concatenate(t)
        ctx.draw(hi, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let crop = ctx.makeImage() else { continue }
        // Attach the crop to the capture-quality face it overlaps most.
        let best = faces.indices.max { iou(faces[$0].box, face.boundingBox) < iou(faces[$1].box, face.boundingBox) }
        if let best, out[best] == nil, iou(faces[best].box, face.boundingBox) > 0.2 {
            out[best] = crop
        }
    }
    return out
}

/// Analyzes one image file. Never throws: what went wrong is reported in `error`, and a file that
/// cannot be decoded at all comes back with `decoded == false`.
func analyzeImage(at url: URL, embedder: FaceEmbedder?) async -> PhotoAnalysis {
    var out = PhotoAnalysis()
    let attrs = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)) ?? [:]
    out.size = (attrs[.size] as? NSNumber)?.intValue ?? 0
    out.mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        out.error = "cannot open"
        return out
    }
    let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    var width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
    var height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
    if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&width, &height) }

    guard let work = thumbnail(src, maxPixels: analysisMaxPixels), let thumb = thumbnail(src, maxPixels: thumbMaxPixels) else {
        out.error = "cannot decode"
        return out
    }
    out.width = width
    out.height = height
    out.thumbnail = thumb
    out.taken = captureDate(props)
    out.gps = gpsLocation(props)

    let handler = ImageRequestHandler(work)
    var errors: [String] = []

    do {
        out.feature = try await handler.perform(GenerateImageFeaturePrintRequest()).data
    } catch { errors.append("featureprint: \(error.localizedDescription)") }

    do {
        out.faces = try await handler.perform(DetectFaceCaptureQualityRequest()).map {
            FaceAnalysis(quality: $0.captureQuality?.score, box: $0.boundingBox.cgRect)
        }
    } catch { errors.append("faces: \(error.localizedDescription)") }
    if !out.faces.isEmpty, let embedder {
        for (i, crop) in alignedCrops(src: src, work: work, faces: out.faces) {
            do {
                out.faces[i].embedding = try embedder.embed(crop)
            } catch { errors.append("face embedding: \(error.localizedDescription)") }
        }
    }

    do {
        let a = try await handler.perform(CalculateImageAestheticsScoresRequest())
        out.aesthetic = a.overallScore
        out.utility = a.isUtility
    } catch { errors.append("aesthetics: \(error.localizedDescription)") }

    out.sharpness = sharpness(thumbnail(src, maxPixels: 512) ?? thumb)
    out.error = errors.isEmpty ? nil : errors.joined(separator: "; ")
    return out
}
