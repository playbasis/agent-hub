import Foundation

/// Counts imported model opinions about captured pages. This is not provider
/// accounting, a verified tool result, or a goal-wide success/failure rate.
public struct JEVHistoricalToolSummary: Equatable, Sendable {
    public let captureCount: Int
    public let partialCaptureCount: Int
    /// Captures where at least one imported opinion flagged a listed nonzero exit.
    /// The count intentionally includes contested or uncertain captures.
    public let nonzeroFlaggedCount: Int
    /// Captures with at least one yes and one no opinion; not judge accuracy.
    public let nonzeroConflictCount: Int
    /// Captures with at least one unknown opinion; can overlap other counts.
    public let nonzeroUncertainCount: Int
    public let singleModelCount: Int

    private struct CaptureKey: Hashable {
        let evidenceID: String
        let captureID: String
        let stateHash: String
        let rubricHash: String
    }

    /// Different captures, states and rubrics remain distinct. Repeated model
    /// calls count as opinions about a capture, never additional captures.
    /// Invalid local receipts are excluded rather than linked by assumption.
    public static func build(receipts: [JEVToolPageAssessment], sessionIDs: Set<String>) -> Self {
        let selected = receipts.filter { sessionIDs.contains($0.sessionID) && (try? $0.validate()) != nil }
        let groups = Dictionary(grouping: selected) {
            CaptureKey(evidenceID: $0.evidenceID, captureID: $0.captureID, stateHash: $0.stateHash, rubricHash: $0.rubricHash)
        }
        var partial = 0, flagged = 0, conflict = 0, uncertain = 0, single = 0
        for opinions in groups.values {
            if opinions.contains(where: { $0.pagePartial || $0.toolFactsTruncated }) { partial += 1 }
            let values = Set(opinions.map(\.answers.listedNonzeroExit))
            if values.contains(.yes) { flagged += 1 }
            if values.contains(.yes) && values.contains(.no) { conflict += 1 }
            if values.contains(.unknown) { uncertain += 1 }
            if Set(opinions.map(\.model)).count == 1 { single += 1 }
        }
        return Self(captureCount: groups.count, partialCaptureCount: partial,
                    nonzeroFlaggedCount: flagged, nonzeroConflictCount: conflict,
                    nonzeroUncertainCount: uncertain, singleModelCount: single)
    }
}
