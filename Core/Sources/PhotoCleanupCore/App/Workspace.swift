import Foundation

/// What only a real Mac app can do for the interface: file pickers, Finder, the Settings window,
/// moving the window. Called from a background thread; implementations hop to the main thread.
public protocol WorkspaceUI: AnyObject {
    /// Lets the user pick: "folder" (one photo folder), "me" (up to three photos of them) or
    /// "old-review" (an output folder of the earlier scripts). Empty when cancelled.
    func choose(_ kind: String) -> [URL]
    func reveal(_ url: URL)
    func openSettings()
    /// Opens Terminal, where the user types the commands the interface shows. The app runs none of them.
    func openTerminal()
    /// "drag" starts moving the window from the mouse press in progress, "zoom" zooms it.
    func window(_ action: String)
}

public enum WorkspaceError: LocalizedError {
    case needsApp(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .needsApp(let what): "\(what) needs the Photo Cleanup app."
        case .invalid(let m): m
        }
    }
}

/// Everything the interface needs above a single library: the list of photo folders, which one is
/// open, scanning, the second opinion, and the state of the Claude CLI. It has no UI of its own; the
/// Mac app and the development server both drive it and show what `state()` reports.
public final class Workspace {
    public struct Claude: Equatable, Sendable {
        public var path: String?
        public var version: String?
        public var loggedIn = false
        public var detail = "Looking for the Claude CLI"
        public var checking = true
        public var ready: Bool { path != nil && loggedIn }

        public init(path: String? = nil, version: String? = nil, loggedIn: Bool = false, detail: String = "Looking for the Claude CLI", checking: Bool = true) {
            self.path = path
            self.version = version
            self.loggedIn = loggedIn
            self.detail = detail
            self.checking = checking
        }
    }

    struct Session {
        let id: String
        let library: Library
        let catalog: Catalog
        let router: Router
    }

    public let librariesDir: URL
    /// The interface's own files (index.html and what it loads).
    public let uiDir: URL
    public weak var ui: WorkspaceUI?
    /// Called on any thread whenever `state()` would report something new.
    public var onChange: (@Sendable () -> Void)?
    /// Preferences the app keeps: the Claude command, the model and how many batches run at once.
    public var claudePath: @Sendable () -> String? = { nil }
    public var claudeModel: @Sendable () -> String = { "haiku" }
    public var claudeParallel: @Sendable () -> Int = { 3 }
    /// How a removed library leaves: to the Trash, so it can be put back. Tests replace it.
    public var discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    let embedder: FaceEmbedder?
    private let lock = NSRecursiveLock()
    private var session: Session?
    private var folders: [[String: Any]]?  // cached; nil = list again
    private var claude = Claude()
    private var scan: [String: Any]?
    private var lastScan: [String: Any]?
    private var scanTask: Task<Void, Never>?
    private var opinion: SecondOpinionRun.Progress?
    private var opinionLog: [String] = []
    private var opinionTask: Task<Void, Never>?
    private var dataVersion = 0
    private var notice: [String: Any]?
    private var noticeId = 0

    public init(librariesDir: URL, uiDir: URL, embedder: FaceEmbedder? = nil) {
        self.librariesDir = librariesDir
        self.uiDir = uiDir
        self.embedder = embedder
        try? FileManager.default.createDirectory(at: librariesDir, withIntermediateDirectories: true)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func changed() { onChange?() }

    // MARK: - State

    public var claudeState: Claude { locked { claude } }
    public var isBusy: Bool { locked { scan != nil } }
    public var hasOpenFolder: Bool { locked { session != nil } }
    public var router: Router? { locked { session?.router } }

    /// Everything the interface shows outside a library's own data, as JSON-ready values.
    public func state() -> [String: Any] {
        locked {
            let list = listFolders()
            let saved = list.reduce(0) { $0 + ($1["savedBytes"] as? Int ?? 0) }
            let waiting = list.reduce(0) { $0 + ($1["waitingBytes"] as? Int ?? 0) }
            var out: [String: Any] = [
                "app": ["name": "Photo Cleanup", "tagline": "Keep the best shot. Let the rest go."],
                "faceModel": embedder != nil,
                "claude": ["ready": claude.ready, "path": claude.path as Any? ?? NSNull(), "version": claude.version as Any? ?? NSNull(),
                           "loggedIn": claude.loggedIn, "checking": claude.checking, "detail": claude.detail],
                "folders": list,
                "totals": ["savedBytes": saved, "waitingBytes": waiting],
                "open": session?.id as Any? ?? NSNull(),
                "dataVersion": dataVersion,
                "scan": scan as Any? ?? NSNull(),
                "lastScan": lastScan as Any? ?? NSNull(),
                "notice": notice as Any? ?? NSNull(),
            ]
            let pending = (try? session?.catalog.groupsNeedingSecondOpinion().count) ?? 0
            out["opinion"] = ["running": opinion != nil, "done": opinion?.done ?? 0, "total": opinion?.total ?? 0, "failed": opinion?.failed ?? 0,
                              "groups": opinion?.groups ?? 0, "pending": pending, "log": opinionLog,
                              "model": claudeModel()] as [String: Any]
            return out
        }
    }

    /// Photo folders with a library, most recently opened first. Each library carries a summary, so
    /// nothing is regrouped to show the list.
    private func listFolders() -> [[String: Any]] {
        if let folders { return folders }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: librariesDir, includingPropertiesForKeys: nil)) ?? []
        var list: [(opened: Double, name: String, json: [String: Any])] = []
        for dir in dirs {
            let live = session?.id == dir.lastPathComponent ? session?.library : nil
            guard let library = live ?? (try? Library.open(at: dir)) else { continue }
            let s = library.summary ?? LibrarySummary()
            let opened = library.lastOpened?.timeIntervalSince1970
            list.append((opened ?? 0, library.name, [
                "id": dir.lastPathComponent, "name": library.name, "path": (library.root.path as NSString).abbreviatingWithTildeInPath,
                "photos": library.photoCount, "connected": library.isPhotoFolderAvailable, "lastOpened": opened as Any? ?? NSNull(),
                "groups": s.groups, "groupsReviewed": s.reviewedGroups, "toRemove": s.toRemove, "toRemoveBytes": s.toRemoveBytes,
                "savedBytes": s.savedBytes, "waitingBytes": s.waitingBytes, "you": s.you, "covers": s.covers.map(String.init),
            ]))
        }
        list.sort { $0.opened != $1.opened ? $0.opened > $1.opened : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        folders = list.map(\.json)
        return folders!
    }

    private func say(_ text: String, error: Bool = false) {
        locked {
            noticeId += 1
            notice = ["id": noticeId, "text": text, "error": error]
        }
        changed()
    }

    /// Where a folder's thumbnail is, for the cards on the home screen.
    public func thumbURL(folder: String, photo: String) -> URL? {
        guard !folder.isEmpty, !folder.contains("/"), !folder.hasPrefix("."), let id = Int64(photo) else { return nil }
        return librariesDir.appendingPathComponent(folder).appendingPathComponent("thumbs/\(id).jpg")
    }

    // MARK: - Actions

    /// Runs one action of the interface. Returns what the page needs back; throws with a message
    /// meant for the user.
    public func perform(_ action: String, _ body: [String: Any]) throws -> [String: Any] {
        switch action {
        case "open":
            try open(id: body["id"] as? String ?? "")
        case "close":
            close()
        case "choose":
            guard let ui else { throw WorkspaceError.needsApp("Choosing files") }
            return ["paths": ui.choose(body["kind"] as? String ?? "folder").map(\.path)]
        case "add":
            guard let path = body["path"] as? String, !path.isEmpty else { throw WorkspaceError.invalid("No folder was chosen.") }
            try add(folder: URL(fileURLWithPath: path), photosOfYou: (body["me"] as? [String] ?? []).map { URL(fileURLWithPath: $0) })
        case "remove":
            try remove(id: body["id"] as? String ?? "")
        case "scan":
            startScan()
        case "me":
            // New photos of you for the open folder: the reference is replaced and every face matched again.
            guard embedder != nil else { throw WorkspaceError.invalid("This build of Photo Cleanup has no face recognition.") }
            let photos = (body["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            guard !photos.isEmpty else { throw WorkspaceError.invalid("No photo was chosen.") }
            guard hasOpenFolder, !isBusy else { throw WorkspaceError.invalid("Wait for the scan to finish first.") }
            startScan(photosOfYou: photos)
        case "scan-cancel":
            locked { scanTask }?.cancel()
        case "opinion":
            if body["action"] as? String == "stop" { locked { opinionTask }?.cancel() } else { try startOpinion() }
        case "claude":
            refreshClaude()
        case "settings":
            guard let ui else { throw WorkspaceError.needsApp("Settings") }
            ui.openSettings()
        case "terminal":
            guard let ui else { throw WorkspaceError.needsApp("Opening Terminal") }
            ui.openTerminal()
        case "reveal":
            guard let ui else { throw WorkspaceError.needsApp("Showing a folder in Finder") }
            if let id = body["id"] as? String, let library = try? Library.open(at: librariesDir.appendingPathComponent(id)) { ui.reveal(library.root) }
        case "import":
            try importOldReview(from: (body["path"] as? String).map { URL(fileURLWithPath: $0) })
        case "window":
            ui?.window(body["action"] as? String ?? "")
        default:
            throw WorkspaceError.invalid("Unknown action \(action).")
        }
        return ["ok": true]
    }

    public func open(id: String) throws {
        try locked {
            guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw WorkspaceError.invalid("Unknown folder.") }
            if session?.id == id { return }
            closeLocked()
            let library = try Library.open(at: librariesDir.appendingPathComponent(id))
            let catalog = try Catalog(library: library)
            library.markOpened()
            session = Session(id: id, library: library, catalog: catalog, router: Router(catalog: catalog, appDir: uiDir))
            lastScan = nil
            opinionLog = []
            folders = nil
            dataVersion += 1
        }
        changed()
        // Files moved or deleted in Finder since the last visit are picked up without being asked.
        guard let s = locked({ session }), s.id == id, s.library.isPhotoFolderAvailable else { return }
        Task.detached { [weak self] in
            // So is what an earlier version of the app analyzed differently.
            guard s.catalog.hasOutdatedAnalysis() || s.catalog.hasPhotosOffTheirPath(), let self, self.locked({ self.session?.id }) == id else { return }
            self.startScan()
        }
    }

    public func close() {
        locked { closeLocked() }
        changed()
    }

    private func closeLocked() {
        scanTask?.cancel()
        opinionTask?.cancel()
        // Choices and reviewed marks made since the last regroup change the home screen's numbers.
        _ = try? session?.catalog.saveSummary()
        session?.library.markOpened()
        session = nil
        scan = nil
        opinion = nil
        folders = nil
    }

    /// Creates a library for a photo folder (or opens the one that exists for it) and scans it.
    public func add(folder: URL, photosOfYou: [URL]) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.invalid("\(folder.lastPathComponent) is not a folder.")
        }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let existing: String? = locked {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: librariesDir, includingPropertiesForKeys: nil)) ?? []
            return dirs.first { (try? Library.open(at: $0))?.root.path == root }?.lastPathComponent
        }
        if let existing {
            try open(id: existing)
        } else {
            let dir = librariesDir.appendingPathComponent(UUID().uuidString)
            _ = try Library.create(at: dir, photoFolder: folder)
            locked { folders = nil }
            try open(id: dir.lastPathComponent)
        }
        startScan(photosOfYou: photosOfYou)
    }

    /// Forgets a photo folder: its library goes to the Trash. The photos are not touched.
    public func remove(id: String) throws {
        try locked {
            guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw WorkspaceError.invalid("Unknown folder.") }
            if session?.id == id { closeLocked() }
            let dir = librariesDir.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.sqlite").path) else { throw WorkspaceError.invalid("Unknown folder.") }
            try discard(dir)
            folders = nil
        }
        changed()
    }

    /// Analyzes new and changed photos, finds you, and regroups. Incremental and safe to cancel.
    public func startScan(photosOfYou: [URL] = []) {
        let current: Session? = locked {
            guard let s = session, scan == nil else { return nil }
            scan = ["title": "Looking for photos", "done": 0, "total": 0, "failed": 0]
            return s
        }
        guard let s = current else { return }
        changed()
        let embedder = self.embedder
        let task = Task { [weak self] in
            var message: (String, Bool)?
            do {
                let summary = try await Analyzer(library: s.library, embedder: embedder).run { [weak self] p in
                    guard let self else { return }
                    let title: String? = switch p.phase {
                    case .listing: "Looking for photos"
                    case .analyzing: "Analyzing photos"
                    case .neighbors: "Comparing photos"
                    case .done: nil
                    }
                    guard let title else { return }
                    self.locked { if self.scan != nil { self.scan = ["title": title, "done": p.done, "total": p.total, "failed": p.failed] } }
                    self.changed()
                }
                self?.setScan(title: "Finding you")
                let me = Me(store: s.library.store)
                if !photosOfYou.isEmpty, let embedder {
                    do {
                        try await me.setReference(photos: photosOfYou, embedder: embedder)
                    } catch {
                        message = (error.localizedDescription, true)
                        try me.match()
                    }
                } else if let embedder, me.hasReference, me.referenceIsStale(dimensions: embedder.dimensions) {
                    // The reference was made with an earlier face model: make it again from the same photos.
                    let photos = me.referencePaths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
                    var renewed = false
                    if !photos.isEmpty { renewed = (try? await me.setReference(photos: photos, embedder: embedder)) != nil }
                    if !renewed {
                        try me.match()
                        message = ("Faces are recognised in a new way now, and the photo of you could not be found again. Choose one under Photos of you.", false)
                    }
                } else {
                    try me.match()
                }
                self?.setScan(title: "Grouping")
                try s.catalog.regroup()
                self?.locked {
                    self?.lastScan = ["analyzed": summary.analyzed, "relinked": summary.relinked, "missing": summary.missing,
                                      "failed": summary.failed, "cancelled": summary.cancelled]
                }
            } catch {
                message = (error.localizedDescription, true)
            }
            guard let self else { return }
            self.locked {
                self.scan = nil
                self.scanTask = nil
                self.folders = nil
                self.dataVersion += 1
            }
            if let message { self.say(message.0, error: message.1) } else { self.changed() }
        }
        locked { scanTask = task }
    }

    private func setScan(title: String) {
        locked { if scan != nil { scan = ["title": title, "done": 0, "total": 0, "failed": 0] } }
        changed()
    }

    // MARK: - Claude

    /// Looks for the Claude CLI and its sign-in state. It starts the command, so never on the main thread.
    public func refreshClaude() {
        locked { claude.checking = true }
        changed()
        let preferred = claudePath()
        Task.detached { [weak self] in
            var found = Claude(detail: "Not installed", checking: false)
            if let cli = ClaudeCLI.locate(preferred: preferred) {
                let s = cli.status()
                found = Claude(path: cli.url.path, version: s.version, loggedIn: s.loggedIn, detail: s.detail, checking: false)
            }
            self?.setClaude(found)
        }
    }

    /// For tests and for picturing the states that this Mac is not in.
    public func setClaude(_ value: Claude) {
        locked { claude = value }
        changed()
    }

    public func startOpinion() throws {
        let start: (Session, String)? = try locked {
            guard let s = session, opinion == nil else { return nil }
            guard let path = claude.path, claude.loggedIn else { throw WorkspaceError.invalid("Claude is not set up on this Mac.") }
            opinion = SecondOpinionRun.Progress()
            opinionLog = []
            return (s, path)
        }
        guard let (s, path) = start else { return }
        changed()
        let run = SecondOpinionRun(cli: ClaudeCLI(url: URL(fileURLWithPath: path)), model: claudeModel(), parallel: claudeParallel())
        let task = Task { [weak self] in
            var last = "Stopped."
            do {
                let p = try await run.run(catalog: s.catalog) { [weak self] event in
                    guard let self else { return }
                    self.locked {
                        guard self.opinion != nil else { return }
                        self.opinion = event.progress
                        self.opinionLog.append(event.log)
                        self.dataVersion += 1
                    }
                    self.changed()
                }
                last = p.total == 0 ? "" : "Done: \(p.groups) groups looked at" + (p.failed > 0 ? ", \(p.failed) batches failed and can be run again" : "")
                    + String(format: ". Reported cost %.3f.", p.usage.costUSD)
            } catch is CancellationError {
                last = "Stopped. What was finished is kept; start again to continue."
            } catch {
                last = "Stopped: \(error.localizedDescription)"
            }
            guard let self else { return }
            _ = try? s.catalog.saveSummary()
            self.locked {
                if !last.isEmpty { self.opinionLog.append(last) }
                self.opinion = nil
                self.opinionTask = nil
                self.folders = nil
                self.dataVersion += 1
            }
            self.changed()
        }
        locked { opinionTask = task }
    }

    // MARK: - The earlier scripts

    /// Brings the review done with the old scripts into the open library. Only reads that folder.
    public func importOldReview(from chosen: URL?) throws {
        let (folder, s): (URL, Session) = try locked {
            guard let s = session else { throw WorkspaceError.invalid("Open a folder first.") }
            if let chosen { return (chosen, s) }
            guard let ui else { throw WorkspaceError.needsApp("Choosing the old output folder") }
            guard let picked = ui.choose("old-review").first else { throw CancellationError() }
            return (picked, s)
        }
        let r = try importLegacyReview(from: folder, into: s.library)
        try s.catalog.regroup()
        var lines = ["\(r.matched) of \(r.oldPhotos) photos from the old review were found in this folder."]
        if r.gone + r.inRemoveFolder + r.notFound > 0 {
            lines.append("\(r.gone) had been removed by the old tool, \(r.inRemoveFolder) are in _to_remove, \(r.notFound) are no longer here.")
        }
        lines.append("Imported \(r.decisions) choices, \(r.reviewed) reviewed marks, \(r.picks) second opinions and \(r.names) names.")
        locked {
            dataVersion += 1
            folders = nil
        }
        say(lines.joined(separator: " "))
        // The photo of you the old tool used, when this library has none yet.
        let me = Me(store: s.library.store)
        if !me.hasReference, let embedder, let path = r.referencePhoto, FileManager.default.fileExists(atPath: path) {
            Task { [weak self] in
                _ = try? await me.setReference(photos: [URL(fileURLWithPath: path)], embedder: embedder)
                try? s.catalog.regroup()
                self?.locked { self?.dataVersion += 1 }
                self?.changed()
            }
        }
    }
}
