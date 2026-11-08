import Foundation

/// Joins what each session recorded at its start (instruction files and the
/// skill list) with the instruction files on disk, per project. Sizes are
/// measured where the agent recorded them and read from disk otherwise;
/// each row says which.
public enum InstructionReport {
    public struct Input: Sendable {
        /// Scoped sessions (see `ReportScope`).
        public var sessions: [ActivitySession]
        public var catalog: InstructionCatalog
        public var from: Date?
        public var to: Date
        public var provider: String
        public var project: String
        public var hourly: Bool
        public var timeZone: TimeZone

        public init(sessions: [ActivitySession], catalog: InstructionCatalog, from: Date?, to: Date, provider: String = "all",
                    project: String = "all", hourly: Bool = false, timeZone: TimeZone = ActivityAnalytics.reportingTimeZone) {
            self.sessions = sessions; self.catalog = catalog; self.from = from; self.to = to
            self.provider = provider; self.project = project; self.hourly = hourly; self.timeZone = timeZone
        }
    }

    /// The parts of what a session starts with, before the first message.
    public enum Part: String, CaseIterable, Sendable {
        case project, personal, memory, skills

        public var title: String {
            switch self {
            case .project: return "Project rules"
            case .personal: return "Your rules"
            case .memory: return "Memory"
            case .skills: return "Skill list"
            }
        }
    }

    public struct SessionStart: Identifiable, Equatable, Sendable {
        public var sessionID: String
        public var provider: AgentName
        public var projectPath: String?
        public var startedAt: Date
        /// Characters by part; nil when neither a record nor the files say.
        public var parts: [Part: Int]?
        /// From the agent's own record rather than the files on disk.
        public var measured: Bool
        public var clientVersion: String?
        public var id: String { sessionID }

        public var instructionCharacters: Int? {
            parts.map { $0.filter { $0.key != .skills }.values.reduce(0, +) }
        }
        public var projectCharacters: Int? { parts.map { $0[.project] ?? 0 } }
    }

    public struct Edit: Identifiable, Equatable, Sendable {
        public var id: String
        public var sessionID: String
        public var turnID: String
        public var provider: AgentName
        /// Absolute when known, else as recorded.
        public var path: String
        public var projectPath: String?
        public var timestamp: Date
        public var turnStatus: TurnStatus
        public var fileName: String { (path as NSString).lastPathComponent }
    }

    /// Typical start of one agent's sessions in the period.
    public struct AgentStart: Equatable, Sendable, Identifiable {
        public var agent: AgentName
        public var sessions: Int
        public var measuredSessions: Int
        /// Median characters per part.
        public var parts: [Part: Int]
        public var id: String { agent.rawValue }
        public var total: Int { parts.values.reduce(0, +) }
        public var instructions: Int { parts.filter { $0.key != .skills }.values.reduce(0, +) }
    }

    public struct ProjectRow: Identifiable, Equatable, Sendable {
        /// Project path, or "~" for the files every project gets.
        public var id: String
        public var instructions: ProjectInstructions?
        public var sessions: [AgentName: Int] = [:]
        public var buckets: [Int] = []
        /// Median instruction characters a session, by agent.
        public var perSession: [AgentName: Int] = [:]
        public var perSessionMeasured: [AgentName: Bool] = [:]
        public var charactersLoaded = 0
        public var edits: [Edit] = []
        public var lastActive: Date?
        /// Newest change to any of its instruction files.
        public var lastChanged: Date?
        /// Sessions that got no project rules while the other agent has some.
        public var missingSessions: [AgentName: Int] = [:]
        /// Claude sessions on a version that doesn't read AGENTS.md, here where AGENTS.md is the only file.
        public var olderClaudeSessions = 0

        public var isPersonal: Bool { id == "~" }
        public var parity: ProjectInstructions.Parity { instructions?.parity ?? .none }
        public var totalSessions: Int { sessions.values.reduce(0, +) }
        public var truncatedBytes: Int { instructions?.codex.truncatedBytes ?? 0 }
        public var needsLook: Bool {
            guard !isPersonal else { return false }
            if truncatedBytes > 0 || !missingSessions.isEmpty || olderClaudeSessions > 0 { return true }
            switch parity {
            case .different: return true
            case .claudeOnly: return (sessions[.codex] ?? 0) > 0
            case .codexOnly: return (sessions[.claude] ?? 0) > 0
            default: return false
            }
        }
    }

    public struct Totals: Equatable, Sendable {
        public var projects = 0
        public var projectsWithRules = 0
        public var projectsSame = 0
        public var projectsDiffer = 0
        public var sessions = 0
        public var measuredSessions = 0
        public var charactersLoaded = 0
        public var edits = 0
        public var editsByProvider: [AgentName: Int] = [:]
        /// Instruction files modified on disk in the period.
        public var filesChanged = 0
    }

    public struct Insight: Identifiable, Equatable, Sendable {
        public var highlight: ActivityHighlight
        /// Project row to select when the insight is clicked.
        public var projectKey: String?
        public var id: String { highlight.id }
    }

    public struct Result: Equatable, Sendable {
        public var rows: [ProjectRow]
        public var totals: Totals
        public var starts: [AgentStart]
        public var insights: [Insight]
        /// Agent edits to instruction files in the period, newest first.
        public var edits: [Edit]
        public var bucketStarts: [Date]
        /// Instruction characters loaded by sessions starting in each bucket.
        public var loadSeries: [Int]
        public var hourly: Bool
        public var coverage: [String]

        public static let empty = Result(rows: [], totals: Totals(), starts: [], insights: [], edits: [], bucketStarts: [], loadSeries: [], hourly: false, coverage: [])

        public func row(_ id: String?) -> ProjectRow? { id.flatMap { key in rows.first { $0.id == key } } }
    }

    public static func build(_ input: Input) -> Result {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone
        let starts = SkillReport.bucketStarts(from: input.from, to: input.to, hourly: input.hourly, calendar: calendar)
        let windowStart = input.from ?? starts.first ?? input.to
        func inPeriod(_ date: Date) -> Bool { date <= input.to && (input.from.map { date >= $0 } ?? true) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let catalog = input.catalog

        let agents: [AgentName] = input.provider == "all" ? [.claude, .codex]
            : [AgentName.claude, .codex].filter { $0.rawValue == input.provider }
        let scoped = input.sessions.filter { session in
            agents.contains(session.provider) && session.createdAt <= input.to
                && (input.from.map { session.updatedAt >= $0 } ?? true)
                && (input.project == "all" || (input.project == ActivityAccountingQuery.unattributedProjectID
                    ? session.projectPath == nil : session.projectPath == input.project))
        }
        let byID = Dictionary(input.sessions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })

        // What each session started with.
        var sessionStarts: [SessionStart] = []
        for session in scoped {
            sessionStarts.append(start(of: session, parent: session.parentSessionID.flatMap { byID[$0] }, catalog: catalog))
        }

        // Agent edits to instruction files.
        var edits: [Edit] = []
        for session in scoped {
            for turn in session.turns {
                guard let time = turn.completedAt ?? turn.startedAt, inPeriod(time) else { continue }
                for artifact in turn.artifacts where artifact.kind != "image" {
                    let path = absolute(artifact.path, project: session.projectPath, home: home)
                    guard InstructionReference.isInstructionFile(path) else { continue }
                    edits.append(Edit(id: "\(session.id)|\(artifact.id)", sessionID: session.id, turnID: turn.id, provider: session.provider,
                                      path: path, projectPath: session.projectPath, timestamp: time, turnStatus: TurnStatus(turn)))
                }
            }
        }
        edits.sort { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }

        // Projects.
        let grouped = Dictionary(grouping: sessionStarts, by: { $0.projectPath ?? "" })
        var rows: [ProjectRow] = []
        for (key, values) in grouped where !key.isEmpty {
            var row = ProjectRow(id: key, instructions: catalog.projects[key])
            for agent in agents {
                let mine = values.filter { $0.provider == agent }
                guard !mine.isEmpty else { continue }
                row.sessions[agent] = mine.count
                let measured = mine.filter(\.measured).compactMap(\.instructionCharacters)
                let any = mine.compactMap(\.instructionCharacters)
                if let median = ActivityMetrics.median((measured.isEmpty ? any : measured).map(Double.init)) {
                    row.perSession[agent] = Int(median.rounded())
                    row.perSessionMeasured[agent] = !measured.isEmpty
                }
            }
            row.charactersLoaded = values.compactMap(\.instructionCharacters).reduce(0, +)
            row.lastActive = values.map(\.startedAt).max()
            var buckets = Array(repeating: 0, count: starts.count)
            for value in values {
                if let index = SkillReport.bucketIndex(max(value.startedAt, windowStart), starts: starts, end: input.to) { buckets[index] += 1 }
            }
            row.buckets = buckets
            row.edits = edits.filter { $0.projectPath == key }
            if let instructions = row.instructions {
                row.lastChanged = (instructions.claude.projectLinks + instructions.codex.projectLinks)
                    .compactMap { catalog.files[$0.path]?.modifiedAt }.max()
                // An agent working here with no project rules while the other has some.
                for agent in agents {
                    let other: AgentName = agent == .claude ? .codex : .claude
                    let theirs = instructions.chain(other).projectLinks
                    guard !theirs.isEmpty else { continue }
                    let empty = values.filter { $0.provider == agent && $0.projectCharacters == 0 }
                    let olderClaude = agent == .claude ? empty.filter { !InstructionReference.claudeReadsAgentsFile($0.clientVersion) } : []
                    if agent == .claude, !olderClaude.isEmpty,
                       instructions.claude.projectLinks.allSatisfy({ $0.reason == .fallback || $0.reason == .imported }) {
                        row.olderClaudeSessions = olderClaude.count
                    } else if !empty.isEmpty, instructions.chain(agent).projectLinks.isEmpty {
                        row.missingSessions[agent] = empty.count
                    }
                }
            }
            rows.append(row)
        }
        rows.sort { lhs, rhs in
            lhs.totalSessions == rhs.totalSessions ? lhs.id < rhs.id : lhs.totalSessions > rhs.totalSessions
        }
        // The files every project gets come first.
        let personal = catalog.personal
        if !(personal.claude.links.isEmpty && personal.codex.links.isEmpty) {
            var row = ProjectRow(id: "~", instructions: personal)
            for agent in agents {
                let count = sessionStarts.filter { $0.provider == agent }.count
                if count > 0 { row.sessions[agent] = count }
                let mine = sessionStarts.filter { $0.provider == agent }
                let measured = mine.filter(\.measured).compactMap { $0.parts?[.personal] }
                let values = measured.isEmpty ? mine.compactMap { $0.parts?[.personal] } : measured
                if let median = ActivityMetrics.median(values.map(Double.init)), median > 0 {
                    row.perSession[agent] = Int(median.rounded())
                    row.perSessionMeasured[agent] = !measured.isEmpty
                }
            }
            row.lastChanged = (personal.claude.links + personal.codex.links).compactMap { catalog.files[$0.path]?.modifiedAt }.max()
            row.edits = edits.filter { edit in (personal.claude.links + personal.codex.links).contains { $0.path == edit.path } }
            rows.insert(row, at: 0)
        }

        // Typical starts by agent.
        var agentStarts: [AgentStart] = []
        for agent in agents {
            let mine = sessionStarts.filter { $0.provider == agent }
            guard !mine.isEmpty else { continue }
            let measured = mine.filter { $0.measured && $0.parts != nil }
            let basis = measured.isEmpty ? mine.filter { $0.parts != nil } : measured
            var parts: [Part: Int] = [:]
            for part in Part.allCases {
                let values = basis.compactMap { $0.parts?[part] }
                if let median = ActivityMetrics.median(values.map(Double.init)), median > 0 { parts[part] = Int(median.rounded()) }
            }
            agentStarts.append(AgentStart(agent: agent, sessions: mine.count, measuredSessions: measured.count, parts: parts))
        }

        var totals = Totals()
        let projectRows = rows.filter { !$0.isPersonal }
        totals.projects = projectRows.count
        totals.projectsWithRules = projectRows.filter { $0.parity != .none }.count
        totals.projectsSame = projectRows.filter { $0.parity == .same }.count
        totals.projectsDiffer = projectRows.filter(\.needsLook).count
        totals.sessions = sessionStarts.count
        totals.measuredSessions = sessionStarts.filter(\.measured).count
        totals.charactersLoaded = sessionStarts.compactMap(\.instructionCharacters).reduce(0, +)
        totals.edits = edits.count
        for edit in edits { totals.editsByProvider[edit.provider, default: 0] += 1 }
        var changed = Set<String>()
        for row in rows {
            for link in (row.instructions?.claude.links ?? []) + (row.instructions?.codex.links ?? []) where link.reason != .memory {
                if let date = catalog.files[link.path]?.modifiedAt, date >= windowStart, date <= input.to { changed.insert(link.path) }
            }
        }
        totals.filesChanged = changed.count

        var coverage = [
            "Claude Code 2.1.260 and later records which instruction files each session loaded and their size. For older versions, and sessions whose record isn't in view, the Hub works it out from the files on disk.",
            "Codex records its combined AGENTS.md text at the start of each task.",
            "Instruction files ride along with every request; providers usually serve the repeats from cache, so each is counted once per session here. Token figures are estimates at about four characters a token.",
        ]
        coverage += catalog.notes
        var series = Array(repeating: 0, count: starts.count)
        for value in sessionStarts {
            guard let characters = value.instructionCharacters,
                  let index = SkillReport.bucketIndex(max(value.startedAt, windowStart), starts: starts, end: input.to) else { continue }
            series[index] += characters
        }
        let insights = makeInsights(rows: rows, totals: totals, starts: agentStarts, catalog: catalog, to: input.to, windowStart: windowStart)
        return Result(rows: rows, totals: totals, starts: agentStarts, insights: insights, edits: Array(edits.prefix(500)),
                      bucketStarts: starts, loadSeries: series, hourly: input.hourly, coverage: coverage)
    }

    // MARK: Session starts

    static func start(of session: ActivitySession, parent: ActivitySession?, catalog: InstructionCatalog) -> SessionStart {
        var value = SessionStart(sessionID: session.id, provider: session.provider, projectPath: session.projectPath,
                                 startedAt: session.createdAt, parts: nil, measured: false,
                                 clientVersion: session.startContext?.clientVersion ?? parent?.startContext?.clientVersion)
        // Sub-agents begin from their parent's context unless they recorded their own.
        let context = session.startContext?.instructionsRecorded == true ? session.startContext
            : (parent?.startContext?.instructionsRecorded == true ? parent?.startContext : nil)
        let skills = session.startContext?.skillListCharacters ?? parent?.startContext?.skillListCharacters
        if let context {
            var parts: [Part: Int] = [:]
            for load in context.instructions {
                switch load.kind {
                case .project, .local: parts[.project, default: 0] += load.characters
                case .personal, .managed: parts[.personal, default: 0] += load.characters
                case .memory: parts[.memory, default: 0] += load.characters
                case .combined:
                    // Codex sends its personal file and the project files as one text.
                    let personal = load.path.isEmpty ? load.characters
                        : min(load.characters, catalog.personal.codex.links.compactMap { catalog.files[$0.path]?.characters }.reduce(0, +))
                    parts[.personal, default: 0] += personal
                    parts[.project, default: 0] += load.characters - personal
                }
            }
            if let skills { parts[.skills] = skills }
            value.parts = parts
            value.measured = true
            return value
        }
        guard let path = session.projectPath, let chain = catalog.projects[path]?.chain(session.provider) else {
            if let skills { value.parts = [.skills: skills] }
            return value
        }
        // Older Claude Code versions don't read AGENTS.md in place of CLAUDE.md.
        let readsFallback = session.provider != .claude || InstructionReference.claudeReadsAgentsFile(value.clientVersion)
        var parts: [Part: Int] = [:]
        for link in chain.links {
            if link.reason == .fallback && !readsFallback { continue }
            if link.reason == .imported, !readsFallback, chain.links.contains(where: { $0.path == link.importedBy && $0.reason == .fallback }) { continue }
            let characters = catalog.files[link.path].map { link.bytesRead >= $0.bytes ? $0.characters : link.bytesRead } ?? link.bytesRead
            switch link.reason {
            case .memory: parts[.memory, default: 0] += characters
            case _ where link.isPersonal: parts[.personal, default: 0] += characters
            default: parts[.project, default: 0] += characters
            }
        }
        if let skills { parts[.skills] = skills }
        value.parts = parts
        return value
    }

    /// "just now", "12m ago", "3h ago", "2d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    static func absolute(_ path: String, project: String?, home: String) -> String {
        let restored = path.replacingOccurrences(of: "/Users/[REDACTED]", with: home)
        if restored.hasPrefix("/") { return restored }
        guard let project else { return restored }
        return URL(fileURLWithPath: project).appendingPathComponent(restored).standardizedFileURL.path
    }

    // MARK: Insights

    static func makeInsights(rows: [ProjectRow], totals: Totals, starts: [AgentStart], catalog: InstructionCatalog,
                             to: Date, windowStart: Date) -> [Insight] {
        var results: [Insight] = []
        let projects = rows.filter { !$0.isPersonal }
        func name(_ row: ProjectRow) -> String { URL(fileURLWithPath: row.id).lastPathComponent }
        func tokens(_ characters: Int) -> String { SkillReport.tokens(max(1, characters / 4)) }
        func mainFile(_ chain: InstructionChain) -> InstructionFile? {
            chain.projectLinks.compactMap { catalog.files[$0.path] }.filter { !$0.isPointer }.max { $0.characters < $1.characters }
        }

        // Each agent following its own rulebook.
        if let row = projects.filter({ $0.parity == .different }).max(by: { $0.totalSessions < $1.totalSessions }),
           let instructions = row.instructions {
            let claude = mainFile(instructions.claude), codex = mainFile(instructions.codex)
            results.append(Insight(highlight: ActivityHighlight(
                kind: .instructionsDiffer, tone: .warning, symbol: "arrow.triangle.branch",
                value: "2 rulebooks",
                title: "Claude and Codex follow different rules in \(name(row))",
                detail: "\(claude.map { "\($0.kind.title) ≈\(tokens($0.characters))" } ?? "Claude's files") · \(codex.map { "\($0.kind.title) ≈\(tokens($0.characters))" } ?? "Codex's files")",
                note: "Claude Code reads CLAUDE.md and Codex reads AGENTS.md. Here they're separate files with different contents, so the agents work to different rules. To keep one set, move the rules into AGENTS.md and make CLAUDE.md a single line: @AGENTS.md"),
                projectKey: row.id))
        }

        // An agent working without the project's rules.
        typealias Gap = (row: ProjectRow, agent: AgentName, sessions: Int, older: Bool)
        var gaps: [Gap] = []
        for row in projects {
            if row.olderClaudeSessions >= 2 { gaps.append((row, .claude, row.olderClaudeSessions, true)) }
            for (agent, count) in row.missingSessions where count >= 2 { gaps.append((row, agent, count, false)) }
        }
        if let gap = gaps.max(by: { $0.sessions < $1.sessions }) {
            let agentName = SkillReport.providerName(gap.agent)
            let detail: String
            let note: String
            if gap.older {
                detail = "They ran a Claude Code version that doesn't read AGENTS.md"
                note = "Claude Code reads AGENTS.md in place of a missing CLAUDE.md from version 2.1.299. Update Claude Code, or add a CLAUDE.md that says @AGENTS.md so every version reads it."
            } else if gap.agent == .codex {
                detail = "Codex reads AGENTS.md; this project only has CLAUDE.md"
                note = "Codex doesn't read CLAUDE.md unless its own settings list it as a fallback name, which the Hub doesn't read. Move the rules into AGENTS.md and make CLAUDE.md say @AGENTS.md: both agents then read one file."
            } else {
                detail = "Claude Code had no project rules here; Codex did"
                note = "Claude Code's project-instructions setting may leave AGENTS.md out. A CLAUDE.md that says @AGENTS.md gives Claude the same rules as Codex."
            }
            results.append(Insight(highlight: ActivityHighlight(
                kind: .instructionsMissing, tone: .warning, symbol: "doc.badge.ellipsis",
                value: "\(gap.sessions) sessions",
                title: "\(agentName) worked without project rules in \(name(gap.row))",
                detail: detail, note: note, provider: gap.agent), projectKey: gap.row.id))
        }

        // Codex stops reading past its limit.
        if let row = projects.filter({ $0.truncatedBytes > 0 }).max(by: { $0.truncatedBytes < $1.truncatedBytes }) {
            let kilobytes = max(1, Int((Double(row.truncatedBytes) / 1_024).rounded()))
            results.append(Insight(highlight: ActivityHighlight(
                kind: .instructionsTruncated, tone: .warning, symbol: "scissors",
                value: "\(kilobytes) KB",
                title: "Codex never reads the end of \(name(row))'s rules",
                detail: "Its AGENTS.md files pass Codex's 32 KB limit",
                note: "Codex stops reading project instructions after 32 KB by default (project_doc_max_bytes in its settings). Anything past that point never reaches the model. Move detail into a skill or a document the file links to.",
                provider: .codex), projectKey: row.id))
        }

        // The heaviest standing context.
        var heaviest: (row: ProjectRow, agent: AgentName, characters: Int)?
        for row in projects {
            for (agent, characters) in row.perSession where (row.sessions[agent] ?? 0) >= 3 && characters >= 12_000 {
                if characters > (heaviest?.characters ?? 0) { heaviest = (row, agent, characters) }
            }
        }
        if let heavy = heaviest {
            let biggest = heavy.row.instructions.flatMap { mainFile($0.chain(heavy.agent)) }
            let memory = heavy.row.instructions?.chain(heavy.agent).links.first { $0.reason == .memory }.flatMap { catalog.files[$0.path] }
            let largest = [biggest, memory].compactMap { $0 }.max { $0.characters < $1.characters }
            let label = largest.map { $0.kind == .memory ? "Claude's memory" : $0.kind.title }
            results.append(Insight(highlight: ActivityHighlight(
                kind: .instructionsHeavy, tone: .notable, symbol: "text.alignleft",
                value: "≈\(tokens(heavy.characters))",
                title: "Rules in every \(SkillReport.providerName(heavy.agent)) session in \(name(heavy.row))",
                detail: "≈\(tokens(heavy.row.charactersLoaded)) in this period\(largest.map { " · largest: \(label ?? "") ≈\(tokens($0.characters))" } ?? "")",
                note: "Instruction files load at the start of every session and stay in context for every request. Keep them to rules the agent needs every time; move occasional detail into a skill or a document the file links to.",
                provider: heavy.agent), projectKey: heavy.row.id))
        }

        // Rules that changed while agents worked.
        if totals.edits > 0, let latest = rows.flatMap(\.edits).max(by: { $0.timestamp < $1.timestamp }) {
            let split = [AgentName.claude, .codex].compactMap { agent -> String? in
                guard let count = totals.editsByProvider[agent], count > 0 else { return nil }
                return "\(SkillReport.providerName(agent)) \(count)"
            }.joined(separator: " · ")
            let files = Set(rows.flatMap(\.edits).map(\.path))
            results.append(Insight(highlight: ActivityHighlight(
                kind: .instructionsEdited, tone: .notable, symbol: "pencil.line",
                value: "\(totals.edits) \(totals.edits == 1 ? "edit" : "edits")",
                title: files.count == 1 ? "Agents edited \(latest.fileName)" : "Agents edited \(files.count) instruction files",
                detail: "\(split) · last \(ago(latest.timestamp, now: to))",
                note: "Recorded agent edits to AGENTS.md, CLAUDE.md and rule files in this period. A change applies from the next session that starts in the project; review it like any other rule change."),
                projectKey: latest.projectPath))
        }

        // A rule file that changed in the period, by how much, and its use since.
        if totals.edits == 0 {
            var latest: (row: ProjectRow, path: String, version: ContextFileVersion)?
            for row in projects {
                guard let instructions = row.instructions else { continue }
                for link in instructions.claude.links + instructions.codex.links where link.reason != .memory {
                    guard let record = catalog.history[link.path], record.versions.count > 1, let version = record.current,
                          version.added != nil, version.changedAt >= windowStart, version.changedAt <= to else { continue }
                    if version.changedAt > (latest?.version.changedAt ?? .distantPast) { latest = (row, link.path, version) }
                }
            }
            if let change = latest {
                let file = (change.path as NSString).lastPathComponent
                let lines = "+\(change.version.added ?? 0) −\(change.version.removed ?? 0)"
                results.append(Insight(highlight: ActivityHighlight(
                    kind: .instructionsEdited, tone: .notable, symbol: "clock.arrow.circlepath",
                    value: lines,
                    title: "\(file) changed in \(name(change.row))",
                    detail: "\(ago(change.version.changedAt, now: to)) · now version \(catalog.history[change.path]?.versions.count ?? 1)",
                    note: "Lines added and removed since the previous version the Hub saw. The new rules apply to sessions started after the change; open the project to see each version and the sessions that ran under it."),
                    projectKey: change.row.id))
            }
        }

        // Every project gives both agents one set of rules.
        let compared = projects.filter { $0.parity != .none }
        if compared.count >= 2, compared.allSatisfy({ $0.parity == .same }), projects.allSatisfy({ !$0.needsLook }) {
            results.append(Insight(highlight: ActivityHighlight(
                kind: .instructionsShared, tone: .positive, symbol: "checkmark.seal",
                value: "\(compared.count) of \(compared.count)",
                title: "Both agents get the same rules",
                detail: "In every project with instruction files",
                note: "Claude Code and Codex read the same project instructions in each of these projects, through a shared AGENTS.md or a CLAUDE.md that imports it."),
                projectKey: nil))
        }

        let order: [ActivityHighlight.Kind] = [.instructionsDiffer, .instructionsMissing, .instructionsTruncated, .instructionsHeavy, .instructionsEdited, .instructionsShared]
        return Array(results.sorted {
            $0.highlight.tone != $1.highlight.tone ? $0.highlight.tone < $1.highlight.tone
                : (order.firstIndex(of: $0.highlight.kind) ?? 0) < (order.firstIndex(of: $1.highlight.kind) ?? 0)
        }.prefix(4))
    }
}
