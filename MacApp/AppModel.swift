import Foundation
import PhotoCleanupCore
import SwiftUI

/// A library on disk, as listed on the start screen.
struct LibraryInfo: Identifiable, Equatable {
    let id: String  // the library folder's name
    let dir: URL
    let name: String
    let root: String
    let photos: Int
    let available: Bool
    var summary: LibrarySummary? = nil
    var lastOpened: Date? = nil
    var thumbsDir: URL? = nil
}

/// The open library: its database, the page's data and the page's server.
final class Session {
    let info: LibraryInfo
    let library: Library
    let catalog: Catalog
    let router: Router

    init(info: LibraryInfo, library: Library, appDir: URL) throws {
        self.info = info
        self.library = library
        catalog = try Catalog(library: library)
        router = Router(catalog: catalog, appDir: appDir)
    }
}

/// What the scan is doing right now, in the user's words.
struct PipelineState: Equatable {
    var title: String
    var done = 0
    var total = 0
    var failed = 0

    var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
}

/// What is known about the Claude CLI on this Mac.
struct ClaudeState: Equatable {
    var path: String?
    var version: String?
    var loggedIn = false
    var detail = "Looking for the Claude CLI…"
    var checking = true

    var ready: Bool { path != nil && loggedIn }
}

enum Preferences {
    static let claudePath = "claudePath"
    static let claudeModel = "claudeModel"
    static let claudeParallel = "claudeParallel"

    static var model: String { UserDefaults.standard.string(forKey: claudeModel) ?? "haiku" }
    static var parallel: Int { max(1, min(6, UserDefaults.standard.object(forKey: claudeParallel) as? Int ?? 3)) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var libraries: [LibraryInfo] = []
    @Published var claude = ClaudeState()
    /// Progress of the second opinion while it runs.
    @Published var opinion: SecondOpinionRun.Progress?
    @Published var opinionLog: [String] = []
    /// Groups of similar shots Claude has not looked at yet.
    @Published var pendingGroups = 0
    @Published var showOpinionPanel = false
    /// The opening screen is up until its checks pass or the user carries on.
    @Published var showLaunch = true
    private var opinionTask: Task<Void, Never>?

    func finishLaunch() {
        withAnimation(Theme.spring) { showLaunch = false }
    }

    /// Something worth telling the user that is not an error.
    @Published var notice: String?

    /// Brings the review done with the old scripts (their output folder) into the open library.
    /// Only reads that folder; refuses when this library already has choices of its own.
    func importOldReview(from folder: URL) {
        guard let session, !isBusy else { return }
        do {
            let r = try importLegacyReview(from: folder, into: session.library)
            try session.catalog.regroup()
            refreshPending()
            pageVersion += 1
            var lines = ["\(r.matched.formatted()) of \(r.oldPhotos.formatted()) photos from the old review were found in this folder."]
            if r.gone + r.inRemoveFolder + r.notFound > 0 {
                lines.append("\(r.gone.formatted()) had been removed by the old tool, \(r.inRemoveFolder.formatted()) are in _to_remove, and \(r.notFound.formatted()) are no longer in this folder.")
            }
            lines.append("Imported \(r.decisions.formatted()) choices, \(r.reviewed.formatted()) reviewed marks, \(r.picks.formatted()) second opinions, \(r.names.formatted()) names and \((r.merges + r.moves + r.notCollections).formatted()) collection edits.")
            notice = lines.joined(separator: "\n\n")
            // The photo of you the old tool used, when this library has none yet.
            let me = Me(store: session.library.store)
            if !me.hasReference, let embedder, let path = r.referencePhoto, FileManager.default.fileExists(atPath: path) {
                Task {
                    _ = try? await me.setReference(photos: [URL(fileURLWithPath: path)], embedder: embedder)
                    try? session.catalog.regroup()
                    pageVersion += 1
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    @Published var session: Session?
    @Published var pipeline: PipelineState?
    @Published var lastScan: ScanSummary?
    @Published var pageVersion = 0
    @Published var errorMessage: String?
    @Published var showAddFolder = false

    private var scanTask: Task<Void, Never>?

    /// `~/Library/Application Support/Photo Cleanup/Libraries`, one folder per library.
    let librariesDir: URL
    /// The review page's files inside the app.
    let appDir: URL
    /// Face recognition model inside the app; nil when the app was built without it.
    let embedder: FaceEmbedder?

    var isBusy: Bool { pipeline != nil }
    var recognisesFaces: Bool { embedder != nil }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        librariesDir = ProcessInfo.processInfo.environment["PHOTOCLEANUP_LIBRARIES"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("Photo Cleanup/Libraries")
        appDir = Bundle.main.resourceURL!.appendingPathComponent("app")
        embedder = Bundle.main.url(forResource: "ArcFace", withExtension: "mlmodelc").flatMap { try? CoreMLFaceEmbedder(compiledModelAt: $0) }
        try? FileManager.default.createDirectory(at: librariesDir, withIntermediateDirectories: true)
        refreshLibraries()
        refreshClaude()
    }

    // MARK: - Second opinion

    /// Looks for the Claude CLI and its sign-in state, off the main thread (it starts the command).
    func refreshClaude() {
        claude.checking = true
        let preferred = UserDefaults.standard.string(forKey: Preferences.claudePath)
        Task {
            let state = await Task.detached { () -> ClaudeState in
                guard let cli = ClaudeCLI.locate(preferred: preferred) else {
                    return ClaudeState(detail: "Not found. Install Claude Code, or choose the command below.", checking: false)
                }
                let s = cli.status()
                return ClaudeState(path: cli.url.path, version: s.version, loggedIn: s.loggedIn, detail: s.detail, checking: false)
            }.value
            claude = state
        }
    }

    func refreshPending() {
        pendingGroups = (try? session?.catalog.groupsNeedingSecondOpinion().count) ?? 0
    }

    func startSecondOpinion() {
        guard let session, opinion == nil, let path = claude.path else { return }
        opinion = SecondOpinionRun.Progress()
        opinionLog = []
        let run = SecondOpinionRun(cli: ClaudeCLI(url: URL(fileURLWithPath: path)), model: Preferences.model, parallel: Preferences.parallel)
        opinionTask = Task {
            do {
                let p = try await run.run(catalog: session.catalog) { event in
                    Task { @MainActor [weak self] in
                        guard let self, self.opinion != nil else { return }  // a late event after the run ended
                        self.opinion = event.progress
                        self.opinionLog.append(event.log)
                    }
                }
                await Task.yield()
                if p.total > 0 {
                    opinionLog.append("Done: \(p.groups) groups looked at" + (p.failed > 0 ? ", \(p.failed) batches failed and can be run again" : "")
                        + String(format: ". Reported cost %.3f.", p.usage.costUSD))
                }
            } catch is CancellationError {
                opinionLog.append("Stopped. What was finished is kept; start again to continue.")
            } catch {
                opinionLog.append("Stopped: \(error.localizedDescription)")
            }
            opinion = nil
            opinionTask = nil
            refreshPending()
            pageVersion += 1
        }
    }

    func cancelSecondOpinion() { opinionTask?.cancel() }

    // MARK: - Libraries

    func refreshLibraries() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: librariesDir, includingPropertiesForKeys: nil)) ?? []
        libraries = dirs.compactMap { dir -> LibraryInfo? in
            guard let library = try? Library.open(at: dir) else { return nil }
            return LibraryInfo(id: dir.lastPathComponent, dir: dir, name: library.name, root: library.root.path,
                               photos: library.photoCount, available: library.isPhotoFolderAvailable,
                               summary: library.summary, lastOpened: library.lastOpened, thumbsDir: library.thumbsDir)
        }.sorted {
            // Most recently opened first; libraries never opened go last, by name.
            switch ($0.lastOpened, $1.lastOpened) {
            case let (a?, b?): a > b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Forgets a photo folder: its library (database, thumbnails) goes to the Trash. The photos are
    /// not touched.
    func removeLibrary(_ info: LibraryInfo) {
        guard session?.info.id != info.id,
              info.dir.deletingLastPathComponent().standardizedFileURL.path == librariesDir.standardizedFileURL.path else { return }
        do {
            try FileManager.default.trashItem(at: info.dir, resultingItemURL: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshLibraries()
    }

    /// Space clean-ups have taken out of your photos, over every library.
    var totalSavedBytes: Int { libraries.reduce(0) { $0 + ($1.summary?.savedBytes ?? 0) } }
    var totalWaitingBytes: Int { libraries.reduce(0) { $0 + ($1.summary?.waitingBytes ?? 0) } }

    func open(_ info: LibraryInfo) {
        do {
            session = try Session(info: info, library: try Library.open(at: info.dir), appDir: appDir)
            session?.library.markOpened()
            lastScan = nil
            opinionLog = []
            refreshPending()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeLibrary() {
        scanTask?.cancel()
        opinionTask?.cancel()
        // Choices and reviewed marks made since the last regroup change the home screen's numbers.
        _ = try? session?.catalog.saveSummary()
        session?.library.markOpened()
        session = nil
        pendingGroups = 0
        refreshLibraries()
    }

    /// Creates a library for a photo folder (or opens the one that already exists for it) and scans it.
    func addLibrary(photoFolder: URL, photosOfYou: [URL]) {
        let root = photoFolder.resolvingSymlinksInPath().standardizedFileURL.path
        if let existing = libraries.first(where: { $0.root == root }) {
            open(existing)
        } else {
            do {
                let dir = librariesDir.appendingPathComponent(UUID().uuidString)
                let library = try Library.create(at: dir, photoFolder: photoFolder)
                let info = LibraryInfo(id: dir.lastPathComponent, dir: dir, name: library.name, root: library.root.path, photos: 0, available: true)
                session = try Session(info: info, library: library, appDir: appDir)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        scan(photosOfYou: photosOfYou)
    }

    /// Analyzes new and changed photos, finds you, and regroups. Incremental and safe to cancel.
    func scan(photosOfYou: [URL] = []) {
        guard let session, pipeline == nil else { return }
        pipeline = PipelineState(title: "Looking for photos")
        let embedder = self.embedder
        scanTask = Task {
            do {
                let summary = try await Analyzer(library: session.library, embedder: embedder).run { progress in
                    Task { @MainActor [weak self] in
                        switch progress.phase {
                        case .listing: self?.pipeline = PipelineState(title: "Looking for photos")
                        case .analyzing: self?.pipeline = PipelineState(title: "Analyzing photos", done: progress.done, total: progress.total, failed: progress.failed)
                        case .neighbors: self?.pipeline = PipelineState(title: "Comparing photos")
                        case .done: break
                        }
                    }
                }
                pipeline = PipelineState(title: "Finding you")
                let me = Me(store: session.library.store)
                if !photosOfYou.isEmpty, let embedder {
                    try await me.setReference(photos: photosOfYou, embedder: embedder)
                } else {
                    try await Task.detached { try me.match() }.value
                }
                pipeline = PipelineState(title: "Grouping")
                try await Task.detached { try session.catalog.regroup() }.value
                lastScan = summary
                refreshPending()
                pageVersion += 1
            } catch {
                errorMessage = error.localizedDescription
            }
            pipeline = nil
            scanTask = nil
        }
    }

    func cancelScan() { scanTask?.cancel() }
}
