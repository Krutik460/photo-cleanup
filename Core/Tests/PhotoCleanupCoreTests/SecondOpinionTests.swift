import GRDB
import XCTest
@testable import PhotoCleanupCore

final class SecondOpinionTests: XCTestCase {
    var base: URL!
    var library: Library!
    var catalog: Catalog!
    var ids: [String: String] = [:]

    /// A stand-in for the `claude` command: reads the message, and answers "photo 1 is the favorite,
    /// remove the rest" for every group in it. `mode.txt` next to it selects a failure instead.
    let fakeClaude = """
    #!/usr/bin/python3
    import json, os, re, sys, time
    here = os.path.dirname(os.path.abspath(__file__))
    mode = open(os.path.join(here, "mode.txt")).read().strip() if os.path.exists(os.path.join(here, "mode.txt")) else "ok"
    if sys.argv[1:] == ["--version"]:
        print("9.9.9 (Fake)"); sys.exit(0)
    if sys.argv[1:] == ["auth", "status"]:
        print(json.dumps({"loggedIn": mode != "signedout", "authMethod": "claude.ai"})); sys.exit(0)
    message = json.loads(sys.stdin.readline())
    open(os.path.join(here, "calls.log"), "a").write(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd(), "env": sorted(os.environ)}) + "\\n")
    texts = [c["text"] for c in message["message"]["content"] if c["type"] == "text"]
    groups = [re.match(r"Group (\\S+): photos 1-(\\d+)", t) for t in texts]
    answers = [{"group": m.group(1), "fav": [1], "keep": [], "remove": list(range(2, int(m.group(2)) + 1)), "why": "Sharpest of the group."} for m in groups if m]
    print(json.dumps({"type": "system", "subtype": "init"}))
    if mode == "slow": time.sleep(30)
    if mode == "exit": sys.stderr.write("boom\\n"); sys.exit(3)
    if mode == "error": print(json.dumps({"type": "result", "is_error": True, "result": "Credit balance is too low"})); sys.exit(1)
    if mode == "nostruct": print(json.dumps({"type": "result", "is_error": False, "result": "I cannot do that"})); sys.exit(0)
    print(json.dumps({"type": "result", "is_error": False, "structured_output": {"groups": answers}, "total_cost_usd": 0.002,
                      "usage": {"input_tokens": 2, "cache_creation_input_tokens": 5000, "cache_read_input_tokens": 100, "output_tokens": 700}}))
    """

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pc-" + UUID().uuidString)
        let photos = base.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        library = try Library.create(at: base.appendingPathComponent("library"), photoFolder: photos)
        // Two groups to judge (a: three shots with you in two, b: two shots) and one exact duplicate pair.
        try library.store.db.write { db in
            func add(_ name: String, _ time: Double, me: Double? = nil) throws {
                try db.execute(sql: """
                    INSERT INTO photo (rel_path, original_rel_path, size, mtime, taken, width, height, aesthetic, sharpness, analysis_version, me_sim, me_face)
                    VALUES (?, ?, 2000000, 0, ?, 4000, 3000, 0.2, 400, ?, ?, ?)
                    """, arguments: ["\(name).jpg", "\(name).jpg", time, analysisVersion, me, me == nil ? nil : 0])
                ids[name] = String(db.lastInsertedRowID)
                if me != nil { try db.execute(sql: "INSERT INTO face (photo_id, idx, quality, x, y, w, h) VALUES (?, 0, 0.8, 0, 0, 1, 1)", arguments: [db.lastInsertedRowID]) }
            }
            func near(_ a: String, _ b: String, _ d: Double) throws {
                let x = Int64(ids[a]!)!, y = Int64(ids[b]!)!
                try db.execute(sql: "INSERT INTO neighbor (a, b, distance) VALUES (?, ?, ?)", arguments: [min(x, y), max(x, y), d])
            }
            try add("a1", 1_800_000_000, me: 0.7); try add("a2", 1_800_000_001, me: 0.6); try add("a3", 1_800_000_002, me: 0.7)
            try add("b1", 1_800_100_000); try add("b2", 1_800_100_001)
            try add("c1", 1_800_200_000); try add("c2", 1_800_200_000)
            try near("a1", "a2", 0.2); try near("a1", "a3", 0.2); try near("a2", "a3", 0.2)
            try near("b1", "b2", 0.2)
            try near("c1", "c2", 0.01)
            try db.execute(sql: "INSERT INTO reference_face (source_path, embedding) VALUES ('me.jpg', x'00')")
        }
        for (i, id) in ids.values.sorted().enumerated() {
            try writeJPEG(makePicture(seed: i, size: 240), to: library.thumbURL(Int64(id)!))
        }
        catalog = try Catalog(library: library, timeZone: TimeZone(identifier: "UTC")!)
    }

    override func tearDownWithError() throws {
        catalog = nil
        library = nil
        try? FileManager.default.removeItem(at: base)
    }

    func makeFakeCLI(mode: String = "ok") throws -> ClaudeCLI {
        let dir = base.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude")
        try fakeClaude.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try mode.write(to: dir.appendingPathComponent("mode.txt"), atomically: true, encoding: .utf8)
        return ClaudeCLI(url: url)
    }

    func group(_ members: Int, you: [Int] = [], id: String = "g1") -> ReviewGroup {
        ReviewGroup(id: id, members: (1...members).map { "p\($0)" }, you: you)
    }

    func answer(_ fav: [Int], _ keep: [Int], _ remove: [Int], notes: [ReviewAnswer.Note]? = nil, id: String = "g1") -> ReviewAnswer {
        ReviewAnswer(group: id, fav: fav, keep: keep, remove: remove, why: "Everyone's eyes open.", notes: notes)
    }

    // MARK: - Turning answers into picks

    func testAnswerBecomesPicks() {
        let (picks, problems) = SecondOpinion.picks(for: [group(4)], answers: [answer([2], [3], [1, 4], notes: [.init(photo: 3, note: "Different pose.")])])
        XCTAssertEqual(problems, [])
        XCTAssertEqual(picks["p2"], ReviewPick(state: .fav, why: "Everyone's eyes open."))
        XCTAssertEqual(picks["p3"], ReviewPick(state: .keep, why: "Different pose."))
        XCTAssertEqual(picks["p1"], ReviewPick(state: .remove, why: ""))
        XCTAssertEqual(picks["p4"]?.state, .remove)
    }

    func testAPhotoTheAnswerForgotIsKeptNeverRemoved() {
        let (picks, _) = SecondOpinion.picks(for: [group(4)], answers: [answer([1], [], [2])])
        XCTAssertEqual(picks["p3"]?.state, .keep)
        XCTAssertEqual(picks["p4"]?.state, .keep)
    }

    func testAGroupWithoutAnAnswerOrAFavoriteIsLeftAlone() {
        let batch = [group(2, id: "g1"), group(2, id: "g2"), group(2, id: "g3")]
        let (picks, problems) = SecondOpinion.picks(for: batch, answers: [answer([], [1], [2], id: "g1"), answer([7], [], [1, 2], id: "g2")])
        XCTAssertTrue(picks.isEmpty)
        XCTAssertEqual(problems, ["g1: no favorite", "g2: no favorite", "g3: no answer"])
    }

    func testANumberInTwoListsTakesTheSaferOne() {
        // 1 is both fav and remove, 2 both keep and remove; 9 does not exist.
        let (picks, _) = SecondOpinion.picks(for: [group(3)], answers: [answer([1], [2], [1, 2, 3, 9])])
        XCTAssertEqual([picks["p1"]?.state, picks["p2"]?.state, picks["p3"]?.state], [.fav, .keep, .remove])
        XCTAssertEqual(picks.count, 3)
    }

    func testAGroupWithYouAlwaysKeepsAPhotoOfYou() {
        let (picks, problems) = SecondOpinion.picks(for: [group(4, you: [2, 3])], answers: [answer([1], [], [2, 3, 4])])
        XCTAssertEqual(picks["p2"]?.state, .fav)  // the on-device best shot of you
        XCTAssertEqual(picks["p3"]?.state, .remove)
        XCTAssertEqual(picks["p1"]?.state, .fav)
        XCTAssertEqual(problems, ["g1: the answer kept no photo of you; kept #2"])
        // Keeping one of you as "keep" is enough.
        XCTAssertEqual(SecondOpinion.picks(for: [group(4, you: [2, 3])], answers: [answer([1], [3], [2, 4])]).problems, [])
    }

    func testLongReasonsAreCut() {
        var a = answer([1], [], [2])
        a.why = String(repeating: "x", count: 500)
        XCTAssertEqual(SecondOpinion.picks(for: [group(2)], answers: [a]).picks["p1"]?.why.count, 200)
    }

    // MARK: - Batches and the message

    func testBatchesHoldAtMostTwentySheetsAndNeverSplitAGroup() {
        let groups = (1...30).map { group($0 % 5 == 0 ? 40 : 6, id: "g\($0)") }  // 40 photos = 3 sheets
        let batches = SecondOpinion.batches(groups)
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), groups.map(\.id))
        for b in batches { XCTAssertLessThanOrEqual(b.reduce(0) { $0 + $1.sheets }, 20) }
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(SecondOpinion.batches([group(400)]).count, 1)  // one huge group still goes out, alone
        XCTAssertTrue(SecondOpinion.batches([]).isEmpty)
    }

    func testMessageCarriesSheetsAndNothingThatIdentifiesFiles() throws {
        let groups = try catalog.groupsNeedingSecondOpinion()
        XCTAssertEqual(groups.map(\.members.count), [3, 2])  // the duplicate pair is not sent
        XCTAssertEqual(groups[0].you.count, 3)
        XCTAssertEqual(groups[1].you, [])

        let data = SecondOpinion.message(for: groups) { self.library.thumbURL(Int64($0)!) }
        XCTAssertEqual(data.last, UInt8(ascii: "\n"))
        let line = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let content = (line["message"] as! [String: Any])["content"] as! [[String: Any]]
        XCTAssertEqual(content.map { $0["type"] as! String }, ["text", "image", "text", "image", "text"])
        XCTAssertEqual(content[0]["text"] as? String, "Group \(groups[0].id): photos 1-3; YOU: 1, 2, 3; suggested fav: 1")
        XCTAssertEqual(content[2]["text"] as? String, "Group \(groups[1].id): photos 1-2; YOU: none; suggested fav: 1")
        let text = String(decoding: data, as: UTF8.self)
        for secret in [library.root.path, "a1.jpg", ".jpg", "thumbs"] { XCTAssertFalse(text.contains(secret), secret) }

        let jpeg = Data(base64Encoded: (content[1]["source"] as! [String: Any])["data"] as! String)!
        let sheet = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
        XCTAssertEqual(sheet.height, 316)  // one row of 300 px cells
        XCTAssertEqual(sheet.width, 3 * 300 + 4 * 8)
    }

    func testContactSheetSurvivesAMissingThumbnail() {
        let one = library.thumbURL(Int64(ids["a1"]!)!), gone = base.appendingPathComponent("nope.jpg")
        XCTAssertNotNil(contactSheet(thumbnails: [one, gone, one, one, one], firstNumber: 1, you: [2]))
        XCTAssertNil(contactSheet(thumbnails: [gone], firstNumber: 1, you: []))
    }

    // MARK: - Running the command

    func testReviewReturnsAnswersAndUsageAndRunsWithoutTools() async throws {
        let cli = try makeFakeCLI()
        let groups = try catalog.groupsNeedingSecondOpinion()
        let message = SecondOpinion.message(for: groups) { self.library.thumbURL(Int64($0)!) }
        let r = try await cli.review(message: message, model: "haiku", workingDirectory: library.dir)
        XCTAssertEqual(r.answers.map(\.group), groups.map(\.id))
        XCTAssertEqual(r.answers[0].remove, [2, 3])
        XCTAssertEqual(r.usage.inputTokens, 5102)
        XCTAssertEqual(r.usage.outputTokens, 700)
        XCTAssertEqual(r.usage.costUSD, 0.002)

        let call = try JSONSerialization.jsonObject(with: Data(String(contentsOf: cli.url.deletingLastPathComponent().appendingPathComponent("calls.log"), encoding: .utf8).utf8)) as! [String: Any]
        let argv = call["argv"] as! [String]
        XCTAssertEqual(argv[argv.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(argv[argv.firstIndex(of: "--model")! + 1], "haiku")
        XCTAssertTrue(argv.contains("--no-session-persistence") && argv.contains("--strict-mcp-config") && argv.contains("-p"))
        XCTAssertFalse(argv.contains("--bare"))  // that mode ignores the Claude login
        XCTAssertEqual((call["cwd"] as! String).replacingOccurrences(of: "/private", with: ""), library.dir.path.replacingOccurrences(of: "/private", with: ""))
        // Only what the command needs is passed on. The last four are added by /usr/bin/python3 itself.
        XCTAssertEqual(Set(call["env"] as! [String]).subtracting(["HOME", "USER", "LANG", "PATH", "PWD", "__CF_USER_TEXT_ENCODING",
                                                                    "MANPATH", "LIBRARY_PATH", "CPATH", "SDKROOT"]), [])
    }

    func testFailuresAreExplained() async throws {
        let message = Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[]}}\n".utf8)
        for (mode, expected) in [("exit", "exited with code 3 and no result: boom"), ("error", "Credit balance is too low"), ("nostruct", "no structured answer")] {
            let cli = try makeFakeCLI(mode: mode)
            do {
                _ = try await cli.review(message: message, model: "haiku", workingDirectory: library.dir)
                XCTFail("\(mode) must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(mode): \(error.localizedDescription)")
            }
        }
    }

    func testStatusAndLocate() throws {
        let cli = try makeFakeCLI()
        XCTAssertEqual(cli.status(), ClaudeCLI.Status(version: "9.9.9 (Fake)", loggedIn: true, detail: "Signed in with your Claude account"))
        XCTAssertFalse(try makeFakeCLI(mode: "signedout").status().loggedIn)
        XCTAssertEqual(ClaudeCLI.locate(preferred: cli.url.path)?.url, cli.url)
        // The usual place in the home folder is found without any setting.
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: cli.url, to: home.appendingPathComponent(".local/bin/claude"))
        XCTAssertEqual(ClaudeCLI.locate(preferred: "/nowhere/claude", home: home)?.url.path, home.appendingPathComponent(".local/bin/claude").path)
    }

    func testRunSavesPicksAndTheNextRunHasNothingLeft() async throws {
        let cli = try makeFakeCLI()
        let log = Log()
        let p = try await SecondOpinionRun(cli: cli).run(catalog: catalog) { log.add($0.log) }
        XCTAssertEqual([p.total, p.done, p.failed, p.groups], [1, 1, 0, 2])
        XCTAssertEqual(p.usage.outputTokens, 700)
        XCTAssertTrue(log.lines[0].hasPrefix("2 groups in 1 batches"))
        XCTAssertTrue(log.lines[1].hasPrefix("batch 1: 2 groups"))

        let states = try catalog.effectiveStates()
        let groups = catalog.result.groups.filter { $0.kind != .duplicate }
        XCTAssertEqual(groups.map { g in g.members.map { states[$0]! } }, [[.fav, .remove, .remove], [.fav, .remove]])
        let page = try JSONSerialization.jsonObject(with: catalog.pageData()) as! [String: Any]
        XCTAssertEqual((page["haiku"] as! [String: Any]).count, 5)

        XCTAssertTrue(try catalog.groupsNeedingSecondOpinion().isEmpty)
        let again = try await SecondOpinionRun(cli: cli).run(catalog: catalog) { log.add($0.log) }
        XCTAssertEqual(again.total, 0)
        XCTAssertEqual(log.lines.last, "Every group already has a second opinion.")

        try catalog.clearSecondOpinion()
        XCTAssertEqual(try catalog.groupsNeedingSecondOpinion().count, 2)
    }

    func testAFailedBatchChangesNothingAndCanBeRunAgain() async throws {
        let log = Log()
        let p = try await SecondOpinionRun(cli: try makeFakeCLI(mode: "error")).run(catalog: catalog) { log.add($0.log) }
        XCTAssertEqual([p.done, p.failed, p.groups], [1, 1, 0])
        XCTAssertTrue(log.lines.last!.contains("failed, its groups stay as they were: claude reported an error: Credit balance is too low"))
        XCTAssertEqual(try catalog.groupsNeedingSecondOpinion().count, 2)
        let ok = try await SecondOpinionRun(cli: try makeFakeCLI()).run(catalog: catalog)
        XCTAssertEqual(ok.groups, 2)
    }

    func testCancellingStopsTheCommand() async throws {
        let cli = try makeFakeCLI(mode: "slow")
        let catalog = self.catalog!
        let started = Date()
        let task = Task { try await SecondOpinionRun(cli: cli).run(catalog: catalog) }
        try await Task.sleep(for: .seconds(1.5))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not finish normally")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(try catalog.groupsNeedingSecondOpinion().count, 2)
    }
}

final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
