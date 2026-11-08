import Foundation
import CryptoKit

/// The only metadata eligible for this explicit pilot export. IDs stay local.
public enum JEVAssessmentEvidence {
    public struct Metadata: Codable, Sendable {
        public let provider: String, status: String
        public let durationSeconds: Double?
        public let categoryCounts: [String: Int]
        public let toolCount: Int?, modelStepCount: Int?
        public let models: [String]
        public let historyPartial: Bool
        enum CodingKeys: String, CodingKey { case provider, status, durationSeconds, categoryCounts, toolCount, modelStepCount, models, historyPartial }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider, forKey: .provider); try c.encode(status, forKey: .status); try c.encode(durationSeconds, forKey: .durationSeconds)
            try c.encode(categoryCounts, forKey: .categoryCounts); try c.encode(toolCount, forKey: .toolCount); try c.encode(modelStepCount, forKey: .modelStepCount)
            try c.encode(models, forKey: .models); try c.encode(historyPartial, forKey: .historyPartial)
        }
    }
    public struct Snapshot: Codable, Sendable {
        public let evidenceID: String, sessionID: String, turnID: String, snapshotDigest: String
        public let metadata: Metadata
    }
    /// Identity fields are intentionally local-only and are not added to the
    /// v1 digest or transmitted to an assessor. Two observations claiming the
    /// same local evidence ID must agree about these fields before either can
    /// be considered current.
    private struct SourceIdentity: Equatable {
        let provider: AgentName
        let nativeSessionID: String
        let parentSessionID: String?
        let startedAt: Date?
        let completedAt: Date?
    }
    private struct SessionIdentity: Equatable {
        let provider: AgentName
        let nativeSessionID: String
        let parentSessionID: String?
    }
    private struct Candidate {
        let snapshot: Snapshot
        let source: SourceIdentity
    }
    private enum Selection {
        case candidate(Candidate)
        case ambiguous
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func evidenceID(sessionID: String, turnID: String) -> String {
        let identity = "\(sessionID.utf8.count):\(sessionID)\(turnID.utf8.count):\(turnID)"
        return "evidence:" + hash(Data(identity.utf8))
    }
    public static func snapshots(overview: ActivityOverview, restrictingTo evidenceIDs: Set<String>? = nil) -> [Snapshot] {
        let allowed = Set(["Coordination", "Execution", "Implementation", "Inspection", "Other", "Research", "Review", "Tests"])
        let statuses = Set(["completed", "complete", "finished", "done", "failed", "error", "interrupted", "running", "in_progress", "in-progress", "active", "pending", "waiting", "canceled", "cancelled", "stopped", "idle", "paused", "queued", "aborted", "success", "succeeded", "unknown"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A conflicting session identity invalidates its turn links even when
        // the conflicting observation omits the target turn altogether.
        var identities: [String: SessionIdentity] = [:], ambiguousSessions = Set<String>()
        for session in overview.sessions {
            if Task.isCancelled { return [] }
            let identity = SessionIdentity(provider: session.provider, nativeSessionID: session.nativeID, parentSessionID: session.parentSessionID)
            if let previous = identities[session.id], previous != identity { ambiguousSessions.insert(session.id) }
            else if identities[session.id] == nil { identities[session.id] = identity }
        }
        var selected: [String: Selection] = [:]
        for session in overview.sessions {
          if ambiguousSessions.contains(session.id) { continue }
          for turn in session.turns {
            if Task.isCancelled { return [] }
            // Filter before encoding per-turn metadata. This keeps dashboard
            // refresh work proportional to imported assessments, not all data.
            let evidenceID = Self.evidenceID(sessionID: session.id, turnID: turn.id)
            if let evidenceIDs, !evidenceIDs.contains(evidenceID) { continue }
            var categories: [String: Int] = [:]
            for (name, count) in turn.categories { let title = name.capitalized; if allowed.contains(title), count >= 0, count <= 100_000_000 { categories[title, default: 0] += count } }
            let rawModels = [turn.model].compactMap { $0 } + (turn.modelSteps ?? []).compactMap { $0.model }
            let pattern = "^(claude-|gpt-|gemini-|grok-|o[134](-|$))[A-Za-z0-9_.-]{0,70}$"
            let models = Array(Set(rawModels.filter { $0.range(of: pattern, options: .regularExpression) != nil })).sorted().prefix(16)
            let duration = turn.durationSeconds.flatMap { $0.isFinite && $0 >= 0 && $0 <= 31_536_000 ? $0 : nil }
            let toolCount = turn.toolCount.flatMap { (0...100_000_000).contains($0) ? $0 : nil }
            let stepCount = turn.modelSteps.map { $0.count <= 100_000_000 ? $0.count : 100_000_000 }
            let metadata = Metadata(provider: ["claude", "codex", "gemini", "grok"].contains(session.provider.rawValue) ? session.provider.rawValue : "unknown", status: statuses.contains(turn.status.lowercased()) ? turn.status.lowercased() : "unknown", durationSeconds: duration, categoryCounts: categories, toolCount: toolCount, modelStepCount: stepCount, models: Array(models), historyPartial: !session.historyComplete || turn.modelStepsComplete != true)
            guard let data = try? encoder.encode(metadata) else { continue }
            // Length-prefixing avoids collisions when native IDs contain separators.
            let snapshot = Snapshot(evidenceID: evidenceID, sessionID: session.id, turnID: turn.id, snapshotDigest: hash(data), metadata: metadata)
            let source = SourceIdentity(provider: session.provider, nativeSessionID: session.nativeID,
                                        parentSessionID: session.parentSessionID,
                                        startedAt: turn.startedAt, completedAt: turn.completedAt)
            let candidate = Candidate(snapshot: snapshot, source: source)
            switch selected[evidenceID] {
            case nil:
                selected[evidenceID] = .candidate(candidate)
            case .some(.candidate(let previous)):
                if previous.source != source || previous.snapshot.snapshotDigest != snapshot.snapshotDigest {
                    selected[evidenceID] = .ambiguous
                }
            case .some(.ambiguous):
                break
            }
          }
        }
        // A digest is not evidence that contradictory source identities are
        // equivalent. Never select a winner based on input-array order.
        return selected.keys.sorted().compactMap { key in
            guard case .some(.candidate(let candidate)) = selected[key] else { return nil }
            return candidate.snapshot
        }
    }
    public static func currentDigests(overview: ActivityOverview, restrictingTo evidenceIDs: Set<String>? = nil) -> [String: String] {
        Dictionary(uniqueKeysWithValues: snapshots(overview: overview, restrictingTo: evidenceIDs).map { ($0.evidenceID, $0.snapshotDigest) })
    }
    /// Explicit local-only export: includes private local identities and must
    /// never be used as the remote model payload. Atomic, owner-only, no-clobber.
    public static func exportSnapshots(overview: ActivityOverview, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshots(overview: overview))
        try Task.checkCancellation()
        guard data.count <= 64 * 1024 * 1024 else { throw JEVAssessmentError.tooLarge }
        try ActivityAccountingExport.write(data, to: url)
    }
}
