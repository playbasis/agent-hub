import Foundation

/// An external judgment, never native accounting or a verified task outcome.
public struct JEVAssessmentReceipt: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case assessed, failed, unavailable }
    public enum TriState: String, Codable, Sendable { case yes, no, unknown }
    public struct Usage: Codable, Equatable, Sendable {
        public let inputTokens: Int?
        public let outputTokens: Int?
        public init(inputTokens: Int? = nil, outputTokens: Int? = nil) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
    }
    public struct Result: Codable, Equatable, Sendable {
        public let workKind: String
        public let evidenceLevel: String
        public let outcomeSupport: String
        /// Descriptive hints, not measured counts or authoritative classifications.
        public let tags: [String]
        public let retry: TriState
        public let correction: TriState
        public let clarification: TriState
        public let claimNeedsReview: TriState
        /// Model-reported confidence, not calibrated probability of correctness.
        public let modelReportedConfidence: Double?
        public init(workKind: String, evidenceLevel: String, outcomeSupport: String, tags: [String] = [], retry: TriState, correction: TriState, clarification: TriState, claimNeedsReview: TriState, modelReportedConfidence: Double? = nil) {
            self.workKind = workKind; self.evidenceLevel = evidenceLevel; self.outcomeSupport = outcomeSupport; self.tags = tags
            self.retry = retry; self.correction = correction; self.clarification = clarification; self.claimNeedsReview = claimNeedsReview; self.modelReportedConfidence = modelReportedConfidence
        }
    }
    public let schemaVersion: String
    public let id: String
    public let evidenceID: String
    public let snapshotDigest: String
    public let sessionID: String
    public let turnID: String?
    public let provider: String
    public let inputDigest: String
    public let model: String
    public let rubricVersion: String
    public let rubricHash: String
    public let assessedAt: Date
    public let status: Status
    public let result: Result?
    public let usage: Usage?
    public init(id: String, evidenceID: String, snapshotDigest: String, sessionID: String, turnID: String? = nil, provider: String, inputDigest: String, model: String, rubricVersion: String, rubricHash: String, assessedAt: Date, status: Status, result: Result? = nil, usage: Usage? = nil) {
        self.schemaVersion = "jev-assessment/1"; self.id = id; self.evidenceID = evidenceID; self.snapshotDigest = snapshotDigest; self.sessionID = sessionID; self.turnID = turnID; self.provider = provider; self.inputDigest = inputDigest; self.model = model; self.rubricVersion = rubricVersion; self.rubricHash = rubricHash; self.assessedAt = assessedAt; self.status = status; self.result = result; self.usage = usage
    }
    public func validate() throws {
        func identifier(_ s: String, max: Int = 256) -> Bool {
            !s.isEmpty && s.utf8.count <= max && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0) }
        }
        func digest(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) } }
        guard schemaVersion == "jev-assessment/1", identifier(id), identifier(evidenceID), identifier(sessionID), turnID.map({ identifier($0) }) ?? true,
              identifier(provider, max: 64), identifier(model, max: 128), identifier(rubricVersion, max: 128), digest(snapshotDigest), digest(inputDigest), digest(rubricHash), assessedAt.timeIntervalSince1970.isFinite,
              (status == .assessed) == (result != nil) else { throw JEVAssessmentError.invalidReceipt }
        if let r = result {
            guard identifier(r.workKind, max: 64), identifier(r.evidenceLevel, max: 64), identifier(r.outcomeSupport, max: 64), r.tags.count <= 32,
                  r.tags.allSatisfy({ identifier($0, max: 64) }), Set(r.tags).count == r.tags.count,
                  r.modelReportedConfidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw JEVAssessmentError.invalidReceipt }
        }
        if let u = usage, [u.inputTokens, u.outputTokens].compactMap({ $0 }).contains(where: { $0 < 0 || $0 > 100_000_000 }) { throw JEVAssessmentError.invalidReceipt }
    }
}

public enum JEVAssessmentError: Error { case unsafePath, tooLarge, invalidReceipt, duplicateConflict, invalidJSON }

public struct JEVAssessmentSummary: Sendable {
    public let receipt: JEVAssessmentReceipt
    /// nil means no current snapshot was supplied, not that it is current.
    public let isStale: Bool?
}

public struct JEVAssessmentRollup: Sendable {
    public let total: Int
    public let assessed: Int
    public let failed: Int
    public let unavailable: Int
    public let stale: Int
    public let byProvider: [String: Int]
    public let bySession: [String: Int]
    public let byWorkKind: [String: Int]
}
