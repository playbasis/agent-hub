import Foundation
import XCTest
@testable import BridgeCore

final class JEVAssessmentEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(id: String = "codex:one", provider: AgentName = .codex,
                         nativeID: String = "one", parent: String? = nil,
                         turns: [ActivityTurn] = [ActivityTurn(id: "turn", status: "completed")]) -> ActivitySession {
        ActivitySession(id: id, provider: provider, nativeID: nativeID, title: "Fixture",
                        createdAt: now, updatedAt: now, observedAt: now,
                        parentSessionID: parent, turns: turns, source: "fixture")
    }

    private func overview(_ sessions: [ActivitySession]) -> ActivityOverview {
        ActivityOverview(generatedAt: now, sessions: sessions)
    }

    func testEqualDuplicateObservationsProduceOneStableSnapshot() throws {
        let first = session()
        var duplicate = first
        duplicate.turns.append(first.turns[0])
        let forward = JEVAssessmentEvidence.snapshots(overview: overview([first, duplicate]))
        let reverse = JEVAssessmentEvidence.snapshots(overview: overview([duplicate, first]))
        XCTAssertEqual(forward.count, 1)
        XCTAssertEqual(reverse.count, 1)
        XCTAssertEqual(forward[0].evidenceID, reverse[0].evidenceID)
        XCTAssertEqual(forward[0].snapshotDigest, reverse[0].snapshotDigest)
        XCTAssertEqual(JEVAssessmentEvidence.currentDigests(overview: overview([first, duplicate])),
                       JEVAssessmentEvidence.currentDigests(overview: overview([duplicate, first])))
    }

    func testConflictingMetadataIsUnavailableInEitherOrderEvenAfterAnotherMatch() {
        let original = session()
        var conflict = original
        conflict.turns[0].status = "failed"
        for observations in [[original, conflict, original], [conflict, original, original]] {
            let input = overview(observations)
            let evidenceID = JEVAssessmentEvidence.evidenceID(sessionID: original.id, turnID: "turn")
            XCTAssertTrue(JEVAssessmentEvidence.snapshots(overview: input).isEmpty)
            XCTAssertNil(JEVAssessmentEvidence.currentDigests(overview: input)[evidenceID])
        }
    }

    func testConflictingSourceIdentityAndTurnTimesAreUnavailable() {
        let original = session()
        var nativeConflict = original; nativeConflict.nativeID = "different-native-session"
        var providerConflict = original; providerConflict.provider = .claude
        var parentConflict = original; parentConflict.parentSessionID = "codex:parent"
        var timeConflict = original; timeConflict.turns[0].startedAt = now
        for conflict in [nativeConflict, providerConflict, parentConflict, timeConflict] {
            for observations in [[original, conflict], [conflict, original]] {
                XCTAssertTrue(JEVAssessmentEvidence.snapshots(overview: overview(observations)).isEmpty)
            }
        }
    }

    func testConflictingSessionWithoutTargetTurnStillInvalidatesLink() {
        let original = session()
        var conflicting = original
        conflicting.nativeID = "another-native-session"
        conflicting.turns = []
        let evidenceID = JEVAssessmentEvidence.evidenceID(sessionID: original.id, turnID: "turn")
        for input in [overview([original, conflicting]), overview([conflicting, original])] {
            XCTAssertTrue(JEVAssessmentEvidence.snapshots(overview: input).isEmpty)
            XCTAssertNil(JEVAssessmentEvidence.currentDigests(overview: input)[evidenceID])
        }
    }

    func testDistinctSessionsStaySeparateAndRestrictionDoesNotGuess() {
        let first = session()
        let second = session(id: "claude:two", provider: .claude, nativeID: "two")
        var firstConflict = first; firstConflict.turns[0].status = "failed"
        let firstID = JEVAssessmentEvidence.evidenceID(sessionID: first.id, turnID: "turn")
        let secondID = JEVAssessmentEvidence.evidenceID(sessionID: second.id, turnID: "turn")
        XCTAssertNotEqual(firstID, secondID)
        let input = overview([first, second, firstConflict])
        let all = JEVAssessmentEvidence.snapshots(overview: input)
        XCTAssertEqual(all.map(\.evidenceID), [secondID])
        XCTAssertTrue(JEVAssessmentEvidence.snapshots(overview: input, restrictingTo: [firstID]).isEmpty)
        XCTAssertEqual(JEVAssessmentEvidence.snapshots(overview: input, restrictingTo: [secondID]).map(\.evidenceID), [secondID])
    }

    func testSingleObservationRetainsV1DigestAndExistingReceiptLink() throws {
        let original = session()
        let snapshot = try XCTUnwrap(JEVAssessmentEvidence.snapshots(overview: overview([original])).first)
        // Freeze the original Foundation JSONEncoder v1 bytes. Foundation's
        // sortedKeys puts "models" before "modelStepCount"; ASCII sorting
        // those keys produces a different hash and breaks interoperability.
        XCTAssertEqual(snapshot.snapshotDigest, "171c055afeb269045fb2dc98c3247b9899bbfe5cda4513f56bd31879cb592a64")
        let result = JEVAssessmentReceipt.Result(workKind: "research", evidenceLevel: "no_evidence", outcomeSupport: "insufficient", tags: ["metadata_only"], retry: .unknown, correction: .unknown, clarification: .unknown, claimNeedsReview: .unknown)
        let receipt = JEVAssessmentReceipt(id: "fixture", evidenceID: snapshot.evidenceID, snapshotDigest: snapshot.snapshotDigest,
            sessionID: snapshot.sessionID, turnID: snapshot.turnID, provider: "codex", inputDigest: snapshot.snapshotDigest,
            model: "jev-1.14.0", rubricVersion: "v1", rubricHash: snapshot.snapshotDigest, assessedAt: now,
            status: .assessed, result: result)
        let report = JEVAssessmentDisplay.build(receipts: [receipt], currentDigests: JEVAssessmentEvidence.currentDigests(overview: overview([original])), sessionIDs: [original.id])
        XCTAssertEqual(report.currentEvidence, 1)
        XCTAssertEqual(report.items.first?.turnID, "turn")
        var conflict = original; conflict.turns[0].status = "failed"
        let uncertain = JEVAssessmentDisplay.build(receipts: [receipt], currentDigests: JEVAssessmentEvidence.currentDigests(overview: overview([original, conflict])), sessionIDs: [original.id])
        XCTAssertEqual(uncertain.currentEvidence, 0)
        XCTAssertEqual(uncertain.unavailable, 1)
        XCTAssertTrue(uncertain.items.isEmpty)
    }
}
