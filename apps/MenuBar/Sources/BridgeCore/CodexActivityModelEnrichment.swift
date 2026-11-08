import Foundation

extension CodexActivityParser {
    /// Adds checkpoint metadata to existing native turn IDs. rootTurnId is a
    /// causal goal correlation (children can share it), never a turn alias.
    static func enrichModelSteps(_ value: ActivitySession, telemetry: CodexModelStepReader.Result) -> ActivitySession {
        var session = value
        session.warnings.append(contentsOf: telemetry.warnings)
        var byID = Dictionary(session.turns.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for (nativeID, metadata) in telemetry.turns {
            let id = "codex:turn:\(nativeID)"
            let prior = byID[id]
            // Older receipt-bearing turns may be outside the API's recent
            // turn page. Do not manufacture turns from bare context alone.
            guard prior != nil || !metadata.modelSteps.isEmpty else { continue }
            var turn = prior ?? ActivityTurn(id: id, status: metadata.status)
            turn.startedAt = turn.startedAt ?? metadata.startedAt
            turn.completedAt = turn.completedAt ?? metadata.completedAt
            if turn.durationSeconds == nil, let start = turn.startedAt, let end = turn.completedAt, end >= start {
                turn.durationSeconds = end.timeIntervalSince(start)
            }
            turn.model = metadata.model ?? turn.model
            turn.effort = metadata.effort ?? turn.effort
            turn.modelSteps = metadata.modelSteps
            turn.modelStepsComplete = metadata.modelStepsComplete
            if !metadata.skills.isEmpty { turn.skills = (turn.skills ?? []).mergingSkillUses(metadata.skills) }
            else if telemetry.finished, turn.skills == nil { turn.skills = [] }
            if !metadata.modelSteps.isEmpty {
                let usage = modelStepUsage(metadata.modelSteps)
                turn.usage = usage
                turn.usageIsPartial = !metadata.modelStepsComplete || metadata.modelSteps.contains { $0.usageIsPartial == true || !$0.usage.hasAuthoritativeProvenance }
            }
            if prior == nil { turn.status = metadata.status }
            byID[id] = prior?.merging(turn) ?? turn
        }
        session.turns = byID.values.sorted {
            let lhs = $0.startedAt ?? .distantPast, rhs = $1.startedAt ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        session.models = Array(Set(session.turns.compactMap(\.model) + session.turns.flatMap { ($0.modelSteps ?? []).compactMap(\.model) })).sorted()
        session.efforts = Array(Set(session.turns.compactMap(\.effort) + session.turns.flatMap { ($0.modelSteps ?? []).compactMap(\.effort) })).sorted()
        if !telemetry.turns.isEmpty || telemetry.hitBudget || telemetry.hitDeadline || telemetry.hitLimit {
            session.historyComplete = session.historyComplete && telemetry.finished && !telemetry.hitLimit
        }
        if telemetry.hitBudget || telemetry.hitDeadline || !telemetry.finished {
            session.warnings.append("Model-step history is still being read in bounded passes. Counts are observed lower bounds; a later refresh resumes the saved position.")
        }
        session.warnings = Array(Set(session.warnings)).sorted()
        return session
    }

    private static func modelStepUsage(_ steps: [ActivityModelStep]) -> TokenUsage {
        let steps = steps.filter { $0.usage.hasAuthoritativeProvenance }
        func component(_ field: KeyPath<TokenUsage, Int?>) -> Int? {
            let values = steps.map { $0.usage[keyPath: field] }
            // A component absent from even one checkpoint is not a complete
            // component total. Overall reported totals remain independent.
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return ActivityMetrics.knownTotal(values)
        }
        let total = ActivityMetrics.knownTotal(steps.map { $0.usage.total })
        let provenance: MetricProvenance = steps.isEmpty ? .unavailable : .derived
        return TokenUsage(input: component(\.input), output: component(\.output), cachedInput: component(\.cachedInput),
                          cacheWriteInput: component(\.cacheWriteInput), reasoning: component(\.reasoning), total: total, provenance: provenance)
    }
}
