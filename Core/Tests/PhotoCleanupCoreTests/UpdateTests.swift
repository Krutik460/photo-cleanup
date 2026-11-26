import XCTest
@testable import PhotoCleanupCore

/// The update check on canned replies (no test goes online), and the two rules that keep the app's
/// caches small.
final class UpdateTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Library.previewsRoot = nil
        try? FileManager.default.removeItem(at: base)
    }

    func reply(tag: String = "v0.4.0", draft: Bool = false, prerelease: Bool = false, page: String = "https://github.com/Krutik460/photo-cleanup/releases/tag/v0.4.0",
               assets: [String] = ["https://github.com/Krutik460/photo-cleanup/releases/download/v0.4.0/Photo-Cleanup-0.4.0.dmg"]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": page,
                                                     "assets": assets.map { ["browser_download_url": $0] }])
    }

    func testVersionsCompareByNumber() {
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.3.1", than: "0.3"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(UpdateCheck.isNewer("0.3.0", than: "0.3"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2.9", than: "0.3.0"))
        XCTAssertFalse(UpdateCheck.isNewer("nonsense", than: "0.1"))
        XCTAssertEqual(UpdateCheck.numbers("v1.2.3-beta.4"), [1, 2, 3])
    }

    func testAReleaseIsReadFromGitHubsReply() {
        let r = UpdateCheck.release(from: reply())
        XCTAssertEqual(r, AppUpdate(version: "0.4.0", page: "https://github.com/Krutik460/photo-cleanup/releases/tag/v0.4.0",
                                    download: "https://github.com/Krutik460/photo-cleanup/releases/download/v0.4.0/Photo-Cleanup-0.4.0.dmg"))
        XCTAssertNil(UpdateCheck.release(from: reply(draft: true)))
        XCTAssertNil(UpdateCheck.release(from: reply(prerelease: true)))
        XCTAssertNil(UpdateCheck.release(from: Data("{\"message\":\"rate limit\"}".utf8)))
        XCTAssertNil(UpdateCheck.release(from: Data("not json".utf8)))
        // No disk image attached: the release page is where the button goes.
        XCTAssertNil(UpdateCheck.release(from: reply(assets: ["https://github.com/x/y/notes.txt"]))?.download)
        // A link that leaves GitHub, or is not https, is never opened.
        XCTAssertNil(UpdateCheck.release(from: reply(page: "https://example.com/release")))
        XCTAssertNil(UpdateCheck.release(from: reply(assets: ["http://github.com/a/b.dmg", "https://evil.example/Photo-Cleanup.dmg"]))?.download)
    }

    func testTheCheckIsDueOnceADay() {
        let day = UpdateCheck.interval
        XCTAssertTrue(UpdateCheck.isDue(nil, now: 1000))
        XCTAssertFalse(UpdateCheck.isDue(UpdateMemory(checkedAt: 1000, latest: nil), now: 1000 + day - 1))
        XCTAssertTrue(UpdateCheck.isDue(UpdateMemory(checkedAt: 1000, latest: nil), now: 1000 + day))
        XCTAssertTrue(UpdateCheck.isDue(UpdateMemory(checkedAt: 5000, latest: nil), now: 1000), "a clock that went back does not stop the check")
    }

    /// A workspace whose "GitHub" is `reply`, counting how often it is asked.
    func workspace(version: String?, enabled: Bool = true, reply: Data?) -> (Workspace, () -> Int, () -> UpdateMemory?) {
        final class Box: @unchecked Sendable { var asked = 0; var memory: UpdateMemory? }
        let box = Box()
        let w = Workspace(librariesDir: base.appendingPathComponent("libs"), uiDir: base)
        w.appVersion = version
        w.updatesEnabled = { enabled }
        w.loadUpdateMemory = { box.memory }
        w.saveUpdateMemory = { box.memory = $0 }
        w.fetchRelease = { _ in
            box.asked += 1
            guard let reply else { throw URLError(.notConnectedToInternet) }
            return reply
        }
        return (w, { box.asked }, { box.memory })
    }

    func update(_ w: Workspace) -> [String: Any] { w.state()["update"] as? [String: Any] ?? [:] }

    func testANewerReleaseShowsUpAndIsRemembered() async {
        let (w, asked, memory) = workspace(version: "0.3.0", reply: reply())
        XCTAssertTrue(update(w)["available"] is NSNull)
        w.checkForUpdate(now: Date(timeIntervalSince1970: 1000))
        await w.updateCheckFinished()
        XCTAssertEqual(asked(), 1)
        XCTAssertEqual((update(w)["available"] as? [String: Any])?["version"] as? String, "0.4.0")
        XCTAssertEqual((update(w)["available"] as? [String: Any])?["download"] as? Bool, true)
        XCTAssertEqual(update(w)["current"] as? String, "0.3.0")
        XCTAssertEqual(memory()?.checkedAt, 1000)

        // Within the day it is not asked again, unless you ask in Settings.
        w.checkForUpdate(now: Date(timeIntervalSince1970: 2000))
        await w.updateCheckFinished()
        XCTAssertEqual(asked(), 1)
        w.checkForUpdate(force: true, now: Date(timeIntervalSince1970: 3000))
        await w.updateCheckFinished()
        XCTAssertEqual(asked(), 2)
    }

    func testNothingIsOfferedWhenTheAppIsCurrentOrTheCheckIsOff() async {
        let (same, _, _) = workspace(version: "0.4.0", reply: reply())
        same.checkForUpdate()
        await same.updateCheckFinished()
        XCTAssertTrue(update(same)["available"] is NSNull)
        XCTAssertEqual(update(same)["failed"] as? Bool, false)

        let (off, asked, _) = workspace(version: "0.3.0", enabled: false, reply: reply())
        off.checkForUpdate()
        await off.updateCheckFinished()
        XCTAssertEqual(asked(), 0, "switched off: GitHub is not asked")

        // The command line tool has no version to compare, and no update check.
        let (tool, toolAsked, _) = workspace(version: nil, reply: reply())
        tool.checkForUpdate(force: true)
        await tool.updateCheckFinished()
        XCTAssertEqual(toolAsked(), 0)
        XCTAssertNil(tool.state()["update"])
    }

    func testAFailedCheckKeepsWhatWasKnownAndAsksAgainNextTime() async {
        let (w, asked, memory) = workspace(version: "0.3.0", reply: nil)
        w.saveUpdateMemory(UpdateMemory(checkedAt: 0, latest: AppUpdate(version: "0.3.5", page: "https://github.com/a/b")))
        w.checkForUpdate(now: Date(timeIntervalSince1970: 10 * UpdateCheck.interval))
        await w.updateCheckFinished()
        XCTAssertEqual(asked(), 1)
        XCTAssertEqual(update(w)["failed"] as? Bool, true)
        XCTAssertEqual(memory()?.checkedAt, 0, "not counted as checked")
        XCTAssertEqual((update(w)["available"] as? [String: Any])?["version"] as? String, "0.3.5")
        XCTAssertEqual((update(w)["available"] as? [String: Any])?["download"] as? Bool, false)
    }

    // MARK: - Caches

    func testTheCompiledModelCacheIsEmptiedOnlyWhenItHoldsMoreThanOneCopy() throws {
        let model = base.appendingPathComponent("SFace.mlmodelc"), caches = base.appendingPathComponent("caches")
        let cache = caches.appendingPathComponent("com.apple.e5rt.e5bundlecache/26B123")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: model.appendingPathComponent("weights.bin"))
        func copy(_ name: String) throws {
            try FileManager.default.createDirectory(at: cache.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(count: 1000).write(to: cache.appendingPathComponent(name).appendingPathComponent("model.bundle"))
        }
        try copy("A")
        XCTAssertEqual(trimCompiledModelCache(in: caches, model: model), 0, "one copy is the one in use")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("A").path))
        try copy("B")
        try copy("C")
        XCTAssertEqual(trimCompiledModelCache(in: caches, model: model), 3000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appendingPathComponent("com.apple.e5rt.e5bundlecache").path))
        XCTAssertEqual(trimCompiledModelCache(in: caches, model: model), 0, "nothing there is fine")
    }

    func testPreviewsGoToTheCachesFolderWhenTheAppSaysSo() throws {
        let photos = base.appendingPathComponent("photos"), dir = base.appendingPathComponent("libs/one")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var library: Library? = try Library.create(at: dir, photoFolder: photos)
        XCTAssertEqual(library?.previewsDir.path, dir.appendingPathComponent("previews").path)
        try Data("old preview".utf8).write(to: dir.appendingPathComponent("previews/1.jpg"))
        library = nil

        Library.previewsRoot = base.appendingPathComponent("caches/Previews")
        library = try Library.open(at: dir)
        XCTAssertEqual(library?.previewsDir.path, base.appendingPathComponent("caches/Previews/one").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("caches/Previews/one").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("previews").path), "the previews kept with the library are gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("thumbs").path), "thumbnails stay with the library")
    }
}
