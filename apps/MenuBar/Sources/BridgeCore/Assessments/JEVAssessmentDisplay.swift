import Foundation

/// A conservative presentation of model opinions, never native accounting.
/// Count a native evidence item once, not once per judge or repeated call.
public struct JEVAssessmentDisplay: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: String
        public let sessionID: String
        public let turnID: String?
        public let assessedAt: Date
        public let modelOpinions: [String]
    }
    public var currentEvidence = 0
    public var agreedKinds: [String: Int] = [:]
    public var singleJudge = 0
    public var disagreements = 0
    /// Includes a specific label versus unknown; unlike a conflict between two
    /// specific labels, an abstention is not evidence that either is wrong.
    public var differingLabels = 0
    public var incomparable = 0
    public var insufficient = 0
    public var stale = 0
    public var unavailable = 0
    public var flaggedRetry = 0
    public var flaggedCorrection = 0
    public var flaggedClarification = 0
    public var flaggedClaim = 0
    public var items: [Item] = []

    public init() {}

    public static func build(receipts: [JEVAssessmentReceipt], currentDigests: [String: String], sessionIDs: Set<String>) -> Self {
        let allowedKinds = Set(["implementation", "debugging", "research", "review", "verification", "planning", "coordination"])
        var result = Self()
        let selected = receipts.filter { sessionIDs.contains($0.sessionID) }
        let grouped = Dictionary(grouping: selected, by: \.evidenceID)
        for (evidenceID, rows) in grouped {
            // An imported file may carry inconsistent identities. Never join
            // or open another session merely because its digest matches.
            let linked = rows.filter { row in
                guard let turnID = row.turnID else { return false }
                return JEVAssessmentEvidence.evidenceID(sessionID: row.sessionID, turnID: turnID) == evidenceID
            }
            guard !linked.isEmpty else { result.unavailable += 1; continue }
            guard let digest = currentDigests[evidenceID] else { result.unavailable += 1; continue }
            let current = linked.filter { $0.snapshotDigest == digest && $0.status == .assessed && $0.result != nil }
            if current.isEmpty {
                if linked.contains(where: { $0.snapshotDigest != digest }) { result.stale += 1 }
                else { result.unavailable += 1 }
                continue
            }
            // One latest verdict per model; an equal-time tie with different
            // evidence, rubric, or verdict has no defensible winner. Receipt
            // IDs are not a timestamp and must not resolve a disagreement.
            let attemptsByModel = Dictionary(grouping: current, by: \.model)
            var perModel: [String: JEVAssessmentReceipt] = [:]
            var ambiguousModels = Set<String>()
            for (model, attempts) in attemptsByModel {
                guard let latestAt = attempts.map(\.assessedAt).max() else { continue }
                let tied = attempts.filter { $0.assessedAt == latestAt }.sorted { $0.id < $1.id }
                guard let first = tied.first else { continue }
                if tied.contains(where: {
                    $0.result != first.result || $0.rubricHash != first.rubricHash ||
                    $0.rubricVersion != first.rubricVersion || $0.inputDigest != first.inputDigest ||
                    $0.provider != first.provider
                }) {
                    ambiguousModels.insert(model)
                } else {
                    perModel[model] = first
                }
            }
            let opinions = perModel.values.compactMap(\.result)
            result.currentEvidence += 1
            if attemptsByModel.count == 1 { result.singleJudge += 1 }
            if let newest = current.max(by: { $0.assessedAt == $1.assessedAt ? $0.id < $1.id : $0.assessedAt < $1.assessedAt }) {
                let labels = attemptsByModel.keys.sorted().compactMap { model -> String? in
                    if ambiguousModels.contains(model) { return "\(model): conflicting latest assessments" }
                    guard let row = perModel[model] else { return nil }
                    guard let opinion = row.result else { return nil }
                    let outcome = opinion.tags.contains("metadata_only") ? "outcome not established" : "unverified: \(opinion.outcomeSupport)"
                    return "\(row.model): \(opinion.workKind), \(outcome)"
                }
                result.items.append(Item(id: evidenceID, sessionID: newest.sessionID, turnID: newest.turnID,
                                         assessedAt: newest.assessedAt, modelOpinions: labels))
            }
            guard ambiguousModels.isEmpty else { result.incomparable += 1; continue }
            // A shared local snapshot identity does not prove two imported
            // assessments actually saw the same input. Compare the declared
            // model input, provider and version as well as the rubric bytes;
            // otherwise agreement or disagreement would mix different jobs.
            guard Set(perModel.values.map(\.rubricHash)).count == 1,
                  Set(perModel.values.map(\.rubricVersion)).count == 1,
                  Set(perModel.values.map(\.inputDigest)).count == 1,
                  Set(perModel.values.map(\.provider)).count == 1 else {
                result.incomparable += 1; continue
            }
            let kinds = Set(opinions.map { allowedKinds.contains($0.workKind) ? $0.workKind : "unknown" })
            if kinds.count > 1 { result.differingLabels += 1 }
            let specific = kinds.subtracting(["unknown"])
            if specific.count > 1 { result.disagreements += 1 }
            else if kinds.contains("unknown") { result.insufficient += 1 }
            else if let kind = specific.first { result.agreedKinds[kind, default: 0] += 1 }
            else { result.insufficient += 1 }
            // Aggregate-only metadata cannot establish a retry, correction or
            // claim. Preserve the raw judgment in its receipt but never surface
            // it as a review candidate without richer evidence.
            let contentOpinions = perModel.values.filter { $0.result?.tags.contains("metadata_only") == false }.compactMap(\.result)
            if contentOpinions.contains(where: { $0.retry == .yes }) { result.flaggedRetry += 1 }
            if contentOpinions.contains(where: { $0.correction == .yes }) { result.flaggedCorrection += 1 }
            if contentOpinions.contains(where: { $0.clarification == .yes }) { result.flaggedClarification += 1 }
            if contentOpinions.contains(where: { $0.claimNeedsReview == .yes }) { result.flaggedClaim += 1 }
        }
        result.items.sort { $0.assessedAt == $1.assessedAt ? $0.id < $1.id : $0.assessedAt > $1.assessedAt }
        return result
    }
}
