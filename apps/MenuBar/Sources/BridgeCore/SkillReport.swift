import Foundation

/// Joins the skills each agent can load with the loads recorded in one
/// report scope. Everything here is derived from saved metadata: names,
/// SKILL.md locations, times, turn status and file paths. Correlation with
/// outcomes is reported as such, never as the skill's effect.
public enum SkillReport {
    public struct Input: Sendable {
        /// Scoped sessions with owned turns (see `ReportScope`).
        public var sessions: [ActivitySession]
        public var catalog: SkillCatalog
        public var from: Date?
        public var to: Date
        /// "all" or a provider's raw value.
        public var provider: String
        /// "all", a project path, or `ActivityAccountingQuery.unattributedProjectID`.
        public var project: String
        public var hourly: Bool
        public var timeZone: TimeZone

        public init(sessions: [ActivitySession], catalog: SkillCatalog, from: Date?, to: Date, provider: String = "all",
                    project: String = "all", hourly: Bool = false, timeZone: TimeZone = ActivityAnalytics.reportingTimeZone) {
            self.sessions = sessions; self.catalog = catalog; self.from = from; self.to = to
            self.provider = provider; self.project = project; self.hourly = hourly; self.timeZone = timeZone
        }
    }

    public struct Event: Identifiable, Equatable, Sendable {
        public var id: String
        public var key: String
        public var name: String
        public var provider: AgentName
        public var sessionID: String
        public var turnID: String
        public var projectPath: String?
        public var timestamp: Date
        public var trigger: ActivitySkillUse.Trigger
        public var loadedCharacters: Int?
        public var turnStatus: TurnStatus
    }

    public struct Outcomes: Equatable, Sendable {
        public var finished = 0, failed = 0, interrupted = 0, inProgress = 0, unknown = 0
        public var recorded: Int { finished + failed + interrupted }
        public var total: Int { recorded + inProgress + unknown }
        mutating func add(_ status: TurnStatus) {
            switch status {
            case .finished: finished += 1
            case .failed: failed += 1
            case .interrupted: interrupted += 1
            case .inProgress: inProgress += 1
            case .unknown: unknown += 1
            }
        }
    }

    public struct ProjectShare: Equatable, Sendable, Identifiable {
        public var path: String?
        public var loads: Int
        public var id: String { path ?? "unattributed" }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var summary: String
        /// Installed copies visible in this scope, owned copies first.
        public var copies: [InstalledSkill]
        public var loads = 0
        public var loadsByProvider: [AgentName: Int] = [:]
        public var turns = 0
        public var sessions = 0
        public var projects: [ProjectShare] = []
        public var firstUsed: Date?
        public var lastUsed: Date?
        public var buckets: [Int] = []
        /// Median measured size of the injected text, else the SKILL.md size.
        public var tokensPerLoad: Int?
        public var tokensPerLoadMeasured = false
        public var tokensLoaded: Int?
        public var outcomes = Outcomes()
        public var medianTurnSeconds: Double?
        /// Distinct files changed in the sessions that loaded the skill, in this period.
        public var sessionFilesChanged = 0
        public var edits = 0
        public var lastEdited: Date?
        public var copiesDiffer = false
        /// Agents without a copy that worked in the projects where it was used,
        /// with how many of their sessions that covers.
        public var missingSessions: [AgentName: Int] = [:]

        public var isUsed: Bool { loads > 0 }
        public var installedFor: [AgentName] { Array(Set(copies.map(\.provider))).sorted { $0.rawValue < $1.rawValue } }
        public var usedBy: [AgentName] { loadsByProvider.filter { $0.value > 0 }.map(\.key).sorted { $0.rawValue < $1.rawValue } }
        public var primary: InstalledSkill? { copies.first }
        public var scope: InstalledSkill.Scope? { primary?.scope }
        public var loadsPerSession: Double? { sessions > 0 ? Double(loads) / Double(sessions) : nil }
        public var editedAt: Date? { copies.compactMap(\.modifiedAt).max() }
        /// Re-read often at a size worth trimming, in a copy the person can edit.
        public var isRereadHeavy: Bool {
            (loadsPerSession ?? 0) >= 3 && sessions >= 2 && (tokensPerLoad ?? 0) >= 400 && copies.contains { $0.scope.isOwned }
        }
        /// An agent can't load it where it's used, its copies differ, or it's re-read heavily.
        public var needsLook: Bool { !missingSessions.isEmpty || copiesDiffer || isRereadHeavy }
    }

    public struct Totals: Equatable, Sendable {
        /// Distinct skills installed in scope.
        public var installed = 0
        /// Distinct skills with a load: installed ones plus ones loaded from elsewhere.
        public var used = 0
        public var installedUsed = 0
        public var loads = 0
        public var loadsByProvider: [AgentName: Int] = [:]
        public var sessionsWithSkill = 0
        public var turnsWithSkill = 0
        public var turnsMeasured = 0
        public var turnsInPeriod = 0
        public var tokensLoaded: Int?
        /// Always-on skill list per new session, by agent (personal, plugin and built-in skills).
        public var listingTokens: [AgentName: Int] = [:]
        public var idleOwned = 0
        public var idleOwnedListingTokens = 0
    }

    public struct Insight: Identifiable, Equatable, Sendable {
        public var highlight: ActivityHighlight
        /// Skill to select when the insight is clicked.
        public var skillKey: String?
        public var id: String { highlight.id }
    }

    public struct Result: Equatable, Sendable {
        public var rows: [Row]
        public var totals: Totals
        public var insights: [Insight]
        /// Loads in the period, newest first.
        public var events: [Event]
        public var bucketStarts: [Date]
        public var hourly: Bool
        public var coverage: [String]

        public static let empty = Result(rows: [], totals: Totals(), insights: [], events: [], bucketStarts: [], hourly: false, coverage: [])

        public func events(for key: String, limit: Int = 40) -> [Event] {
            Array(events.lazy.filter { $0.key == key }.prefix(limit))
        }
    }

    public static func build(_ input: Input) -> Result {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone
        let starts = bucketStarts(from: input.from, to: input.to, hourly: input.hourly, calendar: calendar)
        let windowStart = input.from ?? starts.first ?? input.to
        func inPeriod(_ date: Date) -> Bool { date <= input.to && (input.from.map { date >= $0 } ?? true) }

        // Installed copies visible to this scope.
        let copies = input.catalog.skills.filter { skill in
            (input.provider == "all" || skill.provider.rawValue == input.provider)
                && (skill.scope != .project || input.project == "all" || skill.owner == input.project)
        }
        let copiesByKey = Dictionary(grouping: copies, by: \.key)

        // Loads, edits and turn context.
        var events: [Event] = []
        var turnsByKey: [String: [String: ActivityTurn]] = [:]
        var sessionsByKey: [String: Set<String>] = [:]
        var editsByKey: [String: (count: Int, last: Date?)] = [:]
        var totals = Totals()
        var seenTurns = Set<String>()
        var turnsWithSkill = Set<String>()
        var sessionsWithSkill = Set<String>()
        var sessionByID: [String: ActivitySession] = [:]
        for session in input.sessions {
            sessionByID[session.id] = session
            for turn in session.turns {
                guard seenTurns.insert(turn.id).inserted else { continue }
                let turnTime = turn.startedAt ?? turn.completedAt
                if let turnTime, inPeriod(turnTime) {
                    totals.turnsInPeriod += 1
                    if turn.skills != nil { totals.turnsMeasured += 1 }
                }
                for use in turn.skills ?? [] {
                    guard let time = use.timestamp ?? turnTime, inPeriod(time) else { continue }
                    let key = use.key
                    guard !key.isEmpty else { continue }
                    if !use.isLoad {
                        let prior = editsByKey[key]
                        editsByKey[key] = ((prior?.count ?? 0) + 1, max(prior?.last ?? time, time))
                        continue
                    }
                    events.append(Event(id: "\(session.id)|\(use.id)", key: key, name: use.name, provider: session.provider,
                                        sessionID: session.id, turnID: turn.id, projectPath: session.projectPath, timestamp: time,
                                        trigger: use.trigger, loadedCharacters: use.loadedCharacters, turnStatus: TurnStatus(turn)))
                    turnsByKey[key, default: [:]][turn.id] = turn
                    sessionsByKey[key, default: []].insert(session.id)
                    turnsWithSkill.insert(turn.id)
                    sessionsWithSkill.insert(session.id)
                }
            }
        }
        events.sort { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }
        let eventsByKey = Dictionary(grouping: events, by: \.key)

        // Agents' sessions per project, for "can't load it here" gaps.
        var providerSessionsByProject: [AgentName: [String: Set<String>]] = [:]
        for session in input.sessions where session.provider == .claude || session.provider == .codex {
            providerSessionsByProject[session.provider, default: [:]][session.projectPath ?? "", default: []].insert(session.id)
        }

        var rows: [Row] = []
        for key in Set(copiesByKey.keys).union(eventsByKey.keys).union(editsByKey.keys) {
            let installed = (copiesByKey[key] ?? []).sorted(by: copyOrder)
            let loads = eventsByKey[key] ?? []
            var row = Row(id: key, name: installed.first?.name ?? loads.first?.name ?? key, summary: installed.first?.summary ?? "", copies: installed)
            row.loads = loads.count
            for event in loads { row.loadsByProvider[event.provider, default: 0] += 1 }
            row.sessions = sessionsByKey[key]?.count ?? 0
            row.firstUsed = loads.last?.timestamp
            row.lastUsed = loads.first?.timestamp
            row.edits = editsByKey[key]?.count ?? 0
            row.lastEdited = editsByKey[key]?.last

            var byProject: [String: Int] = [:]
            for event in loads { byProject[event.projectPath ?? "", default: 0] += 1 }
            row.projects = byProject.map { ProjectShare(path: $0.key.isEmpty ? nil : $0.key, loads: $0.value) }
                .sorted { $0.loads == $1.loads ? ($0.path ?? "") < ($1.path ?? "") : $0.loads > $1.loads }

            var buckets = Array(repeating: 0, count: starts.count)
            for event in loads {
                if let index = bucketIndex(event.timestamp, starts: starts, end: input.to) { buckets[index] += 1 }
            }
            row.buckets = buckets

            let turns = Array((turnsByKey[key] ?? [:]).values)
            row.turns = turns.count
            for turn in turns { row.outcomes.add(TurnStatus(turn)) }
            row.medianTurnSeconds = ActivityMetrics.median(turns.compactMap { turn in
                turn.durationSeconds ?? zip2(turn.startedAt, turn.completedAt).flatMap { $1 >= $0 ? $1.timeIntervalSince($0) : nil }
            })
            var files = Set<String>()
            for id in sessionsByKey[key] ?? [] {
                for turn in sessionByID[id]?.turns ?? [] {
                    guard let time = turn.startedAt ?? turn.completedAt, inPeriod(time) else { continue }
                    for artifact in turn.artifacts where artifact.kind != "image" { files.insert(artifact.path) }
                }
            }
            row.sessionFilesChanged = files.count

            let measured = loads.compactMap(\.loadedCharacters).map { max(1, $0 / 4) }
            let copyTokens = installed.map(\.loadTokens)
            if let median = ActivityMetrics.median(measured.map(Double.init)) {
                row.tokensPerLoad = Int(median.rounded()); row.tokensPerLoadMeasured = true
            } else if let median = ActivityMetrics.median(copyTokens.map(Double.init)) {
                row.tokensPerLoad = Int(median.rounded())
            }
            if row.loads > 0, let fallback = row.tokensPerLoad {
                row.tokensLoaded = loads.reduce(0) { total, event in
                    let own = event.loadedCharacters.map { max(1, $0 / 4) }
                        ?? installed.first { $0.provider == event.provider }?.loadTokens ?? fallback
                    return total + own
                }
            }

            let owned = installed.filter { $0.scope.isOwned }
            let ownedClaude = Set(owned.filter { $0.provider == .claude }.map(\.fingerprint))
            let ownedCodex = Set(owned.filter { $0.provider == .codex }.map(\.fingerprint))
            row.copiesDiffer = !ownedClaude.isEmpty && !ownedCodex.isEmpty && ownedClaude.isDisjoint(with: ownedCodex)

            if input.provider == "all", row.loads > 0, !owned.isEmpty {
                let projects = Set(row.projects.map { $0.path ?? "" })
                for agent in [AgentName.claude, .codex] where !installed.contains(where: { $0.provider == agent }) && (row.loadsByProvider[agent] ?? 0) == 0 {
                    let sessions = projects.reduce(into: Set<String>()) { $0.formUnion(providerSessionsByProject[agent]?[$1] ?? []) }
                    if !sessions.isEmpty { row.missingSessions[agent] = sessions.count }
                }
            }
            rows.append(row)
        }
        rows.sort(by: rowOrder)

        totals.installed = copiesByKey.count
        totals.used = rows.filter(\.isUsed).count
        totals.installedUsed = rows.filter { $0.isUsed && !$0.copies.isEmpty }.count
        totals.loads = events.count
        for event in events { totals.loadsByProvider[event.provider, default: 0] += 1 }
        totals.turnsWithSkill = turnsWithSkill.count
        totals.sessionsWithSkill = sessionsWithSkill.count
        let loaded = rows.compactMap(\.tokensLoaded)
        totals.tokensLoaded = loaded.isEmpty ? nil : loaded.reduce(0, +)
        for copy in copies where copy.scope != .project { totals.listingTokens[copy.provider, default: 0] += copy.listingTokens }
        let idle = rows.filter { !$0.isUsed && $0.copies.contains { $0.scope == .personal } }
        totals.idleOwned = idle.count
        totals.idleOwnedListingTokens = idle.reduce(0) { $0 + $1.copies.filter { $0.scope == .personal }.reduce(0) { $0 + $1.listingTokens } }

        var coverage = [
            "Claude Code: Skill tool calls and skills started with a slash command, in the transcripts the Hub reads (the newest 40, changed in the last 14 days).",
            "Codex: SKILL.md files the agent read with a command, in saved tasks.",
            "Token figures are estimates at about four characters per token.",
        ]
        if totals.turnsInPeriod > totals.turnsMeasured {
            coverage.append("\((totals.turnsInPeriod - totals.turnsMeasured).formatted()) of \(totals.turnsInPeriod.formatted()) turns in this period were saved before skill tracking or without tool details, so they show no skill loads.")
        }
        coverage += input.catalog.notes

        let insights = makeInsights(rows: rows, totals: totals, from: input.from, to: input.to, windowStart: windowStart)
        return Result(rows: rows, totals: totals, insights: insights, events: Array(events.prefix(2_000)),
                      bucketStarts: starts, hourly: input.hourly, coverage: coverage)
    }

    // MARK: Insights

    static func makeInsights(rows: [Row], totals: Totals, from: Date?, to: Date, windowStart: Date) -> [Insight] {
        var results: [Insight] = []
        let used = rows.filter(\.isUsed)

        // An agent working where a skill helps, without a copy of it.
        typealias Gap = (row: Row, agent: AgentName, sessions: Int)
        var gaps: [Gap] = []
        for row in used {
            // One session is shown on the skill itself; a headline needs a pattern.
            guard let widest = row.missingSessions.max(by: { $0.value < $1.value }), widest.value >= 2 else { continue }
            gaps.append((row, widest.key, widest.value))
        }
        if let gap = gaps.max(by: { $0.sessions == $1.sessions ? $0.row.loads < $1.row.loads : $0.sessions < $1.sessions }) {
            let (row, agent, sessions) = gap
            let other = row.installedFor.first.map(providerName) ?? "another agent"
            let place = row.projects.first?.path.map { URL(fileURLWithPath: $0).lastPathComponent }
            results.append(Insight(highlight: ActivityHighlight(
                kind: .skillGap, tone: .warning, symbol: "arrow.left.arrow.right",
                value: "\(sessions) \(sessions == 1 ? "session" : "sessions")",
                title: "\(providerName(agent)) can't load \(row.name)",
                detail: "\(providerName(agent)) worked \(place.map { "in \($0)" } ?? "in the same projects") · installed for \(other) only",
                note: "\(providerName(agent)) had sessions in the projects where \(other) loaded this skill, but has no copy of it. Both agents read the same SKILL.md format: copy the skill's folder into \(agent == .claude ? "~/.claude/skills" : "~/.codex/skills") or the project's \(agent == .claude ? ".claude/skills" : ".codex/skills") to share it.",
                provider: agent), skillKey: row.id))
        }

        // Heavy re-reading of a large skill.
        if let reread = used.filter(\.isRereadHeavy)
            .max(by: { ($0.tokensLoaded ?? 0) < ($1.tokensLoaded ?? 0) }), let perSession = reread.loadsPerSession {
            let each = reread.tokensPerLoad.map(tokens) ?? "?"
            results.append(Insight(highlight: ActivityHighlight(
                kind: .skillReread, tone: .warning, symbol: "arrow.clockwise",
                value: "\(perSession.formatted(.number.precision(.fractionLength(perSession < 10 ? 1 : 0))))×",
                title: "\(reread.name) is re-read in each session",
                detail: "≈\(each) tokens a read · ≈\(reread.tokensLoaded.map(tokens) ?? "?") in this period",
                note: "Average loads per session that loaded it. Agents often re-read a skill after their context is compacted. A shorter SKILL.md, with detail moved into reference files the agent opens only when needed, costs less each time."),
                skillKey: reread.id))
        }

        // Claude and Codex copies that drifted apart.
        if let drift = rows.filter(\.copiesDiffer).max(by: { $0.loads < $1.loads }) {
            let claude = drift.copies.filter { $0.provider == .claude && $0.scope.isOwned }.compactMap(\.modifiedAt).max()
            let codex = drift.copies.filter { $0.provider == .codex && $0.scope.isOwned }.compactMap(\.modifiedAt).max()
            let newer = (claude ?? .distantPast) > (codex ?? .distantPast) ? "Claude" : "Codex"
            results.append(Insight(highlight: ActivityHighlight(
                kind: .skillDrift, tone: .warning, symbol: "arrow.triangle.branch",
                value: "2 versions",
                title: "\(drift.name) differs between Claude and Codex",
                detail: "The \(newer) copy was edited more recently",
                note: "The SKILL.md files installed for each agent have different contents, so the two agents follow different instructions."),
                skillKey: drift.id))
        }

        // A long always-on skill list, mostly plugins nobody loaded.
        let listing = [AgentName.claude, .codex].compactMap { agent -> (AgentName, Int, Int, Int)? in
            guard let total = totals.listingTokens[agent], total >= 3_000 else { return nil }
            let idle = rows.filter { ($0.loadsByProvider[agent] ?? 0) == 0 }
                .flatMap { $0.copies.filter { $0.provider == agent && $0.scope == .plugin } }
            let idleTokens = idle.reduce(0) { $0 + $1.listingTokens }
            return idleTokens >= 1_000 ? (agent, total, idle.count, idleTokens) : nil
        }.max { $0.1 < $1.1 }
        if let (agent, total, count, idleTokens) = listing {
            results.append(Insight(highlight: ActivityHighlight(
                kind: .skillListing, tone: .notable, symbol: "list.bullet.rectangle",
                value: "≈\(tokens(total))",
                title: "Skill descriptions in every \(providerName(agent)) session",
                detail: "≈\(tokens(idleTokens)) is from \(count) plugin \(count == 1 ? "skill" : "skills") not loaded in this period",
                note: "Every session begins with each installed skill's name and description so the agent can choose one. Turning off plugins you don't use shortens that list for every new session.",
                provider: agent), skillKey: nil))
        }

        // A skill that changed during the period and has been used since.
        if let edited = used.compactMap({ row -> (Row, Date)? in
            guard let date = row.copies.filter({ $0.scope.isOwned }).compactMap(\.modifiedAt).max(),
                  date >= windowStart, date <= to else { return nil }
            return (row, date)
        }).max(by: { $0.1 < $1.1 }) {
            let (row, date) = edited
            let days = max(0, Int(to.timeIntervalSince(date) / 86_400))
            results.append(Insight(highlight: ActivityHighlight(
                kind: .skillEdited, tone: .notable, symbol: "pencil.line",
                value: days == 0 ? "Today" : "\(days)d ago",
                title: "\(row.name) changed recently",
                detail: "\(row.loads) \(row.loads == 1 ? "load" : "loads") in this period · \(row.sessions) \(row.sessions == 1 ? "session" : "sessions")",
                note: "Its SKILL.md was modified in this period. Open it to compare the turns before and after the change."),
                skillKey: row.id))
        }

        // The skill doing most of the work.
        if totals.loads >= 5, let top = used.first {
            let share = Double(top.loads) / Double(totals.loads)
            if share >= 0.4 {
                let agent = top.loadsByProvider.max { $0.value < $1.value }?.key
                let place = top.projects.first?.path.map { URL(fileURLWithPath: $0).lastPathComponent }
                results.append(Insight(highlight: ActivityHighlight(
                    kind: .skillLeader, tone: .neutral, symbol: "star",
                    value: "\(Int((share * 100).rounded()))%",
                    title: used.count == 1 ? "\(top.name) is the only skill in use" : "\(top.name) does most of the skill work",
                    detail: "\(top.loads) of \(totals.loads) loads\(agent.map { " · mostly \(providerName($0))" } ?? "")\(place.map { " in \($0)" } ?? "")",
                    note: "Share of recorded skill loads in this period.", provider: agent), skillKey: top.id))
            }
        }

        // Personal skills nobody loaded.
        let span = to.timeIntervalSince(from ?? .distantPast)
        if totals.idleOwned > 0, span >= 6 * 86_400 {
            results.append(Insight(highlight: ActivityHighlight(
                kind: .skillIdle, tone: .neutral, symbol: "moon.zzz",
                value: "\(totals.idleOwned)",
                title: "\(totals.idleOwned) of your skills \(totals.idleOwned == 1 ? "wasn't" : "weren't") loaded",
                detail: "Their descriptions still add ≈\(tokens(totals.idleOwnedListingTokens)) tokens to each new session",
                note: "Personal skills with no recorded load in this period. Every installed skill's name and description is listed to the agent at the start of each session, used or not."),
                skillKey: nil))
        }

        let order: [ActivityHighlight.Kind] = [.skillGap, .skillReread, .skillDrift, .skillListing, .skillEdited, .skillLeader, .skillIdle]
        return Array(results.sorted {
            $0.highlight.tone != $1.highlight.tone ? $0.highlight.tone < $1.highlight.tone
                : (order.firstIndex(of: $0.highlight.kind) ?? 0) < (order.firstIndex(of: $1.highlight.kind) ?? 0)
        }.prefix(4))
    }

    // MARK: Helpers

    public static func providerName(_ agent: AgentName) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .none: return "Agent"
        }
    }

    /// "820", "4.2k", "1.3M".
    public static func tokens(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000 { return (number / 1_000_000).formatted(.number.precision(.fractionLength(number >= 10_000_000 ? 0 : 1))) + "M" }
        if number >= 1_000 { return (number / 1_000).formatted(.number.precision(.fractionLength(number >= 10_000 ? 0 : 1))) + "k" }
        return value.formatted()
    }

    /// Owned copies first, then plugins, then built-in; Claude before Codex.
    static func copyOrder(_ lhs: InstalledSkill, _ rhs: InstalledSkill) -> Bool {
        func rank(_ scope: InstalledSkill.Scope) -> Int {
            switch scope { case .personal: return 0; case .project: return 1; case .plugin: return 2; case .system: return 3 }
        }
        if rank(lhs.scope) != rank(rhs.scope) { return rank(lhs.scope) < rank(rhs.scope) }
        if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
        return lhs.path < rhs.path
    }

    /// Used skills by loads, then recency; unused skills by name.
    static func rowOrder(_ lhs: Row, _ rhs: Row) -> Bool {
        if lhs.loads != rhs.loads { return lhs.loads > rhs.loads }
        if lhs.lastUsed != rhs.lastUsed { return (lhs.lastUsed ?? .distantPast) > (rhs.lastUsed ?? .distantPast) }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    static func bucketStarts(from: Date?, to: Date, hourly: Bool, calendar: Calendar) -> [Date] {
        if hourly {
            let last = calendar.dateInterval(of: .hour, for: to)?.start ?? to
            return (0 ..< 24).reversed().compactMap { calendar.date(byAdding: .hour, value: -$0, to: last) }
        }
        let lastDay = calendar.startOfDay(for: to)
        let firstDay = from.map { calendar.startOfDay(for: $0) } ?? calendar.date(byAdding: .day, value: -29, to: lastDay) ?? lastDay
        let days = max(1, min(31, (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1))
        return (0 ..< days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: lastDay) }
    }

    static func bucketIndex(_ date: Date, starts: [Date], end: Date) -> Int? {
        guard let first = starts.first, date >= first, date <= end else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= date { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func zip2(_ a: Date?, _ b: Date?) -> (Date, Date)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}
