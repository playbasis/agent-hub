import BridgeCore
import Foundation

/// Explanations for saved sessions without separately dated work in the
/// selected report. These are evidence states, never live runtime states.
enum AgentRosterEvidence: String, Equatable {
    case recorded, metadataOnly, sharedHistory, outsidePeriod, datesUnavailable, unplacedUsage, unattributed

    var title: String {
        switch self {
        case .recorded: return "Recorded work"
        case .metadataOnly: return "History unavailable"
        case .sharedHistory: return "Copied history only"
        case .outsidePeriod: return "Outside this period"
        case .datesUnavailable: return "Dates unavailable"
        case .unplacedUsage: return "Usage not placed"
        case .unattributed: return "No attributed work"
        }
    }

    var explanation: String {
        switch self {
        case .recorded: return "This session has its own saved evidence in this period."
        case .metadataOnly: return "The session was discovered, but its own work records are not available in this snapshot. Missing usage is not zero."
        case .sharedHistory: return "Only inherited records are saved here. They stay with their owning session and are not counted twice."
        case .outsidePeriod: return "This session has saved records, but none dated inside this report window."
        case .datesUnavailable: return "Saved records have missing or unusable dates, so they cannot be placed in this period."
        case .unplacedUsage: return "Saved usage cannot be assigned to this period and is excluded from its totals."
        case .unattributed: return "Saved records do not establish separately attributed work in this view. They remain available for inspection."
        }
    }

    static func read(sessionID: String, report: ActivityAccounting.Report, records: TurnInspectionRecords) -> Self {
        guard report.isValid else { return .unattributed }
        if report.totals.nativeRecords > 0 || report.totals.observedModelSteps > 0 || report.totals.tokensKnown != nil {
            return .recorded
        }
        if report.summary.unallocatedTurns > 0 { return .unplacedUsage }
        let retained = records.turns(in: sessionID)
        guard !retained.isEmpty else { return .metadataOnly }
        let owned = records.ownedTurns[sessionID] ?? []
        guard !owned.isEmpty else { return .sharedHistory }

        func dates(_ turn: ActivityTurn) -> [Date] {
            ([turn.startedAt, turn.completedAt] + (turn.modelSteps ?? []).map(\.timestamp))
                .compactMap { $0.flatMap(ActivityAccountingPrecision.date) }
        }
        if owned.contains(where: { dates($0).isEmpty }) { return .datesUnavailable }
        func inWindow(_ date: Date) -> Bool {
            date < report.scope.to && (report.scope.from.map { date >= $0 } ?? true)
        }
        let hasWindowEvidence = owned.contains { turn in
            if dates(turn).contains(where: inWindow) { return true }
            guard let start = turn.startedAt.flatMap(ActivityAccountingPrecision.date),
                  let end = turn.completedAt.flatMap(ActivityAccountingPrecision.date), end >= start else { return false }
            return start < report.scope.to && (report.scope.from.map { end > $0 } ?? true)
        }
        return hasWindowEvidence ? .unattributed : .outsidePeriod
    }

    /// Native conversation names take precedence over an older attached goal.
    /// A goal-launch instruction is a wrapper, not the user's task title.
    static func displayTitle(_ session: ActivitySession) -> String {
        let native = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if ActivityTitles.isPlaceholder(native) || ActivityTitles.isCodexGoalWrapper(native),
           let objective = session.goal?.objective.trimmingCharacters(in: .whitespacesAndNewlines),
           !ActivityTitles.isPlaceholder(objective), !ActivityTitles.isCodexGoalWrapper(objective) {
            return objective
        }
        return ActivityTitles.display(native, provider: session.provider, projectPath: session.projectPath)
    }

    /// A goal attachment alone does not establish a coordinator role. Roles
    /// describe date-safe, owned tool categories from the same report as totals.
    static func role(_ report: ActivityAccounting.Report) -> AgentRole? {
        let categories = ActivityReportPresentation.categoryEvidence(report)
        guard categories.contains(where: { $0.categories.values.contains(where: { $0 > 0 }) }) else { return nil }
        let evidence = ActivitySession(id: "roster-role", provider: .none, nativeID: "", title: "",
            createdAt: report.scope.to, updatedAt: report.scope.to, observedAt: report.scope.to,
            turns: categories, source: "canonical-roster-categories")
        return AgentRole.infer(evidence, hasChildren: false)
    }
}
