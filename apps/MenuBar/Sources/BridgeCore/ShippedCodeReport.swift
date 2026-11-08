import Foundation

/// Joins the commits read from Git with the agent sessions that worked in
/// the same repository: lines added and removed, which commits sessions are
/// linked to, tokens per changed line, and sessions with no linked commit.
/// Links are evidence, labelled by strength, never proof of authorship.
public enum ShippedCodeReport {
    public struct Input: Sendable {
        /// Scoped sessions (see `ReportScope`).
        public var sessions: [ActivitySession]
        public var repositories: [ActivityRepository]
        public var from: Date?
        public var to: Date
        /// Known tokens per session in the period, from canonical accounting.
        public var tokensBySession: [String: Int]
        /// Known output tokens per session: what the agents wrote.
        public var outputTokensBySession: [String: Int]
        public var home: String

        public init(sessions: [ActivitySession], repositories: [ActivityRepository], from: Date?, to: Date,
                    tokensBySession: [String: Int] = [:], outputTokensBySession: [String: Int] = [:],
                    home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
            self.sessions = sessions; self.repositories = repositories; self.from = from; self.to = to
            self.tokensBySession = tokensBySession; self.outputTokensBySession = outputTokensBySession; self.home = home
        }
    }

    /// How a commit is tied to a session, strongest first.
    public enum Link: Int, Comparable, Sendable {
        /// The commit names the session's agent as a co-author.
        case coAuthored = 0
        /// The commit changes files the session edited, while it ran.
        case sameFiles = 1
        /// The commit landed in the session's repository while it ran (or soon after).
        case duringSession = 2

        public static func < (lhs: Link, rhs: Link) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .coAuthored: return "Co-authored"
            case .sameFiles: return "Same files"
            case .duringSession: return "During the session"
            }
        }
    }

    public struct Commit: Identifiable, Equatable, Sendable {
        public var commit: ActivityCommit
        public var repositoryID: String
        public var repositoryName: String
        /// Linked sessions at the strongest evidence found.
        public var sessionIDs: [String]
        public var link: Link?
        public var agents: [AgentName]
        public var id: String { repositoryID + ":" + commit.id }
        public var isLinked: Bool { link != nil }

        public init(commit: ActivityCommit, repositoryID: String, repositoryName: String, sessionIDs: [String], link: Link?, agents: [AgentName]) {
            self.commit = commit; self.repositoryID = repositoryID; self.repositoryName = repositoryName
            self.sessionIDs = sessionIDs; self.link = link; self.agents = agents
        }
    }

    public struct Lines: Equatable, Sendable {
        public var additions = 0
        public var deletions = 0
        public init(additions: Int = 0, deletions: Int = 0) { self.additions = additions; self.deletions = deletions }
        public var total: Int { additions + deletions }
        mutating func add(_ commit: ActivityCommit) { additions += commit.additions ?? 0; deletions += commit.deletions ?? 0 }
    }

    public struct Project: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var root: String
        public var roots: [String]
        public var available: Bool
        public var scannedAt: Date
        public var commits = 0
        public var linkedCommits = 0
        public var coAuthoredCommits = 0
        public var lines = Lines()
        public var linkedLines = Lines()
        /// Lock and other generated files, included in `lines`.
        public var generatedLines = Lines()
        public var filesChanged = 0
        /// Commits whose line counts weren't read.
        public var uncountedCommits = 0
        public var sessions = 0
        public var sessionsWithCommits = 0
        public var tokens = 0
        public var lastCommit: Date?

        public var tokensPerLine: Double? { linkedLines.total > 0 && tokens > 0 ? Double(tokens) / Double(linkedLines.total) : nil }
    }

    public struct SessionOutput: Equatable, Sendable {
        public var sessionID: String
        public var commitIDs: [String] = []
        public var lines = Lines()
        public var strongest: Link?
    }

    public struct Totals: Equatable, Sendable {
        public var repositories = 0
        public var unavailableRepositories = 0
        public var commits = 0
        public var linkedCommits = 0
        public var coAuthoredCommits = 0
        public var coAuthoredByAgent: [AgentName: Int] = [:]
        public var lines = Lines()
        public var linkedLines = Lines()
        public var generatedLines = Lines()
        public var filesChanged = 0
        public var uncountedCommits = 0
        /// Sessions with activity in a scanned repository.
        public var sessions = 0
        public var sessionsWithCommits = 0
        /// Tokens of sessions in scanned repositories.
        public var tokens = 0
        /// Output tokens of those sessions.
        public var outputTokens = 0
        /// Tokens of sessions with no linked commit.
        public var tokensWithoutCommits = 0
        public var oldestScan: Date?
        public var newestScan: Date?

        public var tokensPerLine: Double? { linkedLines.total > 0 && tokens > 0 ? Double(tokens) / Double(linkedLines.total) : nil }
        public var tokensPerCommit: Double? { linkedCommits > 0 && tokens > 0 ? Double(tokens) / Double(linkedCommits) : nil }
        public var outputTokensPerLine: Double? { linkedLines.total > 0 && outputTokens > 0 ? Double(outputTokens) / Double(linkedLines.total) : nil }
        public var sessionsWithoutCommits: Int { sessions - sessionsWithCommits }
    }

    public struct Result: Equatable, Sendable {
        public var totals: Totals
        public var projects: [Project]
        /// Commits in the period, newest first.
        public var commits: [Commit]
        public var sessions: [String: SessionOutput]
        public var notes: [String]

        public static let empty = Result(totals: Totals(), projects: [], commits: [], sessions: [:], notes: [])
        public var hasScan: Bool { totals.repositories > 0 }

        public func project(containing path: String?) -> Project? {
            guard let path else { return nil }
            return projects.first { project in project.roots.contains { path == $0 || path.hasPrefix($0 + "/") } }
        }
    }

    /// Commits landing this long after a session's last activity still count
    /// as made during it: people often review and commit after the agent stops.
    public static let grace: TimeInterval = 2 * 3_600

    public static func build(_ input: Input) -> Result {
        func inPeriod(_ date: Date) -> Bool { date <= input.to && (input.from.map { date >= $0 } ?? true) }
        let sessions = input.sessions.filter { $0.provider == .claude || $0.provider == .codex }
        var result = Result.empty
        var totals = Totals()
        var sessionOutputs: [String: SessionOutput] = [:]
        var commits: [Commit] = []
        var projects: [Project] = []
        var countedSessions = Set<String>()
        let allRoots = Array(Set(input.repositories.flatMap { ([$0.root] + $0.worktrees.map(\.path)).map(resolved) })).sorted { $0.count > $1.count }

        for repository in input.repositories {
            let roots = Array(Set(([repository.root] + repository.worktrees.map(\.path)).map(resolved))).sorted { $0.count > $1.count }
            let available = repository.commitHistoryAvailable == true
            var project = Project(id: repository.id, name: repository.name, root: repository.root, roots: roots,
                                  available: available, scannedAt: repository.observedAt)
            // Sessions that worked in this repository (any of its worktrees).
            let mine = sessions.compactMap { session -> (session: ActivitySession, root: String, active: [ClosedRange<Date>], files: Set<String>)? in
                guard let path = session.projectPath.map(resolved),
                      let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") })
                        ?? editedRoot(session, project: path, roots: allRoots, home: input.home).flatMap({ roots.contains($0) ? $0 : nil }) else { return nil }
                let active = activeWindows(session)
                guard let start = active.first?.lowerBound, let end = active.last?.upperBound,
                      inPeriod(end) || inPeriod(start) || (input.from.map { start < $0 && end > input.to } ?? false) else { return nil }
                return (session, root, active, editedFiles(session, project: path, root: root, home: input.home))
            }
            guard available || !mine.isEmpty else { continue }
            if !available { totals.unavailableRepositories += 1; projects.append(project); continue }
            totals.repositories += 1
            totals.oldestScan = min(totals.oldestScan ?? repository.observedAt, repository.observedAt)
            totals.newestScan = max(totals.newestScan ?? repository.observedAt, repository.observedAt)

            for item in mine {
                project.sessions += 1
                project.tokens += input.tokensBySession[item.session.id] ?? 0
                if countedSessions.insert(item.session.id).inserted {
                    totals.sessions += 1
                    totals.tokens += input.tokensBySession[item.session.id] ?? 0
                    totals.outputTokens += input.outputTokensBySession[item.session.id] ?? 0
                }
            }
            for commit in repository.commits where inPeriod(commit.timestamp) {
                project.commits += 1
                project.lastCommit = max(project.lastCommit ?? commit.timestamp, commit.timestamp)
                if commit.additions == nil { project.uncountedCommits += 1 } else {
                    project.lines.add(commit)
                    project.filesChanged += commit.filesChanged ?? 0
                    for file in commit.files ?? [] where isGenerated(file.path) {
                        project.generatedLines.additions += file.additions ?? 0
                        project.generatedLines.deletions += file.deletions ?? 0
                    }
                }
                let agents = commit.coAuthors ?? []
                if !agents.isEmpty { project.coAuthoredCommits += 1; for agent in agents { totals.coAuthoredByAgent[agent, default: 0] += 1 } }
                // The strongest evidence among sessions active when it landed.
                var best: (link: Link, ids: [String])?
                let paths = Set(commit.paths)
                for item in mine where item.active.contains(where: { $0.contains(commit.timestamp) }) {
                    let link: Link = agents.contains(item.session.provider) ? .coAuthored
                        : (!paths.isDisjoint(with: item.files) ? .sameFiles : .duringSession)
                    if best == nil || link < best!.link { best = (link, [item.session.id]) }
                    else if link == best!.link { best!.ids.append(item.session.id) }
                }
                // A named co-author outranks another agent's session that only
                // shares files or time; it stands even with no session in view.
                if !agents.isEmpty, best.map({ $0.link > .coAuthored }) ?? true { best = (.coAuthored, []) }
                let link = best?.link
                if link != nil {
                    project.linkedCommits += 1
                    if commit.additions != nil { project.linkedLines.add(commit) }
                }
                for id in best?.ids ?? [] {
                    var output = sessionOutputs[id] ?? SessionOutput(sessionID: id)
                    output.commitIDs.append(commit.id)
                    output.lines.add(commit)
                    output.strongest = min(output.strongest ?? link!, link!)
                    sessionOutputs[id] = output
                }
                commits.append(Commit(commit: commit, repositoryID: repository.id, repositoryName: repository.name,
                                      sessionIDs: best?.ids ?? [], link: link, agents: agents))
            }
            project.sessionsWithCommits = mine.filter { sessionOutputs[$0.session.id] != nil }.count
            totals.commits += project.commits
            totals.linkedCommits += project.linkedCommits
            totals.coAuthoredCommits += project.coAuthoredCommits
            totals.lines.additions += project.lines.additions; totals.lines.deletions += project.lines.deletions
            totals.linkedLines.additions += project.linkedLines.additions; totals.linkedLines.deletions += project.linkedLines.deletions
            totals.generatedLines.additions += project.generatedLines.additions; totals.generatedLines.deletions += project.generatedLines.deletions
            totals.filesChanged += project.filesChanged
            totals.uncountedCommits += project.uncountedCommits
            projects.append(project)
        }
        totals.sessionsWithCommits = countedSessions.filter { sessionOutputs[$0] != nil }.count
        totals.tokensWithoutCommits = countedSessions.filter { sessionOutputs[$0] == nil }.reduce(0) { $0 + (input.tokensBySession[$1] ?? 0) }
        commits.sort { $0.commit.timestamp == $1.commit.timestamp ? $0.id < $1.id : $0.commit.timestamp > $1.commit.timestamp }
        projects.sort { $0.lines.total == $1.lines.total ? $0.name < $1.name : $0.lines.total > $1.lines.total }

        var notes = [
            "Commits come from Scan projects: up to \(ActivityGitReader.commitLimit) non-merge commits per repository from the last 30 days, read-only. Lines are added and removed lines in text files, as Git counts them.",
            "A commit is linked to a session when it names the session's agent as a co-author, changes files the session edited while it ran, or lands in the session's repository while it ran or within two hours after. Links show where work and commits line up; they don't prove who wrote the code.",
            "Tokens per changed line divides the known tokens of agent sessions in scanned repositories by the lines in linked commits. Most of those tokens are context re-sent from cache on every step; written tokens count only what the agents produced.",
        ]
        if totals.generatedLines.total > 0 { notes.append("Lock and generated files (package-lock.json, yarn.lock, Cargo.lock and similar) are included in the line counts and shown separately.") }
        if totals.uncountedCommits > 0 { notes.append("\(totals.uncountedCommits) commits had no line counts because their history was too large to read; they're counted but add no lines.") }
        result.totals = totals
        result.projects = projects
        result.commits = Array(commits.prefix(2_000))
        result.sessions = sessionOutputs
        result.notes = notes
        return result
    }

    /// When the session was working, padded to catch its commits: from ten
    /// minutes before each turn to `grace` after it, merged and sorted.
    static func activeWindows(_ session: ActivitySession) -> [ClosedRange<Date>] {
        var spans: [(Date, Date)] = session.turns.compactMap { turn in
            guard let start = turn.startedAt ?? turn.completedAt else { return nil }
            let end = max(turn.completedAt ?? start, start)
            return (start.addingTimeInterval(-600), end.addingTimeInterval(grace))
        }
        if spans.isEmpty { spans = [(session.createdAt.addingTimeInterval(-600), max(session.updatedAt, session.createdAt).addingTimeInterval(grace))] }
        spans.sort { $0.0 < $1.0 }
        var merged: [ClosedRange<Date>] = []
        for (start, end) in spans {
            if let last = merged.last, start <= last.upperBound { merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, end) }
            else { merged.append(start ... end) }
        }
        return merged
    }

    /// A session started in a parent folder (Codex threads often are) belongs
    /// to the repository holding the files it edited, or, when it recorded
    /// no edits, to the one scanned repository its folder contains.
    static func editedRoot(_ session: ActivitySession, project: String, roots: [String], home: String) -> String? {
        let inside = roots.filter { $0.hasPrefix(project + "/") }
        guard !inside.isEmpty else { return nil }
        var sawEdits = false
        for turn in session.turns {
            for artifact in turn.artifacts where artifact.kind != "image" {
                sawEdits = true
                let path = normalized(InstructionReport.absolute(artifact.path, project: project, home: home))
                if let root = roots.first(where: { path.hasPrefix($0 + "/") }) { return root }
            }
        }
        return !sawEdits && inside.count == 1 ? inside[0] : nil
    }

    /// Files a session edited, relative to its repository working copy.
    static func editedFiles(_ session: ActivitySession, project: String, root: String, home: String) -> Set<String> {
        var files = Set<String>()
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for turn in session.turns {
            for artifact in turn.artifacts where artifact.kind != "image" {
                let path = InstructionReport.absolute(artifact.path, project: project, home: home)
                let value = normalized(path)
                if value.hasPrefix(prefix) { files.insert(String(value.dropFirst(prefix.count))) }
            }
        }
        return files
    }

    /// Git reports real paths; sessions may name a folder through a link.
    static func resolved(_ path: String) -> String {
        normalized(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    static func normalized(_ path: String) -> String {
        let value = URL(fileURLWithPath: path).standardizedFileURL.path
        return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    static let generatedNames: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "bun.lockb", "Cargo.lock",
                                               "Gemfile.lock", "poetry.lock", "Pipfile.lock", "composer.lock", "Podfile.lock", "go.sum",
                                               "Package.resolved", "mix.lock", "pubspec.lock", "uv.lock"]

    /// Lock files and minified bundles: real changes, but not written by hand.
    public static func isGenerated(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return generatedNames.contains(name) || name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".map")
    }

    /// "+60,302 / −6,716".
    public static func linesLabel(_ lines: Lines) -> String {
        "+\(lines.additions.formatted()) / −\(lines.deletions.formatted())"
    }
}
