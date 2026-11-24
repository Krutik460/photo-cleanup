import Foundation

public enum LibraryError: LocalizedError {
    case photoFolderUnavailable(String)
    case notALibrary(String)

    public var errorDescription: String? {
        switch self {
        case .photoFolderUnavailable(let path): "The photo folder is not available: \(path). Connect the drive and try again."
        case .notALibrary(let path): "No photo cleanup library at \(path)."
        }
    }
}

/// One photo folder and everything known about it: a directory holding `library.sqlite` and the
/// caches (thumbnails, previews, contact sheets) that can always be rebuilt from the photos.
public final class Library {
    public let dir: URL
    public let store: Store
    public let root: URL

    public var thumbsDir: URL { dir.appendingPathComponent("thumbs") }
    public var previewsDir: URL { dir.appendingPathComponent("previews") }
    public var sheetsDir: URL { dir.appendingPathComponent("sheets") }

    public func thumbURL(_ id: Int64) -> URL { thumbsDir.appendingPathComponent("\(id).jpg") }

    /// Where a photo is now. The only place that turns a stored path into a file path.
    public func url(forRelPath rel: String) -> URL { root.appendingPathComponent(rel) }

    public var isPhotoFolderAvailable: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    private init(dir: URL, store: Store, root: URL) throws {
        self.dir = dir
        self.store = store
        self.root = root
        for d in [thumbsDir, previewsDir, sheetsDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    public static func create(at dir: URL, photoFolder: URL, name: String? = nil) throws -> Library {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("library.sqlite").path)
        // Folders are resolved once, so /tmp and /private/tmp (or a symlinked volume) name one library.
        let root = photoFolder.resolvingSymlinksInPath().standardizedFileURL
        try store.setMeta("root", root.path)
        try store.setMeta("name", name ?? root.lastPathComponent)
        return try Library(dir: dir, store: store, root: root)
    }

    public static func open(at dir: URL) throws -> Library {
        let file = dir.appendingPathComponent("library.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { throw LibraryError.notALibrary(dir.path) }
        let store = try Store(path: file.path)
        guard let root = try store.meta("root") else { throw LibraryError.notALibrary(dir.path) }
        return try Library(dir: dir, store: store, root: URL(fileURLWithPath: root))
    }

    public var name: String { (try? store.meta("name")) ?? root.lastPathComponent }
}
