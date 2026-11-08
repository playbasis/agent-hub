import Foundation

/// Recent recorded evidence, not a process monitor. No metadata update,
/// unclosed record or tool aggregate proves that a model/tool runs right now.
public enum LiveWork {
    /// Newest evidence within this window counts as working.
    public static let workingWindow: TimeInterval = 5 * 60
    /// An open turn without evidence for longer than `workingWindow` is quiet
    /// (waiting on a long command, on a person, or stopped without a final
    /// record) for up to this long, then drops out of the live view.
    public static let quietWindow: TimeInterval = 30 * 60
    /// Finished work stays listed this long.
    public static let finishedWindow: TimeInterval = 60 * 60
    /// A gap longer than this ends a stretch of continuous work.
    public static let stretchGap: TimeInterval = 10 * 60
    /// Session metadata can land a few seconds after a turn's finish record.
    static let finishMargin: TimeInterval = 30
    /// Turns started this recently also count toward what an agent is doing.
    public static let focusWindow: TimeInterval = 10 * 60
    /// Minutes in the step pulse.
    public static let pulseMinutes = 30

    public enum State: String, Sendable, Comparable {
        /// Legacy coordinate: "working" means recent observed evidence only.
        case working, quiet, finished
        private var rank: Int { self == .working ? 0 : self == .quiet ? 1 : 2 }
        public static func < (lhs: State, rhs: State) -> Bool { lhs.rank < rhs.rank }
    }

    public enum EvidenceState: String, Sendable {
        case recentModelSteps, recentTurnStart, quietOpenRecord, recordedFinish, contextOnly, inconsistent
    }

    /// The kind of tool work in the newest turn, in plain words.
    public enum Focus: String, Sendable, CaseIterable {
        case researching, readingCode, writingCode, runningTests, runningCommands, reviewing, coordinating, usingTools

        public var title: String {
            switch self {
            case .researching: return "Researching"
            case .readingCode: return "Reading code"
            case .writingCode: return "Writing code"
            case .runningTests: return "Running tests"
            case .runningCommands: return "Running commands"
            case .reviewing: return "Reviewing changes"
            case .coordinating: return "Coordinating sub-agents"
            case .usingTools: return "Using tools"
            }
        }

        /// The work-mix category this focus comes from, so colours and
        /// symbols match the work-mix bars.
        public var category: String {
            switch self {
            case .researching: return "Research"
            case .readingCode: return "Inspection"
            case .writingCode: return "Implementation"
            case .runningTests: return "Tests"
            case .runningCommands: return "Execution"
            case .reviewing: return "Review"
            case .coordinating: return "Coordination"
            case .usingTools: return "Other"
            }
        }

        public init(category raw: String) {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "research": self = .researching
            case "inspection": self = .readingCode
            case "implementation": self = .writingCode
            case "tests": self = .runningTests
            case "execution": self = .runningCommands
            case "review": self = .reviewing
            case "coordination", "delegation": self = .coordinating
            default: self = .usingTools
            }
        }

        /// The largest named category; the catch-all only when nothing else
        /// was recorded. Ties resolve by name so the label doesn't flicker.
        public static func dominant(_ categories: [String: Int]) -> Focus? {
            let counted = categories.filter { $0.value > 0 }
            guard !counted.isEmpty else { return nil }
            let named = counted.filter { Focus(category: $0.key) != .usingTools }
            let pool = named.isEmpty ? counted : named
            let best = pool.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
            return best.map { Focus(category: $0.key) }
        }
    }

    public struct Agent: Identifiable, Sendable, Equatable {
        public var id: String
        public var provider: AgentName
        public var title: String
        public var projectPath: String?
        public var state: State
        public var lastActivity: Date
        /// Start of the latest cluster of recorded evidence, not continuous execution.
        public var stretchStart: Date
        /// The newest turn's finish time when it has one.
        public var finishedAt: Date?
        public var failed: Bool
        public var focus: Focus?
        /// Legacy layout coordinate only. Use nullable toolCallCount in labels.
        public var toolCalls: Int
        /// Canonical observed model-step receipts per minute. No turn fallback.
        public var pulse: [Int]?
        public var stepsLastFiveMinutes: Int?
        public var model: String?
        public var changedFiles: [String]
        public var toolCallCount: Int? = nil
        public var toolCallsArePartial = false
        public var unallocatedToolCallCount: Int? = nil
        public var evidenceState: EvidenceState = .contextOnly
        public var evidenceDetails: [String] = []
        public var nativeTurnIDs: [String] = []
        public var modelStepIDs: [String] = []
        public var activityTimestamp: Date? = nil
        public var goalAssociation: GoalWorkMapping.Association? = nil
        /// Passive snapshot data does not verify another app's process state.
        public var executionVerified = false
    }

    /// A top-level session and the sub-agents working under it.
    public struct Job: Identifiable, Sendable, Equatable {
        public var lead: Agent
        public var helpers: [Agent]
        public var goalAssociation: GoalWorkMapping.Association? = nil
        public var id: String { goalAssociation?.jobID ?? lead.goalAssociation?.jobID ?? lead.id }
        public var agents: [Agent] { [lead] + helpers }
        public var state: State { agents.map(\.state).min() ?? lead.state }
        public var workingCount: Int { agents.filter { $0.state == .working }.count }
        public var lastActivity: Date { agents.compactMap(\.activityTimestamp).max() ?? .distantPast }
    }

    public struct Summary: Sendable, Equatable {
        public var jobs: [Job]
        public var workingAgents: Int
        public var workingSubAgents: Int
        public var workingProjects: Int
        public var lastActivity: Date?
        public var active: [Job] { jobs.filter { $0.state != .finished } }
        public var finished: [Job] { jobs.filter { $0.state == .finished } }
    }

    /// One agent's live reading, or nil when it has no evidence recent enough
    /// to matter now.
    public static func agent(_ session: ActivitySession, now: Date, accounting: ActivityAccounting.Report? = nil,
                             ownershipContext: [ActivitySession]? = nil, goalAssociation: GoalWorkMapping.Association? = nil) -> Agent? {
        guard let clock = ActivityAccountingPrecision.date(now), valid(session.createdAt, at: clock), valid(session.observedAt, at: clock) else { return nil }
        let report = accounting ?? ActivityAccounting.build(overview: ActivityOverview(generatedAt: clock, sessions: ownershipContext ?? [session]),
            sessionIDs: [session.id], from: clock.addingTimeInterval(-finishedWindow), to: clock.addingTimeInterval(0.001))
        let steps = report.receipts.filter { $0.sessionID == session.id && $0.countsAsModelStep && $0.timestamp.map { valid($0, at: clock) } == true }
        let native = report.nativeObservations.filter { $0.sessionID == session.id }
        // Each native record's newest step, found in one pass over the steps.
        var newestStep: [String: Date] = [:]
        for step in steps {
            guard let at = step.timestamp else { continue }
            let key = step.provider.rawValue + ":" + step.nativeTurnID
            newestStep[key] = max(newestStep[key] ?? at, at)
        }
        func latestDate(_ item: ActivityAccounting.NativeObservation) -> Date? {
            var dates: [Date] = [item.startedAt, item.completedAt].compactMap { $0 }.filter { valid($0, at: clock) }
            if let step = newestStep[item.id] { dates.append(step) }
            return dates.max()
        }
        var latest: ActivityAccounting.NativeObservation?
        var latestAt = Date.distantPast
        for item in native {
            guard let at = latestDate(item) else { continue }
            if latest == nil || at > latestAt || (at == latestAt && item.id > latest!.id) { latest = item; latestAt = at }
        }
        let newestTurnSteps = latest.map { item in steps.filter { item.id == $0.provider.rawValue + ":" + $0.nativeTurnID } } ?? steps
        let latestStep = newestTurnSteps.max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        let stamps = native.flatMap { [$0.startedAt, $0.completedAt].compactMap { $0 } }.filter { valid($0, at: clock) }
            + steps.compactMap(\.timestamp)
        guard let last = stamps.max() else { return nil }
        let age = clock.timeIntervalSince(last)
        guard age.isFinite, age >= 0 else { return nil }
        let finishedAt = latest?.completedAt.flatMap { valid($0, at: clock) ? $0 : nil }
        let validStart = latest?.startedAt.flatMap { valid($0, at: clock) ? $0 : nil }
        let state: State
        var evidenceState: EvidenceState
        var details = ["Recent evidence is not verification of current model or tool execution."]
        if let finishedAt, finishedAt >= (validStart ?? finishedAt) {
            guard clock.timeIntervalSince(finishedAt) <= finishedWindow else { return nil }
            state = .finished
            evidenceState = .recordedFinish
            if last > finishedAt {
                details.append("Usage was recorded after the native finish; it does not prove a new turn started.")
            }
        } else if age <= workingWindow {
            state = .working
            evidenceState = latestStep?.timestamp.map { clock.timeIntervalSince($0) <= workingWindow } == true ? .recentModelSteps : .recentTurnStart
        } else if age <= quietWindow {
            state = .quiet
            evidenceState = .quietOpenRecord
        } else {
            return nil
        }
        if latest?.completedAt.map({ !valid($0, at: clock) }) == true || latest?.startedAt.map({ !valid($0, at: clock) }) == true {
            evidenceState = .inconsistent
            details.append("An invalid or future native timestamp was ignored.")
        } else if let finishedAt, let validStart, finishedAt < validStart {
            evidenceState = .inconsistent
            details.append("Native start and finish timestamps disagree; execution state is unavailable.")
        }
        // An evidence cluster is not proof of uninterrupted work between events.
        let sorted = stamps.sorted()
        var stretchStart = last
        for stamp in sorted.reversed() where stamp <= stretchStart {
            if stretchStart.timeIntervalSince(stamp) > stretchGap { break }
            stretchStart = stamp
        }
        var pulse: [Int]?
        var recentSteps: Int?
        if !steps.isEmpty {
            var buckets = Array(repeating: 0, count: pulseMinutes)
            for at in steps.compactMap(\.timestamp) {
                let seconds = clock.timeIntervalSince(at)
                guard seconds.isFinite, seconds >= 0, seconds < Double(pulseMinutes) * 60 else { continue }
                let minutesAgo = Int(seconds / 60) // bounded above before conversion
                buckets[pulseMinutes - 1 - minutesAgo] += 1
            }
            pulse = buckets
            recentSteps = steps.filter { $0.timestamp.map { clock.timeIntervalSince($0) <= workingWindow } ?? false }.count
        }
        let focusStart = clock.addingTimeInterval(-focusWindow)
        let qualified = native.filter { item in
            if item.provider == .claude { return item.timestamp.map { valid($0, at: clock) && $0 >= focusStart } ?? false }
            guard let start = item.startedAt, let end = item.completedAt, valid(start, at: clock), valid(end, at: clock), end >= start else { return false }
            return start >= focusStart
        }
        let unplaced = native.filter { item in
            !qualified.contains(where: { $0.id == item.id }) && item.completedAt.map { $0 >= focusStart } != false
        }
        var categories: [String: Int] = [:]
        var categoryOverflow = false
        for item in qualified {
            for (name, count) in item.categories where count > 0 {
                let sum = categories[name, default: 0].addingReportingOverflow(count)
                categoryOverflow = categoryOverflow || sum.overflow
                categories[name] = sum.overflow ? Int.max : sum.partialValue
            }
        }
        let tools = knownTotal(qualified.map(\.toolCalls))
        let wholeTools = knownTotal(unplaced.map(\.toolCalls))
        if !unplaced.isEmpty { details.append("Whole-turn tool aggregates have no individual event times; they are not assigned to the last ten minutes.") }
        if tools.overflow || categoryOverflow { details.append("An aggregate count overflowed and is unavailable.") }
        if steps.isEmpty { details.append("Model-step counts are unavailable; native turns are not counted as implied model requests.") }
        if latest != nil && latestStep == nil { details.append("The newest native record has no dated model-step identity; an earlier model is not reused.") }
        let failed = ["failed", "error", "errored"].contains(latest?.status.lowercased() ?? "")
        var value = Agent(id: session.id, provider: session.provider, title: session.goal?.objective ?? session.title,
                     projectPath: session.projectPath, state: state, lastActivity: last, stretchStart: stretchStart,
                     finishedAt: finishedAt, failed: failed, focus: Focus.dominant(categories),
                     toolCalls: tools.value ?? 0, pulse: pulse, stepsLastFiveMinutes: recentSteps, model: latestStep?.model,
                     changedFiles: Array(Set(qualified.flatMap(\.artifacts).map { URL(fileURLWithPath: $0.path).lastPathComponent }).sorted().prefix(3)))
        value.toolCallCount = tools.value
        value.toolCallsArePartial = tools.overflow || categoryOverflow || qualified.contains { $0.toolCalls == nil } || !unplaced.isEmpty
        value.unallocatedToolCallCount = wholeTools.value
        value.evidenceState = evidenceState; value.evidenceDetails = details
        value.nativeTurnIDs = Array(Set(native.map(\.id))).sorted()
        value.modelStepIDs = Array(Set(steps.map(\.id))).sorted()
        value.activityTimestamp = last
        if let latest, let turn = session.turns.first(where: { latest.id == session.provider.rawValue + ":" + $0.id }) {
            value.goalAssociation = GoalWorkMapping.association(for: turn, sessionID: session.id, sessions: ownershipContext ?? [session], now: clock,
                at: latestStep?.timestamp ?? latest.startedAt, sessionAssociation: goalAssociation)
        } else { value.goalAssociation = goalAssociation }
        if value.goalAssociation?.state != .matched { value.title = session.title }
        return value
    }

    /// Jobs with live or recently finished work, working first, then newest.
    /// `roots` and `children` come from the session tree the page already
    /// shows, so a job here is the same row as in the list below it.
    public static func summary(roots: [ActivitySession], children: [String: [ActivitySession]], now: Date,
                               ownershipContext: [ActivitySession]? = nil, accounting: ActivityAccounting.Report? = nil,
                               accountingBySession: [String: ActivityAccounting.Report]? = nil,
                               explicitGoalLinks: [GoalWorkMapping.ExplicitGoalLink] = [], rootTurnLinks: [GoalWorkMapping.RootTurnLink] = []) -> Summary {
        guard let clock = ActivityAccountingPrecision.date(now) else { return Summary(jobs: [], workingAgents: 0, workingSubAgents: 0, workingProjects: 0, lastActivity: nil) }
        var listed: [String: ActivitySession] = [:]
        for session in roots + children.values.flatMap({ $0 }) { listed[session.id] = session }
        var context = ownershipContext ?? Array(listed.values)
        let known = Set(context.map(\.id)); context += listed.values.filter { !known.contains($0.id) }
        let associations = GoalWorkMapping.resolve(sessions: context, now: clock, explicitGoalLinks: explicitGoalLinks, rootTurnLinks: rootTurnLinks)
        let report = accounting ?? ActivityAccounting.build(overview: ActivityOverview(generatedAt: clock, sessions: context), sessionIDs: Set(listed.keys),
            from: clock.addingTimeInterval(-finishedWindow), to: clock.addingTimeInterval(0.001))
        let bySession = accountingBySession ?? report.bySession()
        var agents: [String: Agent] = [:]
        for session in listed.values {
            if let value = agent(session, now: clock, accounting: bySession[session.id], ownershipContext: context, goalAssociation: associations[session.id]) { agents[session.id] = value }
        }
        let groups = Dictionary(grouping: agents.values, by: { $0.goalAssociation?.jobID ?? "session:" + $0.id })
        let all = Dictionary(context.map { ($0.id, $0) }, uniquingKeysWith: { first, second in first.observedAt > second.observedAt ? first : second })
        var jobs: [Job] = []
        for members in groups.values {
            guard let first = members.sorted(by: { $0.id < $1.id }).first else { continue }
            let association = first.goalAssociation
            let leadID = association?.goalSessionID ?? association?.rootSessionID ?? first.id
            // An owner can have separate pre-goal work in another group. It
            // supplies context here, not a second copy of that activity.
            let sameGroupLead = agents[leadID].flatMap { value in value.goalAssociation?.jobID == first.goalAssociation?.jobID ? value : nil }
            let lead = sameGroupLead ?? all[leadID].map { frame($0, association: association) } ?? first
            let helpers = members.filter { $0.id != lead.id }.sorted {
                if $0.state != $1.state { return $0.state < $1.state }
                return $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity
            }
            jobs.append(Job(lead: lead, helpers: helpers, goalAssociation: association))
        }
        jobs.sort {
            if $0.state != $1.state { return $0.state < $1.state }
            return $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity
        }
        let working = Array(Dictionary(jobs.flatMap(\.agents).filter { $0.state == .working }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        return Summary(jobs: jobs, workingAgents: working.count,
                       workingSubAgents: working.filter { all[$0.id]?.parentSessionID.map { !$0.isEmpty } == true }.count,
                       workingProjects: Set(working.compactMap(\.projectPath)).count,
                       lastActivity: jobs.flatMap(\.agents).compactMap(\.activityTimestamp).max())
    }

    private static func frame(_ session: ActivitySession, association: GoalWorkMapping.Association?) -> Agent {
        var value = Agent(id: session.id, provider: session.provider, title: association?.state == .matched ? session.goal?.objective ?? session.title : session.title, projectPath: session.projectPath,
              state: .finished, lastActivity: .distantPast, stretchStart: .distantPast, finishedAt: nil, failed: false,
              focus: nil, toolCalls: 0, pulse: nil, stepsLastFiveMinutes: nil, model: nil, changedFiles: [])
        value.evidenceDetails = ["Context owner only; no recent recorded activity is available for this lead."]
        value.goalAssociation = association
        return value
    }
    private static func valid(_ value: Date, at now: Date) -> Bool { value.timeIntervalSinceReferenceDate.isFinite && value <= now }
    private static func knownTotal(_ values: [Int?]) -> (value: Int?, overflow: Bool) {
        var total = 0, count = 0
        for value in values.compactMap({ $0 }) where value >= 0 {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return (nil, true) }
            total = sum.partialValue; count += 1
        }
        return (count > 0 ? total : nil, false)
    }
}
