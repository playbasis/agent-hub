import Foundation

/// Reporting is a passive, versioned view of native work. Unknown measurements
/// remain nil; a helper's `notLoaded` status never means another app is idle.
public struct ActivitySourceHealth: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var status: String
    public var checkedAt: Date
    public var lastSuccessAt: Date?
    public var message: String
    public init(id: String, status: String, checkedAt: Date = Date(), lastSuccessAt: Date? = nil, message: String) {
        self.id = id; self.status = status; self.checkedAt = checkedAt
        self.lastSuccessAt = lastSuccessAt; self.message = message
    }
}

public struct ActivityGoal: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    public var objective: String
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date
    public var providerTimeSeconds: Double?
    public var tokensUsed: Int?
    public var tokenBudget: Int?
    public init(id: String, sessionID: String, objective: String, status: String, createdAt: Date, updatedAt: Date, providerTimeSeconds: Double? = nil, tokensUsed: Int? = nil, tokenBudget: Int? = nil) {
        self.id = id; self.sessionID = sessionID; self.objective = objective
        self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.providerTimeSeconds = providerTimeSeconds; self.tokensUsed = tokensUsed; self.tokenBudget = tokenBudget
    }
    public var isOpen: Bool { status != "complete" && status != "cleared" }
    public func age(at now: Date) -> Double { max(0, (isOpen ? now : updatedAt).timeIntervalSince(createdAt)) }
}

public struct ActivityArtifact: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var kind: String
    public var status: String
    public init(id: String, path: String, kind: String = "file", status: String = "observed") {
        self.id = id; self.path = path; self.kind = kind; self.status = status
    }
}

public struct ActivityTurn: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var startedAt: Date?
    public var completedAt: Date?
    public var durationSeconds: Double?
    public var status: String
    /// All user-message submissions, including origins that cannot be verified.
    public var promptCount: Int?
    /// Only submissions whose source establishes a human origin.
    public var humanPromptCount: Int?
    public var toolCount: Int?
    public var model: String?
    public var effort: String?
    public var usage: TokenUsage
    /// True denotes a subtotal from bounded or ongoing history. False requires
    /// complete per-turn usage evidence; nil is legacy/unspecified coverage.
    public var usageIsPartial: Bool?
    /// Observed usage checkpoints have their own timestamps and identities.
    /// nil is legacy/unmeasured, never one implied model request per turn.
    public var modelSteps: [ActivityModelStep]?
    public var modelStepsComplete: Bool?
    public var categories: [String: Int]
    public var artifacts: [ActivityArtifact]
    /// Skills loaded or edited in this turn. nil is unmeasured (older saved
    /// turns, sources without tool metadata); an empty list is a measured none.
    public var skills: [ActivitySkillUse]?
    public init(id: String, startedAt: Date? = nil, completedAt: Date? = nil, durationSeconds: Double? = nil, status: String = "unknown", promptCount: Int? = nil, humanPromptCount: Int? = nil, toolCount: Int? = nil, model: String? = nil, effort: String? = nil, usage: TokenUsage = TokenUsage(), categories: [String: Int] = [:], artifacts: [ActivityArtifact] = [], usageIsPartial: Bool? = nil, modelSteps: [ActivityModelStep]? = nil, modelStepsComplete: Bool? = nil, skills: [ActivitySkillUse]? = nil) {
        self.id = id; self.startedAt = startedAt; self.completedAt = completedAt
        self.durationSeconds = durationSeconds; self.status = status
        self.promptCount = promptCount; self.humanPromptCount = humanPromptCount
        self.toolCount = toolCount; self.model = model; self.effort = effort; self.usage = usage; self.usageIsPartial = usageIsPartial
        self.categories = categories; self.artifacts = artifacts
        self.modelSteps = modelSteps; self.modelStepsComplete = modelStepsComplete
        self.skills = skills
    }
    /// A bounded or delayed replay may omit fields already observed. Explicit
    /// corrections (including zero) win; missing fields never erase evidence.
    public func merging(_ incoming: ActivityTurn) -> ActivityTurn {
        var value = incoming
        value.startedAt = incoming.startedAt ?? startedAt
        value.completedAt = incoming.completedAt ?? completedAt
        value.durationSeconds = incoming.durationSeconds ?? durationSeconds
        value.promptCount = incoming.promptCount ?? promptCount
        value.humanPromptCount = incoming.humanPromptCount ?? humanPromptCount
        value.toolCount = incoming.toolCount ?? toolCount
        value.model = incoming.model ?? model; value.effort = incoming.effort ?? effort
        value.usage.input = incoming.usage.input ?? usage.input
        value.usage.output = incoming.usage.output ?? usage.output
        value.usage.cachedInput = incoming.usage.cachedInput ?? usage.cachedInput
        value.usage.cacheWriteInput = incoming.usage.cacheWriteInput ?? usage.cacheWriteInput
        value.usage.reasoning = incoming.usage.reasoning ?? usage.reasoning
        value.usage.total = incoming.usage.total ?? usage.total
        if incoming.usage.provenance == .unavailable { value.usage.provenance = usage.provenance }
        if incoming.usage.hasAuthoritativeProvenance && !usage.hasAuthoritativeProvenance {
            value.usage = incoming.usage
            value.usageIsPartial = incoming.usageIsPartial
        } else if usage.hasAuthoritativeProvenance && !incoming.usage.hasAuthoritativeProvenance {
            value.usage = usage
            value.usageIsPartial = usageIsPartial
        } else if incoming.usageIsPartial == true {
            // Overlapping tail subtotals cannot be summed. Keep the single
            // largest observed subtotal (a lower bound), or any complete receipt.
            if usageIsPartial == false || (usage.total ?? -1) >= (incoming.usage.total ?? -1) {
                value.usage = usage
                value.usageIsPartial = usageIsPartial == false ? false : true
            }
        } else if incoming.usage.provenance == .unavailable { value.usageIsPartial = usageIsPartial }
        if incoming.toolCount == nil { value.categories = categories; value.artifacts = artifacts }
        switch (skills, incoming.skills) {
        case (nil, _): break
        case (let prior?, nil): value.skills = prior
        case (let prior?, let fresh?): value.skills = prior.mergingSkillUses(fresh)
        }
        if let incomingSteps = incoming.modelSteps {
            let oldSteps = modelSteps ?? []
            var byID = Dictionary(oldSteps.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for step in incomingSteps {
                if let prior = byID[step.id] {
                    byID[step.id] = prior.merging(step)
                } else { byID[step.id] = step }
            }
            value.modelSteps = byID.values.sorted {
                let lhs = $0.timestamp ?? .distantPast, rhs = $1.timestamp ?? .distantPast
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
            let incomingIDs = Set(incomingSteps.map(\.id))
            let oldIDs = Set(oldSteps.map(\.id))
            let retainsKnownClosedEvidence = modelStepsComplete == true && completedAt != nil
                && incoming.modelStepsComplete != true && incomingIDs.isSubset(of: oldIDs)
                && !["running", "inProgress", "active"].contains(incoming.status)
            value.modelStepsComplete = retainsKnownClosedEvidence ||
                (incoming.modelStepsComplete == true && oldSteps.allSatisfy { incomingIDs.contains($0.id) })
        } else {
            value.modelSteps = modelSteps
            value.modelStepsComplete = modelStepsComplete
        }
        if ["unknown", "observed"].contains(incoming.status) || (completedAt != nil && incoming.completedAt == nil) { value.status = status }
        return value
    }
}

public struct ActivitySession: Codable, Equatable, Identifiable, Sendable {
    /// Provider-prefixed native session identity (codex:<id> or claude:<id>).
    public var id: String
    public var provider: AgentName
    public var nativeID: String
    public var title: String
    public var projectPath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var observedAt: Date
    public var runtimeState: String
    public var parentSessionID: String?
    public var models: [String]
    public var efforts: [String]
    public var goal: ActivityGoal?
    public var turns: [ActivityTurn]
    public var historyComplete: Bool
    public var source: String
    public var warnings: [String]
    /// Instruction files and skill list the session started with; nil until read.
    public var startContext: ActivityStartContext?
    public init(id: String, provider: AgentName, nativeID: String, title: String, projectPath: String? = nil, createdAt: Date, updatedAt: Date, observedAt: Date = Date(), runtimeState: String = "unknown", parentSessionID: String? = nil, models: [String] = [], efforts: [String] = [], goal: ActivityGoal? = nil, turns: [ActivityTurn] = [], historyComplete: Bool = false, source: String, warnings: [String] = [], startContext: ActivityStartContext? = nil) {
        self.id = id; self.provider = provider; self.nativeID = nativeID; self.title = title
        self.projectPath = projectPath; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.observedAt = observedAt; self.runtimeState = runtimeState; self.parentSessionID = parentSessionID
        self.models = models; self.efforts = efforts; self.goal = goal; self.turns = turns
        self.historyComplete = historyComplete; self.source = source; self.warnings = warnings
        self.startContext = startContext
    }
    public var isChild: Bool { parentSessionID != nil }
}

public struct ActivityAccountDay: Codable, Equatable, Identifiable, Sendable {
    public var date: String
    public var tokens: Int
    public var id: String { date }
    public init(date: String, tokens: Int) { self.date = date; self.tokens = tokens }
}

public struct ActivityAccountUsage: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var lifetimeTokens: Int?
    public var peakDailyTokens: Int?
    public var longestRunningTurnSeconds: Int?
    public var currentStreakDays: Int?
    public var longestStreakDays: Int?
    public var daily: [ActivityAccountDay]
    public init(observedAt: Date = Date(), lifetimeTokens: Int? = nil, peakDailyTokens: Int? = nil, longestRunningTurnSeconds: Int? = nil, currentStreakDays: Int? = nil, longestStreakDays: Int? = nil, daily: [ActivityAccountDay] = []) {
        self.observedAt = observedAt; self.lifetimeTokens = lifetimeTokens; self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSeconds = longestRunningTurnSeconds; self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays; self.daily = daily
    }
}

public struct ActivityCollection: Sendable {
    public var sessions: [ActivitySession]
    public var health: ActivitySourceHealth
    public var accountUsage: ActivityAccountUsage?
    public init(sessions: [ActivitySession], health: ActivitySourceHealth, accountUsage: ActivityAccountUsage? = nil) {
        self.sessions = sessions; self.health = health; self.accountUsage = accountUsage
    }
}

public struct ActivityWorktree: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var branch: String?
    public var head: String?
    public var changedFiles: Int?
    public init(path: String, branch: String? = nil, head: String? = nil, changedFiles: Int? = nil) {
        self.path = path; self.branch = branch; self.head = head; self.changedFiles = changedFiles
    }
}

public struct ActivityCommit: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var subject: String
    public var timestamp: Date
    /// Repository-relative paths the commit changed (bounded).
    public var paths: [String]
    /// Lines added and removed in text files; nil when the commit's
    /// statistics weren't read (older scans or an oversized history).
    public var additions: Int?
    public var deletions: Int?
    public var filesChanged: Int?
    /// Per-file line counts (bounded); nil when only totals were read.
    public var files: [ActivityCommitFile]?
    /// Agents named in the commit's Co-authored-by trailers.
    public var coAuthors: [AgentName]?
    public init(id: String, subject: String, timestamp: Date, paths: [String] = [], additions: Int? = nil, deletions: Int? = nil,
                filesChanged: Int? = nil, files: [ActivityCommitFile]? = nil, coAuthors: [AgentName]? = nil) {
        self.id = id; self.subject = subject; self.timestamp = timestamp; self.paths = paths
        self.additions = additions; self.deletions = deletions; self.filesChanged = filesChanged
        self.files = files; self.coAuthors = coAuthors
    }
    public var linesChanged: Int? { additions.flatMap { a in deletions.map { a + $0 } } }
}

public struct ActivityCommitFile: Codable, Equatable, Sendable {
    public var path: String
    /// nil for binary files, which have no line counts.
    public var additions: Int?
    public var deletions: Int?
    public init(path: String, additions: Int?, deletions: Int?) {
        self.path = path; self.additions = additions; self.deletions = deletions
    }
}

public struct ActivityRepository: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var root: String
    public var worktrees: [ActivityWorktree]
    public var commits: [ActivityCommit]
    /// nil is legacy/unverified coverage, false means the history read failed.
    /// Only true makes an empty commit list a measured zero for the stated scope.
    public var commitHistoryAvailable: Bool?
    public var observedAt: Date
    public var warning: String?
    public init(id: String, name: String, root: String, worktrees: [ActivityWorktree] = [], commits: [ActivityCommit] = [], observedAt: Date = Date(), warning: String? = nil, commitHistoryAvailable: Bool? = nil) {
        self.id = id; self.name = name; self.root = root; self.worktrees = worktrees
        self.commits = commits; self.observedAt = observedAt; self.warning = warning
        self.commitHistoryAvailable = commitHistoryAvailable
    }
}

public struct ActivityOverview: Codable, Equatable, Sendable {
    public var schemaVersion = "activity/1"
    public var generatedAt: Date
    public var sessions: [ActivitySession]
    public var sources: [ActivitySourceHealth]
    public var accountUsage: ActivityAccountUsage?
    public var repositories: [ActivityRepository]
    public var pinnedSessionID: String?
    /// Optional additive metadata; never part of token/time accounting.
    public var connectionHistory: ActivityConnectionHistory?
    public init(generatedAt: Date = Date(), sessions: [ActivitySession] = [], sources: [ActivitySourceHealth] = [], accountUsage: ActivityAccountUsage? = nil, repositories: [ActivityRepository] = [], pinnedSessionID: String? = nil, connectionHistory: ActivityConnectionHistory? = nil) {
        self.generatedAt = generatedAt; self.sessions = sessions; self.sources = sources
        self.accountUsage = accountUsage; self.repositories = repositories; self.pinnedSessionID = pinnedSessionID
        self.connectionHistory = connectionHistory
    }
    public static let empty = ActivityOverview(generatedAt: .distantPast)
    public var goals: [ActivityGoal] { sessions.compactMap(\.goal).sorted { $0.updatedAt > $1.updatedAt } }
    public var activeGoals: [ActivityGoal] { goals.filter { $0.status == "active" } }
    public var pinnedSession: ActivitySession? {
        sessions.first { $0.id == pinnedSessionID }
            ?? sessions.first { $0.goal?.status == "active" }
    }
}

public struct ActivityPinRequest: Codable, Sendable {
    public var sessionID: String?
    public init(sessionID: String?) { self.sessionID = sessionID }
}

public struct ActivityJournalEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var date: String
    public var revision: Int
    public var generatedAt: Date
    public var previousID: String?
    public var supersedesID: String?
    public var timezone: String
    public var snapshotDigest: String
    public var outcomes: [String]
    public var continuingGoalIDs: [String]
    public var evidenceIDs: [String]
    public var markdown: String
}

public enum ActivityMetrics {
    /// Forks may carry identical native turn IDs. Aggregate their evidence once.
    public static func uniqueTurns(_ sessions: [ActivitySession]) -> [ActivityTurn] {
        var values: [String: ActivityTurn] = [:]
        for session in sessions.sorted(by: { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }) {
            for turn in session.turns { values[turn.id] = values[turn.id]?.merging(turn) ?? turn }
        }
        return values.values.sorted { $0.id < $1.id }
    }
    /// Closed intervals only. Unknown/open endings are never extended to now.
    public static func elapsedSeconds(_ turns: [ActivityTurn], from: Date? = nil, to: Date? = nil) -> Double? {
        if let from, let to, to < from { return nil }
        var intervals = turns.compactMap { turn -> (Date, Date)? in
            guard let start = turn.startedAt, let end = turn.completedAt, end >= start,
                  start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite else { return nil }
            let a = max(start, from ?? start), b = min(end, to ?? end)
            return b >= a ? (a, b) : nil
        }.sorted { $0.0 < $1.0 }
        guard var current = intervals.first else { return nil }
        intervals.removeFirst()
        var total = 0.0
        for interval in intervals {
            if interval.0 <= current.1 { current.1 = max(current.1, interval.1) }
            else { total += current.1.timeIntervalSince(current.0); current = interval }
        }
        let result = total + current.1.timeIntervalSince(current.0)
        return result.isFinite ? result : nil
    }
    public static func summedSeconds(_ turns: [ActivityTurn]) -> Double? {
        let durations = turns.compactMap(\.durationSeconds).filter { $0.isFinite && $0 >= 0 }
        guard !durations.isEmpty else { return nil }
        let total = durations.reduce(0, +)
        return total.isFinite ? total : nil
    }
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let result = values.reduce(0) { $0 + $1 / Double(values.count) }
        return result.isFinite ? result : nil
    }
    public static func median(_ values: [Double]) -> Double? {
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let values = values.sorted(); guard !values.isEmpty else { return nil }
        let i = values.count / 2
        return values.count.isMultiple(of: 2) ? values[i - 1] / 2 + values[i] / 2 : values[i]
    }
    public static func knownTotal(_ values: [Int?]) -> Int? {
        let values = values.compactMap { $0 }.filter { $0 >= 0 }
        guard !values.isEmpty else { return nil }
        var total = 0
        for value in values {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}
