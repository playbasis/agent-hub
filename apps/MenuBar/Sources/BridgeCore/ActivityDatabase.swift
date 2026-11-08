import Foundation
import SQLite3

/// Owned exclusively by ActivityReportingService's actor. Independent CLI
/// readers/writers use separate connections with WAL and bounded busy waits.
final class ActivityDatabase {
    private var db: OpaquePointer?
    private let encoder = BridgeJSON.compactEncoder
    private let decoder = BridgeJSON.decoder
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Decoded sessions with their display turns, reused by `overview()` while
    /// their rows are unchanged. Decoding every turn of every session was the
    /// app's largest steady cost; most refreshes change a handful of sessions.
    private var sessionCache: [String: ActivitySession] = [:]
    /// Sessions this connection wrote since the cache was filled.
    private var staleSessionIDs: Set<String> = []
    /// SQLite's count of other connections' commits (the CLI shares the file).
    private var cachedDataVersion: Int64?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open activity database"
            if let db { sqlite3_close(db) }; db = nil
            throw BridgeError.configuration(message)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(db, 3_000)
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA foreign_keys=ON")
            // Serialize schema discovery and migration across app/CLI connections.
            // Checking the old schema outside this transaction races another opener.
            try exec("BEGIN IMMEDIATE")
            try exec("CREATE TABLE IF NOT EXISTS activity_meta (key TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS activity_sessions (id TEXT PRIMARY KEY, updated REAL NOT NULL, payload BLOB NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS activity_turns (session_id TEXT NOT NULL REFERENCES activity_sessions(id), id TEXT NOT NULL, event_time REAL NOT NULL DEFAULT 0, payload BLOB NOT NULL, PRIMARY KEY(session_id,id))")
            if !hasColumn(table: "activity_turns", name: "event_time") {
                try exec("ALTER TABLE activity_turns ADD COLUMN event_time REAL NOT NULL DEFAULT 0")
                try exec("UPDATE activity_turns SET event_time=COALESCE(CAST(strftime('%s',json_extract(CAST(payload AS TEXT),'$.completedAt')) AS REAL),CAST(strftime('%s',json_extract(CAST(payload AS TEXT),'$.startedAt')) AS REAL),0)")
            }
            try exec("CREATE INDEX IF NOT EXISTS activity_turns_time ON activity_turns(session_id,event_time DESC)")
            try exec("CREATE INDEX IF NOT EXISTS activity_sessions_updated ON activity_sessions(updated DESC)")
            try exec("CREATE TABLE IF NOT EXISTS activity_goals (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload BLOB NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS activity_goal_focus (session_id TEXT PRIMARY KEY, goal_id TEXT NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS activity_journal (id TEXT PRIMARY KEY, day TEXT NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL, UNIQUE(day,revision))")
            try exec("CREATE TABLE IF NOT EXISTS activity_report_evidence (id TEXT PRIMARY KEY REFERENCES activity_journal(id), payload BLOB NOT NULL)")
            try exec("PRAGMA user_version=1")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            if let db { sqlite3_close(db) }; db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    func merge(_ collections: [ActivityCollection], now: Date) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for collection in collections {
                var health = collection.health
                let old: ActivitySourceHealth? = try metadata("source:" + health.id)
                if health.lastSuccessAt == nil {
                    health.lastSuccessAt = old?.lastSuccessAt
                }
                if let success = old?.lastSuccessAt {
                    health.lastSuccessAt = max(success, health.lastSuccessAt ?? success)
                }
                if try !isOlder(health.checkedAt, than: old?.checkedAt) { try setMetadata("source:" + health.id, health) }
                if let usage = collection.accountUsage {
                    let oldUsage: ActivityAccountUsage? = try metadata("codex-account-usage")
                    if try !isOlder(usage.observedAt, than: oldUsage?.observedAt) { try setMetadata("codex-account-usage", usage) }
                }
                for session in collection.sessions {
                    staleSessionIDs.insert(session.id)
                    let stored: [ActivitySession] = try read("SELECT payload FROM activity_sessions WHERE id=?", strings: [session.id])
                    // An older CLI scan can finish after the app's newer scan.
                    // Never replay it over newer metadata, goal state, or turns
                    // (including turns that a complete newer snapshot removed).
                    if try isOlder(session.observedAt, than: stored.first?.observedAt) { continue }
                    let incomingTurns = try reconcilePendingClaudeSubmissions(session)
                    let previousTurns: [ActivityTurn] = session.historyComplete ? try read("SELECT payload FROM activity_turns WHERE session_id=?", strings: [session.id]) : []
                    let previousByID = Dictionary(previousTurns.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                    var metadata = session
                    metadata.turns = []
                    // A moving transcript window can miss the session's start.
                    if let prior = stored.first?.startContext {
                        metadata.startContext = session.startContext.map { prior.merging($0) } ?? prior
                    }
                    try write("INSERT INTO activity_sessions(id,updated,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET updated=excluded.updated,payload=excluded.payload", strings: [session.id], numbers: [session.updatedAt.timeIntervalSince1970], data: encoder.encode(metadata))
                    // A complete provider snapshot supersedes removed turns;
                    // bounded tails merge without losing previously collected history.
                    if session.historyComplete { try write("DELETE FROM activity_turns WHERE session_id=?", strings: [session.id]) }
                    for turn in incomingTurns {
                        let previous: [ActivityTurn] = try read("SELECT payload FROM activity_turns WHERE session_id=? AND id=?", strings: [session.id, turn.id])
                        let prior = previous.first ?? previousByID[turn.id]
                        var reconciled = prior?.merging(turn) ?? turn
                        if isPartialClaudeTranscript(session), let prior {
                            // A moving tail can start after the submission for
                            // an otherwise identical response. Its zero means
                            // "not in this window", not a correction to the
                            // previously observed count. Complete snapshots
                            // can still make authoritative downward corrections.
                            reconciled.promptCount = maximum(prior.promptCount, reconciled.promptCount)
                            reconciled.humanPromptCount = maximum(prior.humanPromptCount, reconciled.humanPromptCount)
                            // The first response snapshot in a moving tail
                            // must not move a known request start forward.
                            reconciled.startedAt = [prior.startedAt, reconciled.startedAt].compactMap { $0 }.min()
                        }
                        let time = (reconciled.completedAt ?? reconciled.startedAt ?? .distantPast).timeIntervalSince1970
                        try write("INSERT INTO activity_turns(session_id,id,event_time,payload) VALUES(?,?,?,?) ON CONFLICT(session_id,id) DO UPDATE SET event_time=excluded.event_time,payload=excluded.payload", strings: [session.id, turn.id], numbers: [time], data: encoder.encode(reconciled))
                    }
                    if let goal = session.goal {
                        try write("INSERT INTO activity_goals(id,session_id,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", strings: [goal.id, session.id], data: encoder.encode(goal))
                        if goal.isOpen { try write("INSERT INTO activity_goal_focus(session_id,goal_id) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET goal_id=excluded.goal_id", strings: [session.id, goal.id]) }
                        else { try write("DELETE FROM activity_goal_focus WHERE session_id=?", strings: [session.id]) }
                    } else {
                        try write("DELETE FROM activity_goal_focus WHERE session_id=?", strings: [session.id])
                    }
                }
            }
            let priorRefresh: Date? = try metadata("last-refresh")
            try setMetadata("last-refresh", max(now, priorRefresh ?? now))
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    private func isPartialClaudeTranscript(_ session: ActivitySession) -> Bool {
        session.provider == .claude && session.source == "claude-local-transcript/1" && !session.historyComplete
    }

    private func maximum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        [lhs, rhs].compactMap { $0 }.max()
    }

    /// Pending submissions are synthetic cache rows, not native turn records.
    /// A bounded refresh may observe their response after the original prompt
    /// has left the transcript tail. Resolve that placeholder only when a
    /// later, timestamped native response establishes progress past it; retain
    /// its known prompt count as a lower bound on that response. Never sum two
    /// overlapping observations or discard an unresolved/undated submission.
    private func reconcilePendingClaudeSubmissions(_ session: ActivitySession) throws -> [ActivityTurn] {
        guard isPartialClaudeTranscript(session) else { return session.turns }
        // The first adapter version double-namespaced this synthetic ID.
        // Recognize both spellings without broad suffix-based row deletion.
        let pendingIDs = ["\(session.id):pending-prompts", "\(session.id):\(session.id):pending-prompts"]
        guard !session.turns.contains(where: { pendingIDs.contains($0.id) }) else { return session.turns }
        let pending: [ActivityTurn] = try read("SELECT payload FROM activity_turns WHERE session_id=? AND id IN (?,?)",
            strings: [session.id] + pendingIDs)
        var turns = session.turns
        for submission in pending {
            guard submission.status == "submission_observed", let count = submission.promptCount, count > 0,
                  submission.usage.total == nil, let submittedAt = submission.startedAt else { continue }
            let candidates = turns.indices.filter { index in
                let response = turns[index]
                guard response.id.hasPrefix("\(session.id):claude-request:"), let started = response.startedAt,
                      started > submittedAt, started <= session.updatedAt, started <= session.observedAt else { return false }
                // A start marker alone cannot establish an actual response.
                return response.status == "completed" || response.usage.output != nil
            }
            let ordered = candidates.sorted(by: {
                let lhs = turns[$0], rhs = turns[$1]
                return lhs.startedAt == rhs.startedAt ? lhs.id < rhs.id : lhs.startedAt! < rhs.startedAt!
            })
            var responseIndex: Int?
            for index in ordered {
                let prior: [ActivityTurn] = try read("SELECT payload FROM activity_turns WHERE session_id=? AND id=?",
                    strings: [session.id, turns[index].id])
                // Continuing snapshots of a request that began before the
                // submission do not establish that it received that prompt.
                if let knownStart = prior.first?.startedAt, knownStart <= submittedAt { continue }
                responseIndex = index
                break
            }
            guard let responseIndex else { continue }
            turns[responseIndex].promptCount = maximum(turns[responseIndex].promptCount, count)
            turns[responseIndex].humanPromptCount = maximum(turns[responseIndex].humanPromptCount, submission.humanPromptCount)
            try write("DELETE FROM activity_turns WHERE session_id=? AND id=?", strings: [session.id, submission.id])
        }
        return turns
    }

    func overview() throws -> ActivityOverview {
        // All component reads must see the same WAL snapshot when a second
        // app/CLI connection commits in parallel.
        try exec("BEGIN DEFERRED")
        do {
            let value = try readOverview()
            try exec("COMMIT")
            return value
        } catch { try? exec("ROLLBACK"); throw error }
    }

    private func readOverview() throws -> ActivityOverview {
        // Another connection's commit can change any row; this connection's
        // own writes mark exactly the sessions they touched.
        let version = try dataVersion()
        if version != cachedDataVersion { sessionCache.removeAll(); cachedDataVersion = version }
        else { for id in staleSessionIDs { sessionCache.removeValue(forKey: id) } }
        staleSessionIDs.removeAll()
        let pinned: String? = try metadata("pinned-session")
        var order = try ids("SELECT id FROM activity_sessions ORDER BY updated DESC,id LIMIT 250")
        var included = Set(order)
        for id in try ids("SELECT s.id FROM activity_sessions s JOIN activity_goal_focus g ON s.id=g.session_id ORDER BY s.updated DESC,s.id")
            + ids("SELECT id FROM activity_sessions WHERE id=?", strings: [pinned ?? ""]) where included.insert(id).inserted { order.append(id) }
        var sessions: [ActivitySession] = []
        sessions.reserveCapacity(order.count)
        for id in order {
            if let cached = sessionCache[id] { sessions.append(cached); continue }
            guard let session = try loadSession(id) else { continue }
            sessionCache[id] = session
            sessions.append(session)
        }
        sessionCache = sessionCache.filter { included.contains($0.key) }
        let sources: [ActivitySourceHealth] = try read("SELECT payload FROM activity_meta WHERE key LIKE 'source:%' ORDER BY key")
        let date: Date? = try metadata("last-refresh")
        let account: ActivityAccountUsage? = try metadata("codex-account-usage")
        let repos: [ActivityRepository]? = try metadata("repositories")
        // Optional sidecar corruption/schema drift cannot hide native work.
        // Keep the stored bytes intact; the observer will fail soft on writes.
        let connection: ActivityConnectionHistory? = try? metadata("connection-history")
        return ActivityOverview(generatedAt: date ?? .distantPast, sessions: sessions, sources: sources, accountUsage: account, repositories: repos ?? [], pinnedSessionID: pinned, connectionHistory: connection)
    }

    func recordConnection(_ state: ActivityConnectionHistory.State, at date: Date, monitorID: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            var history: ActivityConnectionHistory = try metadata("connection-history") ?? .init()
            let before = history
            history.observe(state, at: date, monitorID: monitorID)
            if history != before { try setMetadata("connection-history", history) }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    /// One session with its newest 3,000 turns and identities derived from them.
    private func loadSession(_ id: String) throws -> ActivitySession? {
        guard var session: ActivitySession = try read("SELECT payload FROM activity_sessions WHERE id=?", strings: [id]).first else { return nil }
        let turns: [ActivityTurn] = try read("SELECT payload FROM activity_turns WHERE session_id=? ORDER BY event_time DESC,rowid DESC LIMIT 3001", strings: [id])
        session.turns = Array(turns.prefix(3000)).sorted {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
        }
        // Bounded enrichment may omit model/effort metadata on the next
        // refresh. Retained receipts still establish observed identities.
        // Derive on read so a complete provider history removal can also
        // remove identities that no longer have supporting evidence.
        let stepModels = session.turns.flatMap { ($0.modelSteps ?? []).compactMap(\.model) }
        session.models = Array(Set(session.models + session.turns.compactMap(\.model) + stepModels))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted()
        let stepEfforts = session.turns.flatMap { ($0.modelSteps ?? []).compactMap(\.effort) }
        session.efforts = Array(Set(session.efforts + session.turns.compactMap(\.effort) + stepEfforts))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted()
        if turns.count > 3000 { session.historyComplete = false; session.warnings.append("Display is limited to 3,000 retained turns.") }
        return session
    }

    private func ids(_ sql: String, strings: [String] = []) throws -> [String] {
        let statement = try prepare(sql, strings: strings)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw failure() }
            // Use the stored length: IDs may contain NUL characters.
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            values.append(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self))
        }
    }

    private func dataVersion() throws -> Int64 {
        let statement = try prepare("PRAGMA data_version", strings: [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }

    func pin(_ sessionID: String?) throws {
        if let sessionID { try setMetadata("pinned-session", sessionID) }
        else { try write("DELETE FROM activity_meta WHERE key=?", strings: ["pinned-session"]) }
    }

    func repositories(_ values: [ActivityRepository]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let previous: [ActivityRepository] = try metadata("repositories") ?? []
            var retained = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for value in values {
                let prior = retained[value.id] ?? retained.values.first { $0.root == value.root }
                if try isOlder(value.observedAt, than: prior?.observedAt) { continue }
                var result = value
                if value.commitHistoryAvailable == false, let prior {
                    // Preserve the last known evidence without re-dating it as
                    // a successful fresh read. Unknown remains visibly unknown.
                    result.id = prior.id
                    result.commits = prior.commits
                    if result.worktrees.isEmpty { result.worktrees = prior.worktrees }
                    result.observedAt = prior.observedAt
                    result.warning = "Latest inspection failed; retained evidence is from the last successful observation. " + (value.warning ?? "Git history unavailable.")
                }
                // A formerly inaccessible path acquires its canonical common
                // directory identity once Git becomes readable. Replace the
                // placeholder instead of showing one repository twice.
                if let prior, prior.id != result.id { retained.removeValue(forKey: prior.id) }
                retained[result.id] = result
            }
            try setMetadata("repositories", retained.values.sorted { $0.id < $1.id })
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func journal() throws -> [ActivityJournalEntry] {
        try read("SELECT payload FROM activity_journal ORDER BY day DESC, revision DESC LIMIT 180")
    }

    func publish(_ proposed: ActivityJournalEntry, snapshot: ActivityOverview? = nil) throws -> ActivityJournalEntry {
        try exec("BEGIN IMMEDIATE")
        do {
            let previous: [ActivityJournalEntry] = try read("SELECT payload FROM activity_journal WHERE day=? ORDER BY revision DESC LIMIT 1", strings: [proposed.date])
            if let last = previous.first, last.snapshotDigest == proposed.snapshotDigest {
                try exec("COMMIT"); return last
            }
            let preceding: [ActivityJournalEntry] = try read("SELECT payload FROM activity_journal WHERE day<? ORDER BY day DESC, revision DESC LIMIT 1", strings: [proposed.date])
            var entry = proposed
            entry.revision = (previous.first?.revision ?? 0) + 1
            entry.id = entry.date + ":" + String(entry.revision)
            entry.previousID = preceding.first?.id
            entry.supersedesID = previous.first?.id
            // Keep unresolved follow-ups from the previous published snapshot
            // when its source disappears; absence is not a completion signal.
            if let prior = previous.first ?? preceding.first, let snapshot {
                let terminal = Set(snapshot.goals.filter { !$0.isOpen }.map(\.id))
                let current = Set(entry.continuingGoalIDs)
                let unobserved = prior.continuingGoalIDs.filter { !current.contains($0) && !terminal.contains($0) }
                if !unobserved.isEmpty {
                    entry.continuingGoalIDs.append(contentsOf: unobserved)
                    entry.markdown += "\n## Unresolved carry-forward\n\n"
                    entry.markdown += unobserved.map { "- \(ActivityJournalBuilder.escapedText($0)): no current state in this snapshot; completion has not been established." }.joined(separator: "\n") + "\n"
                }
            }
            entry.markdown += "\n## Report continuity\n\nRevision: \(entry.revision)."
            if let previousID = entry.previousID { entry.markdown += " Previous day report: \(previousID)." }
            if let supersedesID = entry.supersedesID { entry.markdown += " Updates snapshot \(supersedesID); the earlier snapshot is retained." }
            entry.markdown += "\n"
            try write("INSERT INTO activity_journal(id,day,revision,payload) VALUES(?,?,?,?)", strings: [entry.id, entry.date], numbers: [Double(entry.revision)], data: encoder.encode(entry))
            if let snapshot { try write("INSERT INTO activity_report_evidence(id,payload) VALUES(?,?)", strings: [entry.id], data: encoder.encode(snapshot)) }
            try exec("COMMIT")
            return entry
        } catch { try? exec("ROLLBACK"); throw error }
    }

    func reportEvidence(id: String) throws -> ActivityOverview? {
        try read("SELECT payload FROM activity_report_evidence WHERE id=?", strings: [id]).first
    }

    private func metadata<T: Decodable>(_ key: String) throws -> T? { try read("SELECT payload FROM activity_meta WHERE key=?", strings: [key]).first }
    /// ISO-8601 persistence has millisecond precision. Comparing an incoming
    /// sub-millisecond value with an already-rounded stored value can reject
    /// a newer observation. Equal serialized timestamps use last arrival.
    private func isOlder(_ incoming: Date, than stored: Date?) throws -> Bool {
        guard let stored else { return false }
        let normalized = try decoder.decode(Date.self, from: encoder.encode(incoming))
        return normalized < stored
    }
    private func setMetadata<T: Encodable>(_ key: String, _ value: T) throws {
        try write("INSERT INTO activity_meta(key,payload) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", strings: [key], data: encoder.encode(value))
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func hasColumn(table: String, name: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let column = sqlite3_column_text(statement, 1), String(cString: column) == name { return true }
        }
        return false
    }
    private func prepare(_ sql: String, strings: [String], numbers: [Double] = [], data: Data? = nil) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        var index: Int32 = 1
        do {
            func checked(_ result: Int32) throws { guard result == SQLITE_OK else { throw failure() } }
            for string in strings {
                guard let size = Int32(exactly: string.utf8.count) else { throw BridgeError.configuration("Activity database: text value is too large") }
                try checked(sqlite3_bind_text(statement, index, string, size, transient)); index += 1
            }
            for number in numbers { try checked(sqlite3_bind_double(statement, index, number)); index += 1 }
            if let data {
                guard let size = Int32(exactly: data.count) else { throw BridgeError.configuration("Activity database: payload is too large") }
                try checked(data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, size, transient) })
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    private func write(_ sql: String, strings: [String], numbers: [Double] = [], data: Data? = nil) throws {
        let statement = try prepare(sql, strings: strings, numbers: numbers, data: data)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func read<T: Decodable>(_ sql: String, strings: [String] = []) throws -> [T] {
        let statement = try prepare(sql, strings: strings)
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw failure() }
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            values.append(try decoder.decode(T.self, from: Data(bytes: bytes, count: count)))
        }
    }
    private func failure() -> BridgeError { .configuration("Activity database: " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")) }
}
