import Foundation

/// Passive goal/job attribution from explicit native relationships. Shared
/// folders, similar titles and nearby timestamps are never causal evidence.
public enum GoalWorkMapping {
    public enum State: String, Codable, Sendable { case matched, ambiguous, unattributed }
    public enum EvidenceKind: String, Codable, Sendable { case ownGoal, explicitGoalID, nativeParent, nativeRootTurn, goalLifetime }
    public struct Evidence: Codable, Equatable, Sendable {
        public var kind: EvidenceKind
        public var sourceSessionID: String
        public var targetSessionID: String?
        public var nativeTurnID: String?
        public var rootTurnID: String?
        public var goalID: String?
        public var evidenceID: String
        public var timestamp: Date? = nil
    }
    public struct Association: Codable, Equatable, Sendable {
        public var state: State
        public var goalID: String?
        public var goalSessionID: String?
        public var rootSessionID: String?
        public var jobID: String
        public var candidateGoalIDs: [String]
        public var evidence: [Evidence]
        public var reason: String
    }
    public struct ExplicitGoalLink: Codable, Sendable {
        public var provider: AgentName
        public var sessionID: String
        public var nativeTurnID: String?
        public var goalID: String
        public var evidenceID: String
        public init(provider: AgentName, sessionID: String, nativeTurnID: String? = nil, goalID: String, evidenceID: String) {
            self.provider = provider; self.sessionID = sessionID; self.nativeTurnID = nativeTurnID; self.goalID = goalID; self.evidenceID = evidenceID
        }
    }
    /// Caller supplies a verified native correlation. rootTurnID is a causal
    /// link to a goal's owned turn, never an alias for the child's own turn ID.
    public struct RootTurnLink: Codable, Sendable {
        public var provider: AgentName
        public var sessionID: String
        public var nativeTurnID: String
        public var rootTurnID: String
        public var evidenceID: String
        public init(provider: AgentName, sessionID: String, nativeTurnID: String, rootTurnID: String, evidenceID: String) {
            self.provider = provider; self.sessionID = sessionID; self.nativeTurnID = nativeTurnID; self.rootTurnID = rootTurnID; self.evidenceID = evidenceID
        }
    }

    public static func resolve(sessions: [ActivitySession], now: Date, explicitGoalLinks: [ExplicitGoalLink] = [], rootTurnLinks: [RootTurnLink] = []) -> [String: Association] {
        var byID: [String: ActivitySession] = [:]
        for session in ActivityAccountingPrecision.metadataSessions(sessions) {
            if let prior = byID[session.id], session.observedAt < prior.observedAt || (session.observedAt == prior.observedAt && session.updatedAt < prior.updatedAt) { continue }
            byID[session.id] = session
        }
        // Parent/own-goal mapping needs metadata only. Do not rebuild an
        // 80k-step ownership graph on every live-clock tick unless a supplied
        // turn-level link actually needs that verification.
        let needsTurns = !rootTurnLinks.isEmpty || explicitGoalLinks.contains { $0.nativeTurnID != nil }
        let owned = needsTurns ? ActivityAnalytics.ownedTurnsBySession(in: Array(byID.values)) : [:]
        let native = Dictionary(grouping: byID.values, by: { $0.provider.rawValue + ":" + $0.nativeID })
        func parent(_ session: ActivitySession) -> (ActivitySession?, String?) {
            guard let reference = session.parentSessionID, !reference.isEmpty else { return (nil, nil) }
            if let exact = byID[reference] {
                return exact.provider == session.provider && exact.id != session.id && exact.createdAt <= now && exact.observedAt <= now
                    ? (exact, nil) : (nil, "invalid_native_parent")
            }
            let candidates = native[session.provider.rawValue + ":" + reference] ?? []
            guard candidates.count == 1, let found = candidates.first, found.id != session.id else {
                return (nil, candidates.count > 1 ? "ambiguous_native_parent" : "native_parent_unavailable")
            }
            return found.createdAt <= now && found.observedAt <= now ? (found, nil) : (nil, "invalid_native_parent")
        }
        func goalIsOpen(_ goal: ActivityGoal, owner: ActivitySession) -> Bool {
            guard finite(now), finite(goal.createdAt), finite(goal.updatedAt), goal.createdAt <= goal.updatedAt,
                  goal.updatedAt <= now, owner.createdAt <= now, owner.observedAt <= now,
                  !goal.id.isEmpty, goal.id.utf8.count <= 4_096,
                  ["active", "running", "paused", "waiting", "blocked", "pending", "inprogress", "in_progress"].contains(goal.status.lowercased()) else { return false }
            // Copied goal metadata is not proof that another session owns it.
            if goal.sessionID == owner.id { return true }
            let candidates = native[owner.provider.rawValue + ":" + goal.sessionID] ?? []
            return candidates.count == 1 && candidates.first?.id == owner.id
        }
        let goalOwners = byID.values.filter { session in session.goal.map { goalIsOpen($0, owner: session) } == true }
        let goalsByID = Dictionary(grouping: goalOwners, by: { $0.provider.rawValue + ":" + ($0.goal?.id ?? "") })
        func turnMatches(_ stored: String, _ requested: String, provider: AgentName) -> Bool {
            stored == requested || stored == provider.rawValue + ":turn:" + requested
                || requested == provider.rawValue + ":turn:" + stored
        }
        func ownsTurn(_ session: ActivitySession, _ requested: String) -> Bool {
            guard !requested.isEmpty else { return false }
            return (owned[session.id] ?? []).contains { turn in
                turnMatches(turn.id, requested, provider: session.provider)
                    && ([turn.startedAt, turn.completedAt].compactMap { $0 } + (turn.modelSteps ?? []).compactMap(\.timestamp)).contains { finite($0) && $0 <= now }
            }
        }
        let direct = Dictionary(grouping: explicitGoalLinks, by: \.sessionID)
        let correlations = Dictionary(grouping: rootTurnLinks, by: \.sessionID)
        var result: [String: Association] = [:]
        for id in Set(sessions.map(\.id)).sorted() {
            guard let session = byID[id], finite(now), session.createdAt <= now, session.observedAt <= now else {
                result[id] = Association(state: .unattributed, jobID: "session:" + id, candidateGoalIDs: [], evidence: [], reason: "invalid_or_future_metadata")
                continue
            }
            var candidates: [ActivitySession] = []
            var evidence: [Evidence] = []
            var rootID: String? = session.id
            var reason = "no_verified_open_goal"
            if let goal = session.goal, goalIsOpen(goal, owner: session) {
                candidates += goalsByID[session.provider.rawValue + ":" + goal.id] ?? []
                evidence.append(Evidence(kind: .ownGoal, sourceSessionID: id, targetSessionID: id, goalID: goal.id, evidenceID: goal.id))
            }
            for link in direct[id] ?? [] where link.provider == session.provider && !link.evidenceID.isEmpty {
                guard link.nativeTurnID.map({ ownsTurn(session, $0) }) ?? true else { continue }
                let found = goalsByID[session.provider.rawValue + ":" + link.goalID] ?? []
                candidates += found
                for owner in found { evidence.append(Evidence(kind: .explicitGoalID, sourceSessionID: id, targetSessionID: owner.id,
                    nativeTurnID: link.nativeTurnID, goalID: link.goalID, evidenceID: link.evidenceID)) }
            }
            if candidates.isEmpty && session.goal != nil {
                reason = "own_goal_not_verified_open"
            } else if candidates.isEmpty {
                var visited: Set<String> = [id]
                var cursor = session
                while true {
                    let (ancestor, problem) = parent(cursor)
                    if let problem { reason = problem; rootID = nil; break }
                    guard let ancestor else { break }
                    guard visited.insert(ancestor.id).inserted else { reason = "cyclic_native_parent"; rootID = nil; break }
                    evidence.append(Evidence(kind: .nativeParent, sourceSessionID: cursor.id, targetSessionID: ancestor.id,
                                             evidenceID: "session:\(cursor.id):parentSessionID"))
                    rootID = ancestor.id
                    if let goal = ancestor.goal {
                        if goalIsOpen(goal, owner: ancestor) { candidates += goalsByID[session.provider.rawValue + ":" + goal.id] ?? [] }
                        else { reason = "nearest_goal_not_verified_open" }
                        break
                    }
                    cursor = ancestor
                }
                for link in correlations[id] ?? [] where link.provider == session.provider && !link.evidenceID.isEmpty {
                    guard ownsTurn(session, link.nativeTurnID) else { reason = "source_turn_unverified"; continue }
                    let found = goalOwners.filter { $0.provider == session.provider && ownsTurn($0, link.rootTurnID) }
                    candidates += found
                    for owner in found { evidence.append(Evidence(kind: .nativeRootTurn, sourceSessionID: id, targetSessionID: owner.id,
                        nativeTurnID: link.nativeTurnID, rootTurnID: link.rootTurnID, goalID: owner.goal?.id, evidenceID: link.evidenceID)) }
                }
            }
            let unique = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
            let goalIDs = Array(Set(unique.compactMap { $0.goal?.id })).sorted()
            let proof = evidence.sorted { evidenceKey($0) < evidenceKey($1) }
            if unique.count == 1, let owner = unique.first, let goal = owner.goal {
                result[id] = Association(state: .matched, goalID: goal.id, goalSessionID: owner.id, rootSessionID: owner.id,
                    jobID: "goal:\(owner.provider.rawValue):\(goal.id)", candidateGoalIDs: goalIDs, evidence: proof, reason: "verified_native_relationship")
            } else {
                let ambiguous = unique.count > 1
                result[id] = Association(state: ambiguous ? .ambiguous : .unattributed, rootSessionID: ambiguous ? nil : rootID,
                    jobID: "session:" + (ambiguous ? id : rootID ?? id), candidateGoalIDs: goalIDs,
                    evidence: proof, reason: ambiguous ? "conflicting_or_ambiguous_goal_evidence" : reason)
            }
        }
        return result
    }

    /// A current session goal is not applied to all historical turns. Without
    /// an event time, only a verified native turn start inside its known goal
    /// lifetime permits whole-turn association. Stage views may pass their own
    /// recorded event time; that validates, but never creates, a causal link.
    public static func association(for turn: ActivityTurn, sessionID: String, sessions: [ActivitySession], now: Date,
                                   at eventTime: Date? = nil, sessionAssociation: Association? = nil) -> Association {
        var value = sessionAssociation ?? resolve(sessions: sessions, now: now)[sessionID]
            ?? Association(state: .unattributed, jobID: "session:" + sessionID, candidateGoalIDs: [], evidence: [], reason: "session_unavailable")
        guard value.state == .matched, let goalID = value.goalID, let ownerID = value.goalSessionID else { return value }
        let metadata = ActivityAccountingPrecision.metadataSessions(sessions)
        func latest(_ id: String) -> ActivitySession? {
            metadata.filter { $0.id == id }.max { a, b in a.observedAt == b.observedAt ? a.updatedAt < b.updatedAt : a.observedAt < b.observedAt }
        }
        let source = latest(sessionID)
        let goal = latest(ownerID)?.goal
        let stamp = (eventTime ?? turn.startedAt).flatMap(ActivityAccountingPrecision.date)
        let clock = ActivityAccountingPrecision.date(now)
        guard source?.turns.contains(where: { $0.id == turn.id }) == true, let goal, goal.id == goalID,
              let stamp, let clock, stamp <= clock, finite(goal.createdAt), stamp >= goal.createdAt,
              value.evidence.contains(where: { $0.sourceSessionID == sessionID }) else {
            value.state = .unattributed; value.goalID = nil; value.goalSessionID = nil
            value.jobID = "session:" + (value.rootSessionID ?? sessionID)
            value.reason = stamp == nil ? "turn_time_unavailable" : "turn_outside_verified_goal_lifetime"
            return value
        }
        value.evidence.append(Evidence(kind: .goalLifetime, sourceSessionID: sessionID, targetSessionID: ownerID,
            nativeTurnID: turn.id, goalID: goalID, evidenceID: "turn:\(turn.id):\(eventTime == nil ? "startedAt" : "eventTime")", timestamp: stamp))
        return value
    }

    private static func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
    private static func evidenceKey(_ value: Evidence) -> String {
        [value.kind.rawValue, value.sourceSessionID, value.targetSessionID ?? "", value.nativeTurnID ?? "", value.rootTurnID ?? "", value.goalID ?? "", value.evidenceID].joined(separator: "|")
    }
}
