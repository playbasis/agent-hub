import CoreFoundation
import Foundation

/// Passive reporting adapter. It never loads/resumes a native thread or starts
/// a turn. A helper app-server cannot observe another host's runtime state.
/// Discovery remains partial by design. Separately, the saved overview exposes
/// 250 recent sessions plus focused/pinned sessions and 3,000 turns per session;
/// pagination here does not remove or expand those database presentation bounds.
public struct CodexActivityCollector {
    private let configuration: AgentConfiguration
    private static let recentLimit = 25
    private static let sessionLimit = 90
    private static let turnLimit = 60
    private let pagination: CodexDiscoveryPagination
    typealias Request = (String, [String: Any]?) async throws -> [String: Any]

    public init(configuration: AgentConfiguration) {
        self.configuration = configuration
        pagination = CodexDiscoveryPagination.shared(for: configuration.codexCommand)
    }
    init(configuration: AgentConfiguration, pagination: CodexDiscoveryPagination) {
        self.configuration = configuration
        self.pagination = pagination
    }

    public func collect(now: Date = Date(), knownSessions: [ActivitySession] = []) async -> ActivityCollection {
        let deadline = Date().addingTimeInterval(40)
        do {
            let directory = BridgePaths.providerProbeDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = try Self.reportingExecutable(configuration.codexCommand)
            let connection = try await CodexAppServerSession(
                executable: executable, currentDirectory: directory,
                clientName: "bridge-activity-reader", clientVersion: "activity/1"
            )
            defer { connection.close() }
            return await collect(now: now, knownSessions: knownSessions) { method, params in
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw ReadDeadline.exceeded }
                return try await connection.request(method, params: params, timeoutSeconds: max(1, min(10, Int(remaining))))
            }
        } catch {
            return ActivityCollection(sessions: [], health: ActivitySourceHealth(
                id: "codex-activity", status: "unavailable", checkedAt: now,
                message: "Codex history could not be read: \(TraceRedactor.redact(error.localizedDescription))"
            ))
        }
    }

    // Separate request seam keeps protocol behavior testable without provider
    // calls, credentials, or launching any model execution.
    func collect(now: Date, knownSessions: [ActivitySession], request: Request) async -> ActivityCollection {
        let deadline = Date().addingTimeInterval(40)
        var progress = pagination.snapshot()
        defer { pagination.store(progress) }
        func fetch(_ method: String, _ params: [String: Any]?) async throws -> [String: Any] {
            guard Date() < deadline, !Task.isCancelled else { throw ReadDeadline.exceeded }
            return try await request(method, params)
        }
        var messages: [String] = []
        var accountUsage: ActivityAccountUsage?
        do { accountUsage = CodexActivityParser.account(try await fetch("account/usage/read", nil), now: now) }
        catch { messages.append("Account totals unavailable; local history has separate coverage.") }

        var metadata: [String: [String: Any]] = [:]
        var orderedIDs: [String] = []
        func include(_ object: [String: Any]) {
            guard let id = CodexActivityParser.string(object["id"]) else { return }
            if metadata[id] != nil {
                if object.count > 1 { metadata[id] = object }
                return
            }
            guard orderedIDs.count < Self.sessionLimit else { return }
            metadata[id] = object
            orderedIDs.append(id)
        }
        // The caller places its pinned session first. Open goals remain in the
        // refresh set even when an unrelated busy project fills the recent list.
        var knownSeen = Set<String>()
        let known = knownSessions.filter { $0.provider == .codex && knownSeen.insert($0.nativeID).inserted }
        let activeStates = Set(["active", "running", "inProgress", "in_progress"])
        var prioritySeen = Set<String>()
        let priority = (Array(known.prefix(1)) + known.filter { $0.goal?.isOpen == true || activeStates.contains($0.runtimeState) })
            .filter { prioritySeen.insert($0.nativeID).inserted }
        let selectedPriority = priority.count > 25
            ? Array(priority.prefix(1)) + Self.rotated(Array(priority.dropFirst()), offset: progress.priorityOffset, limit: 24)
            : priority
        if priority.count > 25 {
            progress.priorityOffset = (progress.priorityOffset + 24) % max(1, priority.count - 1)
            messages.append("More than 25 priority tasks are open; the first stays in focus while the others rotate between refreshes.")
        }
        for session in selectedPriority {
            include(["id": session.nativeID])
        }
        let selectedIDs = Set(selectedPriority.map(\.nativeID))
        let olderKnown = known.filter { !selectedIDs.contains($0.nativeID) }
        for session in Self.rotated(olderKnown, offset: progress.knownOffset, limit: 5) { include(["id": session.nativeID]) }
        if !olderKnown.isEmpty { progress.knownOffset = (progress.knownOffset + min(5, olderKnown.count)) % olderKnown.count }
        let deferred = Self.rotated(progress.deferredIDs, offset: progress.deferredOffset, limit: 8)
        for id in deferred { include(["id": id]) }
        if !progress.deferredIDs.isEmpty { progress.deferredOffset = (progress.deferredOffset + min(8, progress.deferredIDs.count)) % progress.deferredIDs.count }

        func listPage(cursor: String?, ancestor: String?, limit: Int) async throws -> (records: [[String: Any]], nextCursor: String?) {
            var params: [String: Any] = [
                "limit": limit, "sortKey": "updated_at", "sortDirection": "desc", "useStateDbOnly": true,
                // Global history must include agents of non-goal roots too;
                // ancestor expansion is enrichment, not their only discovery.
                "sourceKinds": ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"],
            ]
            if let cursor { params["cursor"] = cursor }
            if let ancestor { params["ancestorThreadId"] = ancestor }
            let page = try Self.readPage(try await fetch("thread/list", params))
            guard page.records.count <= limit else {
                throw CodexAppServerSession.RPCError(message: "Native history exceeded the requested page size.")
            }
            return page
        }
        var listingSucceeded = false
        do {
            let first = try await listPage(cursor: nil, ancestor: nil, limit: Self.recentLimit)
            for thread in first.records { include(thread) }
            listingSucceeded = true
            if first.nextCursor != nil {
                messages.append("Root history is paginated; older tasks rotate through a bounded discovery window.")
                if let cursor = progress.root.next ?? first.nextCursor, orderedIDs.count < Self.sessionLimit {
                    do {
                        let older = try await listPage(cursor: cursor, ancestor: nil, limit: min(Self.recentLimit, Self.sessionLimit - orderedIDs.count))
                        for thread in older.records { include(thread) }
                        if !progress.root.advance(consumed: cursor, next: older.nextCursor) {
                            messages.append("Root-history cursor repeated; discovery will restart on the next refresh.")
                        }
                    } catch {
                        progress.root = .init()
                        messages.append("An older root-history page was unavailable or invalid; discovery will restart on the next refresh.")
                    }
                } else if progress.root.next == nil { progress.root.next = first.nextCursor }
            } else { progress.root = .init() }
        } catch { messages.append("Recent-task listing unavailable.") }

        var goals: [String: ActivityGoal] = [:]
        var goalReads = Set<String>()
        var failedGoalReads = Set<String>()
        var goalEndpointUnavailable = false
        for id in orderedIDs {
            if goalEndpointUnavailable || Date() >= deadline { failedGoalReads.insert(id); continue }
            do {
                let value = try await fetch("thread/goal/get", ["threadId": id])
                goals[id] = try Self.readGoalResult(value, nativeID: id)
                goalReads.insert(id)
            } catch {
                failedGoalReads.insert(id)
                goalEndpointUnavailable = Self.endpointUnavailable(error)
            }
        }

        // Discover descendants at every depth for ongoing goals; if there is
        // no goal, include children of the two most recently observed roots.
        let goalRoots = orderedIDs.filter { id in
            goals[id]?.isOpen == true || (failedGoalReads.contains(id) && known.first(where: { $0.nativeID == id })?.goal?.isOpen == true)
        }
        let roots: [String]
        if goalRoots.isEmpty { roots = Array(orderedIDs.filter { metadata[$0]?["parentThreadId"] == nil }.prefix(2)) }
        else {
            roots = Array(goalRoots.prefix(1)) + Self.rotated(Array(goalRoots.dropFirst()), offset: progress.goalOffset, limit: 2)
            if goalRoots.count > 3 { messages.append("Agent trees for additional open goals rotate between refreshes.") }
        }
        var visitedRotatingRoots = 0
        for (rootIndex, root) in roots.enumerated() where orderedIDs.count < Self.sessionLimit {
            if rootIndex > 0 { visitedRotatingRoots += 1 }
            var position = progress.descendants[root] ?? .init()
            let allowance = max(1, (Self.sessionLimit - orderedIDs.count) / (roots.count - rootIndex))
            let freshLimit = min(50, position.next == nil ? allowance : max(1, allowance / 2))
            do {
                let first = try await listPage(cursor: nil, ancestor: root, limit: freshLimit)
                for thread in first.records { include(thread) }
                if first.nextCursor != nil {
                    messages.append("Descendant history is paginated; older agents rotate between refreshes within the 90-task collection limit.")
                    let remaining = min(allowance - freshLimit, Self.sessionLimit - orderedIDs.count)
                    if let cursor = position.next ?? first.nextCursor, remaining > 0 {
                        let older = try await listPage(cursor: cursor, ancestor: root, limit: min(50, remaining))
                        for thread in older.records { include(thread) }
                        if !position.advance(consumed: cursor, next: older.nextCursor) {
                            messages.append("A descendant-history cursor repeated; that tree will restart on the next refresh.")
                        }
                    } else if position.next == nil { position.next = first.nextCursor }
                } else { position = .init() }
                progress.rememberDescendants(position, for: root)
            } catch {
                progress.rememberDescendants(.init(), for: root)
                messages.append("Some descendant-task pages are unavailable or invalid; saved observations were retained.")
                if Self.endpointUnavailable(error) { break }
            }
        }
        if goalRoots.count > 1 {
            progress.goalOffset = (progress.goalOffset + max(1, visitedRotatingRoots)) % (goalRoots.count - 1)
        }
        if orderedIDs.count >= Self.sessionLimit {
            messages.append("Discovery reached the 90-task refresh limit; unvisited pages and deferred tasks continue on later refreshes.")
        }

        var sessions: [ActivitySession] = []
        var transcriptPaths: [String: String] = [:]
        var failures = 0
        var turnsEndpointUnavailable = false
        var hydrated = Set<String>()
        // Open goals retain priority. Deferred discoveries and rotating known
        // tasks are hydrated before repeating unrelated fresh history, so a
        // stable recent page cannot permanently starve older model evidence.
        let descendants = orderedIDs.filter {
            guard let parent = CodexActivityParser.string(metadata[$0]?["parentThreadId"]) else { return false }
            return goalRoots.contains(parent)
        }
        var hydrationSeen = Set<String>()
        let hydrationIDs = ((known.first.map { [$0.nativeID] } ?? []) + goalRoots + deferred + descendants + orderedIDs)
            .filter { metadata[$0] != nil && hydrationSeen.insert($0).inserted }
        for id in hydrationIDs.prefix(Self.sessionLimit) {
            if Task.isCancelled || Date() >= deadline {
                messages.append("Refresh time budget reached; remaining saved tasks will be available on a later refresh.")
                break
            }
            do {
                let response = try await fetch("thread/read", ["threadId": id, "includeTurns": false])
                guard let thread = response["thread"] as? [String: Any],
                      CodexActivityParser.string(thread["id"]) == id else { failures += 1; continue }
                var rawTurns: [[String: Any]] = []
                var nextCursor: String?
                var seenCursors = Set<String>()
                var historyComplete = false
                var warnings: [String] = []
                do {
                    if turnsEndpointUnavailable { throw ReadDeadline.unsupportedHistory }
                    repeat {
                        var params: [String: Any] = [
                            "threadId": id, "limit": min(20, Self.turnLimit - rawTurns.count),
                            "sortDirection": "desc", "itemsView": "summary",
                        ]
                        if let nextCursor { params["cursor"] = nextCursor }
                        let page = try await fetch("thread/turns/list", params)
                        let validated = try Self.readPage(page)
                        let records = validated.records
                        // We explicitly requested summary items. Older servers
                        // omit the discriminator; absence must not imply that
                        // an empty summary establishes zero prompts or tools.
                        rawTurns.append(contentsOf: records.prefix(Self.turnLimit - rawTurns.count).map { record in
                            var record = record
                            if record["itemsView"] == nil { record["itemsView"] = "summary" }
                            return record
                        })
                        nextCursor = validated.nextCursor
                        historyComplete = nextCursor == nil
                        if let nextCursor, !seenCursors.insert(nextCursor).inserted { break }
                        if records.isEmpty { break }
                    } while nextCursor != nil && rawTurns.count < Self.turnLimit
                } catch {
                    warnings.append("Turn history could not be fully loaded.")
                    if Self.endpointUnavailable(error) { turnsEndpointUnavailable = true }
                }
                if !historyComplete { warnings.append("Recent turn window only; session totals are partial.") }
                if goalEndpointUnavailable { failedGoalReads.insert(id) }
                if !goalReads.contains(id) && !failedGoalReads.contains(id) {
                    do {
                        goals[id] = try Self.readGoalResult(try await fetch("thread/goal/get", ["threadId": id]), nativeID: id)
                        goalReads.insert(id)
                    } catch {
                        failedGoalReads.insert(id)
                        if Self.endpointUnavailable(error) { goalEndpointUnavailable = true }
                    }
                }
                if failedGoalReads.contains(id) {
                    warnings.append("Goal state could not be refreshed.")
                    goals[id] = known.first { $0.nativeID == id }?.goal
                }
                if let path = CodexActivityParser.string(thread["path"]) { transcriptPaths[id] = path }
                if let session = CodexActivityParser.session(thread, turns: rawTurns, goal: goals[id],
                    telemetry: CodexActivityTranscript(), historyComplete: historyComplete, now: now, warnings: warnings) {
                    sessions.append(session)
                    hydrated.insert(id)
                }
            } catch {
                failures += 1
                if Self.endpointUnavailable(error) { break }
            }
        }
        var queued = Set<String>()
        progress.deferredIDs = (progress.deferredIDs + orderedIDs)
            .filter { !hydrated.contains($0) && queued.insert($0).inserted }
        if progress.deferredIDs.count > 180 {
            progress.deferredIDs = Array(progress.deferredIDs.prefix(180))
            messages.append("Deferred-discovery capacity reached; history remains partial and later page cycles will revisit omitted tasks.")
        }
        // Complete inexpensive metadata discovery first. Heavy native logs must
        // not hide the goal's agent tree while its token details are imported.
        var pendingStepHistories = 0
        for index in sessions.indices {
            if Date() >= deadline || Task.isCancelled {
                sessions[index].warnings.append("Model and usage enrichment deferred by the refresh time budget.")
                pendingStepHistories += 1
                continue
            }
            let isGoal = sessions[index].goal?.isOpen == true
            let bytes = (isGoal ? 8 : (sessions[index].isChild ? 2 : 1)) * 1_024 * 1_024
            let telemetry = CodexActivityTranscript.read(path: transcriptPaths[sessions[index].nativeID],
                deadline: min(deadline, Date().addingTimeInterval(isGoal ? 1.5 : 0.3)), maximumBytes: UInt64(bytes))
            sessions[index] = CodexActivityParser.enrich(sessions[index], telemetry: telemetry)
            // The instructions and skill list the task started with; read once per rollout.
            if let start = CodexStartContextReader.read(path: transcriptPaths[sessions[index].nativeID]) {
                sessions[index].startContext = sessions[index].startContext.map { $0.merging(start) } ?? start
            }
            // Step identity must come from the file's own context, not its
            // moving tail or the thread's currently configured model. The
            // bounded reader resumes historical progress on later refreshes.
            let priority = isGoal || index == 0
            let steps = CodexModelStepReader.read(path: transcriptPaths[sessions[index].nativeID],
                deadline: min(deadline, Date().addingTimeInterval(priority ? 4 : 0.8)), priority: priority)
            sessions[index] = CodexActivityParser.enrichModelSteps(sessions[index], telemetry: steps)
            if !steps.finished || steps.hitLimit { pendingStepHistories += 1 }
        }
        if pendingStepHistories > 0 {
            messages.append("Model-step details are incomplete for \(pendingStepHistories) tasks; bounded history reading resumes on later refreshes. Counts are observed lower bounds.")
        }
        if failures > 0 { messages.append("\(failures) saved tasks could not be refreshed.") }
        if !failedGoalReads.isEmpty { messages.append("Some native goal states could not be read.") }
        messages.insert("Saved native tasks; live activity in other Codex hosts is not directly observed. Submission counts and tool metadata cover only observed records; human origin is unknown. Tool categories are inferred.", at: 0)
        let succeeded = listingSucceeded || !sessions.isEmpty
        return ActivityCollection(sessions: sessions, health: ActivitySourceHealth(
            id: "codex-activity", status: succeeded ? "partial" : "unavailable", checkedAt: now,
            lastSuccessAt: succeeded ? now : nil, message: Array(Set(messages)).sorted().joined(separator: " ")
        ), accountUsage: accountUsage)
    }

    private enum ReadDeadline: String, LocalizedError {
        case exceeded = "Reporting refresh time budget reached."
        case unsupportedHistory = "Native turn history endpoint is unavailable."
        var errorDescription: String? { rawValue }
    }
    private static func rotated<T>(_ values: [T], offset: Int, limit: Int) -> [T] {
        guard !values.isEmpty, limit > 0 else { return [] }
        let start = max(0, offset) % values.count
        return (0 ..< min(limit, values.count)).map { values[(start + $0) % values.count] }
    }
    private static func endpointUnavailable(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return error is ReadDeadline || ["unknown method", "method not found", "unsupported", "not supported", "did not answer", "unrecognized request"]
            .contains { message.contains($0) }
    }
    private static func readGoalResult(_ result: [String: Any], nativeID: String) throws -> ActivityGoal? {
        if result["goal"] is NSNull { return nil }
        guard let value = CodexActivityParser.goal(result, nativeID: nativeID) else {
            throw CodexAppServerSession.RPCError(message: "Native goal response was missing required fields.")
        }
        return value
    }
    private static func readPage(_ result: [String: Any]) throws -> (records: [[String: Any]], nextCursor: String?) {
        guard let records = result["data"] as? [[String: Any]],
              records.allSatisfy({ CodexActivityParser.string($0["id"]).map { $0.utf8.count <= 4_096 } == true }) else {
            throw CodexAppServerSession.RPCError(message: "Native history response was missing required records or identities.")
        }
        let cursor = result["nextCursor"]
        guard cursor == nil || cursor is NSNull || CodexActivityParser.string(cursor).map({ $0.utf8.count <= 8_192 }) == true else {
            throw CodexAppServerSession.RPCError(message: "Native history response contained an invalid continuation cursor.")
        }
        return (records, CodexActivityParser.string(cursor))
    }
    static func reportingExecutable(_ command: String, desktopCandidates: [URL]? = nil) throws -> URL {
        // Desktop can write a newer history schema than a separately installed
        // npm CLI understands. Its own bundled reader preserves native lineage
        // (older readers can silently return zero descendants). Explicit user
        // executable configuration still takes precedence.
        if command == "codex" {
            let appRoots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
            let candidates = desktopCandidates ?? appRoots.flatMap { root in
                ["ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                                 "Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                                 "Codex.app/Contents/Resources/codex"].map { root.appendingPathComponent($0) }
            }
            for candidate in candidates {
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return try ExecutableLocator.resolve(command)
    }
}

/// Discovery progress only: opaque cursors and native IDs, never transcripts,
/// messages, credentials or provider execution. Each configured client keeps a
/// bounded in-memory work queue; process restart safely begins a new page cycle.
final class CodexDiscoveryPagination: @unchecked Sendable {
    struct Cursor: Sendable {
        var next: String?
        private var consumedHashes: [Int] = []
        init(next: String? = nil) { self.next = next }

        mutating func advance(consumed: String, next: String?) -> Bool {
            let hash = consumed.hashValue
            if !consumedHashes.contains(hash) { consumedHashes.append(hash) }
            if consumedHashes.count > 16 { consumedHashes.removeFirst(consumedHashes.count - 16) }
            guard let next else { self = .init(); return true }
            guard !consumedHashes.contains(next.hashValue) else { self = .init(); return false }
            self.next = next
            return true
        }
    }
    struct Snapshot: Sendable {
        fileprivate var revision: UInt64 = 0
        var root = Cursor()
        var descendants: [String: Cursor] = [:]
        private var descendantOrder: [String] = []
        var priorityOffset = 0
        var knownOffset = 0
        var goalOffset = 0
        var deferredOffset = 0
        var deferredIDs: [String] = []
        init() {}

        mutating func rememberDescendants(_ cursor: Cursor, for id: String) {
            descendantOrder.removeAll { $0 == id }
            if cursor.next == nil { descendants.removeValue(forKey: id); return }
            descendants[id] = cursor
            descendantOrder.append(id)
            while descendantOrder.count > 32 {
                descendants.removeValue(forKey: descendantOrder.removeFirst())
            }
        }
    }
    private let lock = NSLock()
    private var progress = Snapshot()
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return progress }
    func store(_ value: Snapshot) {
        lock.lock(); defer { lock.unlock() }
        // Overlapping app readers must not rewind a newer page cycle. The
        // reporting service normally coalesces them; this is a final safeguard.
        guard value.revision == progress.revision else { return }
        progress = value
        progress.revision &+= 1
    }

    private final class Pool: @unchecked Sendable {
        let lock = NSLock()
        var clients: [String: CodexDiscoveryPagination] = [:]
        var order: [String] = []
    }
    private static let pool = Pool()
    static func shared(for command: String) -> CodexDiscoveryPagination {
        let key = String(command.prefix(4_096))
        pool.lock.lock(); defer { pool.lock.unlock() }
        if let value = pool.clients[key] {
            pool.order.removeAll { $0 == key }; pool.order.append(key)
            return value
        }
        while pool.clients.count >= 16, let oldest = pool.order.first {
            pool.clients.removeValue(forKey: oldest); pool.order.removeFirst()
        }
        let value = CodexDiscoveryPagination()
        pool.clients[key] = value; pool.order.append(key)
        return value
    }
}

enum CodexActivityParser {
    static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue >= 0 ? value.doubleValue : nil
    }
    static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
    static func duration(_ value: Any?) -> Double? {
        guard let value = number(value), value <= 253_402_300_799 else { return nil }
        return value
    }
    static func date(_ value: Any?) -> Date? {
        // Foundation accepts dates far beyond a usable calendar range. Such
        // values must not reach integer goal IDs or duration arithmetic.
        let maximum = 253_402_300_799.0 // End of year 9999.
        if let value = number(value), value <= maximum { return Date(timeIntervalSince1970: value) }
        guard let value = value as? String else { return nil }
        guard let date = ISO8601.date(value),
              (0...maximum).contains(date.timeIntervalSince1970) else { return nil }
        return date
    }
    static func account(_ result: [String: Any], now: Date) -> ActivityAccountUsage? {
        guard let summary = result["summary"] as? [String: Any] else { return nil }
        return ActivityAccountUsage(observedAt: now, lifetimeTokens: integer(summary["lifetimeTokens"]),
            peakDailyTokens: integer(summary["peakDailyTokens"]), longestRunningTurnSeconds: integer(summary["longestRunningTurnSec"]),
            currentStreakDays: integer(summary["currentStreakDays"]), longestStreakDays: integer(summary["longestStreakDays"]),
            daily: (result["dailyUsageBuckets"] as? [[String: Any]] ?? []).compactMap {
                guard let day = string($0["startDate"]), let tokens = integer($0["tokens"]) else { return nil }
                return ActivityAccountDay(date: day, tokens: tokens)
            }.sorted { $0.date < $1.date })
    }
    static func goal(_ result: [String: Any], nativeID: String) -> ActivityGoal? {
        guard let goal = result["goal"] as? [String: Any],
              let objective = string(goal["objective"]), let created = date(goal["createdAt"]),
              let updated = date(goal["updatedAt"]), let status = string(goal["status"]) else { return nil }
        return ActivityGoal(id: "codex:goal:\(nativeID):\(Int(created.timeIntervalSince1970))", sessionID: "codex:\(nativeID)",
            objective: TraceRedactor.redact(objective, maximumCharacters: 2_000), status: status, createdAt: created, updatedAt: updated,
            providerTimeSeconds: duration(goal["timeUsedSeconds"]), tokensUsed: integer(goal["tokensUsed"]), tokenBudget: integer(goal["tokenBudget"]))
    }
    static func session(_ thread: [String: Any], turns rawTurns: [[String: Any]], goal: ActivityGoal?, telemetry: CodexActivityTranscript,
                        historyComplete: Bool, now: Date, warnings: [String] = []) -> ActivitySession? {
        guard let id = string(thread["id"]), let created = date(thread["createdAt"]), let updated = date(thread["updatedAt"]) else { return nil }
        var warnings = warnings
        let source = thread["source"] as? [String: Any]
        let subagent = (source?["subAgent"] ?? source?["subagent"]) as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        let parent = string(thread["parentThreadId"]) ?? string(spawn?["parent_thread_id"])
        let agentLabel = string(spawn?["agent_path"]).map { URL(fileURLWithPath: $0).lastPathComponent.replacingOccurrences(of: "_", with: " ") }
        if string(thread["forkedFromId"]) != nil { warnings.append("Forked conversation: inherited turns share their original evidence IDs.") }
        let state = (thread["status"] as? [String: Any]).flatMap { string($0["type"]) } ?? string(thread["status"]) ?? "unknown"
        if state == "notLoaded" { warnings.append("Not loaded in the reporting helper; activity in the native app is unknown.") }
        var seen = Set<String>()
        let turns = rawTurns.compactMap { turn($0, telemetry: telemetry) }.filter { seen.insert($0.id).inserted }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        return ActivitySession(id: "codex:\(id)", provider: .codex, nativeID: id,
            title: TraceRedactor.redact(string(thread["name"]) ?? agentLabel ?? string(thread["agentNickname"]) ?? goal.map { String($0.objective.prefix(100)) } ?? "Codex \(id.prefix(8))", maximumCharacters: 180),
            projectPath: string(thread["cwd"]), createdAt: created, updatedAt: updated, observedAt: now, runtimeState: state,
            parentSessionID: parent.map { "codex:\($0)" },
            models: Array(Set(turns.compactMap(\.model))).sorted(), efforts: Array(Set(turns.compactMap(\.effort))).sorted(),
            goal: goal, turns: turns, historyComplete: historyComplete, source: "codex-app-server/1", warnings: warnings)
    }
    static func turn(_ raw: [String: Any], telemetry: CodexActivityTranscript = CodexActivityTranscript()) -> ActivityTurn? {
        guard let id = string(raw["id"]) else { return nil }
        let native = telemetry.turns[id]
        let items = raw["items"] as? [[String: Any]] ?? []
        let full = string(raw["itemsView"]) == nil || string(raw["itemsView"]) == "full"
        var seen = Set<String>(), tools = 0, prompts = 0
        var categories: [String: Int] = [:]
        var artifacts: [ActivityArtifact] = []
        var skills: [ActivitySkillUse] = []
        let toolTypes = Set(["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch", "imageView", "imageGeneration", "sleep"])
        for (index, item) in items.enumerated() {
            let itemID = string(item["id"]) ?? "index:\(index)"
            guard seen.insert(itemID).inserted else { continue }
            let type = string(item["type"]) ?? "unknown"
            if type == "userMessage" { prompts += 1 }
            if toolTypes.contains(type) { tools += 1 }
            if let category = category(item) { categories[category, default: 0] += 1 }
            skills += skillUses(item, itemID: itemID) { nil }
            if type == "fileChange" {
                for (offset, change) in (item["changes"] as? [[String: Any]] ?? []).enumerated() {
                    guard let path = string(change["path"]) else { continue }
                    artifacts.append(ActivityArtifact(id: "codex:item:\(itemID):\(offset)", path: TraceRedactor.redact(path, maximumCharacters: 1_024),
                        kind: (change["kind"] as? [String: Any]).flatMap { string($0["type"]) } ?? string(change["kind"]) ?? "file",
                        status: string(item["status"]) ?? "observed"))
                }
            } else if type == "imageGeneration", let path = string(item["savedPath"]) {
                artifacts.append(ActivityArtifact(id: "codex:item:\(itemID)", path: TraceRedactor.redact(path, maximumCharacters: 1_024), kind: "image", status: string(item["status"]) ?? "observed"))
            }
        }
        let start = date(raw["startedAt"]) ?? native?.startedAt
        let end = date(raw["completedAt"]) ?? native?.completedAt
        let duration = number(raw["durationMs"]).flatMap { Self.duration($0 / 1_000) }
            ?? (start != nil && end != nil && end! >= start! ? end!.timeIntervalSince(start!) : nil)
        if !full, let native {
            categories = native.categories
            artifacts = native.artifacts.values.sorted { $0.id < $1.id }
        }
        // Full item views establish a measured list; transcript records add
        // timestamps for the same item IDs.
        let nativeSkills = native.map { Array($0.skills.values) } ?? []
        let skillList: [ActivitySkillUse]? = full || native?.beganInWindow == true ? skills.mergingSkillUses(nativeSkills) : (nativeSkills.isEmpty ? nil : nativeSkills.mergingSkillUses([]))
        var value = ActivityTurn(id: "codex:turn:\(id)", startedAt: start, completedAt: end, durationSeconds: duration,
            status: string(raw["status"]) ?? "unknown",
            promptCount: full ? prompts : [prompts > 0 ? prompts : nil, native?.observedPromptCount].compactMap { $0 }.max(), humanPromptCount: nil,
            toolCount: full ? tools : native?.observedToolCount, model: native?.model, effort: native?.effort,
            usage: native?.usage ?? TokenUsage(), categories: categories, artifacts: artifacts, skills: skillList)
        value.usageIsPartial = telemetry.usageIsPartial(for: id, status: value.status)
        return value
    }
    static func enrich(_ value: ActivitySession, telemetry: CodexActivityTranscript) -> ActivitySession {
        var session = value
        session.warnings.append(contentsOf: telemetry.warnings)
        for index in session.turns.indices {
            let id = String(session.turns[index].id.dropFirst("codex:turn:".count))
            guard let native = telemetry.turns[id] else { continue }
            session.turns[index].model = native.model
            session.turns[index].effort = native.effort
            session.turns[index].usage = native.usage
            session.turns[index].usageIsPartial = telemetry.usageIsPartial(for: id, status: session.turns[index].status)
            if native.beganInWindow {
                session.turns[index].promptCount = [session.turns[index].promptCount, native.observedPromptCount].compactMap { $0 }.max()
                session.turns[index].toolCount = native.observedToolCount
            }
            session.turns[index].categories = native.categories
            session.turns[index].artifacts = native.artifacts.values.sorted { $0.id < $1.id }
            let nativeSkills = Array(native.skills.values)
            if let known = session.turns[index].skills { session.turns[index].skills = known.mergingSkillUses(nativeSkills) }
            else if native.beganInWindow || !nativeSkills.isEmpty { session.turns[index].skills = nativeSkills.mergingSkillUses([]) }
        }
        session.models = Array(Set(session.turns.compactMap(\.model))).sorted()
        session.efforts = Array(Set(session.turns.compactMap(\.effort))).sorted()
        if session.turns.contains(where: { $0.usageIsPartial == true }) {
            session.warnings.append("Some turn usage is a lower bound from incomplete transcript coverage.")
        }
        return session
    }
    /// Codex loads a skill by reading its SKILL.md. Only the skill folder and
    /// path are kept; the command line is discarded after classification.
    /// The timestamp is parsed only when a skill was found: most items aren't.
    static func skillUses(_ item: [String: Any], itemID: String, timestamp: () -> Date?) -> [ActivitySkillUse] {
        let type = string(item["type"]).map { $0.prefix(1).lowercased() + $0.dropFirst() }
        var references: [(name: String, path: String, trigger: ActivitySkillUse.Trigger)] = []
        if type == "commandExecution" {
            let command = item["command"] as? String ?? (item["command"] as? [String])?.joined(separator: " ") ?? ""
            let found = SkillReference.references(inCommand: command)
            references = found.reads.map { ($0.name, $0.path, .read) } + found.edits.map { ($0.name, $0.path, .edit) }
        } else if type == "fileChange" {
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { string($0["path"]) }
            references = SkillReference.edits(inPaths: paths).map { ($0.name, $0.path, .edit) }
        }
        guard !references.isEmpty else { return [] }
        let time = timestamp()
        return references.enumerated().map { offset, reference in
            ActivitySkillUse(id: "codex:item:\(itemID):skill:\(offset)", name: reference.name, trigger: reference.trigger,
                             path: TraceRedactor.redact(reference.path, maximumCharacters: 1_024), timestamp: time)
        }
    }

    static func category(_ item: [String: Any]) -> String? {
        switch string(item["type"]) {
        case "fileChange": return "implementation"
        case "webSearch": return "research"
        case "enteredReviewMode": return "review"
        case "collabAgentToolCall": return "coordination"
        case "commandExecution":
            let command = (string(item["command"]) ?? "").lowercased()
            if command.range(of: #"\b(test|pytest|xctest|jest|vitest|ctest)\b"#, options: .regularExpression) != nil { return "tests" }
            if command.range(of: #"\bgit\s+(diff|show|log|status)\b"#, options: .regularExpression) != nil { return "review" }
            if command.range(of: #"\b(rg|grep|cat|sed|find|head|tail)\b"#, options: .regularExpression) != nil { return "research" }
            return "other tools"
        default: return nil
        }
    }
}

/// Reads only the known rollout returned by app-server. No credential files,
/// prompt text, tool arguments, outputs, or hidden reasoning enter this model.
struct CodexActivityTranscript {
    struct Turn {
        var model: String?
        var effort: String?
        var startedAt: Date?
        var completedAt: Date?
        var usage = TokenUsage()
        var beganInWindow = false
        var completedInWindow = false
        var usageHasGaps = false
        var promptIDs = Set<String>()
        var toolIDs = Set<String>()
        var itemIDs = Set<String>()
        var categories: [String: Int] = [:]
        var artifacts: [String: ActivityArtifact] = [:]
        var skills: [String: ActivitySkillUse] = [:]
        // Older native history modes omit message/tool events. An empty set
        // cannot establish an authoritative zero without a full API item view.
        var observedPromptCount: Int? { beganInWindow && !promptIDs.isEmpty ? promptIDs.count : nil }
        var observedToolCount: Int? { beganInWindow && !toolIDs.isEmpty ? toolIDs.count : nil }
    }
    var turns: [String: Turn] = [:]
    var warnings: [String] = []
    /// A budget stop, malformed relevant record, oversized line, or I/O error
    /// makes completeness unprovable, even if some closed turns were seen.
    var scanTruncated = false
    private var currentTurn: String?
    private var observedUsageTotals = Set<Int>()
    private var previousTotal: Int?

    // Ignore bulky model messages, tool output, and hidden reasoning before
    // JSON decoding. Only reporting events, per-turn context, and user-message
    // IDs are relevant.
    private static let relevantMarkers: [Data] = [
        "\"turn_context\"", "\"task_started\"", "\"task_complete\"", "\"token_count\"", "\"CommandExecution\"", "\"FileChange\"",
        "\"McpToolCall\"", "\"DynamicToolCall\"", "\"CollabAgentToolCall\"", "\"WebSearch\"", "\"ImageGeneration\"", "\"ImageView\"",
        "\"Sleep\"", "\"EnteredReviewMode\"", "\"role\":\"user\"", "\"role\": \"user\"",
    ].map { Data($0.utf8) }

    /// Parsed transcripts keyed by path, size, modification date and byte
    /// window. The Hub refreshes every minute while it is open; an unchanged
    /// file then costs one `stat` instead of a full re-read. Only scans that
    /// finished inside their time budget are kept, since a budget stop depends
    /// on timing rather than on the file.
    private static let cache = TranscriptCache()

    static func read(path: String?, deadline: Date = Date().addingTimeInterval(10), maximumBytes: UInt64 = 8 * 1_024 * 1_024) -> CodexActivityTranscript {
        var result = CodexActivityTranscript()
        guard let path, path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension == "jsonl",
              let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            result.warnings.append("Per-turn model and usage transcript is unavailable."); return result
        }
        defer { try? file.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        var key: TranscriptCache.Key?
        if let size = (attributes?[.size] as? NSNumber)?.uint64Value, let modified = attributes?[.modificationDate] as? Date {
            key = TranscriptCache.Key(path: path, size: size, modified: modified, maximumBytes: maximumBytes)
        }
        if let key, let cached = cache.value(for: key) { return cached }
        var hitDeadline = false, failed = false
        do {
            let length = try file.seekToEnd()
            let start = length > maximumBytes ? length - maximumBytes : 0
            try file.seek(toOffset: start)
            var buffer = Data(), skipFirst = start > 0, oversized = false
            if start > 0 { result.warnings.append("Large transcript: model and token coverage is limited to its most recent \(maximumBytes / 1_024 / 1_024) MiB.") }
            while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
                if Date() >= deadline || Task.isCancelled {
                    result.warnings.append("Transcript scan reached the refresh time budget; usage coverage is partial.")
                    result.scanTruncated = true
                    hitDeadline = true
                    break
                }
                buffer.append(chunk)
                // Walk complete lines with a cursor and drop them once per
                // chunk; removing each line from the front would move the
                // rest of the buffer every time.
                var cursor = buffer.startIndex
                while let newline = buffer[cursor...].firstIndex(of: 10) {
                    let line = buffer[cursor ..< newline]
                    cursor = buffer.index(after: newline)
                    if skipFirst || oversized { skipFirst = false; oversized = false; continue }
                    if relevantMarkers.contains(where: { line.range(of: $0) != nil }) {
                        if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { result.consume(object) }
                        else { result.scanTruncated = true }
                    }
                }
                if cursor > buffer.startIndex { buffer.removeSubrange(buffer.startIndex ..< cursor) }
                if buffer.count > 2 * 1_024 * 1_024 {
                    buffer.removeAll(keepingCapacity: true); oversized = true; result.scanTruncated = true
                }
            }
            // A trailing partial JSONL line belongs to the next refresh.
            if !buffer.isEmpty { result.scanTruncated = true }
        } catch {
            failed = true
            result.scanTruncated = true
            result.warnings.append("Native transcript could not be completely read.")
        }
        if let key, !hitDeadline, !failed { cache.store(result, for: key) }
        return result
    }

    func usageIsPartial(for turnID: String, status: String) -> Bool? {
        guard let turn = turns[turnID], turn.usage.provenance != .unavailable else { return nil }
        let isClosed = ["completed", "failed", "interrupted"].contains(status)
        return scanTruncated || turn.usageHasGaps || !turn.beganInWindow || !turn.completedInWindow
            || turn.startedAt == nil || turn.completedAt == nil || !isClosed
    }

    mutating func consume(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let type = root["type"] as? String
        if type == "turn_context", let id = CodexActivityParser.string(payload["turn_id"]) {
            currentTurn = id
            var turn = turns[id] ?? Turn()
            turn.model = CodexActivityParser.string(payload["model"]) ?? turn.model
            let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
            turn.effort = CodexActivityParser.string(payload["effort"]) ?? CodexActivityParser.string(settings?["reasoning_effort"]) ?? turn.effort
            turns[id] = turn
        } else if type == "event_msg" {
            switch payload["type"] as? String {
            case "task_started":
                guard let id = CodexActivityParser.string(payload["turn_id"]) else { return }
                currentTurn = id
                var turn = turns[id] ?? Turn()
                turn.startedAt = CodexActivityParser.date(payload["started_at"]) ?? turn.startedAt
                turn.beganInWindow = true
                turns[id] = turn
            case "task_complete":
                guard let id = CodexActivityParser.string(payload["turn_id"]) ?? currentTurn else { return }
                var turn = turns[id] ?? Turn()
                turn.startedAt = CodexActivityParser.date(payload["started_at"]) ?? turn.startedAt
                turn.completedAt = CodexActivityParser.date(payload["completed_at"]) ?? turn.completedAt
                turn.completedInWindow = true
                turns[id] = turn
                currentTurn = nil
            case "item_completed":
                guard let id = CodexActivityParser.string(payload["turn_id"]) ?? currentTurn,
                      let item = payload["item"] as? [String: Any] else { return }
                recordItem(item, turnID: id, timestamp: root["timestamp"])
            case "token_count":
                guard let id = currentTurn, let info = payload["info"] as? [String: Any] else { return }
                guard let last = info["last_token_usage"] as? [String: Any],
                      let cumulative = info["total_token_usage"] as? [String: Any],
                      let total = CodexActivityParser.integer(cumulative["total_tokens"]) else {
                    var turn = turns[id] ?? Turn(); turn.usageHasGaps = true; turns[id] = turn
                    return
                }
                // A repeated cumulative total cannot represent additional
                // consumption, even if resumed history fills in new metadata
                // or changes timestamps. Never add the same increment twice.
                guard observedUsageTotals.insert(total).inserted else { return }
                if let previousTotal, total < previousTotal {
                    let warning = "Cumulative token counter reset; ambiguous later measurements were excluded."
                    if !warnings.contains(warning) { warnings.append(warning) }
                    var turn = turns[id] ?? Turn(); turn.usageHasGaps = true; turns[id] = turn
                    return
                }
                var turn = turns[id] ?? Turn()
                let parsed = Self.usage(last)
                let advance = previousTotal.map { total - $0 }
                previousTotal = total
                guard let lastTotal = parsed.total, lastTotal <= total,
                      advance.map({ lastTotal <= $0 }) ?? true else {
                    // An impossible increment must not inflate totals. Keep
                    // earlier receipts and explicitly mark missing coverage.
                    turn.usageHasGaps = true
                    turns[id] = turn
                    return
                }
                if let advance, advance != lastTotal { turn.usageHasGaps = true }
                turn.usage = Self.add(turn.usage, parsed)
                turns[id] = turn
            default: break
            }
        } else if type == "response_item", payload["type"] as? String == "message",
                  payload["role"] as? String == "user", let id = currentTurn,
                  let itemID = CodexActivityParser.string(payload["id"]) {
            var turn = turns[id] ?? Turn()
            turn.promptIDs.insert(itemID)
            turns[id] = turn
        }
    }

    private mutating func recordItem(_ raw: [String: Any], turnID: String, timestamp: Any? = nil) {
        guard let itemID = CodexActivityParser.string(raw["id"]), let rawType = CodexActivityParser.string(raw["type"]) else { return }
        let type = rawType.prefix(1).lowercased() + rawType.dropFirst()
        let tools = Set(["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch", "imageView", "imageGeneration", "sleep"])
        guard tools.contains(type) || type == "enteredReviewMode" else { return }
        var turn = turns[turnID] ?? Turn()
        guard turn.itemIDs.insert(itemID).inserted else { return }
        if tools.contains(type) { turn.toolIDs.insert(itemID) }
        var item: [String: Any] = ["id": itemID, "type": type]
        // Commands are examined only to infer a category, then discarded.
        item["command"] = raw["command"] as? String ?? (raw["command"] as? [String])?.joined(separator: " ")
        if let category = CodexActivityParser.category(item) { turn.categories[category, default: 0] += 1 }
        for use in CodexActivityParser.skillUses(raw, itemID: itemID, timestamp: { CodexActivityParser.date(timestamp) }) { turn.skills[use.id] = use }
        let status = CodexActivityParser.string(raw["status"])?.lowercased() ?? "observed"
        if type == "fileChange" {
            for (offset, change) in (raw["changes"] as? [[String: Any]] ?? []).enumerated() {
                guard let path = CodexActivityParser.string(change["path"]) else { continue }
                let artifactID = "codex:item:\(itemID):\(offset)"
                turn.artifacts[artifactID] = ActivityArtifact(id: artifactID, path: TraceRedactor.redact(path, maximumCharacters: 1_024), status: status)
            }
        } else if type == "imageGeneration", let path = CodexActivityParser.string(raw["saved_path"] ?? raw["savedPath"]) {
            let artifactID = "codex:item:\(itemID)"
            turn.artifacts[artifactID] = ActivityArtifact(id: artifactID, path: TraceRedactor.redact(path, maximumCharacters: 1_024), kind: "image", status: status)
        }
        turns[turnID] = turn
    }

    static func usage(_ value: [String: Any]) -> TokenUsage {
        let input = CodexActivityParser.integer(value["input_tokens"])
        let output = CodexActivityParser.integer(value["output_tokens"])
        let reported = CodexActivityParser.integer(value["total_tokens"])
        let derived: Int?
        if let input, let output {
            let (total, overflow) = input.addingReportingOverflow(output)
            derived = overflow ? nil : total
        } else { derived = nil }
        return TokenUsage(input: input, output: output, cachedInput: CodexActivityParser.integer(value["cached_input_tokens"]),
            cacheWriteInput: CodexActivityParser.integer(value["cache_write_input_tokens"]), reasoning: CodexActivityParser.integer(value["reasoning_output_tokens"]),
            total: reported ?? derived, provenance: reported == nil ? .derived : .providerReported)
    }
    private static func add(_ a: TokenUsage, _ b: TokenUsage) -> TokenUsage {
        if a.provenance == .unavailable { return b }
        func sum(_ a: Int?, _ b: Int?) -> Int? {
            guard let a, let b else { return nil }
            let (value, overflow) = a.addingReportingOverflow(b)
            return overflow ? nil : value
        }
        return TokenUsage(input: sum(a.input, b.input), output: sum(a.output, b.output), cachedInput: sum(a.cachedInput, b.cachedInput),
            cacheWriteInput: sum(a.cacheWriteInput, b.cacheWriteInput), reasoning: sum(a.reasoning, b.reasoning), total: sum(a.total, b.total),
            provenance: a.provenance == .derived || b.provenance == .derived ? .derived : .providerReported)
    }
}

/// Bounded, thread-safe memo for `CodexActivityTranscript.read`.
final class TranscriptCache: @unchecked Sendable {
    struct Key: Hashable {
        var path: String
        var size: UInt64
        var modified: Date
        var maximumBytes: UInt64
    }
    struct Diagnostics: Equatable {
        var entryCount: Int
        /// A conservative retention weight, not a measurement of process RSS.
        var estimatedCostBytes: UInt64
        var maximumEntryCount: Int
        var maximumEstimatedCostBytes: UInt64
    }
    private struct Entry {
        var key: Key
        var value: CodexActivityTranscript
        var cost: UInt64
    }
    private let lock = NSLock()
    /// One parsed window per path. Changing file metadata or read-window size
    /// replaces its prior variant rather than keeping another large parse.
    private var entries: [String: Entry] = [:]
    private var leastRecentFirst: [String] = []
    private var estimatedCostBytes: UInt64 = 0
    private let limit: Int
    private let maximumEstimatedCostBytes: UInt64

    init(limit: Int = 24, maximumEstimatedCostBytes: UInt64 = 16 * 1_024 * 1_024) {
        self.limit = max(0, limit)
        self.maximumEstimatedCostBytes = maximumEstimatedCostBytes
    }

    func value(for key: Key) -> CodexActivityTranscript? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key.path], entry.key == key else { return nil }
        touch(key.path)
        return entry.value
    }

    func store(_ value: CodexActivityTranscript, for key: Key) {
        let cost = Self.retentionWeight(value, key: key)
        lock.lock(); defer { lock.unlock() }
        remove(key.path)
        // A single oversized parse remains usable by its caller but is not
        // cached. It must not flush unrelated useful entries either.
        guard limit > 0, cost <= maximumEstimatedCostBytes else { return }
        while entries.count >= limit || cost > maximumEstimatedCostBytes - estimatedCostBytes {
            guard let oldest = leastRecentFirst.first else { break }
            remove(oldest)
        }
        entries[key.path] = Entry(key: key, value: value, cost: cost)
        leastRecentFirst.append(key.path)
        estimatedCostBytes += cost
    }

    func diagnostics() -> Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return Diagnostics(entryCount: entries.count, estimatedCostBytes: estimatedCostBytes,
            maximumEntryCount: limit, maximumEstimatedCostBytes: maximumEstimatedCostBytes)
    }

    /// Called only while locked. The small count cap keeps order maintenance
    /// bounded; no historical capacity-sized purge is needed.
    private func touch(_ path: String) {
        if let index = leastRecentFirst.firstIndex(of: path) { leastRecentFirst.remove(at: index) }
        leastRecentFirst.append(path)
    }

    private func remove(_ path: String) {
        guard let removed = entries.removeValue(forKey: path) else { return }
        estimatedCostBytes -= removed.cost
        if let index = leastRecentFirst.firstIndex(of: path) { leastRecentFirst.remove(at: index) }
    }

    /// Source-window bytes intentionally over-weight transcripts dominated by
    /// discarded model/tool output. A parsed-metadata estimate also accounts
    /// for dense IDs/sets/artifacts that can expand beyond source bytes. Neither
    /// value claims to be an allocator or resident-memory measurement.
    private static func retentionWeight(_ value: CodexActivityTranscript, key: Key) -> UInt64 {
        var parsed: UInt64 = 4_096
        func add(_ count: Int, bytesEach: UInt64 = 1) {
            let product = UInt64(max(0, count)).multipliedReportingOverflow(by: bytesEach)
            let sum = parsed.addingReportingOverflow(product.partialValue)
            parsed = product.overflow || sum.overflow ? .max : sum.partialValue
        }
        add(key.path.utf8.count)
        for warning in value.warnings { add(warning.utf8.count); add(1, bytesEach: 48) }
        for (id, turn) in value.turns {
            add(1, bytesEach: UInt64(MemoryLayout<CodexActivityTranscript.Turn>.stride) + 128)
            add(id.utf8.count); add(turn.model?.utf8.count ?? 0); add(turn.effort?.utf8.count ?? 0)
            for identifiers in [turn.promptIDs, turn.toolIDs, turn.itemIDs] {
                add(identifiers.count, bytesEach: 64)
                for identifier in identifiers { add(identifier.utf8.count) }
            }
            add(turn.categories.count, bytesEach: 64)
            for category in turn.categories.keys { add(category.utf8.count) }
            for (artifactID, artifact) in turn.artifacts {
                add(1, bytesEach: 256)
                for text in [artifactID, artifact.id, artifact.path, artifact.kind, artifact.status] { add(text.utf8.count) }
            }
            for (useID, use) in turn.skills {
                add(1, bytesEach: 192)
                for text in [useID, use.name, use.path ?? ""] { add(text.utf8.count) }
            }
        }
        return max(64 * 1_024, max(min(key.size, key.maximumBytes), parsed))
    }
}
