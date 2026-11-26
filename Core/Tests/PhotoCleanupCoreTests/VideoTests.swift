import AVFoundation
import GRDB
import XCTest
@testable import PhotoCleanupCore

/// A short real video: the test picture of `seed` held for `seconds`, 320 x 240, H.264.
/// `created` and `place` are written the way an iPhone writes them (QuickTime metadata).
func makeVideo(at url: URL, seed: Int, seconds: Double = 1, created: String? = nil, place: String? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    let w = 320, h = 240, fps: Int32 = 10
    let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
    ])
    var items: [AVMetadataItem] = []
    for (id, value) in [(AVMetadataIdentifier.quickTimeMetadataCreationDate, created), (.quickTimeMetadataLocationISO6709, place)] {
        guard let value else { continue }
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        items.append(item)
    }
    writer.metadata = items
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    let picture = makePicture(seed: seed, size: 320), frames = Int32(seconds * Double(fps))
    for f in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &made)
        let buffer = made!
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

/// Videos from the scan to the file steps, on real (generated) files in a temporary folder.
final class VideoTests: XCTestCase {
    var base: URL!
    var photos: URL!
    var library: Library!
    let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        photos = base.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        library = try Library.create(at: base.appendingPathComponent("library"), photoFolder: photos)
    }

    override func tearDownWithError() throws {
        library = nil
        try? FileManager.default.removeItem(at: base)
    }

    func picture(_ rel: String, seed: Int) throws {
        let url = photos.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJPEG(makePicture(seed: seed), to: url, quality: 0.9)
    }

    func video(_ rel: String, seed: Int, seconds: Double = 1, created: String? = nil, place: String? = nil) throws {
        try makeVideo(at: photos.appendingPathComponent(rel), seed: seed, seconds: seconds, created: created, place: place)
    }

    func copy(_ from: String, _ to: String) throws {
        try FileManager.default.copyItem(at: photos.appendingPathComponent(from), to: photos.appendingPathComponent(to))
    }

    func has(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: photos.appendingPathComponent(rel).path) }

    @discardableResult
    func scan() async throws -> ScanSummary { try await Analyzer(library: library).run() }

    func row(_ rel: String) throws -> PhotoRecord? {
        try library.store.db.read { try PhotoRecord.fetchOne($0, sql: "SELECT * FROM photo WHERE original_rel_path = ?", arguments: [rel]) }
    }

    func id(_ rel: String) throws -> String { String(try XCTUnwrap(try row(rel)?.id)) }

    func count(_ sql: String) throws -> Int { try library.store.db.read { try Int.fetchOne($0, sql: sql) ?? 0 } }

    // MARK: - Scan

    func testAScanFindsVideosAndReadsWhatTheySay() async throws {
        try picture("a.jpg", seed: 1)
        try video("clip.mov", seed: 2, seconds: 3, created: "2026-10-16T10:05:00-0700", place: "+47.6000-122.3300+010.000/")
        try video("plain.mp4", seed: 3)
        // A Live Photo: its video is never opened, so its bytes do not matter.
        try picture("IMG_1.jpg", seed: 4)
        try Data("the video half".utf8).write(to: photos.appendingPathComponent("IMG_1.MOV"))
        try Data("not a video".utf8).write(to: photos.appendingPathComponent("broken.mp4"))

        let s = try await scan()
        XCTAssertEqual([s.found, s.analyzed, s.analyzedVideos], [5, 5, 3])
        XCTAssertEqual(s.failed, ["broken.mp4"])
        XCTAssertNil(try row("IMG_1.MOV"), "the video half of a Live Photo is not an item")

        let clip = try XCTUnwrap(try row("clip.mov"))
        XCTAssertEqual(clip.media, .video)
        XCTAssertEqual([clip.width, clip.height], [320, 240])
        XCTAssertEqual(try XCTUnwrap(clip.duration), 3, accuracy: 0.2)
        // 10:05 on the wall where it was shot, whatever zone this Mac is in.
        XCTAssertEqual(clip.taken, wallClock(iso: "2026-10-16T10:05:00"))
        XCTAssertEqual(try XCTUnwrap(clip.lat), 47.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(clip.lon), -122.33, accuracy: 0.0001)
        XCTAssertNotNil(clip.feature)
        XCTAssertNotNil(clip.fingerprint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.thumbURL(clip.id!).path))
        XCTAssertEqual(try row("a.jpg")?.media, .photo)
        XCTAssertNil(try row("a.jpg")?.duration)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE media = 'video' AND width > 0"), 2)

        // Videos are compared with nothing: only photos have neighbors.
        XCTAssertEqual(try count("SELECT COUNT(*) FROM neighbor n JOIN photo p ON p.id IN (n.a, n.b) WHERE p.media = 'video'"), 0)

        let again = try await scan()
        XCTAssertEqual([again.found, again.analyzed, again.missing], [5, 1, 0], "only the file that could not be read is tried again")
    }

    func testWhenAndWhereAVideoWasShot() {
        XCTAssertEqual(wallClock(iso: "2026-10-16T10:05:00-0700"), wallClock(iso: "2026-10-16T10:05:00+0530"))
        XCTAssertNil(wallClock(iso: "yesterday"))
        XCTAssertEqual(location(iso6709: "+47.6062-122.3321+010.000/")?.lat, 47.6062)
        XCTAssertEqual(location(iso6709: "-33.8688+151.2093/")?.lon, 151.2093)
        XCTAssertNil(location(iso6709: "+00.0000+000.0000/"))
        XCTAssertNil(location(iso6709: "somewhere"))
        XCTAssertEqual(posterTime(duration: 20).seconds, 1)
        XCTAssertEqual(posterTime(duration: 1).seconds, 0.5)
    }

    // MARK: - Groups

    func testOnlyExactCopiesOfAVideoAreGrouped() async throws {
        try video("clip.mov", seed: 2, created: "2026-10-16T10:05:00-0700")
        try copy("clip.mov", "clip 2.mov")
        try video("retake.mov", seed: 2, seconds: 2, created: "2026-10-16T10:06:00-0700")  // the same scene again
        try picture("still.jpg", seed: 2)  // and a photo of it
        try await scan()
        let catalog = try Catalog(library: library, timeZone: utc)
        let r = catalog.result

        XCTAssertEqual(r.groups.count, 1)
        let g = try XCTUnwrap(r.groups.first)
        XCTAssertEqual(g.kind, .duplicate)
        XCTAssertEqual(g.members, [try id("clip.mov"), try id("clip 2.mov")], "the original name is the one to keep")
        XCTAssertEqual(r.photos[try id("clip.mov")]?.auto, .fav)
        XCTAssertEqual(r.photos[try id("clip 2.mov")]?.auto, .remove)
        XCTAssertEqual(r.photos[try id("clip 2.mov")]?.reason, "An exact copy of a video you are keeping")
        for rel in ["retake.mov", "still.jpg"] {
            XCTAssertNil(r.photos[try id(rel)]?.group, rel)
            XCTAssertEqual(r.photos[try id(rel)]?.auto, .keep, rel)
        }
        // The videos of that October day are one collection, as photos would be (the photo has no
        // capture time, so it goes by its file's date).
        XCTAssertEqual(Set(try ["clip.mov", "clip 2.mov", "retake.mov"].map { r.photos[try id($0)]?.collection }).count, 1)

        let page = try JSONSerialization.jsonObject(with: catalog.pageData()) as! [String: Any]
        let shown = page["photos"] as! [String: [String: Any]]
        XCTAssertEqual(try XCTUnwrap(shown[try id("retake.mov")]?["dur"] as? Double), 2, accuracy: 0.2)
        XCTAssertNil(shown[try id("still.jpg")]?["dur"], "only a video has a duration")
        let summary = try catalog.summary()
        XCTAssertEqual([summary.photos, summary.videos, summary.toRemove], [1, 3, 1])
    }

    func testASummaryStoredByAnEarlierVersionStillOpens() throws {
        let old = #"{"photos":12,"collections":2,"groups":3,"reviewedGroups":1,"you":0,"filed":0,"toRemove":4,"toRemoveBytes":9,"removed":0,"removedBytes":0,"waitingBytes":0,"covers":[1,2],"updated":5}"#
        let s = try JSONDecoder().decode(LibrarySummary.self, from: Data(old.utf8))
        XCTAssertEqual([s.photos, s.videos, s.toRemove], [12, 0, 4])
        XCTAssertEqual(s.covers, [1, 2])
    }

    // MARK: - Moving files

    func testAVideoIsFiledCleanedUpAndPutBackLikeAPhoto() async throws {
        try video("Trip/clip.mov", seed: 2)
        try picture("Trip/IMG_1.jpg", seed: 4)
        try Data("the video half".utf8).write(to: photos.appendingPathComponent("Trip/IMG_1.MOV"))
        try await scan()
        let catalog = try Catalog(library: library, timeZone: utc)
        let clip = try id("Trip/clip.mov"), still = try id("Trip/IMG_1.jpg")

        try catalog.rename(collectionOf: clip, to: "Seattle")
        try catalog.setFolder(collectionOf: clip, on: true)
        XCTAssertEqual(try catalog.organize().filed, 2)
        XCTAssertTrue(has("Seattle/clip.mov") && has("Seattle/IMG_1.jpg") && has("Seattle/IMG_1.MOV"))
        XCTAssertEqual(try row("Trip/clip.mov")?.location, .filed)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM companion"), 1, "only the Live Photo video is a companion, the video item is not its own")

        // Both marked remove: the video goes, and the Live Photo video goes with its photo.
        try catalog.decide([clip: .remove, still: .remove])
        XCTAssertEqual(try catalog.cleanUp().moved, 2)
        XCTAssertTrue(has("_to_remove/Trip/clip.mov") && has("_to_remove/Trip/IMG_1.jpg") && has("_to_remove/Trip/IMG_1.MOV"))
        XCTAssertFalse(has("Seattle/IMG_1.MOV"))

        XCTAssertEqual(try catalog.undo(.cleanup).restored, 2)
        XCTAssertTrue(has("Seattle/clip.mov") && has("Seattle/IMG_1.jpg") && has("Seattle/IMG_1.MOV"))
        XCTAssertEqual(try catalog.undo(.organize).restored, 2)
        XCTAssertTrue(has("Trip/clip.mov") && has("Trip/IMG_1.jpg") && has("Trip/IMG_1.MOV"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM companion"), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE location != 'in_place' OR rel_path != original_rel_path"), 0)
    }

    func testALivePhotoVideoLeavesWithItsPhotoWhereverItIs() async throws {
        try picture("IMG_1.jpg", seed: 4)
        try Data("the video half".utf8).write(to: photos.appendingPathComponent("IMG_1.MOV"))
        try await scan()
        let catalog = try Catalog(library: library, timeZone: utc)
        try catalog.decide([try id("IMG_1.jpg"): .remove])
        XCTAssertEqual(try catalog.cleanUp().moved, 1)
        XCTAssertTrue(has("_to_remove/IMG_1.jpg") && has("_to_remove/IMG_1.MOV"))
        XCTAssertFalse(has("IMG_1.MOV"), "left behind, it would show up as a video of its own at the next scan")
        let s = try await scan()
        XCTAssertEqual([s.found, s.missing], [0, 0])

        XCTAssertEqual(try catalog.undo(.cleanup).restored, 1)
        XCTAssertTrue(has("IMG_1.jpg") && has("IMG_1.MOV"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM companion"), 0)
    }

    func testAVideoFiledNextToAPhotoOfTheSameNameStaysAVideoOfItsOwn() async throws {
        // Two cameras counted alike: a photo and an unrelated video share the name IMG_5.
        try picture("A/IMG_5.jpg", seed: 5)
        try video("B/IMG_5.mov", seed: 6)
        try await scan()
        let catalog = try Catalog(library: library, timeZone: utc)
        let still = try id("A/IMG_5.jpg"), clip = try id("B/IMG_5.mov")
        try catalog.editCollections(.move, ids: [clip], into: still)
        try catalog.rename(collectionOf: still, to: "Album")
        try catalog.setFolder(collectionOf: still, on: true)
        XCTAssertEqual(try catalog.organize().filed, 2)
        XCTAssertTrue(has("Album/IMG_5.jpg") && has("Album/IMG_5.mov"))

        let s = try await scan()
        XCTAssertEqual([s.found, s.missing, s.analyzed], [2, 0, 0], "the library knows that file as a video")
        try catalog.regroup()

        // Removing the photo takes the photo only.
        try catalog.decide([still: .remove])
        XCTAssertEqual(try catalog.cleanUp().moved, 1)
        XCTAssertTrue(has("Album/IMG_5.mov"))
        XCTAssertEqual(try row("B/IMG_5.mov")?.relPath, "Album/IMG_5.mov")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM companion"), 0)
    }

    func testAVideoMovedInFinderIsTheSameVideo() async throws {
        try video("clip.mov", seed: 2)
        try await scan()
        let before = try id("clip.mov")
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("Later"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: photos.appendingPathComponent("clip.mov"), to: photos.appendingPathComponent("Later/renamed.mov"))
        let s = try await scan()
        XCTAssertEqual([s.relinked, s.analyzed, s.missing], [1, 0, 0])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM photo WHERE id = \(before) AND rel_path = 'Later/renamed.mov' AND missing = 0"), 1)
    }

    // MARK: - The page

    func testAVideoIsServedInTheBytesAskedFor() async throws {
        try video("clip.mov", seed: 2)
        try picture("a.jpg", seed: 1)
        try await scan()
        let app = base.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let router = Router(catalog: try Catalog(library: library, timeZone: utc), appDir: app)
        let clip = try id("clip.mov"), file = try Data(contentsOf: photos.appendingPathComponent("clip.mov")), size = file.count

        let part = router.handle(method: "GET", path: "/video/\(clip)", range: "bytes=10-19")
        XCTAssertEqual(part.status, 206)
        XCTAssertEqual(part.contentType, "video/quicktime")
        XCTAssertEqual(part.payload(), file.subdata(in: 10..<20))
        XCTAssertEqual(part.headers(length: 10)["Content-Range"], "bytes 10-19/\(size)")
        XCTAssertEqual(part.headers(length: 10)["Accept-Ranges"], "bytes")

        let rest = router.handle(method: "GET", path: "/video/\(clip)", range: "bytes=\(size - 4)-")
        XCTAssertEqual(rest.payload(), file.suffix(4))
        XCTAssertEqual(router.handle(method: "GET", path: "/video/\(clip)", range: "bytes=-6").payload(), file.suffix(6))

        let whole = router.handle(method: "GET", path: "/video/\(clip)")
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.payload(), file)

        let past = router.handle(method: "GET", path: "/video/\(clip)", range: "bytes=\(size)-")
        XCTAssertEqual(past.status, 416)
        XCTAssertEqual(past.headers(length: 0)["Content-Range"], "bytes */\(size)")

        XCTAssertEqual(router.handle(method: "GET", path: "/video/\(try id("a.jpg"))").status, 404, "a photo is not a video")
        XCTAssertEqual(router.handle(method: "GET", path: "/video/999").status, 404)

        // The large tile and the viewer get a poster frame, made once.
        for path in ["/mid/\(clip)", "/full/\(clip)"] {
            let poster = router.handle(method: "GET", path: path)
            XCTAssertEqual(poster.contentType, "image/jpeg", path)
            XCTAssertEqual(poster.file?.deletingLastPathComponent().lastPathComponent, "previews", path)
            let src = CGImageSourceCreateWithURL(try XCTUnwrap(poster.file) as CFURL, nil)!
            XCTAssertEqual(CGImageSourceCreateImageAtIndex(src, 0, nil)?.width, 320, path)
        }
    }

    func testByteRanges() {
        let cap = Router.videoMaxBytes
        XCTAssertEqual(Router.byteRange("bytes=0-1", of: 100), 0..<2)
        XCTAssertEqual(Router.byteRange("bytes=90-500", of: 100), 90..<100)
        XCTAssertEqual(Router.byteRange("bytes=50-", of: 100), 50..<100)
        XCTAssertEqual(Router.byteRange("bytes=-10", of: 100), 90..<100)
        XCTAssertEqual(Router.byteRange("bytes=-500", of: 100), 0..<100)
        XCTAssertEqual(Router.byteRange(nil, of: 100), 0..<100)
        // "The rest" of a long video comes in parts, so it is never held in memory at once.
        XCTAssertEqual(Router.byteRange("bytes=5-", of: cap * 3), 5..<(5 + cap))
        XCTAssertEqual(Router.byteRange(nil, of: cap * 3), 0..<cap)
        for bad in ["bytes=100-", "bytes=5-2", "bytes=a-b", "bytes=0-1,5-6", "items=0-1", "bytes=-0", "bytes"] {
            XCTAssertNil(Router.byteRange(bad, of: 100), bad)
        }
    }
}
