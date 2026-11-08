import Foundation

/// Read-only, explicit repository inspection. No fetch, checkout or hooks.
/// Commits carry their line counts and any agent named in a Co-authored-by
/// trailer; linking them to sessions is the report's job, labelled as such.
struct ActivityGitReader: Sendable {
    static let commitLimit = 300
    static let fileLimit = 400
    /// Repositories whose histories are read at once.
    static let parallelHistories = 4

    enum ReadError: Error { case timedOut, tooLarge, failed }

    private let execute: @Sendable (String, [String]) async throws -> String
    init(execute: (@Sendable (String, [String]) async throws -> String)? = nil) {
        self.execute = execute ?? { path, args in try await Self.runGit(path, args) }
    }

    private func git(_ path: String, _ args: [String], before deadline: Date) async throws -> String {
        try Task.checkCancellation()
        guard Date() < deadline else { throw BridgeError.processFailed("Repository inspection time budget reached") }
        return try await execute(path, args)
    }

    func read(paths: [String], now: Date = Date()) async -> [ActivityRepository] {
        var repositories: [String: ActivityRepository] = [:]
        var histories: [(id: String, path: String, heads: [String])] = []
        let deadline = Date().addingTimeInterval(90)
        // Inventory first (quick): repository identity, worktrees, status.
        for path in paths {
            guard Date() < deadline, !Task.isCancelled else { break }
            guard path.hasPrefix("/"), !path.contains("\0") else { continue }
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard canonical != "/", canonical != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path else { continue }
            do {
                let common = try await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"], before: deadline)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard common.hasPrefix("/") else { continue }
                let id = URL(fileURLWithPath: common).resolvingSymlinksInPath().path
                let root = try await git(path, ["rev-parse", "--show-toplevel"], before: deadline).trimmingCharacters(in: .whitespacesAndNewlines)
                if var existing = repositories[id] {
                    if let i = existing.worktrees.firstIndex(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: root).resolvingSymlinksInPath().path }),
                       let status = try? await git(root, ["status", "--porcelain=v2", "-z", "--untracked-files=no"], before: deadline) {
                        existing.worktrees[i].changedFiles = Self.changedFiles(status)
                        repositories[id] = existing
                    }
                    continue
                }
                let rawWorktrees = try await git(path, ["worktree", "list", "--porcelain", "-z"], before: deadline)
                var worktrees = Self.worktrees(rawWorktrees)
                // Only inspect the explicitly observed path's working copy;
                // inventory sibling worktrees without walking their contents.
                let observed = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                if let i = worktrees.firstIndex(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == observed }),
                   let status = try? await git(root, ["status", "--porcelain=v2", "-z", "--untracked-files=no"], before: deadline) {
                    worktrees[i].changedFiles = Self.changedFiles(status)
                }
                let heads = Array(Set(worktrees.compactMap(\.head))).filter { $0.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil }
                repositories[id] = ActivityRepository(id: id, name: URL(fileURLWithPath: common).deletingLastPathComponent().lastPathComponent, root: root, worktrees: worktrees, observedAt: now)
                histories.append((id, path, heads))
            } catch {
                if Task.isCancelled { break }
                // Not every native task folder is a Git checkout. Preserve a
                // visible unavailable observation instead of fabricated zeros.
                repositories[path] = ActivityRepository(id: path, name: URL(fileURLWithPath: path).lastPathComponent, root: path, observedAt: now, warning: "Git inspection unavailable here; the folder may not be a repository or may not be accessible.", commitHistoryAvailable: false)
            }
        }
        // Then histories, a few at a time: line counts can take seconds on a
        // repository with large changes, and one must not starve the rest.
        await withTaskGroup(of: (String, String?, Bool, String).self) { group in
            var pending = histories[...]
            func start() {
                guard let next = pending.popFirst() else { return }
                group.addTask { [self] in
                    let (history, counts, detail) = await self.history(next.path, heads: next.heads, before: deadline)
                    return (next.id, history, counts, detail)
                }
            }
            for _ in 0 ..< Self.parallelHistories { start() }
            for await (id, history, countsLines, detail) in group {
                let available = history != nil
                let scope = "Up to \(Self.commitLimit) non-merge commits from local branches, worktree HEADs and cached remote refs over 30 days, \(detail). Tracked-file status only. Commits are linked to sessions by repository, time and files, not proven authorship."
                repositories[id]?.commits = Self.commits(history ?? "", countsLines: countsLines)
                repositories[id]?.warning = (available ? "" : "Commit history unavailable; an empty list does not mean zero commits. ") + scope
                repositories[id]?.commitHistoryAvailable = available
                start()
            }
        }
        return repositories.values.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Per-file line counts; per-commit totals when that output is too large;
    /// bare commits when counting takes too long. Returns nil when even the
    /// bare history can't be read.
    private func history(_ path: String, heads: [String], before deadline: Date) async -> (String?, Bool, String) {
        let range = ["log", "--branches", "--remotes", "--no-merges", "--since=30.days.ago", "--max-count=\(Self.commitLimit)"]
        let format = "--format=%x1e%H%x1f%ct%x1f%s%x1f%(trailers:key=Co-authored-by,valueonly,separator=%x1d)"
        do {
            return (try await git(path, range + [format, "--numstat"] + heads + ["--"], before: deadline), true, "with lines added and removed per file")
        } catch ReadError.tooLarge {
            if let value = try? await git(path, range + [format, "--shortstat"] + heads + ["--"], before: deadline) {
                return (value, true, "with lines added and removed per commit")
            }
        } catch {}
        if let value = try? await git(path, range + [format] + heads + ["--"], before: deadline) {
            return (value, false, "without line counts (counting them took too long)")
        }
        return (nil, false, "")
    }

    private static func runGit(_ path: String, _ args: [String]) async throws -> String {
        // Counting lines across a month of large changes is slower and larger
        // than the status and inventory reads.
        let counting = args.contains("--numstat") || args.contains("--shortstat")
        let isLog = args.first == "log"
        let result = try await ProcessRunner.run(executable: "/usr/bin/git", arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path] + args, currentDirectory: BridgePaths.providerProbeDirectory, stdin: "", timeoutSeconds: counting ? 30 : (isLog ? 10 : 4), maximumOutputCharacters: isLog ? 4_000_000 : 150_000)
        if result.timedOut { throw ReadError.timedOut }
        if result.stdout.contains("[…bridge output truncated…]") { throw ReadError.tooLarge }
        guard result.status == 0 else { throw ReadError.failed }
        return result.stdout
    }
    static func worktrees(_ raw: String) -> [ActivityWorktree] {
        var values: [ActivityWorktree] = []
        var current: ActivityWorktree?
        for field in raw.split(separator: "\0", omittingEmptySubsequences: false) {
            let field = String(field)
            if field.hasPrefix("worktree ") {
                if let current { values.append(current) }
                current = ActivityWorktree(path: String(field.dropFirst(9)))
            } else if field.hasPrefix("HEAD ") { current?.head = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") { current?.branch = String(field.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if field == "detached" { current?.branch = "Detached HEAD" }
        }
        if let current { values.append(current) }
        return values
    }
    static func changedFiles(_ raw: String) -> Int {
        var count = 0
        var skipRenameSource = false
        for record in raw.split(separator: "\0", omittingEmptySubsequences: false) {
            // Porcelain-v2 rename/copy records consume a second NUL-delimited
            // source path, whose name may itself begin with a record prefix.
            if skipRenameSource { skipRenameSource = false; continue }
            if record.hasPrefix("2 ") { count += 1; skipRenameSource = true }
            else if record.hasPrefix("1 ") || record.hasPrefix("u ") { count += 1 }
        }
        return count
    }
    /// Records separated by U+001E: a header of hash, time, subject and
    /// co-author trailers (U+001F between fields), then any --numstat lines
    /// or one --shortstat line.
    static func commits(_ raw: String, countsLines: Bool = true) -> [ActivityCommit] {
        var seen = Set<String>()
        return raw.split(separator: "\u{1e}").compactMap { row in
            let lines = row.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { return nil }
            let fields = header.trimmingCharacters(in: .whitespaces).split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3, let time = Double(fields[1]), time.isFinite, seen.insert(String(fields[0])).inserted else { return nil }
            var commit = ActivityCommit(id: String(fields[0]), subject: TraceRedactor.redact(String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines), maximumCharacters: 300),
                                        timestamp: Date(timeIntervalSince1970: time))
            if fields.count == 4 { commit.coAuthors = coAuthors(String(fields[3])) }
            var files: [ActivityCommitFile] = []
            var additions = 0, deletions = 0, fileCount = 0, sawNumstat = false
            for line in lines.dropFirst() {
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3, let path = renamedPath(String(parts[2])) {
                    sawNumstat = true
                    let added = Int(parts[0]), removed = Int(parts[1])
                    additions += added ?? 0; deletions += removed ?? 0; fileCount += 1
                    if files.count < fileLimit { files.append(ActivityCommitFile(path: path, additions: added, deletions: removed)) }
                } else if let totals = shortstat(String(line)) {
                    commit.filesChanged = totals.files; commit.additions = totals.additions; commit.deletions = totals.deletions
                }
            }
            if sawNumstat {
                commit.additions = additions; commit.deletions = deletions; commit.filesChanged = fileCount
                commit.files = files
                commit.paths = files.map(\.path)
            } else if commit.filesChanged == nil, fields.count == 4, countsLines {
                // A counted history with no lines is a commit with no file changes.
                commit.additions = 0; commit.deletions = 0; commit.filesChanged = 0; commit.files = []
            }
            return commit
        }
    }

    /// "{old => new}" and "old => new" rename notation, resolved to the new path.
    static func renamedPath(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        guard value.contains(" => ") else { return value }
        if let open = value.firstIndex(of: "{"), let close = value[open...].firstIndex(of: "}") {
            let inner = value[value.index(after: open) ..< close]
            let target = inner.components(separatedBy: " => ").last ?? ""
            let joined = String(value[..<open]) + target + String(value[value.index(after: close)...])
            return joined.replacingOccurrences(of: "//", with: "/")
        }
        return value.components(separatedBy: " => ").last
    }

    /// " 3 files changed, 10 insertions(+), 2 deletions(-)".
    static func shortstat(_ line: String) -> (files: Int, additions: Int, deletions: Int)? {
        guard line.contains("changed") else { return nil }
        func number(before word: String) -> Int {
            guard let range = line.range(of: word) else { return 0 }
            let digits = line[..<range.lowerBound].reversed().drop { $0 == " " }.prefix { $0.isNumber }
            return Int(String(digits.reversed())) ?? 0
        }
        return (number(before: " file"), number(before: " insertion"), number(before: " deletion"))
    }

    /// Agents named in Co-authored-by trailer values (U+001D between values).
    static func coAuthors(_ raw: String) -> [AgentName] {
        var agents = Set<AgentName>()
        for value in raw.split(separator: "\u{1d}") {
            let text = value.lowercased()
            if text.contains("claude") || text.contains("anthropic") { agents.insert(.claude) }
            if text.contains("codex") || text.contains("openai") || text.contains("chatgpt") { agents.insert(.codex) }
            if text.contains("grok") { agents.insert(.grok) }
        }
        return agents.sorted { $0.rawValue < $1.rawValue }
    }
}
