// Videos, read with AVFoundation on the Mac. A video is analyzed as what its file says (duration,
// size, when and where it was shot) plus one poster frame, which goes through the same Vision steps
// as a photo: that gives it a thumbnail, your face when you are in it, and a score for covers.

import AVFoundation
import CoreGraphics
import Foundation

/// The containers AVFoundation opens. The value is the type the web view is told when it plays one.
let videoContentTypes: [String: String] = ["mov": "video/quicktime", "mp4": "video/mp4", "m4v": "video/mp4", "3gp": "video/3gpp"]
let videoExtensions = Set(videoContentTypes.keys)

/// The video half of a Live Photo is a .mov named like its photo, in the same folder. It is not an
/// item of its own: it moves with its photo.
let livePhotoVideoExtensions: Set<String> = ["mov"]

func isLivePhotoVideo(_ name: String, ofPhotoWithStem stem: String) -> Bool {
    livePhotoVideoExtensions.contains((name as NSString).pathExtension.lowercased())
        && (name as NSString).deletingPathExtension == stem && !name.hasPrefix("._")
}

/// Where a video's poster frame is taken: a moment in, because the first frame is often black or
/// still moving into place.
func posterTime(duration: Double) -> CMTime {
    CMTime(seconds: duration > 2 ? 1 : max(0, duration / 2), preferredTimescale: 600)
}

/// The poster frame, upright, at most `maxPixels` on its long side.
func poster(of asset: AVAsset, duration: Double, maxPixels: Int) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    if let exact = try? await generator.image(at: posterTime(duration: duration)).image { return exact }
    // A clip whose frames do not reach that moment: whatever frame is nearest to the start.
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    return try? await generator.image(at: .zero).image
}

/// A video's poster frame for the page (covers, the large tile), made while the caller waits.
/// Call it off the main thread and off Swift's own task threads.
func videoPoster(of url: URL, maxPixels: Int) -> CGImage? {
    final class Box: @unchecked Sendable { var image: CGImage? }
    let box = Box(), done = DispatchSemaphore(value: 0)
    Task.detached {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite {
            box.image = await poster(of: asset, duration: duration, maxPixels: maxPixels)
        }
        done.signal()
    }
    done.wait()
    return box.image
}

/// `image` at most `maxPixels` on its long side. Never larger than it is.
func scaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
    let longest = max(image.width, image.height)
    guard longest > maxPixels else { return image }
    let f = Double(maxPixels) / Double(longest)
    let w = max(1, Int((Double(image.width) * f).rounded())), h = max(1, Int((Double(image.height) * f).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// "2026-10-16T10:05:00-0700" as the wall clock it shows (seconds since 1970 as if it were UTC), the
/// way capture times of photos are kept. The offset is left out on purpose.
func wallClock(iso text: String) -> Double? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f.date(from: String(text.prefix(19)))?.timeIntervalSince1970
}

/// "+47.6062-122.3321+010.000/" (ISO 6709, how QuickTime and MP4 files write a place).
func location(iso6709 text: String) -> (lat: Double, lon: Double)? {
    let pattern = try! NSRegularExpression(pattern: #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#)
    guard let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
          let lat = Double(text[a]), let lon = Double(text[b]), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
    if lat == 0 && lon == 0 { return nil }  // "null island": a missing fix, not a place
    return (lat, lon)
}

/// When a video was shot, as a wall clock. An iPhone writes the local time with its offset; other
/// cameras only write an instant, which is shown in the Mac's time zone.
func captureTime(metadata: [AVMetadataItem], created: AVMetadataItem?, timeZone: TimeZone) async -> Double? {
    for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate) {
        if let text = try? await item.load(.stringValue), let t = wallClock(iso: text) { return t }
    }
    // A file that never set its clock says 1904 (or 1970): that is no capture time.
    if let date = try? await created?.load(.dateValue), date.timeIntervalSince1970 > 365 * 86400 {
        return date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
    }
    return nil
}

func location(metadata: [AVMetadataItem]) async -> (lat: Double, lon: Double)? {
    for id in [AVMetadataIdentifier.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709, .commonIdentifierLocation] {
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id) {
            if let text = try? await item.load(.stringValue), let place = location(iso6709: text) { return place }
        }
    }
    return nil
}

/// Analyzes one video file. Never throws: what went wrong is reported in `error`, and a file that
/// cannot be read as a video comes back with `decoded == false`.
func analyzeVideo(at url: URL, embedder: FaceEmbedder?, timeZone: TimeZone = .current) async -> PhotoAnalysis {
    var out = fileFacts(of: url)
    let asset = AVURLAsset(url: url)
    var facts = MediaFacts()
    do {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            out.error = "no video in this file"
            return out
        }
        let (duration, metadata, created) = try await asset.load(.duration, .metadata, .creationDate)
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)  // upright, as it plays
        facts.width = Int(abs(shown.width).rounded())
        facts.height = Int(abs(shown.height).rounded())
        facts.duration = duration.seconds.isFinite ? max(0, duration.seconds) : 0
        facts.taken = await captureTime(metadata: metadata, created: created, timeZone: timeZone)
        facts.gps = await location(metadata: metadata)
    } catch {
        out.error = "cannot open"
        return out
    }
    guard facts.width > 0, facts.height > 0, let frame = await poster(of: asset, duration: facts.duration ?? 0, maxPixels: faceDecodePixels) else {
        out.error = "cannot decode"
        return out
    }
    return await analyzePicture(out, facts: facts, embedder: embedder) { scaled(frame, maxPixels: $0) }
}
