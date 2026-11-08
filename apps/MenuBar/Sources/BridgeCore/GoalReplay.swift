import Foundation

/// A source-navigation index, not another token ledger or a success score.
/// Every row points back to one canonical owned native turn in the frozen
/// snapshot. Detailed messages/tools remain on-demand and privacy-gated.
public struct GoalReplayIndex: Sendable {
    public static let maximumIndexedRows = 20_000

    public enum TimestampBasis: String, Sendable { case started, completed, checkpoint, unavailable }
    public enum Coverage: String, CaseIterable, Sendable {
        case unknownTime, missingTurnStart, inconsistentTime, partialHistory
        case unmeasuredModelSteps, partialModelSteps, unmeasuredTools, uncertainGoalLink
        case modelIdentityMissing, mixedModels, extendsPastGoalEnd
        public var explanation: String {
            switch self {
            case .unknownTime: return "No valid event time was recorded; its place in the chronology is unknown."
            case .missingTurnStart: return "The native turn did not record a usable start; whole-turn goal attribution is unavailable."
            case .inconsistentTime: return "Recorded turn dates disagree or include a future/invalid date."
            case .partialHistory: return "The source session's native history is incomplete."
            case .unmeasuredModelSteps: return "Model-step detail was not measured; this turn is not counted as one model step."
            case .partialModelSteps: return "Saved usage checkpoints are a partial observation, not an exact API-attempt count."
            case .unmeasuredTools: return "Tool-call counts are unavailable, not zero."
            case .uncertainGoalLink: return "This source record cannot be attributed to the goal with the available evidence."
            case .modelIdentityMissing: return "Some model identity was not recorded."
            case .mixedModels: return "More than one model identity occurs in this native turn."
            case .extendsPastGoalEnd: return "The native turn extends past the goal's last recorded closed-state update; its full pool is not goal-scoped."
            }
        }
    }
    public struct Row: Identifiable, Sendable {
        public let id: String
        public let sessionID: String
        public let nativeSessionID: String
        public let nativeTurnID: String
        /// Exact canonical owned record used for this row. Consumers must not
        /// look up an older copied/raw observation and display different steps.
        /// ActivityTurn's arrays remain copy-on-write; no payload is hydrated.
        public let sourceTurn: ActivityTurn
        public let provider: AgentName
        public let timestamp: Date?
        public let timestampBasis: TimestampBasis
        public let model: String?
        public let effort: String?
        public let models: [String]
        public let efforts: [String]
        public let status: String
        /// Distinct checkpoint IDs saved for this canonical native turn. This
        /// is navigation coverage, never an independently summed request KPI.
        public let modelStepCount: Int?
        public let modelStepsArePartial: Bool
        /// The provider's whole native-turn count, not a goal/range subtotal.
        public let toolCount: Int?
        public let association: GoalWorkMapping.Association
        public let coverage: [Coverage]
    }
    public struct Summary: Sendable {
        public let knownTurnCount: Int
        public let indexedTurnCount: Int
        public let omittedTurnCount: Int
        public let sessionCount: Int
        public let undatedTurnCount: Int
        public let excludedOutsideLifetime: Int
        public let associationUncertainCount: Int
        public let historyComplete: Bool
        public let isPartial: Bool
        public let warnings: [String]
    }
    public struct Page: Sendable {
        public let rows: [Row]
        public let offset: Int
        public let nextOffset: Int?
        public let totalCount: Int
    }
    public let rootSessionID: String
    public let goalID: String?
    public let rows: [Row]
    public let summary: Summary

    /// Pagination never changes row identities or silently hides the old
    /// 160-record tail. A hard index bound is explicit in Summary.
    public func page(offset: Int = 0, limit: Int = 100) -> Page {
        let start = min(max(0, offset), rows.count)
        guard offset >= 0, limit > 0 else { return Page(rows: [], offset: start, nextOffset: nil, totalCount: rows.count) }
        let end = start + min(limit, 500, rows.count - start)
        return Page(rows: Array(rows[start..<end]), offset: start, nextOffset: end < rows.count ? end : nil, totalCount: rows.count)
    }

    public static func build(overview: ActivityOverview, rootSessionID: String,
                             maximumRows: Int = maximumIndexedRows) -> Self {
        guard let clock = ActivityAccountingPrecision.date(overview.generatedAt) else {
            return empty(root: rootSessionID, warning: "The snapshot has no valid observation time.")
        }
        // Canonical metadata is separate from canonical turn ownership. A
        // conflicting latest identity is not resolved by input-array order.
        let normalized = ActivityAccountingPrecision.metadataSessions(overview.sessions)
        let groups = Dictionary(grouping: normalized, by: \.id)
        var byID: [String: ActivitySession] = [:], conflicting = Set<String>()
        for (id, candidates) in groups {
            guard let latest = candidates.max(by: {
                $0.observedAt == $1.observedAt ? $0.updatedAt < $1.updatedAt : $0.observedAt < $1.observedAt
            }) else { continue }
            let peers = candidates.filter { $0.observedAt == latest.observedAt && $0.updatedAt == latest.updatedAt }
            guard Set(peers.map(metadataIdentity)).count == 1 else { conflicting.insert(id); continue }
            guard latest.createdAt <= latest.updatedAt, latest.createdAt <= clock,
                  latest.updatedAt <= clock, latest.observedAt <= clock else { continue }
            byID[id] = latest
        }
        guard let root = byID[rootSessionID] else {
            return empty(root: rootSessionID, warning: conflicting.contains(rootSessionID)
                ? "The selected session has conflicting native identity records. No history was guessed."
                : "The selected session is unavailable or has invalid/future metadata.")
        }
        let nativeOwners = Dictionary(grouping: byID.values, by: { nativeKey($0.provider, $0.nativeID) })
        func owns(_ goal: ActivityGoal, session: ActivitySession) -> Bool {
            if goal.sessionID == session.id { return true }
            let matches = nativeOwners[nativeKey(session.provider, goal.sessionID)] ?? []
            return matches.count == 1 && matches.first?.id == session.id
        }
        let selectedGoal = root.goal.flatMap { goal -> ActivityGoal? in
            guard owns(goal, session: root), !goal.id.isEmpty,
                  goal.createdAt <= goal.updatedAt, goal.updatedAt <= clock,
                  ["active", "running", "paused", "waiting", "blocked", "pending", "inprogress", "in_progress", "complete", "completed", "cleared"].contains(goal.status.lowercased()) else { return nil }
            return goal
        }
        let closed = selectedGoal.map { ["complete", "completed", "cleared"].contains($0.status.lowercased()) } ?? false
        let lower = selectedGoal?.createdAt
        // Historical inspection does not weaken GoalWorkMapping's open-goal
        // policy. The closed goal's recorded update is a conservative boundary,
        // not an inferred execution/acceptance timestamp.
        let upper = closed ? selectedGoal!.updatedAt : clock
        var parent: [String: String] = [:]
        var invalidParent = Set<String>()
        for value in byID.values where value.parentSessionID != nil {
            guard let reference = value.parentSessionID, !reference.isEmpty else { invalidParent.insert(value.id); continue }
            if let exact = byID[reference] {
                if exact.provider == value.provider, exact.id != value.id { parent[value.id] = exact.id }
                else { invalidParent.insert(value.id) }
            } else {
                let matches = nativeOwners[nativeKey(value.provider, reference)] ?? []
                if matches.count == 1, let found = matches.first, found.id != value.id { parent[value.id] = found.id }
                else { invalidParent.insert(value.id) }
            }
        }
        var cyclic = Set<String>()
        for id in byID.keys.sorted() {
            var path: [String] = [], positions: [String: Int] = [:], cursor: String? = id
            while let current = cursor {
                if let start = positions[current] { cyclic.formUnion(path[start...]); break }
                positions[current] = path.count; path.append(current); cursor = parent[current]
            }
        }
        var family: [String: [GoalWorkMapping.Evidence]] = [root.id: []]
        for value in byID.values where value.id != root.id && value.provider == root.provider {
            var proof: [GoalWorkMapping.Evidence] = [], visited = Set<String>(), cursor = value
            while visited.insert(cursor.id).inserted, !cyclic.contains(cursor.id), !invalidParent.contains(cursor.id) {
                // A nested, independently owned goal is not assigned to its
                // ancestor's current goal from project/time proximity.
                if let own = cursor.goal, owns(own, session: cursor), own.id != selectedGoal?.id { break }
                guard let parentID = parent[cursor.id], let ancestor = byID[parentID] else { break }
                proof.append(.init(kind: .nativeParent, sourceSessionID: cursor.id, targetSessionID: ancestor.id,
                                   evidenceID: "session:\(cursor.id):parentSessionID"))
                if parentID == root.id {
                    if !cyclic.contains(root.id) { family[value.id] = proof }
                    break
                }
                cursor = ancestor
            }
        }
        let context = overview.sessions.filter { byID[$0.id] != nil }
        let owned = ActivityAnalytics.ownedTurnsBySession(in: context)
        var projected: [Row] = [], outside = 0
        for sessionID in family.keys.sorted() {
            guard let source = byID[sessionID] else { continue }
            for turn in owned[sessionID] ?? [] {
                let start = valid(turn.startedAt, clock: clock)
                let end = valid(turn.completedAt, clock: clock)
                // Undated records remain explicitly unattributed review rows;
                // dates outside a known goal lifetime are excluded, counted.
                if let lower, let start, (start < lower || start > upper) { outside += 1; continue }
                let checkpointTimes = (turn.modelSteps ?? []).compactMap { valid($0.timestamp, clock: clock) }
                let stamp = start ?? end ?? checkpointTimes.min()
                let basis: TimestampBasis = start != nil ? .started : end != nil ? .completed : stamp != nil ? .checkpoint : .unavailable
                var coverage: [Coverage] = []
                if stamp == nil { coverage.append(.unknownTime) }
                if start == nil { coverage.append(.missingTurnStart) }
                let badTime = (turn.startedAt != nil && start == nil) || (turn.completedAt != nil && end == nil)
                    || (start != nil && end != nil && end! < start!)
                if badTime { coverage.append(.inconsistentTime) }
                if !source.historyComplete { coverage.append(.partialHistory) }
                let steps = turn.modelSteps.map { values in
                    Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { $0.merging($1) }).values
                }
                let partialSteps = turn.modelStepsComplete != true
                if steps == nil { coverage.append(.unmeasuredModelSteps) }
                else if partialSteps { coverage.append(.partialModelSteps) }
                let tools = turn.toolCount.flatMap { $0 >= 0 ? $0 : nil }
                if tools == nil { coverage.append(.unmeasuredTools) }
                let models = Array(Set(([turn.model] + (turn.modelSteps ?? []).map(\.model)).compactMap(nonempty))).sorted()
                let efforts = Array(Set(([turn.effort] + (turn.modelSteps ?? []).map(\.effort)).compactMap(nonempty))).sorted()
                if models.isEmpty || turn.modelSteps?.contains(where: { nonempty($0.model) == nil }) == true { coverage.append(.modelIdentityMissing) }
                if models.count > 1 { coverage.append(.mixedModels) }
                if closed, end.map({ $0 > upper }) == true { coverage.append(.extendsPastGoalEnd) }
                var proof = family[sessionID] ?? []
                if let goal = selectedGoal {
                    proof.append(.init(kind: .ownGoal, sourceSessionID: root.id, targetSessionID: root.id,
                                       goalID: goal.id, evidenceID: goal.id))
                }
                let matched = selectedGoal != nil && start != nil && !badTime
                if matched, let start, let goal = selectedGoal {
                    proof.append(.init(kind: .goalLifetime, sourceSessionID: sessionID, targetSessionID: root.id,
                        nativeTurnID: turn.id, goalID: goal.id, evidenceID: "turn:\(turn.id):startedAt", timestamp: start))
                } else { coverage.append(.uncertainGoalLink) }
                let association = GoalWorkMapping.Association(state: matched ? .matched : .unattributed,
                    goalID: matched ? selectedGoal?.id : nil, goalSessionID: matched ? root.id : nil, rootSessionID: root.id,
                    jobID: matched ? "goal:\(root.provider.rawValue):\(selectedGoal!.id)" : "session:" + root.id,
                    candidateGoalIDs: selectedGoal.map { [$0.id] } ?? [], evidence: proof,
                    reason: matched ? (closed ? "verified_historical_native_relationship" : "verified_native_relationship")
                        : selectedGoal == nil ? "selected_goal_unavailable" : badTime ? "invalid_turn_timestamps" : "turn_start_unavailable")
                projected.append(Row(id: rowID(provider: source.provider, sessionID: sessionID, turnID: turn.id),
                    sessionID: sessionID, nativeSessionID: source.nativeID, nativeTurnID: turn.id, sourceTurn: turn, provider: source.provider,
                    timestamp: stamp, timestampBasis: basis, model: models.count == 1 ? models[0] : nil,
                    effort: efforts.count == 1 ? efforts[0] : nil, models: models, efforts: efforts, status: turn.status,
                    modelStepCount: steps?.count, modelStepsArePartial: partialSteps, toolCount: tools,
                    association: association, coverage: coverage))
            }
        }
        projected.sort {
            switch ($0.timestamp, $1.timestamp) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
        let known = projected.count
        let bound = min(max(0, maximumRows), maximumIndexedRows)
        let retained = Array(projected.prefix(bound))
        let undated = projected.filter { $0.timestamp == nil }.count
        let uncertain = projected.filter { $0.association.state != .matched }.count
        let completeHistory = family.keys.allSatisfy { byID[$0]?.historyComplete == true }
        var warnings: [String] = []
        if selectedGoal == nil { warnings.append("No verified goal ownership is available; these are source-session records, not verified goal steps.") }
        if closed { warnings.append("Historical goal window ends at its recorded closed-state update; that timestamp is not proof of acceptance.") }
        if !completeHistory { warnings.append("Native history is partial. This list covers known records, not a claim that every provider event was recovered.") }
        if known > retained.count { warnings.append("\(known - retained.count) known turns exceed the explicit \(bound)-row index bound.") }
        if uncertain > 0 { warnings.append("\(uncertain) records have uncertain whole-turn goal attribution.") }
        if outside > 0 { warnings.append("\(outside) known turns started outside the selected goal's recorded lifetime and are excluded.") }
        if !conflicting.isEmpty || cyclic.contains(root.id) { warnings.append("Conflicting or cyclic native relationships were not guessed into this replay.") }
        let partial = !completeHistory || known > retained.count || uncertain > 0 || projected.contains { !$0.coverage.isEmpty }
        return Self(rootSessionID: root.id, goalID: selectedGoal?.id, rows: retained,
            summary: Summary(knownTurnCount: known, indexedTurnCount: retained.count, omittedTurnCount: known - retained.count,
                sessionCount: Set(projected.map(\.sessionID)).count, undatedTurnCount: undated,
                excludedOutsideLifetime: outside, associationUncertainCount: uncertain, historyComplete: completeHistory,
                isPartial: partial, warnings: warnings))
    }

    private static func empty(root: String, warning: String) -> Self {
        Self(rootSessionID: root, goalID: nil, rows: [], summary: Summary(knownTurnCount: 0, indexedTurnCount: 0,
            omittedTurnCount: 0, sessionCount: 0, undatedTurnCount: 0, excludedOutsideLifetime: 0,
            associationUncertainCount: 0, historyComplete: false, isPartial: true, warnings: [warning]))
    }
    private static func valid(_ date: Date?, clock: Date) -> Date? {
        date.flatMap(ActivityAccountingPrecision.date).flatMap { $0 <= clock ? $0 : nil }
    }
    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { let clean = $0.trimmingCharacters(in: .whitespacesAndNewlines); return clean.isEmpty ? nil : clean }
    }
    private static func nativeKey(_ provider: AgentName, _ value: String) -> String { provider.rawValue + ":" + component(value) }
    private static func component(_ value: String) -> String { "\(value.utf8.count):\(value)" }
    private static func rowID(provider: AgentName, sessionID: String, turnID: String) -> String {
        "goal-replay:" + provider.rawValue + ":" + component(sessionID) + ":" + component(turnID)
    }
    private static func metadataIdentity(_ value: ActivitySession) -> String {
        [value.provider.rawValue, value.nativeID, value.parentSessionID ?? "", value.goal?.id ?? "", value.goal?.sessionID ?? "",
         value.goal?.status ?? "", value.goal.map { String($0.createdAt.timeIntervalSince1970) } ?? "",
         value.goal.map { String($0.updatedAt.timeIntervalSince1970) } ?? ""].map(component).joined()
    }
}
