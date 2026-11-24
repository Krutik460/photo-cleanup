import Foundation

public enum ClaudeError: LocalizedError {
    case notFound
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "The Claude CLI was not found. Install Claude Code, or set its path in Settings."
        case .failed(let m): m
        }
    }
}

/// The user's installed `claude` command, run without a terminal. It uses their Claude login, so the
/// app needs no API key.
public struct ClaudeCLI: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public struct Status: Sendable, Equatable {
        public var version: String?
        public var loggedIn: Bool
        public var detail: String  // how they are signed in, or why not
    }

    public struct Usage: Sendable, Equatable {
        public var inputTokens = 0
        public var outputTokens = 0
        public var costUSD = 0.0
        public var seconds = 0.0
    }

    /// Finds the command. An app does not get the shell's PATH, so: the path from Settings, the usual
    /// install locations, then whatever a login shell resolves.
    public static func locate(preferred: String? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeCLI? {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty { candidates.append((preferred as NSString).expandingTildeInPath) }
        candidates += [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                       home.appendingPathComponent(".claude/local/claude").path]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return ClaudeCLI(url: URL(fileURLWithPath: found))
        }
        if let out = try? run(URL(fileURLWithPath: "/bin/zsh"), ["-lic", "command -v claude"], timeout: 10).stdout {
            let path = String(decoding: out, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return ClaudeCLI(url: URL(fileURLWithPath: path)) }
        }
        return nil
    }

    /// Version and sign-in state, for Settings. Never throws: problems are part of the answer.
    public func status() -> Status {
        let version = (try? Self.run(url, ["--version"], environment: environment, timeout: 20)).map {
            String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let auth = try? Self.run(url, ["auth", "status"], environment: environment, timeout: 20),
              let json = try? JSONSerialization.jsonObject(with: auth.stdout) as? [String: Any] else {
            return Status(version: version, loggedIn: false, detail: "Could not read the sign-in state. Run `claude` in Terminal once.")
        }
        let loggedIn = json["loggedIn"] as? Bool ?? false
        let method = json["authMethod"] as? String ?? ""
        return Status(version: version, loggedIn: loggedIn,
                      detail: loggedIn ? (method == "claude.ai" ? "Signed in with your Claude account" : "Signed in (\(method))")
                          : "Not signed in. Run `claude` in Terminal and sign in.")
    }

    /// Only what the command needs: its own folder on the PATH and the user's home, where the login lives.
    var environment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return ["HOME": inherited["HOME"] ?? NSHomeDirectory(), "USER": inherited["USER"] ?? NSUserName(), "LANG": "en_US.UTF-8",
                "PATH": "\(url.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    /// Sends one batch for review and returns the structured answer. The model gets no tools: it can
    /// read and write nothing, and only sees the message.
    public func review(message: Data, model: String, workingDirectory: URL) async throws -> (answers: [ReviewAnswer], usage: Usage) {
        let arguments = ["-p", "--model", model, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--json-schema", SecondOpinion.schema, "--tools", "", "--system-prompt", SecondOpinion.instructions,
                         "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", ""]
        let start = Date()
        let out = try await Self.runAsync(url, arguments, input: message, environment: environment, workingDirectory: workingDirectory)
        // The last "result" event carries the outcome; everything before it is progress.
        var result: [String: Any]?
        for line in out.stdout.split(separator: UInt8(ascii: "\n")) {
            if let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], event["type"] as? String == "result" { result = event }
        }
        let stderr = String(decoding: out.stderr.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result else {
            throw ClaudeError.failed("claude exited with code \(out.status) and no result" + (stderr.isEmpty ? "" : ": \(stderr)"))
        }
        if result["is_error"] as? Bool == true {
            throw ClaudeError.failed("claude reported an error: \(result["result"] as? String ?? result["subtype"] as? String ?? "unknown")")
        }
        guard let structured = result["structured_output"] as? [String: Any], let groups = structured["groups"],
              let answers = try? JSONDecoder().decode([ReviewAnswer].self, from: JSONSerialization.data(withJSONObject: groups)) else {
            throw ClaudeError.failed("claude returned no structured answer: \(String((result["result"] as? String ?? "").prefix(200)))")
        }
        let usage = result["usage"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return (answers, Usage(inputTokens: int("input_tokens") + int("cache_creation_input_tokens") + int("cache_read_input_tokens"),
                               outputTokens: int("output_tokens"), costUSD: (result["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                               seconds: Date().timeIntervalSince(start)))
    }

    // MARK: - Running a process

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// Runs to completion on a background thread; cancelling the task terminates the process.
    static func runAsync(_ executable: URL, _ arguments: [String], input: Data? = nil, environment: [String: String]? = nil,
                         workingDirectory: URL? = nil) async throws -> Output {
        try Task.checkCancellation()
        let process = Process()
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try run(executable, arguments, input: input, environment: environment,
                                                               workingDirectory: workingDirectory, process: process))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()  // a terminated process is a cancelled run, not a failed one
        return output
    }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], input: Data? = nil, environment: [String: String]? = nil,
                    workingDirectory: URL? = nil, timeout: TimeInterval? = nil, process: Process = Process()) throws -> Output {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Feed and drain all three pipes at once: megabytes of images go in while output comes back.
        let group = DispatchGroup()
        var out = Data(), err = Data()
        DispatchQueue.global().async(group: group) {
            if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
            try? stdin.fileHandleForWriting.close()
        }
        DispatchQueue.global().async(group: group) { out = stdout.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) { err = stderr.fileHandleForReading.readDataToEndOfFile() }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
        process.waitUntilExit()
        group.wait()
        return Output(status: process.terminationStatus, stdout: out, stderr: err)
    }
}

/// Runs the second opinion over every group that still needs one, a few batches at a time.
public struct SecondOpinionRun: Sendable {
    public struct Progress: Sendable, Equatable {
        public var done = 0
        public var total = 0
        public var failed = 0
        public var groups = 0  // groups that got a pick
        public var usage = ClaudeCLI.Usage()

        public init(done: Int = 0, total: Int = 0) {
            self.done = done
            self.total = total
        }
    }

    public struct Event: Sendable {
        public var progress: Progress
        public var log: String  // one line for the run's log
    }

    public let cli: ClaudeCLI
    public var model = "haiku"
    public var parallel = 3

    public init(cli: ClaudeCLI, model: String = "haiku", parallel: Int = 3) {
        self.cli = cli
        self.model = model
        self.parallel = max(1, parallel)
    }

    /// Picks are saved batch by batch, so a cancelled or failed run keeps what it finished and the
    /// next run continues with the groups that are left.
    @discardableResult
    public func run(catalog: Catalog, limit: Int? = nil, onEvent: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> Progress {
        var batches = SecondOpinion.batches(try catalog.groupsNeedingSecondOpinion())
        if let limit { batches = Array(batches.prefix(limit)) }
        var progress = Progress(total: batches.count)
        let run = ISO8601DateFormatter().string(from: Date())
        onEvent(Event(progress: progress, log: batches.isEmpty ? "Every group already has a second opinion."
                          : "\(batches.reduce(0) { $0 + $1.count }) groups in \(batches.count) \(batches.count == 1 ? "batch" : "batches"), up to \(parallel) at a time, model \(model)"))
        let library = catalog.library, cli = self.cli, model = self.model

        try await withThrowingTaskGroup(of: (Int, Result<([ReviewAnswer], ClaudeCLI.Usage), Error>).self) { group in
            var next = 0
            func add() {
                guard next < batches.count, !Task.isCancelled else { return }
                let i = next, batch = batches[i]
                next += 1
                group.addTask {
                    do {
                        let message = SecondOpinion.message(for: batch) { library.thumbURL(Int64($0) ?? 0) }
                        let r = try await cli.review(message: message, model: model, workingDirectory: library.dir)
                        return (i, .success((r.answers, r.usage)))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            for _ in 0..<parallel { add() }
            for try await (i, outcome) in group {
                let batch = batches[i], name = "batch \(i + 1)"
                switch outcome {
                case .success(let (answers, usage)):
                    let (picks, problems) = SecondOpinion.picks(for: batch, answers: answers)
                    try catalog.saveSecondOpinion(picks, batch: "\(run) \(name)")
                    progress.groups += batch.filter { g in g.members.contains { picks[$0] != nil } }.count
                    progress.usage.inputTokens += usage.inputTokens
                    progress.usage.outputTokens += usage.outputTokens
                    progress.usage.costUSD += usage.costUSD
                    progress.usage.seconds += usage.seconds
                    progress.done += 1
                    let removed = picks.values.filter { $0.state == .remove }.count
                    onEvent(Event(progress: progress, log: "\(name): \(batch.count) groups in \(Int(usage.seconds)) s, \(removed) of \(picks.count) photos to remove"
                                      + (problems.isEmpty ? "" : "; " + problems.joined(separator: "; "))))
                case .failure(let error):
                    if error is CancellationError { throw error }
                    progress.failed += 1
                    progress.done += 1
                    onEvent(Event(progress: progress, log: "\(name) failed, its groups stay as they were: \(error.localizedDescription)"))
                }
                add()
            }
        }
        return progress
    }
}
