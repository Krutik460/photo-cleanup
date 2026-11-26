import Foundation
import PhotoCleanupCore

// Drives the core without the app.
let usage = """
usage: photocleanup-cli analyze <photo-folder> <library-dir> [--model <SFace.mlmodelc>] [--me <photo of you> ...]
       photocleanup-cli second-opinion <library-dir> [--limit <batches>] [--model haiku] [--claude <path>]
       photocleanup-cli import-review <library-dir> <old output folder> [--replace]   review done with the old scripts
       photocleanup-cli summary | clean-up | undo-clean-up <library-dir>              the library at a glance; the clean-up step
       photocleanup-cli page-data <library-dir>                                       what the review page is given, as JSON
       photocleanup-cli serve <libraries-dir> <ui-folder> [port] [--model <SFace.mlmodelc>]
                                the app's interface on localhost, for development

  --model  compiled face model (scripts/convert_face_model.py). Without it faces are detected but
           not recognised; pass it from the first scan on.
  --me     reference photo of you (repeatable). Remembered in the library.
"""

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
func path(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL }
/// Removes every `name value` pair from the arguments and returns the values.
func option(_ name: String) -> [String] {
    var values: [String] = []
    while let i = args.firstIndex(of: name) {
        guard i + 1 < args.count else { fail(usage) }
        values.append(args[i + 1])
        args.removeSubrange(i...(i + 1))
    }
    return values
}

guard let command = args.first else { fail(usage) }
switch command {
case "analyze":
    let model = option("--model").last, me = option("--me")
    guard args.count == 3 else { fail(usage) }
    let dir = path(args[2])
    do {
        let library = FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.sqlite").path)
            ? try Library.open(at: dir) : try Library.create(at: dir, photoFolder: path(args[1]))
        let embedder = try model.map { try CoreMLFaceEmbedder(compiledModelAt: path($0)) }
        let start = Date()
        let summary = try await Analyzer(library: library, embedder: embedder).run { p in
            if p.phase == .analyzing, p.total > 0, p.done % 50 == 0 || p.done == p.total {
                print("\(p.done)/\(p.total)  (\(p.failed) could not be read)")
            }
        }
        print(String(format: "found %d photos and videos: analyzed %d, found again at a new path %d, missing %d, unreadable %d, in %.1f s",
                     summary.found, summary.analyzed, summary.relinked, summary.missing, summary.failed.count, Date().timeIntervalSince(start)))
        for f in summary.failed { print("  unreadable: \(f)") }

        let who = Me(store: library.store)
        if !me.isEmpty {
            guard let embedder else { fail("--me needs --model") }
            let n = try await who.setReference(photos: me.map(path), embedder: embedder)
            print("reference: \(n) of \(me.count) photo(s) with a usable face")
        } else {
            try who.match()
        }
        if who.hasReference {
            let counts = try library.store.db.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo WHERE me_sim >= ?", arguments: [youThreshold]) ?? 0,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo WHERE me_sim IS NOT NULL") ?? 0)
            }
            print("you appear in \(counts.0) of \(counts.1) photos with a recognisable face (threshold \(youThreshold))")
        }
    } catch {
        fail(error.localizedDescription)
    }
case "second-opinion":
    let model = option("--model").last ?? "haiku", limit = option("--limit").last.flatMap(Int.init), preferred = option("--claude").last
    guard args.count == 2 else { fail(usage) }
    do {
        let catalog = try Catalog(library: try Library.open(at: path(args[1])))
        guard let cli = ClaudeCLI.locate(preferred: preferred) else { fail(ClaudeError.notFound.localizedDescription) }
        let status = cli.status()
        print("claude: \(cli.url.path) \(status.version ?? "?") - \(status.detail)")
        guard status.loggedIn else { fail("not signed in") }
        let p = try await SecondOpinionRun(cli: cli, model: model).run(catalog: catalog, limit: limit) { print($0.log) }
        print(String(format: "%d of %d batches done, %d failed; %d groups reviewed; %d input and %d output tokens, reported cost %.4f",
                     p.done - p.failed, p.total, p.failed, p.groups, p.usage.inputTokens, p.usage.outputTokens, p.usage.costUSD))
    } catch {
        fail(error.localizedDescription)
    }
case "page-data":
    guard args.count == 2 else { fail(usage) }
    do {
        FileHandle.standardOutput.write(try Catalog(library: try Library.open(at: path(args[1]))).pageData())
    } catch {
        fail(error.localizedDescription)
    }
case "summary", "clean-up", "undo-clean-up":
    guard args.count == 2 else { fail(usage) }
    do {
        let catalog = try Catalog(library: try Library.open(at: path(args[1])))
        if command == "clean-up" {
            let r = try catalog.cleanUp()
            print("moved \(r.moved) photos to \(r.folder)" + (r.errors.isEmpty ? "" : "; \(r.errors.count) errors: \(r.errors.prefix(3))"))
        } else if command == "undo-clean-up" {
            let r = try catalog.undo(.cleanup)
            print("put \(r.restored) photos back" + (r.errors.isEmpty ? "" : "; \(r.errors.count) errors: \(r.errors.prefix(3))"))
        }
        let s = try catalog.saveSummary()
        print("\(s.photos) photos, \(s.collections) collections, \(s.reviewedGroups) of \(s.groups) groups reviewed, you in \(s.you); "
            + "to remove \(s.toRemove) (\(s.toRemoveBytes) bytes); removed \(s.removed) (\(s.removedBytes) bytes, \(s.waitingBytes) still in _to_remove)")
    } catch {
        fail(error.localizedDescription)
    }
case "import-review":
    let replace = args.contains("--replace")
    args.removeAll { $0 == "--replace" }
    guard args.count == 3 else { fail(usage) }
    do {
        let library = try Library.open(at: path(args[1]))
        let r = try importLegacyReview(from: path(args[2]), into: library, replace: replace)
        print("old photos \(r.oldPhotos): found here \(r.matched), written off by the old tool \(r.gone), in _to_remove \(r.inRemoveFolder), not found \(r.notFound)")
        print("filed by the old tool and recognised: \(r.filed)")
        print("imported: \(r.decisions) choices, \(r.reviewed) reviewed marks, \(r.picks) second-opinion picks, \(r.names) names, "
            + "\(r.folders) folder switches, \(r.merges) merges, \(r.moves) moves, \(r.notCollections) not-a-trip marks")
        let c = try Catalog(library: library)
        let states = try c.effectiveStates()
        print("now: \(c.photoCount) photos, \(c.result.collections.count) collections, \(c.result.groups.count) groups, "
            + "\(states.values.filter { $0 == .remove }.count) to remove")
    } catch {
        fail(error.localizedDescription)
    }
case "serve":
    let model = option("--model").last
    guard args.count == 3 || args.count == 4 else { fail(usage) }
    do {
        // Everything the app shows, without the app: no file pickers, Finder or Settings window.
        let embedder = try model.map { try CoreMLFaceEmbedder(compiledModelAt: path($0)) }
        let workspace = Workspace(librariesDir: path(args[1]), uiDir: path(args[2]), embedder: embedder)
        workspace.refreshClaude()
        let port = args.count == 4 ? UInt16(args[3]) ?? 8770 : 8770
        let server = try LocalServer(router: AppRouter(workspace: workspace), port: port)
        server.start()
        print("Photo Cleanup: http://localhost:\(port)  (libraries in \(args[1]), development only)")
        dispatchMain()
    } catch {
        fail(error.localizedDescription)
    }
default:
    fail(usage)
}
