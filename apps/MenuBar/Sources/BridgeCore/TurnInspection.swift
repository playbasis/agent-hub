import Foundation

// Pure presentation models for inspecting one recorded turn, listing a goal's
// turns, and narrating recent observations. Nothing here reads provider
// files or infers stages that the source did not record.

/// A recorded turn's status in plain words. "Finished" means the provider
/// stopped responding, never that the work was correct.
public enum TurnStatus: String, Sendable, Equatable {
    case finished, failed, interrupted, inProgress, unknown

    public init(_ raw: String, completedAt: Date?) {
        let status = raw.lowercased().filter(\.isLetter)
        if ["failed", "failure", "error", "errored", "timedout", "timeout", "completedwitherror"].contains(status) { self = .failed }
        else if ["interrupted", "cancelled", "canceled", "aborted", "stopped"].contains(status) { self = .interrupted }
        else if ["completed", "complete", "succeeded", "success", "done", "finished"].contains(status) { self = .finished }
        else if ["running", "inprogress", "active", "started", "pending", "streaming"].contains(status) {
            self = completedAt == nil ? .inProgress : .unknown
        } else { self = .unknown }
    }

    public init(_ turn: ActivityTurn) { self.init(turn.status, completedAt: turn.completedAt) }

    public var title: String {
        switch self {
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .inProgress: return "In progress"
        case .unknown: return "Status not recorded"
        }
    }

    public var isProblem: Bool { self == .failed || self == .interrupted }
}

enum RecordedTime {
    /// A usable event time: finite and not after the snapshot.
    static func valid(_ date: Date?, now: Date) -> Date? {
        guard let date, date.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite, date <= now else { return nil }
        return date
    }
}

// MARK: - One turn, in order

/// Model checkpoints, tool executions, requests and replies merged into one
/// chronology. Back-to-back checkpoints collapse into a group. A tool result
/// joins its call only through an explicit recorded ID.
public enum TurnTimeline {
    public struct StepGroup: Identifiable, Equatable, Sendable {
        public let id: String
        public let steps: [ActivityModelStep]
        public let first: Date?
        public let last: Date?
        public var models: [String] {
            var seen = Set<String>()
            return steps.compactMap(\.model).filter { seen.insert($0).inserted }
        }
    }

    public struct Operation: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: WorkEvidenceItem.Kind
        public let title: String
        public let timestamp: Date?
        /// Tool executions only; requests, replies and notices have none.
        public let outcome: WorkOutcomeSignals.Outcome?
        /// The call first, then its results, in page order.
        public let records: [WorkEvidenceItem]
        public var exitCode: Int? { records.compactMap(\.exitCode).first }
        public var durationSeconds: Double? { records.compactMap(\.durationSeconds).first }
        public var isTool: Bool { outcome != nil }
    }

    public enum Entry: Identifiable, Equatable, Sendable {
        case steps(StepGroup)
        case operation(Operation)
        public var id: String {
            switch self {
            case let .steps(group): return group.id
            case let .operation(operation): return operation.id
            }
        }
        public var timestamp: Date? {
            switch self {
            case let .steps(group): return group.first
            case let .operation(operation): return operation.timestamp
            }
        }
    }

    public struct Counts: Equatable, Sendable {
        public var steps = 0
        public var tools = 0
        public var succeeded = 0
        public var failed = 0
        public var interrupted = 0
        public var unknown = 0
    }

    /// Distinct checkpoints, later observations filling earlier gaps.
    public static func steps(_ raw: [ActivityModelStep]?, now: Date) -> [ActivityModelStep] {
        var byID: [String: ActivityModelStep] = [:]
        for step in raw ?? [] {
            if let prior = byID[step.id] { byID[step.id] = prior.merging(step) } else { byID[step.id] = step }
        }
        return byID.values.sorted {
            switch (RecordedTime.valid($0.timestamp, now: now), RecordedTime.valid($1.timestamp, now: now)) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
    }

    public static func build(steps raw: [ActivityModelStep]?, items: [WorkEvidenceItem]?, now: Date, nativeReadAt: Date? = nil) -> [Entry] {
        let ordered = Self.steps(raw, now: now)
        // Native evidence can be newer than the frozen metadata snapshot. Its
        // actual read clock validates those dates without moving checkpoints.
        let nativeClock = nativeReadAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil } ?? now
        let actions = items.map { Self.operations($0, now: nativeClock) } ?? []

        // Dated entries first by time; at equal times a checkpoint precedes
        // the tool it may have requested. Undated entries keep source order.
        enum Payload { case step(ActivityModelStep), operation(Operation) }
        struct Keyed { var date: Date?; var rank: Int; var order: Int; var payload: Payload }
        var keyed = ordered.enumerated().map { Keyed(date: RecordedTime.valid($0.element.timestamp, now: now), rank: 0, order: $0.offset, payload: .step($0.element)) }
        keyed += actions.enumerated().map { Keyed(date: $0.element.timestamp, rank: 1, order: $0.offset, payload: .operation($0.element)) }
        keyed.sort {
            switch ($0.date, $1.date) {
            case let (a?, b?): return a != b ? a < b : $0.rank != $1.rank ? $0.rank < $1.rank : $0.order < $1.order
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.rank != $1.rank ? $0.rank > $1.rank : $0.order < $1.order
            }
        }

        var entries: [Entry] = []
        var run: [ActivityModelStep] = []
        func flush() {
            guard let first = run.first else { return }
            let dates = run.compactMap { RecordedTime.valid($0.timestamp, now: now) }
            entries.append(.steps(StepGroup(id: "steps:" + first.id, steps: run, first: dates.min(), last: dates.max())))
            run = []
        }
        for entry in keyed {
            switch entry.payload {
            case let .step(step): run.append(step)
            case let .operation(operation): flush(); entries.append(.operation(operation))
            }
        }
        flush()
        return entries
    }

    public static func counts(_ entries: [Entry]) -> Counts {
        var counts = Counts()
        for entry in entries {
            switch entry {
            case let .steps(group): counts.steps += group.steps.count
            case let .operation(operation):
                guard let outcome = operation.outcome else { continue }
                counts.tools += 1
                switch outcome {
                case .success: counts.succeeded += 1
                case .failure: counts.failed += 1
                case .interrupted: counts.interrupted += 1
                case .unknown: counts.unknown += 1
                }
            }
        }
        return counts
    }

    private static func operations(_ items: [WorkEvidenceItem], now: Date) -> [Operation] {
        let summary = WorkOutcomeSignals.summarize(items)
        var executionByItem: [String: WorkOutcomeSignals.ToolExecution] = [:]
        for execution in summary.executions { for id in execution.evidenceIDs { executionByItem[id] = execution } }
        var emitted = Set<String>()
        var result: [Operation] = []
        for item in items {
            let isTool = item.kind == .toolCall || item.kind == .toolResult
            if isTool, let execution = executionByItem[item.id] {
                guard emitted.insert(execution.id).inserted else { continue }
                let members = Set(execution.evidenceIDs)
                let records = items.filter { members.contains($0.id) }
                let ordered = records.filter { $0.kind == .toolCall } + records.filter { $0.kind != .toolCall }
                result.append(Operation(id: "op:" + execution.id, kind: .toolCall, title: execution.title,
                                        timestamp: RecordedTime.valid(execution.timestamp, now: now),
                                        outcome: execution.outcome, records: ordered))
            } else {
                guard emitted.insert(item.id).inserted else { continue }
                result.append(Operation(id: "op:" + item.id, kind: item.kind, title: item.title,
                                        timestamp: RecordedTime.valid(item.timestamp, now: now),
                                        outcome: isTool ? .unknown : nil, records: [item]))
            }
        }
        return result
    }
}

// MARK: - A goal's turns

/// One canonical view shared by lists, the feed and the turn drawer. Receipt
/// corrections use the accounting merge; ownership follows observed provider-
/// safe parent edges, never session creation dates or unrelated duplicate IDs.
public struct TurnInspectionRecords: Sendable {
    public let sessions: [ActivitySession]
    public let byID: [String: ActivitySession]
    public let parents: [String: String]
    public let ownedTurns: [String: [ActivityTurn]]
    private let receipts: [AgentName: [String: ActivityTurn]]

    public init(_ observations: [ActivitySession]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Stamp: Hashable { var id: String; var observed: Double?; var updated: Double? }
        func finite(_ date: Date) -> Double? { date.timeIntervalSince1970.isFinite ? date.timeIntervalSince1970 : nil }
        func stamp(_ session: ActivitySession) -> Stamp { Stamp(id: session.id, observed: finite(session.observedAt), updated: finite(session.updatedAt)) }
        let multiplicity = Dictionary(grouping: observations, by: stamp).mapValues(\.count)
        // Full receipt arrays are not metadata sort keys. Only encode actual
        // same-identity/time ties, never every session on each drawer step.
        let keyed = observations.map { ($0, multiplicity[stamp($0), default: 0] > 1 ? ((try? encoder.encode($0)) ?? Data()) : Data()) }
        let ordered = keyed.sorted {
            let a = finite($0.0.observedAt) ?? -Double.greatestFiniteMagnitude, b = finite($1.0.observedAt) ?? -Double.greatestFiniteMagnitude
            if a != b { return a < b }
            if $0.0.id != $1.0.id { return $0.0.id < $1.0.id }
            let x = finite($0.0.updatedAt) ?? -Double.greatestFiniteMagnitude, y = finite($1.0.updatedAt) ?? -Double.greatestFiniteMagnitude
            if x != y { return x < y }
            return $0.1.lexicographicallyPrecedes($1.1)
        }.map(\.0)
        var byID: [String: ActivitySession] = [:]
        for candidate in ordered {
            var value = candidate
            if let prior = byID[candidate.id], !candidate.historyComplete {
                var turns: [String: ActivityTurn] = [:]
                for turn in prior.turns + candidate.turns { turns[turn.id] = turns[turn.id]?.merging(turn) ?? turn }
                value.turns = turns.values.sorted { $0.id < $1.id }
            }
            byID[candidate.id] = value
        }
        self.byID = byID
        let canonical = byID.values.sorted { $0.id < $1.id }
        sessions = canonical
        parents = ActivityAnalytics.sessionParents(in: canonical)
        ownedTurns = ActivityAnalytics.ownedTurnsBySession(in: ordered)
        receipts = Dictionary(grouping: ordered, by: \.provider).mapValues {
            Dictionary(uniqueKeysWithValues: ActivityMetrics.uniqueTurns($0).map { ($0.id, $0) })
        }
    }

    /// Includes copies retained by this session, with their latest merged
    /// fields. It does not add another session's unrelated turns.
    public func turns(in sessionID: String) -> [ActivityTurn] {
        guard let session = byID[sessionID] else { return [] }
        var seen = Set<String>()
        return session.turns.compactMap { turn in
            guard seen.insert(turn.id).inserted else { return nil }
            return receipts[session.provider]?[turn.id] ?? turn
        }
    }

    public func owner(of turnID: String, in sessionID: String) -> ActivitySession? {
        guard let session = byID[sessionID], session.turns.contains(where: { $0.id == turnID }) else { return nil }
        var owner = session
        var cursor = parents[sessionID]
        var visited: Set<String> = [sessionID]
        while let id = cursor, visited.insert(id).inserted, let ancestor = byID[id] {
            if ancestor.turns.contains(where: { $0.id == turnID }) { owner = ancestor }
            cursor = parents[id]
        }
        return owner
    }

    static func identity(_ parts: String...) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// Recorded turns across a goal's lead and helper sessions, newest first.
/// A turn copied into a child is credited to its observed owning ancestor.
public enum GoalTurnList {
    public enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All", problems = "Problems", tools = "Used tools", long = "Over 10 min"
        public var id: String { rawValue }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let sessionID: String
        public let turnID: String
        public let provider: AgentName
        public let start: Date
        public let end: Date?
        public let status: TurnStatus
        public let model: String?
        public let category: String?
        public let toolCount: Int?
        public let stepCount: Int?
        public var duration: TimeInterval? { end.map { max(0, $0.timeIntervalSince(start)) } }
    }

    public static let longTurnSeconds: TimeInterval = 600

    public static func rows(sessions: [ActivitySession], from: Date, to: Date, now: Date, limit: Int = 5_000) -> [Row] {
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, from <= to, limit > 0 else { return [] }
        let records = TurnInspectionRecords(sessions)
        var rows: [Row] = []
        for session in records.sessions {
            for turn in records.ownedTurns[session.id] ?? [] {
                guard let start = RecordedTime.valid(turn.startedAt, now: now) else { continue }
                let end = RecordedTime.valid(turn.completedAt, now: now).flatMap { $0 >= start ? $0 : nil }
                guard start <= to, (end ?? start) >= from else { continue }
                let steps = turn.modelSteps.map { Set($0.map(\.id)).count }
                rows.append(Row(id: TurnInspectionRecords.identity(session.provider.rawValue, session.id, turn.id), sessionID: session.id, turnID: turn.id, provider: session.provider,
                                start: start, end: end, status: TurnStatus(turn),
                                model: Self.singleModel(turn),
                                category: ActivityAnalytics.dominantCategory(turn),
                                toolCount: turn.toolCount.flatMap { $0 >= 0 ? $0 : nil }, stepCount: steps))
            }
        }
        rows.sort { $0.start == $1.start ? $0.id > $1.id : $0.start > $1.start }
        return Array(rows.prefix(min(5_000, limit)))
    }

    public static func matches(_ row: Row, _ filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .problems: return row.status.isProblem
        case .tools: return (row.toolCount ?? 0) > 0
        case .long: return (row.duration ?? 0) >= longTurnSeconds
        }
    }
    static func singleModel(_ turn: ActivityTurn) -> String? {
        let models = Set(([turn.model] + (turn.modelSteps ?? []).map(\.model)).compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }; return value
        })
        return models.count == 1 ? models.first : nil
    }

    /// One canonical record per session ID, retaining bounded older receipts.
    static func deduplicated(_ sessions: [ActivitySession]) -> [ActivitySession] {
        TurnInspectionRecords(sessions).sessions
    }
}

/// Chronological neighbours of one turn inside its own session.
public enum TurnSequence {
    /// Dated turns oldest first, then undated turns in source order.
    public static func ordered(_ session: ActivitySession, now: Date) -> [ActivityTurn] {
        let indexed = session.turns.enumerated().map { (offset: $0.offset, turn: $0.element, date: RecordedTime.valid($0.element.startedAt, now: now)) }
        var seen = Set<String>()
        return indexed.sorted {
            switch ($0.date, $1.date) {
            case let (a?, b?): return a == b ? $0.offset < $1.offset : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.offset < $1.offset
            }
        }.map(\.turn).filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Recent observations

/// "Just happened": turn starts, finishes, failures and new sub-agents taken
/// from recorded times. Metadata only: no prompt or result text.
public enum LiveFeed {
    public enum Kind: String, Sendable {
        case started, finished, failed, interrupted, joined
    }

    public struct Event: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: Kind
        /// The newest observation folded into this event.
        public let date: Date
        public let sessionID: String
        /// The newest folded turn; nil for a new sub-agent.
        public let turnID: String?
        public let provider: AgentName
        public let title: String
        public let projectPath: String?
        public let isHelper: Bool
        /// Observations of the same kind from one session within ten minutes.
        public let count: Int
    }

    public static let mergeWindow: TimeInterval = 600

    public static func events(sessions: [ActivitySession], now: Date, window: TimeInterval = 3_600, limit: Int = 12) -> [Event] {
        guard now.timeIntervalSince1970.isFinite, window.isFinite, window > 0, limit > 0 else { return [] }
        let horizon = now.addingTimeInterval(-window)
        let records = TurnInspectionRecords(sessions)
        let all = records.sessions
        let titles = Dictionary(all.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        struct Raw { var id: String; var kind: Kind; var date: Date; var session: ActivitySession; var turnID: String? }
        var raw: [Raw] = []
        for session in all {
            if session.isChild, let created = RecordedTime.valid(session.createdAt, now: now), created >= horizon {
                raw.append(Raw(id: "joined:" + session.id, kind: .joined, date: created, session: session, turnID: nil))
            }
            for turn in records.ownedTurns[session.id] ?? [] {
                let identity = TurnInspectionRecords.identity(session.provider.rawValue, session.id, turn.id)
                if let start = RecordedTime.valid(turn.startedAt, now: now), start >= horizon {
                    raw.append(Raw(id: "started:" + identity, kind: .started, date: start, session: session, turnID: turn.id))
                }
                if let end = RecordedTime.valid(turn.completedAt, now: now), end >= horizon,
                   RecordedTime.valid(turn.startedAt, now: now).map({ end >= $0 }) ?? true {
                    let kind: Kind
                    switch TurnStatus(turn) {
                    case .failed: kind = .failed
                    case .interrupted: kind = .interrupted
                    case .finished: kind = .finished
                    case .inProgress, .unknown: continue
                    }
                    raw.append(Raw(id: kind.rawValue + ":" + identity, kind: kind, date: end, session: session, turnID: turn.id))
                }
            }
        }
        raw.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }

        // Fold repeats oldest first so a growing group keeps its identity.
        var events: [Event] = []
        var open: [String: Int] = [:]
        for item in raw {
            let key = TurnInspectionRecords.identity(item.session.provider.rawValue, item.session.id, item.kind.rawValue)
            if item.kind != .joined, let index = open[key], item.date.timeIntervalSince(events[index].date) <= mergeWindow {
                let prior = events[index]
                events[index] = Event(id: prior.id, kind: prior.kind, date: item.date, sessionID: prior.sessionID, turnID: item.turnID, provider: prior.provider,
                                      title: prior.title, projectPath: prior.projectPath, isHelper: prior.isHelper, count: prior.count + 1)
                continue
            }
            let session = item.session
            let title = ActivityTitles.display(session.title, provider: session.provider, projectPath: session.projectPath,
                                               parentTitle: records.parents[session.id].flatMap { titles[$0] })
            open[key] = events.count
            events.append(Event(id: item.id, kind: item.kind, date: item.date, sessionID: session.id, turnID: item.turnID, provider: session.provider,
                                title: title, projectPath: session.projectPath, isHelper: session.isChild, count: 1))
        }
        return Array(events.sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }.prefix(min(5_000, limit)))
    }
}

// MARK: - Titles people can read

public enum ActivityTitles {
    public static let codexGoalTitle = "Codex goal · objective in an attached file"

    /// Codex starts a goal thread with an instruction to read the attached
    /// objective file. That instruction is not the objective.
    public static func isCodexGoalWrapper(_ text: String) -> Bool {
        // Titles are often truncated before the file name, so the opening
        // instruction alone identifies the preamble.
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("read the codex goal objective file")
    }

    /// Generated names such as "Codex 01a1a665" or a bare identifier.
    public static func isPlaceholder(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return true }
        return value.range(of: #"^(?i:(codex|claude|gemini|grok|glm|session|agent)[\s:_-]*)?[0-9a-f][0-9a-f-]{5,}$"#,
                           options: .regularExpression) != nil
    }

    public static func providerName(_ provider: AgentName) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .none: return "Agent"
        }
    }

    public static func display(_ title: String, provider: AgentName, projectPath: String?, parentTitle: String? = nil) -> String {
        if isCodexGoalWrapper(title) { return codexGoalTitle }
        guard isPlaceholder(title) else { return title }
        if let parentTitle, !isPlaceholder(parentTitle) {
            let parent = isCodexGoalWrapper(parentTitle) ? "a Codex goal" : "“" + shortened(parentTitle, 60) + "”"
            return "Helping with " + parent
        }
        if let projectPath, !projectPath.isEmpty {
            return providerName(provider) + " session in " + URL(fileURLWithPath: projectPath).lastPathComponent
        }
        return providerName(provider) + " session"
    }

    private static func shortened(_ text: String, _ limit: Int) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
