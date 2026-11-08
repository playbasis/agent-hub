import Foundation

/// Immutable judgment of a captured page, never a current or verified outcome.
public struct JEVToolPageAssessment: Codable, Equatable, Sendable, Identifiable {
    public enum TriState: String, Codable, Sendable { case yes, no, unknown }
    public struct Answers: Codable, Equatable, Sendable {
        public let listedNonzeroExit, listedCompletedTool, artifactRecorded, goalStatusRecordedCompleted, listedMissingDuration, recordedModelsPresent, turnElapsedMissing: TriState
        public init(listedNonzeroExit: TriState, listedCompletedTool: TriState, artifactRecorded: TriState, goalStatusRecordedCompleted: TriState, listedMissingDuration: TriState, recordedModelsPresent: TriState, turnElapsedMissing: TriState) {
            self.listedNonzeroExit = listedNonzeroExit; self.listedCompletedTool = listedCompletedTool; self.artifactRecorded = artifactRecorded; self.goalStatusRecordedCompleted = goalStatusRecordedCompleted; self.listedMissingDuration = listedMissingDuration; self.recordedModelsPresent = recordedModelsPresent; self.turnElapsedMissing = turnElapsedMissing
        }
    }
    /// Model-reported values; thresholds are policy, not calibrated probabilities.
    public struct Noul: Codable, Equatable, Sendable {
        public let listedNonzeroExit, listedCompletedTool, artifactRecorded, goalStatusRecordedCompleted, listedMissingDuration, recordedModelsPresent, turnElapsedMissing: Double
        public init(listedNonzeroExit: Double, listedCompletedTool: Double, artifactRecorded: Double, goalStatusRecordedCompleted: Double, listedMissingDuration: Double, recordedModelsPresent: Double, turnElapsedMissing: Double) {
            self.listedNonzeroExit = listedNonzeroExit; self.listedCompletedTool = listedCompletedTool; self.artifactRecorded = artifactRecorded; self.goalStatusRecordedCompleted = goalStatusRecordedCompleted; self.listedMissingDuration = listedMissingDuration; self.recordedModelsPresent = recordedModelsPresent; self.turnElapsedMissing = turnElapsedMissing
        }
    }
    public let schemaVersion: String
    public let id, sessionID, turnID, evidenceID, captureID, model, rubricHash, stateHash, requestHash: String
    public let assessedAt: Date?
    public let capturedAt: Date?
    public let source: String
    public let pagePartial, toolFactsTruncated, artifactCountIsPartial: Bool
    public let factCount: Int
    public let answers: Answers
    public let noul: Noul
    public init(id: String, sessionID: String, turnID: String, evidenceID: String, captureID: String, model: String, rubricHash: String, stateHash: String, requestHash: String, assessedAt: Date?, capturedAt: Date? = nil, pagePartial: Bool, toolFactsTruncated: Bool, artifactCountIsPartial: Bool, factCount: Int, answers: Answers, noul: Noul) {
        self.schemaVersion = "jev-tool-page-assessment/1"; self.id = id; self.sessionID = sessionID; self.turnID = turnID; self.evidenceID = evidenceID; self.captureID = captureID; self.model = model; self.rubricHash = rubricHash; self.stateHash = stateHash; self.requestHash = requestHash; self.assessedAt = assessedAt; self.capturedAt = capturedAt; self.source = "historical_structured_page"; self.pagePartial = pagePartial; self.toolFactsTruncated = toolFactsTruncated; self.artifactCountIsPartial = artifactCountIsPartial; self.factCount = factCount; self.answers = answers; self.noul = noul
    }
    public func validate() throws {
        func safeID(_ value: String, max: Int) -> Bool { !value.isEmpty && value.utf8.count <= max && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0) } }
        func localRef(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 1024 && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        func digest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard schemaVersion == "jev-tool-page-assessment/1", source == "historical_structured_page", safeID(id, max: 128), safeID(model, max: 128), localRef(sessionID), localRef(turnID), evidenceID == JEVAssessmentEvidence.evidenceID(sessionID: sessionID, turnID: turnID), digest(captureID), digest(rubricHash), digest(stateHash), digest(requestHash), (1...20).contains(factCount), assessedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true, capturedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw JEVAssessmentError.invalidReceipt }
        do { let n = noul
            let values = [n.listedNonzeroExit, n.listedCompletedTool, n.artifactRecorded, n.goalStatusRecordedCompleted, n.listedMissingDuration, n.recordedModelsPresent, n.turnElapsedMissing]
            let flags = [answers.listedNonzeroExit, answers.listedCompletedTool, answers.artifactRecorded, answers.goalStatusRecordedCompleted, answers.listedMissingDuration, answers.recordedModelsPresent, answers.turnElapsedMissing]
            guard zip(values, flags).allSatisfy({ pair in pair.0.isFinite && (0...1).contains(pair.0) && pair.1 == (pair.0 <= 0.4 ? .no : pair.0 >= 0.6 ? .yes : .unknown) }) else { throw JEVAssessmentError.invalidReceipt }
        }
    }
}
