import Foundation

public actor ActivityReportingService {
    public static let shared = ActivityReportingService()
    private let databaseURL: URL
    private let claudeCollector = ClaudeActivityCollector()
    private var database: ActivityDatabase?
    private var refreshTask: Task<ActivityOverview, Error>?
    private var repositoryTask: Task<ActivityOverview, Error>?
    private var lastRefresh: Date?
    private var connectionMonitor: ActivityPathMonitor?
    private var connectionRecovery = ActivityConnectionRecoveryPolicy()
    private var lastConfiguration: AgentConfiguration?

    /// Explicit desktop lifecycle only. CLI reads and diagnostic previews do
    /// not start observers or write production connection history.
    public func startConnectionMonitoring() {
        guard connectionMonitor == nil else { return }
        let monitor = ActivityPathMonitor { [weak self] state, date, id in
            guard let self else { return }
            Task { await self.recordConnection(state, at: date, monitorID: id) }
        }
        connectionMonitor = monitor
        connectionRecovery.start(id: monitor.monitorID)
        monitor.start()
    }
    public func stopConnectionMonitoring() {
        connectionMonitor?.stop(); connectionMonitor = nil; connectionRecovery.stop()
    }
    private func recordConnection(_ state: ActivityConnectionHistory.State, at date: Date, monitorID: String) async {
        guard connectionMonitor != nil, let recovered = connectionRecovery.accept(state, at: date, id: monitorID) else { return }
        do { try storage().recordConnection(state, at: date, monitorID: monitorID) }
        catch { /* Connectivity metadata must never break native accounting. */ }
        if recovered, let configuration = lastConfiguration {
            // Ordinary coalesced passive collection, never a resumed model turn.
            _ = try? await refresh(configuration: configuration, force: true)
        }
    }

    public init(databaseURL: URL = BridgePaths.applicationSupport.appendingPathComponent("activity.sqlite")) {
        self.databaseURL = databaseURL
    }
    private func storage() throws -> ActivityDatabase {
        if let database { return database }
        let opened = try ActivityDatabase(url: databaseURL)
        database = opened
        return opened
    }
    public func overview() throws -> ActivityOverview { try storage().overview() }

    public func refresh(configuration: AgentConfiguration, force: Bool = false) async throws -> ActivityOverview {
        try Task.checkCancellation()
        if let task = refreshTask {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 45 { return try overview() }
        let task = Task { try await collect(configuration: configuration) }
        refreshTask = task
        defer { refreshTask = nil }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func collect(configuration: AgentConfiguration) async throws -> ActivityOverview {
        lastConfiguration = configuration
        let now = Date()
        let before = try overview()
        var known = before.sessions
        if let pinned = before.pinnedSessionID, let i = known.firstIndex(where: { $0.id == pinned }) { known.insert(known.remove(at: i), at: 0) }
        let knownSessions = known
        async let codex = CodexActivityCollector(configuration: configuration).collect(now: now, knownSessions: knownSessions)
        async let claude = claudeCollector.collect(now: now)
        let collections = await [codex, claude]
        try Task.checkCancellation()
        let database = try storage()
        // The snapshot includes events discovered during collection. Its as-of
        // time must be collection completion, not a timestamp before those events.
        let completedAt = Date()
        try database.merge(collections, now: completedAt)
        // nil means automatic focus, not a request to create a permanent pin.
        // ActivityOverview resolves it against the latest observed active goal.
        let result = try database.overview()
        lastRefresh = completedAt
        return result
    }

    public func pin(sessionID: String?) throws -> ActivityOverview {
        let database = try storage()
        if let sessionID, !(try database.overview()).sessions.contains(where: { $0.id == sessionID }) {
            throw BridgeError.invalidRequest("Choose a collected session to pin.")
        }
        try database.pin(sessionID)
        return try database.overview()
    }

    /// Explicit action only: local Git commands touch observed project folders.
    /// Keeping this out of startup prevents protected-folder permission storms.
    public func inspectRepositories() async throws -> ActivityOverview {
        try Task.checkCancellation()
        if let task = repositoryTask {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }
        let task = Task { () throws -> ActivityOverview in
            let snapshot = try overview()
            var seen = Set<String>()
            var paths = snapshot.sessions.sorted { $0.updatedAt > $1.updatedAt }
                .compactMap(\.projectPath).filter { seen.insert($0).inserted }
            if let pinned = snapshot.pinnedSession?.projectPath { paths.removeAll { $0 == pinned }; paths.insert(pinned, at: 0) }
            let repositories = await ActivityGitReader().read(paths: Array(paths.prefix(12)))
            try Task.checkCancellation()
            try storage().repositories(repositories)
            return try overview()
        }
        repositoryTask = task
        defer { repositoryTask = nil }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    public func journal() throws -> [ActivityJournalEntry] { try storage().journal() }
    public func publishJournal(now: Date = Date(), timezone: TimeZone = ActivityAnalytics.reportingTimeZone) throws -> ActivityJournalEntry {
        let snapshot = try overview()
        guard !snapshot.sessions.isEmpty else { throw BridgeError.invalidRequest("Refresh activity before creating a report.") }
        return try storage().publish(ActivityJournalBuilder.build(snapshot: snapshot, now: now, timezone: timezone), snapshot: snapshot)
    }

    public func reportEvidence(id: String) throws -> ActivityOverview? { try storage().reportEvidence(id: id) }
}

public enum ActivityJournalBuilder {
    /// Changing prose, scope or calculations creates a new immutable revision,
    /// even when the underlying provider receipts have not changed.
    public static let formatVersion = "daily-brief/3"

    public static func build(snapshot: ActivityOverview, now: Date, timezone: TimeZone) throws -> ActivityJournalEntry {
        try build(snapshot: snapshot, now: now, timezone: timezone, formatVersion: formatVersion)
    }

    static func build(snapshot: ActivityOverview, now: Date, timezone: TimeZone, formatVersion: String) throws -> ActivityJournalEntry {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw BridgeError.invalidRequest("Choose a valid date before creating a daily brief.")
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let start = calendar.startOfDay(for: now)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = timezone; formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        let report = ActivityAccounting.build(overview: snapshot, from: start, to: now)
        let elapsed = report.totals.activeSeconds
        let tokens = report.totals.tokensKnown
        let submissions = report.totals.submittedPrompts
        let human = report.totals.confirmedHumanPrompts
        let tools = report.totals.toolCalls
        let completed = report.nativeObservations.filter { item in
            ["completed", "success"].contains(item.status.lowercased()) && item.completedAt.map { $0 >= start && $0 < now } == true
        }
        let open = snapshot.goals.filter { $0.isOpen && $0.createdAt <= now }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        let participating = Set(report.receipts.map(\.sessionID) + report.nativeObservations.map(\.sessionID) + open.map(\.sessionID))
        let sessions = snapshot.sessions.filter { participating.contains($0.id) }
        let projects = Set(sessions.compactMap(\.projectPath)).sorted()
        let artifacts = Array(Dictionary(report.nativeObservations.filter(\.countersIncludedInWindow).flatMap(\.artifacts).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values).sorted { $0.path < $1.path }
        let commits = snapshot.repositories.sorted { $0.id < $1.id }.flatMap { repo in repo.commits.filter { $0.timestamp >= start && $0.timestamp < now }.sorted { $0.id < $1.id }.map { (repo, $0) } }
        let outcomes = [
            "\(report.totals.sessions) \(report.totals.sessions == 1 ? "session" : "sessions") in scope across \(projects.count) project \(projects.count == 1 ? "folder" : "folders").",
            "\(report.totals.observedModelSteps) observed model steps; \(completed.count) native records finished; \(open.count) \(open.count == 1 ? "goal remains" : "goals remain") open.",
            "\(artifacts.count) recorded file \(artifacts.count == 1 ? "change" : "changes"); \(commits.count) observed Git \(commits.count == 1 ? "commit" : "commits") today.",
        ]
        var body = "# \(BridgeBrand.productName) — Daily brief · \(day)\n\n"
        body += "Time zone: \(safe(timezone.identifier)) · Activity before: \(now.formatted(.iso8601))\n\n"
        body += "Source snapshot collected: \(snapshot.generatedAt.formatted(.iso8601))\n\n"
        body += "## Observed work\n\n" + outcomes.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        body += "## Time and usage\n\n"
        body += "- Recorded time (overlaps counted once): \(seconds(elapsed)).\n"
        body += "- Recorded tokens\(report.totals.tokensArePartial ? " (known subtotal)" : ""): \(number(tokens)); \(report.totals.tokenReceipts) of \(report.totals.usageRecords) normalized usage records reported totals.\n"
        body += "- Observed model steps: \(report.totals.observedModelSteps)\(report.totals.modelStepsArePartial ? " (known lower bound)" : ""); native records supporting this window: \(report.totals.nativeRecords).\n"
        body += "- Requests sent: \(number(submissions)); confirmed human requests: \(number(human)).\n"
        body += "- Recorded tool uses: \(number(tools)).\n"
        let heldCounters = report.totals.unallocatedNativeCounters
        if heldCounters.records > 0 {
            body += "- Unallocated whole-turn counters (not today's totals): requests \(number(heldCounters.submittedPrompts)); confirmed human requests \(number(heldCounters.confirmedHumanPrompts)); tool uses \(number(heldCounters.toolCalls)).\n"
        }
        body += "\nAccounting schema: \(report.schemaVersion), local native history only. Model steps are observed usage advances, not human prompts or exact billable attempts. Tokens use the same normalized receipts as the app, from local midnight up to, but not including, the brief's creation time. Provider event times date model steps; pooled native usage is included only when its entire known interval fits this window. It is not assigned to a guessed model or completion day. Missing values remain unknown. Time uses recorded closed native spans, including waits; a running step with no finish is not assigned a duration. Provider account, plan and goal counters are separate.\n\n"
        body += "## Project activity\n\n"
        for project in projects.prefix(20) {
            let matching = sessions.filter { $0.projectPath == project }
            let projectReport = report.projected(sessionIDs: Set(matching.map(\.id)))
            let models = Set(projectReport.modelRows.filter { $0.requests > 0 }.compactMap(\.name)).sorted().joined(separator: ", ")
            body += "- \(safe(URL(fileURLWithPath: project).lastPathComponent)): \(matching.count) sessions; models reported today: \(models.isEmpty ? "not reported" : safe(models)).\n"
        }
        body += "\n## Goals and carry-forward\n\n"
        for goal in open.prefix(20) {
            body += "- \(safe(goal.objective)) — \(safe(goal.status)); provider-reported time so far: \(seconds(goal.providerTimeSeconds)); reference \(safe(goal.id)).\n"
        }
        if open.isEmpty { body += "No open goals in collected scope.\n" }
        body += "\n## Outputs and evidence\n\n"
        for item in artifacts.prefix(30) { body += "- \(safe(item.path)) — \(safe(item.kind)), \(safe(item.status)); reference \(safe(item.id)).\n" }
        for (repo, commit) in commits.prefix(30) { body += "- \(safe(repo.name)) · \(safe(String(commit.id.prefix(12)))) · \(safe(commit.subject)). The commit is observed; which agent authored it is not confirmed.\n" }
        if artifacts.isEmpty && commits.isEmpty { body += "No dated output evidence in this snapshot. Use Analyze repositories to collect Git observations.\n" }
        body += "\n## Source coverage\n\n"
        for source in snapshot.sources.sorted(by: { $0.id < $1.id }) { body += "- \(safe(source.id)): \(safe(source.status)) — \(safe(source.message))\n" }
        let unavailableHistory = snapshot.repositories.filter { $0.commitHistoryAvailable != true }.count
        if unavailableHistory > 0 { body += "- Git history is unavailable or unverified for \(unavailableHistory) repository observations. An empty receipt list does not establish zero commits.\n" }
        body += "\n\(sessions.filter { !$0.historyComplete }.count) sessions in today's work have incomplete history. An active goal may include pauses or waits; it does not establish continuous work. Goal time shown above is time reported so far, not just today's work.\n\n"
        body += "## Next action\n\n"
        body += open.first.map { "Review the latest evidence for \(safe($0.objective)) and resolve its next outstanding step.\n" } ?? "Review collected outputs and assign any remaining follow-ups.\n"
        let evidence = Array(Set(report.receipts.map(\.id) + report.nativeObservations.map(\.id) + open.map(\.id) + commits.map { $0.0.id + ":" + $0.1.id })).sorted()
        // Hash all measurements, not truncated prose. Fine-grained corrections
        // and artifacts beyond the visible report limits still create revisions.
        var semantic = snapshot
        // Connection heartbeats are chart context, not changed work evidence.
        semantic.connectionHistory = nil
        semantic.generatedAt = .distantPast; semantic.pinnedSessionID = nil
        semantic.sessions = semantic.sessions.sorted { $0.id < $1.id }.map { session in
            var session = session; session.observedAt = .distantPast
            if var goal = session.goal {
                goal.providerTimeSeconds = validSeconds(goal.providerTimeSeconds)
                session.goal = goal
            }
            session.models.sort(); session.efforts.sort(); session.warnings.sort()
            session.turns = session.turns.sorted { $0.id < $1.id }.map { turn in
                var turn = turn; turn.durationSeconds = validSeconds(turn.durationSeconds); turn.artifacts.sort { $0.id < $1.id }
                turn.modelSteps?.sort { $0.id < $1.id }
                return turn
            }
            return session
        }
        semantic.sources = semantic.sources.sorted { $0.id < $1.id }.map { source in
            var source = source; source.checkedAt = .distantPast; source.lastSuccessAt = nil; return source
        }
        // Account counters have a different population and do not create a
        // new local-work brief revision when only that separate scope changes.
        semantic.accountUsage = nil
        semantic.repositories = semantic.repositories.sorted { $0.id < $1.id }.map { repo in
            var repo = repo; repo.observedAt = .distantPast
            repo.worktrees.sort { $0.path < $1.path }
            repo.commits = repo.commits.sorted { $0.id < $1.id }.map { commit in
                var commit = commit; commit.paths.sort(); return commit
            }
            return repo
        }
        // The day/timezone and actual time-window projection are semantic too:
        // the same evidence can produce a different report across a boundary.
        // Collection timestamps alone still do not create duplicate revisions.
        let identity = JournalIdentity(formatVersion: formatVersion, day: day, timezone: timezone.identifier,
            snapshot: semantic, includedSessionIDs: sessions.map(\.id).sorted(),
            evidenceIDs: evidence, elapsedSeconds: elapsed, accountingSchema: report.schemaVersion,
            metricDefinitionsVersion: report.metricDefinitionsVersion)
        let digest = TraceCrypto.digest(try BridgeJSON.compactEncoder.encode(identity))
        return ActivityJournalEntry(id: day + ":1", date: day, revision: 1, generatedAt: now, previousID: nil, supersedesID: nil, timezone: timezone.identifier, snapshotDigest: digest, outcomes: outcomes, continuingGoalIDs: open.map(\.id), evidenceIDs: evidence, markdown: body)
    }
    private struct JournalIdentity: Encodable {
        var formatVersion: String
        var day: String
        var timezone: String
        var snapshot: ActivityOverview
        var includedSessionIDs: [String]
        var evidenceIDs: [String]
        var elapsedSeconds: Double?
        var accountingSchema: String
        var metricDefinitionsVersion: String
    }
    private static func number(_ value: Int?) -> String { value.map { $0.formatted() } ?? "unavailable" }
    private static func validSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return value
    }
    private static func seconds(_ value: Double?) -> String {
        guard let value = validSeconds(value) else { return "not reported" }
        if value > 0 && value < 60 { return "less than 1 min" }
        return "\(Int(value / 60)) min"
    }
    /// Provider-controlled titles, paths and messages are plain text, never
    /// Markdown instructions, links, HTML or additional report sections.
    static func escapedText(_ value: String) -> String { safe(value) }

    private static func safe(_ value: String) -> String {
        let collapsed = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed.prefix(500).reduce(into: "") { output, character in
            if character == "&" { output += "&amp;" }
            else if "\\`*_{}[]()#+-.!|><~".contains(character) { output += "\\" + String(character) }
            else { output.append(character) }
        }
    }
}
