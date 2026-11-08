import XCTest
@testable import BridgeCore

final class JEVAssessmentDisplayTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private func record(_ id: String, evidence: String, model: String, kind: String, tags: [String] = ["metadata_only"], retry: JEVAssessmentReceipt.TriState = .no, snapshot: String? = nil) -> JEVAssessmentReceipt {
        let result = JEVAssessmentReceipt.Result(workKind: kind, evidenceLevel: "no_evidence", outcomeSupport: "insufficient", tags: tags, retry: retry, correction: .no, clarification: .no, claimNeedsReview: .no)
        return JEVAssessmentReceipt(id: id, evidenceID: JEVAssessmentEvidence.evidenceID(sessionID: "s", turnID: evidence), snapshotDigest: snapshot ?? digest, sessionID: "s", turnID: evidence, provider: "codex", inputDigest: digest, model: model, rubricVersion: "v1", rubricHash: digest, assessedAt: Date(timeIntervalSince1970: 10), status: .assessed, result: result)
    }
    func testDistinctEvidenceDisagreementUnknownAndStaleness() {
        let rows = [record("a", evidence: "e1", model: "m1", kind: "research", retry: .yes), record("b", evidence: "e1", model: "m2", kind: "research"),
                    record("c", evidence: "e2", model: "m1", kind: "research"), record("d", evidence: "e2", model: "m2", kind: "implementation"),
                    record("e", evidence: "e3", model: "m1", kind: "unknown"), record("f", evidence: "e4", model: "m1", kind: "planning", snapshot: String(repeating: "b", count: 64)),
                    record("g", evidence: "e5", model: "m1", kind: "planning")]
        let ids = ["e1", "e2", "e3", "e4"].map { JEVAssessmentEvidence.evidenceID(sessionID: "s", turnID: $0) }
        let report = JEVAssessmentDisplay.build(receipts: rows, currentDigests: Dictionary(uniqueKeysWithValues: ids.map { ($0, digest) }), sessionIDs: ["s"])
        XCTAssertEqual(report.currentEvidence, 3); XCTAssertEqual(report.agreedKinds["research"], 1)
        XCTAssertEqual(report.disagreements, 1); XCTAssertEqual(report.insufficient, 1)
        XCTAssertEqual(report.differingLabels, 1)
        XCTAssertEqual(report.stale, 1); XCTAssertEqual(report.unavailable, 1)
        XCTAssertEqual(report.items.count, 3)
        XCTAssertEqual(report.items.first(where: { $0.id == ids[1] })?.modelOpinions.count, 2)
        XCTAssertEqual(report.flaggedRetry, 0, "Aggregate metadata cannot prove retries")
        XCTAssertEqual(JEVAssessmentDisplay.build(receipts: rows, currentDigests: [:], sessionIDs: []).currentEvidence, 0)
    }
    func testConflictingUnknownIsNotPresentedAsAgreement() {
        let rows = [record("a", evidence: "e", model: "m1", kind: "research"), record("b", evidence: "e", model: "m2", kind: "unknown")]
        let id = JEVAssessmentEvidence.evidenceID(sessionID: "s", turnID: "e")
        let report = JEVAssessmentDisplay.build(receipts: rows, currentDigests: [id: digest], sessionIDs: ["s"])
        XCTAssertEqual(report.disagreements, 0); XCTAssertEqual(report.differingLabels, 1); XCTAssertEqual(report.insufficient, 1); XCTAssertTrue(report.agreedKinds.isEmpty)
    }
    func testMismatchedImportedTurnCannotOpenAnotherSession() {
        let realID = JEVAssessmentEvidence.evidenceID(sessionID: "other", turnID: "t")
        let result = JEVAssessmentReceipt.Result(workKind: "research", evidenceLevel: "no_evidence", outcomeSupport: "insufficient", retry: .no, correction: .no, clarification: .no, claimNeedsReview: .no)
        let forged = JEVAssessmentReceipt(id: "forged", evidenceID: realID, snapshotDigest: digest, sessionID: "s", turnID: "t", provider: "codex", inputDigest: digest, model: "m", rubricVersion: "v", rubricHash: digest, assessedAt: Date(), status: .assessed, result: result)
        let report = JEVAssessmentDisplay.build(receipts: [forged], currentDigests: [realID: digest], sessionIDs: ["s"])
        XCTAssertEqual(report.currentEvidence, 0); XCTAssertEqual(report.unavailable, 1); XCTAssertTrue(report.items.isEmpty)
    }

    func testTiedConflictingModelVerdictsNeverBecomeAgreement() throws {
        let a = record("a", evidence: "e", model: "m1", kind: "research")
        let b = record("b", evidence: "e", model: "m1", kind: "implementation")
        let c = record("c", evidence: "e", model: "m2", kind: "research")
        let current = [a.evidenceID: digest]
        let forward = JEVAssessmentDisplay.build(receipts: [a, b, c], currentDigests: current, sessionIDs: ["s"])
        let reverse = JEVAssessmentDisplay.build(receipts: [c, b, a], currentDigests: current, sessionIDs: ["s"])
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.currentEvidence, 1)
        XCTAssertEqual(forward.incomparable, 1)
        XCTAssertTrue(forward.agreedKinds.isEmpty)
        XCTAssertEqual(forward.disagreements, 0)
        XCTAssertEqual(try XCTUnwrap(forward.items.first).modelOpinions, ["m1: conflicting latest assessments", "m2: research, outcome not established"])
    }

    func testIdenticalTiedAttemptsRemainOneComparableOpinion() {
        let a = record("a", evidence: "e", model: "m1", kind: "research")
        let b = record("b", evidence: "e", model: "m1", kind: "research")
        let c = record("c", evidence: "e", model: "m2", kind: "research")
        let report = JEVAssessmentDisplay.build(receipts: [b, c, a], currentDigests: [a.evidenceID: digest], sessionIDs: ["s"])
        XCTAssertEqual(report.currentEvidence, 1)
        XCTAssertEqual(report.agreedKinds["research"], 1)
        XCTAssertEqual(report.incomparable, 0)
        XCTAssertEqual(report.items.first?.modelOpinions.count, 2)
    }

    func testTiedDifferentRubricOrInputIsIncomparableDespiteMatchingLabels() {
        let a = record("a", evidence: "e", model: "m1", kind: "research")
        func copy(id: String, rubric: String, input: String, time: Date) -> JEVAssessmentReceipt {
            JEVAssessmentReceipt(id: id, evidenceID: a.evidenceID, snapshotDigest: a.snapshotDigest, sessionID: a.sessionID,
                turnID: a.turnID, provider: a.provider, inputDigest: input, model: a.model, rubricVersion: a.rubricVersion,
                rubricHash: rubric, assessedAt: time, status: a.status, result: a.result, usage: a.usage)
        }
        let other = String(repeating: "b", count: 64)
        for b in [copy(id: "b", rubric: other, input: digest, time: a.assessedAt),
                  copy(id: "b", rubric: digest, input: other, time: a.assessedAt)] {
            let report = JEVAssessmentDisplay.build(receipts: [a, b], currentDigests: [a.evidenceID: digest], sessionIDs: ["s"])
            XCTAssertEqual(report.incomparable, 1)
            XCTAssertEqual(report.singleJudge, 1)
            XCTAssertTrue(report.agreedKinds.isEmpty)
            XCTAssertEqual(report.items.first?.modelOpinions, ["m1: conflicting latest assessments"])
        }
        // A strictly later attempt is a distinct observation, not a tie.
        let newer = copy(id: "newer", rubric: digest, input: digest, time: a.assessedAt.addingTimeInterval(1))
        let report = JEVAssessmentDisplay.build(receipts: [newer, a], currentDigests: [a.evidenceID: digest], sessionIDs: ["s"])
        XCTAssertEqual(report.incomparable, 0)
        XCTAssertEqual(report.agreedKinds["research"], 1)
    }

    func testDifferentModelsNeedMatchingInputProviderAndRubricVersion() {
        let a = record("a", evidence: "e", model: "m1", kind: "research")
        let result = JEVAssessmentReceipt.Result(workKind: "research", evidenceLevel: "no_evidence",
            outcomeSupport: "insufficient", tags: [], retry: .yes, correction: .yes,
            clarification: .no, claimNeedsReview: .no)
        let other = String(repeating: "b", count: 64)
        func second(input: String, provider: String, version: String, rubric: String) -> JEVAssessmentReceipt {
            JEVAssessmentReceipt(id: "b", evidenceID: a.evidenceID, snapshotDigest: a.snapshotDigest,
                sessionID: a.sessionID, turnID: a.turnID, provider: provider, inputDigest: input,
                model: "m2", rubricVersion: version, rubricHash: rubric, assessedAt: a.assessedAt,
                status: .assessed, result: result)
        }
        let cases = [second(input: other, provider: "codex", version: "v1", rubric: digest),
                     second(input: digest, provider: "claude", version: "v1", rubric: digest),
                     second(input: digest, provider: "codex", version: "v2", rubric: digest),
                     second(input: digest, provider: "codex", version: "v1", rubric: other)]
        for b in cases {
            let forward = JEVAssessmentDisplay.build(receipts: [a, b], currentDigests: [a.evidenceID: digest], sessionIDs: ["s"])
            let reverse = JEVAssessmentDisplay.build(receipts: [b, a], currentDigests: [a.evidenceID: digest], sessionIDs: ["s"])
            XCTAssertEqual(forward, reverse)
            XCTAssertEqual(forward.currentEvidence, 1)
            XCTAssertEqual(forward.incomparable, 1)
            XCTAssertTrue(forward.agreedKinds.isEmpty)
            XCTAssertEqual(forward.disagreements, 0)
            XCTAssertEqual(forward.flaggedRetry, 0, "Incomparable inputs cannot be counted as review candidates")
            XCTAssertEqual(forward.flaggedCorrection, 0)
            XCTAssertEqual(forward.items.first?.modelOpinions.count, 2, "Individual opinions remain inspectable")
        }
    }
}
