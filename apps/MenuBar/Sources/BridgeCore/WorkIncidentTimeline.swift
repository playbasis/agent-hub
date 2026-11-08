import Foundation

/// A navigational projection of inspected native pages, not a task score or a
/// causal graph. Events are independent: adjacency does not prove that a later
/// tool, message, or check corrected an earlier one. No payload is retained.
public struct WorkIncidentTimeline: Sendable {
    public static let maximumPages = 128
    public static let maximumEvents = 4_096

    public enum Kind: String, Hashable, Sendable {
        case toolFailure, toolSuccess, toolInterrupted, toolUnknown
        case agentFailureMention, retryMention, correctionMention, verificationMention, completionMention
    }
    /// A tool event's time is the earliest timestamp among its linked items,
    /// not necessarily the time the outcome was returned.
    public enum TimeBasis: Equatable, Sendable { case recordedToolItem, visibleAgentMessage, unavailable }

    public struct Event: Identifiable, Sendable {
        public let id: String
        /// The exact replay row for navigation; nil for a standalone page.
        public let rowID: String?
        public let sessionID: String?
        public let turnID: String?
        /// Nil for a standalone page. True when source-to-goal attribution or
        /// the complete turn's fit inside a closed goal window is uncertain.
        public let goalAttributionUncertain: Bool?
        public let kind: Kind
        public let timestamp: Date?
        public let timeBasis: TimeBasis
        public let title: String
        public let toolName: String?
        public let evidenceIDs: [String]
        public let isObservedTool: Bool
        public let hasConflict: Bool
        public let callNotInPage: Bool
    }

    public let events: [Event]
    /// These counts describe indexed turns and their most recently inspected
    /// page, not all native pages, attempts, or the whole goal's success.
    public let indexedTurnCount: Int
    public let inspectedPageCount: Int
    public let partialPageCount: Int
    public let uninspectedTurnCount: Int
    public let omittedEventCount: Int
    public let isPartial: Bool

    /// Current page only; message hints require explicitly enabled visible text.
    public static func build(batch: WorkEvidenceBatch, includeLexicalHints: Bool = false,
                             scopeID: String) -> Self {
        let summary = WorkOutcomeSignals.summarize(batch.items,
            isPartial: batch.isPartial || batch.nextCursor != nil,
            includeLexicalHints: includeLexicalHints, scopeID: scopeID)
        // A hint has a time only when the exact source ID identifies one item;
        // duplicates or invalid dates cannot establish message chronology.
        let byID = Dictionary(grouping: batch.items.prefix(WorkOutcomeSignals.maximumItems), by: \.id)
        let times = byID.reduce(into: [String: Date]()) { result, pair in
            if pair.value.count == 1, let date = valid(pair.value[0].timestamp) { result[pair.key] = date }
        }
        let all = project(summary, row: nil, hintTimes: times)
        let omitted = max(0, all.count - maximumEvents)
        let retained = sort(retainReviewSignals(all))
        return Self(events: retained, indexedTurnCount: 1,
                    inspectedPageCount: 1, partialPageCount: summary.isPartial ? 1 : 0,
                    uninspectedTurnCount: 0, omittedEventCount: omitted,
                    isPartial: summary.isPartial || omitted > 0)
    }

    /// Goal-wide view of the most recently inspected page of each retained
    /// turn only. Cached hints have no individual timestamps in Summary; do
    /// not use turn timestamps as a substitute or imply a corrective link.
    public static func build(index: GoalReplayIndex, summaries: [String: WorkOutcomeSignals.Summary]) -> Self {
        var all: [Event] = [], pages = 0, partial = 0, omitted = 0
        for row in index.rows {
            guard pages < maximumPages, let summary = summaries[row.id],
                  summary.scopeID == row.provider.rawValue + ":" + row.sessionID + ":" + row.nativeTurnID else { continue }
            pages += 1
            if summary.isPartial { partial += 1 }
            all.append(contentsOf: project(summary, row: row, hintTimes: [:]))
            // Preserve review signals ahead of completed tools, otherwise a
            // busy successful turn can evict every error from the default
            // review view. Within each class, retain latest dated events, then
            // undated events if room remains. This is display prioritization,
            // not a task-quality judgment or an inferred chronology.
            if all.count > maximumEvents {
                omitted += all.count - maximumEvents
                all = retainReviewSignals(all)
            }
        }
        let sorted = sort(all)
        let uninspected = max(0, index.rows.count - pages)
        return Self(events: Array(sorted.prefix(maximumEvents)), indexedTurnCount: index.rows.count,
                    inspectedPageCount: pages, partialPageCount: partial,
                    uninspectedTurnCount: uninspected, omittedEventCount: omitted,
                    isPartial: index.summary.isPartial || uninspected > 0 || partial > 0 || omitted > 0)
    }

    private static func project(_ summary: WorkOutcomeSignals.Summary, row: GoalReplayIndex.Row?,
                                hintTimes: [String: Date]) -> [Event] {
        let identity = row.map { $0.id + ":" } ?? "page:"
        let uncertain = row.map { $0.association.state != .matched || $0.coverage.contains(.uncertainGoalLink) || $0.coverage.contains(.extendsPastGoalEnd) }
        var result = summary.executions.map { execution -> Event in
            let kind: Kind
            switch execution.outcome {
            case .failure: kind = .toolFailure
            case .success: kind = .toolSuccess
            case .interrupted: kind = .toolInterrupted
            case .unknown: kind = .toolUnknown
            }
            return Event(id: identity + execution.id, rowID: row?.id, sessionID: row?.sessionID,
                         turnID: row?.nativeTurnID, goalAttributionUncertain: uncertain,
                         kind: kind, timestamp: valid(execution.timestamp),
                         timeBasis: valid(execution.timestamp) == nil ? .unavailable : .recordedToolItem,
                         title: execution.outcome.title, toolName: execution.title,
                         evidenceIDs: execution.evidenceIDs, isObservedTool: true,
                         hasConflict: execution.hasConflict, callNotInPage: execution.callNotInPage)
        }
        result.append(contentsOf: summary.hints.map { hint -> Event in
            let kind: Kind
            switch hint.kind {
            case .reportedFailure: kind = .agentFailureMention
            case .retryMention: kind = .retryMention
            case .correctionMention: kind = .correctionMention
            case .verificationMention: kind = .verificationMention
            case .reportedCompletion: kind = .completionMention
            }
            let time = hint.evidenceIDs.count == 1 ? hintTimes[hint.evidenceIDs[0]] : nil
            return Event(id: identity + hint.id, rowID: row?.id, sessionID: row?.sessionID,
                         turnID: row?.nativeTurnID, goalAttributionUncertain: uncertain,
                         kind: kind, timestamp: time,
                         timeBasis: time == nil ? .unavailable : .visibleAgentMessage,
                         title: hint.title, toolName: nil, evidenceIDs: hint.evidenceIDs,
                         isObservedTool: false, hasConflict: false, callNotInPage: false)
        })
        return result
    }

    private static func valid(_ date: Date?) -> Date? {
        date.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
    }
    private static func retainReviewSignals(_ events: [Event]) -> [Event] {
        guard events.count > maximumEvents else { return events }
        let ranked = events.sorted {
            let firstReview = $0.kind != .toolSuccess
            let secondReview = $1.kind != .toolSuccess
            if firstReview != secondReview { return firstReview }
            switch ($0.timestamp, $1.timestamp) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
        return Array(ranked.prefix(maximumEvents))
    }
    private static func sort(_ events: [Event]) -> [Event] {
        events.sorted {
            switch ($0.timestamp, $1.timestamp) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
    }
}

public extension WorkOutcomeSignals.Summary {
    /// Forget all text-derived hints when the user disables visible text.
    func withoutLexicalHints() -> Self {
        Self(scopeID: scopeID, executions: executions, hints: [], isPartial: isPartial,
             adapterVersion: adapterVersion)
    }
}
