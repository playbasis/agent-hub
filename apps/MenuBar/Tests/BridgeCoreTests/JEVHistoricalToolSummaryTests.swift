import Foundation
import XCTest
@testable import BridgeCore

final class JEVHistoricalToolSummaryTests: XCTestCase {
    private func receipt(id: String, session: String = "session", turn: String = "turn",
                         capture: String = String(repeating: "a", count: 64),
                         state: String = String(repeating: "b", count: 64),
                         rubric: String = String(repeating: "c", count: 64),
                         model: String = "jev-1.13.0", flag: JEVToolPageAssessment.TriState,
                         partial: Bool = false, truncated: Bool = false,
                         evidenceOverride: String? = nil) -> JEVToolPageAssessment {
        let probability: Double = flag == .yes ? 0.9 : flag == .no ? 0.1 : 0.5
        return JEVToolPageAssessment(id: id, sessionID: session, turnID: turn,
            evidenceID: evidenceOverride ?? JEVAssessmentEvidence.evidenceID(sessionID: session, turnID: turn),
            captureID: capture, model: model, rubricHash: rubric, stateHash: state,
            requestHash: String(repeating: "d", count: 64), assessedAt: nil,
            pagePartial: partial, toolFactsTruncated: truncated, artifactCountIsPartial: true, factCount: 1,
            answers: .init(listedNonzeroExit: flag, listedCompletedTool: .yes, artifactRecorded: .no,
                           goalStatusRecordedCompleted: .unknown, listedMissingDuration: .no,
                           recordedModelsPresent: .yes, turnElapsedMissing: .no),
            noul: .init(listedNonzeroExit: probability, listedCompletedTool: 0.9, artifactRecorded: 0.1,
                        goalStatusRecordedCompleted: 0.5, listedMissingDuration: 0.1,
                        recordedModelsPresent: 0.9, turnElapsedMissing: 0.1))
    }

    func testOpinionsAndRepeatedCallsCountOneCaptureAndPreserveConflict() {
        let values = [receipt(id: "first", flag: .yes, partial: true),
                      receipt(id: "again", flag: .yes),
                      receipt(id: "other", model: "jev-1.14.0", flag: .no),
                      receipt(id: "unknown", model: "jev-1.14.0", flag: .unknown)]
        let summary = JEVHistoricalToolSummary.build(receipts: values, sessionIDs: ["session"])
        XCTAssertEqual(summary.captureCount, 1)
        XCTAssertEqual(summary.partialCaptureCount, 1)
        XCTAssertEqual(summary.nonzeroFlaggedCount, 1)
        XCTAssertEqual(summary.nonzeroConflictCount, 1)
        XCTAssertEqual(summary.nonzeroUncertainCount, 1)
        XCTAssertEqual(summary.singleModelCount, 0)
    }

    func testCaptureStateAndRubricAreSeparateAndScopeIsExact() {
        let values = [receipt(id: "a", flag: .yes),
                      receipt(id: "b", capture: String(repeating: "e", count: 64), flag: .no),
                      receipt(id: "c", state: String(repeating: "f", count: 64), flag: .unknown),
                      receipt(id: "d", rubric: String(repeating: "1", count: 64), flag: .no, truncated: true),
                      receipt(id: "outside", session: "other", flag: .yes)]
        let summary = JEVHistoricalToolSummary.build(receipts: values, sessionIDs: ["session"])
        XCTAssertEqual(summary.captureCount, 4)
        XCTAssertEqual(summary.partialCaptureCount, 1)
        XCTAssertEqual(summary.nonzeroFlaggedCount, 1)
        XCTAssertEqual(summary.nonzeroConflictCount, 0)
        XCTAssertEqual(summary.nonzeroUncertainCount, 1)
        XCTAssertEqual(summary.singleModelCount, 4)
    }

    func testInvalidEvidenceAndEmptyScopeAreNotCounted() {
        let valid = receipt(id: "valid", flag: .yes)
        let invalid = receipt(id: "invalid", flag: .yes, evidenceOverride: "evidence:wrong")
        XCTAssertEqual(JEVHistoricalToolSummary.build(receipts: [valid, invalid], sessionIDs: ["session"]).captureCount, 1)
        XCTAssertEqual(JEVHistoricalToolSummary.build(receipts: [valid], sessionIDs: []).captureCount, 0)
    }

    func testOptionalPrivateCapturedPagesReconcileWithoutCountingJudgesTwice() throws {
        guard let path = ProcessInfo.processInfo.environment["JEV_TOOL_IMPORT_FIXTURE"] else {
            throw XCTSkip("Private research fixture is opt-in")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let lines = try XCTUnwrap(String(data: data, encoding: .utf8)).split(separator: "\n")
        let receipts = try lines.map { try BridgeJSON.decoder.decode(JEVToolPageAssessment.self, from: Data($0.utf8)) }
        let summary = JEVHistoricalToolSummary.build(receipts: receipts, sessionIDs: Set(receipts.map(\.sessionID)))
        XCTAssertEqual(receipts.count, 100)
        XCTAssertEqual(summary.captureCount, 50)
        XCTAssertEqual(summary.partialCaptureCount, 43)
        XCTAssertEqual(summary.nonzeroFlaggedCount, 2)
    }
}
