import Foundation
import ImageIO

/// A reply to one request of the review page: bytes or a file, with what the page needs to know.
public struct RouterResponse {
    public var status = 200
    public var contentType = "application/json"
    public var body = Data()
    public var file: URL?  // served instead of `body` when set
    public var cache = "no-store"

    public init(status: Int = 200, contentType: String = "application/json", body: Data = Data(), file: URL? = nil, cache: String = "no-store") {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.file = file
        self.cache = cache
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

    /// - Parameter appDir: the folder with index.html, app.js and app.css.
    public init(catalog: Catalog, appDir: URL) {
        self.catalog = catalog
        self.appDir = appDir
    }

    public func handle(method: String, path: String, body: Data = Data()) -> RouterResponse {
        do {
            switch method {
            case "GET": return try get(path)
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

    private func get(_ path: String) throws -> RouterResponse {
        if path == "/api/data" {
            return RouterResponse(body: try catalog.pageData())
        }
        if path.hasPrefix("/thumb/") {
            let id = String(path.dropFirst("/thumb/".count))
            guard let pid = Int64(id), catalog.record(of: id) != nil else { return .notFound }
            return RouterResponse(contentType: "image/jpeg", file: catalog.library.thumbURL(pid), cache: "max-age=86400")
        }
        if path.hasPrefix("/full/") {
            let id = String(path.dropFirst("/full/".count))
            guard let src = catalog.currentURL(of: id) else { return .notFound }
            if let type = Self.browserSafe[src.pathExtension.lowercased()] {
                return RouterResponse(contentType: type, file: src, cache: "max-age=86400")
            }
            guard let preview = preview(source: src, name: id, maxPixels: Self.previewMaxPixels) else { return .error(500, "preview failed") }
            return RouterResponse(contentType: "image/jpeg", file: preview, cache: "max-age=86400")
        }
        if path.hasPrefix("/mid/") {
            let id = String(path.dropFirst("/mid/".count))
            guard let pid = Int64(id), let src = catalog.currentURL(of: id) else { return .notFound }
            // While the drive is away (or the file is gone) the thumbnail stands in.
            guard let mid = preview(source: src, name: "\(id).mid", maxPixels: Self.midMaxPixels) else {
                return RouterResponse(contentType: "image/jpeg", file: catalog.library.thumbURL(pid), cache: "no-store")
            }
            return RouterResponse(contentType: "image/jpeg", file: mid, cache: "max-age=86400")
        }
        return Self.staticFile(path, in: appDir)
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

    /// A JPEG of a photo at most `maxPixels` on its long side, made once and kept: what the web view
    /// shows for formats it cannot (HEIC, RAW), and the mid size.
    private func preview(source: URL, name: String, maxPixels: Int) -> URL? {
        let target = catalog.library.previewsDir.appendingPathComponent("\(name).jpg")
        previewLock.lock()
        let lock = previewLocks[name] ?? NSLock()
        previewLocks[name] = lock
        previewLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let longest = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        // Never upscale: a small original is converted at its own size.
        guard let image = thumbnail(src, maxPixels: longest > 0 ? min(longest, maxPixels) : maxPixels) else { return nil }
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
