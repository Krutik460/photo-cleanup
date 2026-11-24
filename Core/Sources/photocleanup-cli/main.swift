import Foundation
import PhotoCleanupCore

// Drives the core without the app. Usage:
//   photocleanup-cli analyze <photo-folder> <library-dir>
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
func path(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL }

guard args.count >= 2 else { fail("usage: photocleanup-cli analyze <photo-folder> <library-dir>") }
switch args[1] {
case "analyze":
    guard args.count == 4 else { fail("usage: photocleanup-cli analyze <photo-folder> <library-dir>") }
    let dir = path(args[3])
    do {
        let library = FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.sqlite").path)
            ? try Library.open(at: dir) : try Library.create(at: dir, photoFolder: path(args[2]))
        let start = Date()
        let summary = try await Analyzer(library: library).run { p in
            if p.phase == .analyzing, p.total > 0, p.done % 50 == 0 || p.done == p.total {
                print("\(p.done)/\(p.total)  (\(p.failed) could not be read)")
            }
        }
        print(String(format: "found %d images: analyzed %d, found again at a new path %d, missing %d, unreadable %d, in %.1f s",
                     summary.found, summary.analyzed, summary.relinked, summary.missing, summary.failed.count, Date().timeIntervalSince(start)))
        for f in summary.failed { print("  unreadable: \(f)") }
    } catch {
        fail(error.localizedDescription)
    }
default:
    fail("unknown command \(args[1])")
}
