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

@MainActor
final class AppModel: ObservableObject {
    @Published var libraries: [LibraryInfo] = []
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
    }

    func refreshLibraries() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: librariesDir, includingPropertiesForKeys: nil)) ?? []
        libraries = dirs.compactMap { dir -> LibraryInfo? in
            guard let library = try? Library.open(at: dir) else { return nil }
            return LibraryInfo(id: dir.lastPathComponent, dir: dir, name: library.name, root: library.root.path,
                               photos: library.photoCount, available: library.isPhotoFolderAvailable)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func open(_ info: LibraryInfo) {
        do {
            session = try Session(info: info, library: try Library.open(at: info.dir), appDir: appDir)
            lastScan = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeLibrary() {
        scanTask?.cancel()
        session = nil
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
