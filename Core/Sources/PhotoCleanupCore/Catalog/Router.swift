import Foundation
import ImageIO

/// A reply to one request of the review page: bytes or a file, with what the page needs to know.
public struct RouterResponse {
    public var status = 200
    public var contentType = "application/json"
    public var body = Data()
    public var file: URL?  // served instead of `body` when set
    public var cache = "no-store"
    /// Set for a video: the bytes of `file` to send, and how long the whole file is.
    public var range: (bytes: Range<Int>, of: Int)?

    public init(status: Int = 200, contentType: String = "application/json", body: Data = Data(), file: URL? = nil, cache: String = "no-store") {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.file = file
        self.cache = cache
    }

    /// What to send: the body, the file, or the asked part of the file. Nil when the file cannot be read.
    public func payload() -> Data? {
        guard let file else { return body }
        guard let range else { return try? Data(contentsOf: file, options: .mappedIfSafe) }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.bytes.lowerBound))
            return try handle.read(upToCount: range.bytes.count) ?? Data()
        } catch {
            return nil
        }
    }

    /// The headers of the reply, for a payload of `length` bytes.
    public func headers(length: Int) -> [String: String] {
        var h = ["Content-Type": contentType, "Content-Length": "\(length)", "Cache-Control": cache]
        if let range {
            h["Accept-Ranges"] = "bytes"
            if status == 206 { h["Content-Range"] = "bytes \(range.bytes.lowerBound)-\(range.bytes.upperBound - 1)/\(range.of)" }
            if status == 416 { h["Content-Range"] = "bytes */\(range.of)" }
        }
        return h
    }

    static func json(_ object: Any, status: Int = 200) -> RouterResponse {
        RouterResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ message: String) -> RouterResponse { json(["error": message], status: status) }
    static let notFound = error(404, "not found")
}

/// The review page's server, without a network: the same requests `server.py` answered, answered from
/// the catalog. The app feeds it from a custom URL scheme; the command line tool from localhost.
public final class Router {
    let catalog: Catalog
    let appDir: URL
    private let previewLock = NSLock()
    private var previewLocks: [String: NSLock] = [:]

    static let browserSafe: [String: String] = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"]
    static let staticTypes: [String: String] = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
                                                "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "png": "image/png"]
    static let previewMaxPixels = 2400
    /// Covers and the large favorite: sharper than a thumbnail, far lighter than the original.
    static let midMaxPixels = 1280
    /// The most of a video sent in one reply. A player asks for small parts; a browser that asks for
    /// "the rest" gets this much and asks again, so a long video is never held in memory.
    static let videoMaxBytes = 8 << 20

    /// - Parameter appDir: the folder with index.html, app.js and app.css.
    public init(catalog: Catalog, appDir: URL) {
        self.catalog = catalog
        self.appDir = appDir
    }

    /// - Parameter range: the request's `Range` header, which a video player sends.
    public func handle(method: String, path: String, body: Data = Data(), range: String? = nil) -> RouterResponse {
        do {
            switch method {
            case "GET": return try get(path, range: range)
            case "POST": return try post(path, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
            default: return .error(405, "method not allowed")
            }
        } catch let e as CatalogError {
            if case .unavailable = e { return .error(503, e.localizedDescription) }
            return .error(400, e.localizedDescription)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func get(_ path: String, range: String?) throws -> RouterResponse {
        if path == "/api/data" {
            return RouterResponse(body: try catalog.pageData())
        }
        if path.hasPrefix("/thumb/") {
            let id = String(path.dropFirst("/thumb/".count))
            guard let pid = Int64(id), catalog.record(of: id) != nil else { return .notFound }
            return RouterResponse(contentType: "image/jpeg", file: catalog.library.thumbURL(pid), cache: "max-age=86400")
        }
        if path.hasPrefix("/video/") {
            let id = String(path.dropFirst("/video/".count))
            guard let record = catalog.record(of: id), record.media == .video, let src = catalog.currentURL(of: id),
                  let type = videoContentTypes[src.pathExtension.lowercased()],
                  let size = (try? FileManager.default.attributesOfItem(atPath: src.resolvingSymlinksInPath().path))?[.size] as? Int else { return .notFound }
            var r = RouterResponse(contentType: type, file: src, cache: "no-store")
            guard let asked = Self.byteRange(range, of: size) else {
                r.status = 416
                r.file = nil
                r.range = (0..<0, size)
                return r
            }
            r.status = range == nil && asked.count == size ? 200 : 206
            r.range = (asked, size)
            return r
        }
        if path.hasPrefix("/full/") {
            let id = String(path.dropFirst("/full/".count))
            guard let record = catalog.record(of: id), let src = catalog.currentURL(of: id) else { return .notFound }
            if record.media == .photo, let type = Self.browserSafe[src.pathExtension.lowercased()] {
                return RouterResponse(contentType: type, file: src, cache: "max-age=86400")
            }
            guard let preview = preview(source: src, video: record.media == .video, name: id, maxPixels: Self.previewMaxPixels) else { return .error(500, "preview failed") }
            return RouterResponse(contentType: "image/jpeg", file: preview, cache: "max-age=86400")
        }
        if path.hasPrefix("/mid/") {
            let id = String(path.dropFirst("/mid/".count))
            guard let pid = Int64(id), let record = catalog.record(of: id), let src = catalog.currentURL(of: id) else { return .notFound }
            // While the drive is away (or the file is gone) the thumbnail stands in.
            guard let mid = preview(source: src, video: record.media == .video, name: "\(id).mid", maxPixels: Self.midMaxPixels) else {
                return RouterResponse(contentType: "image/jpeg", file: catalog.library.thumbURL(pid), cache: "no-store")
            }
            return RouterResponse(contentType: "image/jpeg", file: mid, cache: "max-age=86400")
        }
        return Self.staticFile(path, in: appDir)
    }

    /// The bytes a `Range` header asks for ("bytes=0-99", "bytes=100-", "bytes=-50") of a file of
    /// `size` bytes, at most `videoMaxBytes` of them. Without a header: from the start. Nil when it
    /// asks for nothing the file has.
    static func byteRange(_ header: String?, of size: Int) -> Range<Int>? {
        guard let header else { return 0..<min(size, videoMaxBytes) }
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        guard parts.count == 2, parts[0] == "bytes", !parts[1].contains(",") else { return nil }
        let ends = parts[1].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard ends.count == 2 else { return nil }
        var from = 0, to = size - 1
        if ends[0].isEmpty {  // the last n bytes
            guard let n = Int(ends[1]), n > 0 else { return nil }
            from = max(0, size - n)
        } else {
            guard let a = Int(ends[0]), a >= 0 else { return nil }
            from = a
            if !ends[1].isEmpty {
                guard let b = Int(ends[1]), b >= a else { return nil }
                to = min(b, size - 1)
            }
        }
        guard from < size else { return nil }
        return from..<min(to + 1, from + videoMaxBytes)
    }

    /// The page's own files. Only plain names inside the folder are served.
    static func staticFile(_ path: String, in dir: URL) -> RouterResponse {
        let name = path == "/" ? "index.html" : String(path.dropFirst())
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), let type = staticTypes[(name as NSString).pathExtension.lowercased()] else {
            return .notFound
        }
        // no-cache makes the web view revalidate, so it never runs an old script after an update.
        return RouterResponse(contentType: type, file: dir.appendingPathComponent(name), cache: "no-cache")
    }

    private func post(_ path: String, _ body: [String: Any]) throws -> RouterResponse {
        switch path {
        case "/api/decide":
            var changes: [String: PhotoState?] = [:]
            for (id, value) in body["changes"] as? [String: Any] ?? [:] {
                if value is NSNull {
                    changes[id] = .some(nil)
                } else if let s = (value as? String).flatMap(PhotoState.init(rawValue:)) {
                    changes[id] = s
                }
            }
            return .json(["decisions": try catalog.decide(changes)])
        case "/api/reviewed":
            return .json(["reviewed": try catalog.setReviewed(body["ids"] as? [String] ?? [], body["reviewed"] as? Bool ?? false)])
        case "/api/name":
            try catalog.rename(collectionOf: body["id"] as? String, to: body["name"] as? String ?? "")
            return .json(["ok": true])
        case "/api/folder":
            try catalog.setFolder(collectionOf: body["id"] as? String, on: body["on"] as? Bool ?? false)
            return .json(["ok": true])
        case "/api/collections":
            guard let op = (body["op"] as? String).flatMap(Catalog.CollectionEdit.init(rawValue:)) else { throw CatalogError.invalid("unknown operation") }
            return .json(["anchor": try catalog.editCollections(op, ids: body["ids"] as? [String] ?? [], into: body["into"] as? String)])
        case "/api/organize":
            let r = try catalog.organize()
            return .json(["filed": r.filed, "back": r.back, "folders": r.folders, "errors": r.errors])
        case "/api/cleanup":
            let r = try catalog.cleanUp(duplicatesOnly: body["only"] as? String == "duplicates")
            return .json(["moved": r.moved, "reviewed": r.reviewed, "errors": r.errors, "folder": r.folder])
        case "/api/undo":
            guard let step = (body["step"] as? String).flatMap(UndoStep.init(rawValue:)) else { throw CatalogError.invalid("unknown step") }
            let r = try catalog.undo(step)
            return .json(["restored": r.restored, "skipped": r.skipped, "errors": r.errors])
        default:
            return .notFound
        }
    }

    private static func picture(of source: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let longest = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        // Never upscale: a small original is converted at its own size.
        return thumbnail(src, maxPixels: longest > 0 ? min(longest, maxPixels) : maxPixels)
    }

    /// A JPEG of a photo at most `maxPixels` on its long side, made once and kept: what the web view
    /// shows for formats it cannot (HEIC, RAW), and the mid size. For a video, its poster frame.
    private func preview(source: URL, video: Bool, name: String, maxPixels: Int) -> URL? {
        let target = catalog.library.previewsDir.appendingPathComponent("\(name).jpg")
        previewLock.lock()
        let lock = previewLocks[name] ?? NSLock()
        previewLocks[name] = lock
        previewLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let image = video ? videoPoster(of: source, maxPixels: maxPixels) : Self.picture(of: source, maxPixels: maxPixels) else { return nil }
        let tmp = target.deletingLastPathComponent().appendingPathComponent("\(name).tmp-\(UUID().uuidString).jpg")
        do {
            try writeJPEG(image, to: tmp, quality: 0.85)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            return target
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
    }
}
