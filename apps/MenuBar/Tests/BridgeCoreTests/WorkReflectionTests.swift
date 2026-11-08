import Darwin
import Foundation
import XCTest
import BridgeCore

final class WorkReflectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("work-reflection-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func evidence() -> WorkReflectionEvidence {
        .init(provider: .codex, sessionID: "synthetic-session", goalID: "synthetic-goal", nativeSessionID: "synthetic-native",
              nativeTurnID: "synthetic-turn", modelStepID: "synthetic-step", toolCallID: "synthetic-tool", stageID: "synthetic-stage",
              traceReceiptID: "synthetic-receipt")
    }
    private func draft(rating: Int? = nil, note: String? = nil, proposal: String? = nil) -> WorkReflectionDraft {
        .init(evidence: [evidence()], outcome: .useful, rating: rating, note: note, proposedSkillChange: proposal)
    }
    private func store(_ name: String = "reviews") -> WorkReflectionStore { .init(directory: root.appendingPathComponent(name, isDirectory: true)) }

    func testAnUnusedStoreDoesNotCreateFilesOrCaptureAnything() async throws {
        let path = root.appendingPathComponent("absent", isDirectory: true)
        let store = WorkReflectionStore(directory: path)
        let records = try await store.load()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testEvidenceReferencesRoundTripAndTextIsBoundedRedactedAndPrivate() async throws {
        let store = store()
        let record = try await store.append(draft(rating: 4, note: "token=private-value /Users/synthetic/private " + String(repeating: "x", count: 2_000)))
        XCTAssertEqual(record.draft.evidence, [evidence()])
        XCTAssertTrue(record.draft.note?.contains("[REDACTED]") == true)
        XCTAssertFalse(record.draft.note?.contains("private-value") == true)
        XCTAssertFalse(record.draft.note?.contains("/Users/synthetic") == true)
        XCTAssertLessThanOrEqual(record.draft.note?.count ?? 0, 1_201)
        let directory = await store.directory
        let file = directory.appendingPathComponent(record.id + ".json")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
        let reopened = WorkReflectionStore(directory: directory)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded, [record])
        XCTAssertNil(loaded.first?.proposalDecision)
    }

    func testRevisionsAppendAndNeverOverwriteOriginalFilesOrCountOldRatingsAgain() async throws {
        let store = store()
        let first = try await store.append(draft(rating: 1))
        let directory = await store.directory
        let firstFile = directory.appendingPathComponent(first.id + ".json")
        let originalBytes = try Data(contentsOf: firstFile)
        let next = try await store.append(draft(rating: 5), revising: first.id)
        XCTAssertEqual(next.reviewID, first.reviewID)
        XCTAssertEqual(next.supersedesID, first.id)
        XCTAssertEqual(next.revision, 2)
        XCTAssertEqual(try Data(contentsOf: firstFile), originalBytes)
        let latest = try await store.load()
        let history = try await store.load(includingRevisions: true)
        XCTAssertEqual(latest, [next])
        XCTAssertEqual(history.count, 2)
        let summary = WorkReflectionSummary.build(records: history)
        XCTAssertEqual(summary.reviews, 1)
        XCTAssertEqual(summary.revisions, 2)
        XCTAssertEqual(summary.comparisons.first?.averageRating, 5)
        do { _ = try await store.append(draft(rating: 3), revising: first.id); XCTFail("Stale edits must not fork history") }
        catch { XCTAssertEqual(error as? WorkReflectionError, .staleRevision) }
    }

    func testSkillChangesNeedExplicitApprovalAndNewEditsInvalidateOldApproval() async throws {
        let store = store()
        let pending = try await store.append(draft(proposal: "Check the request format before starting work."))
        XCTAssertEqual(pending.proposalDecision, .pending)
        XCTAssertFalse(pending.decisionByHuman)
        let approved = try await store.decideProposal(recordID: pending.id, decision: .approved)
        XCTAssertEqual(approved.proposalDecision, .approved)
        XCTAssertTrue(approved.decisionByHuman)
        XCTAssertEqual(pending.proposalDecision, .pending, "The earlier revision stays unchanged")
        let revised = try await store.append(draft(proposal: "Ask for missing acceptance criteria first."), revising: approved.id)
        XCTAssertEqual(revised.proposalDecision, .pending)
        let summary = try await store.summary()
        XCTAssertEqual(summary.suggestions.count, 1)
        XCTAssertTrue(summary.suggestions.first?.requiresHumanApproval == true)
        XCTAssertEqual(summary.suggestions.first?.recordID, revised.id)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files, ["reviews"], "Approving a suggestion never creates/edits a skill or sends work")
    }

    func testSourcesAndComparisonRubricsRemainSeparateAndMissingRatingsAreNotZero() async throws {
        let store = store()
        var human = draft(rating: 5)
        human.comparisonKey = "same-task"; human.rubricVersion = "usefulness/1"; human.rubricHash = "rubric-a"
        _ = try await store.append(human)
        human.rating = nil; human.outcome = .unknown
        _ = try await store.append(human)
        var model = human
        model.source = .modelAssessment; model.assessorModel = "synthetic-judge"; model.rating = 1
        _ = try await store.append(model)
        var alternateRubric = human
        alternateRubric.rubricHash = "rubric-b"; alternateRubric.rating = 2
        _ = try await store.append(alternateRubric)
        let check = WorkReflectionDraft(evidence: [evidence()], source: .deterministicCheck, basis: .observation,
            rubricVersion: "check/1", comparisonKey: "same-task", checkName: "synthetic regression", checkPassed: false)
        _ = try await store.append(check)
        let summary = try await store.summary()
        XCTAssertEqual(summary.comparisons.count, 4)
        let comparison = try XCTUnwrap(summary.comparisons.first { $0.source == .humanRating && $0.rubricHash == "rubric-a" })
        XCTAssertEqual(comparison.reviews, 2)
        XCTAssertEqual(comparison.ratedReviews, 1)
        XCTAssertEqual(comparison.ratingCoverage, 0.5)
        XCTAssertEqual(comparison.averageRating, 5, "Unrated is missing evidence, not a zero score")
        let deterministic = try XCTUnwrap(summary.comparisons.first { $0.source == .deterministicCheck })
        XCTAssertNil(deterministic.averageRating)
        XCTAssertEqual(deterministic.failedChecks, 1)
        XCTAssertEqual(deterministic.passedChecks, 0)
        XCTAssertEqual(summary.bySource.first { $0.source == .humanRating }?.reviews, 3)
        XCTAssertEqual(summary.bySource.first { $0.source == .modelAssessment }?.reviews, 1)
    }

    func testMissingComparisonKeysNeverPoolUnrelatedReviews() async throws {
        let store = store()
        _ = try await store.append(draft(rating: 1))
        _ = try await store.append(draft(rating: 5))
        let summary = try await store.summary()
        XCTAssertEqual(summary.comparisons.count, 2)
        XCTAssertEqual(Set(summary.comparisons.compactMap(\.averageRating)), Set([1.0, 5.0]))
        XCTAssertTrue(summary.comparisons.allSatisfy { $0.comparisonKey == nil })
    }

    func testInvalidRatingsSourcesAndUnattributedAssessmentsAreRejected() async throws {
        let store = store()
        var invalid = [draft(rating: 0), draft(rating: 6), WorkReflectionDraft(evidence: [])]
        invalid.append(.init(evidence: [evidence()], source: .modelAssessment, rating: 3))
        invalid.append(.init(evidence: [evidence()], source: .deterministicCheck, rating: 4, checkName: "check", checkPassed: true))
        invalid.append(.init(evidence: [evidence()], source: .humanRating, checkPassed: false))
        for value in invalid {
            do { _ = try await store.append(value); XCTFail("Invalid provenance or measurements must be rejected") }
            catch { XCTAssertEqual(error as? WorkReflectionError, .invalidInput) }
        }
        let records = try await store.load()
        XCTAssertTrue(records.isEmpty)
    }

    func testPrivateUnfinishedStagingFileDoesNotHideGoodHistoryOrGetDeleted() async throws {
        let store = store()
        let good = try await store.append(draft())
        let directory = await store.directory
        let staging = directory.appendingPathComponent(".pending-synthetic-interrupted-write")
        try Data("incomplete".utf8).write(to: staging)
        let records = try await store.load()
        XCTAssertEqual(records, [good])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "Recovery must not erase uncommitted evidence")
    }

    func testCorruptCommittedHistoryFailsClosedWithoutOverwritingIt() async throws {
        let store = store()
        _ = try await store.append(draft())
        let directory = await store.directory
        let corrupt = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        let bytes = Data("{interrupted".utf8)
        try bytes.write(to: corrupt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corrupt.path)
        do { _ = try await store.append(draft()); XCTFail("Corrupt committed evidence must not be ignored") }
        catch { XCTAssertEqual(error as? WorkReflectionError, .invalidStore) }
        XCTAssertEqual(try Data(contentsOf: corrupt), bytes)
    }

    func testSymlinksAndFIFOsCannotBeReadAsReviewRecords() async throws {
        let store = store()
        _ = try await store.append(draft())
        let directory = await store.directory
        let target = root.appendingPathComponent("outside-marker")
        try Data("untouched".utf8).write(to: target)
        let link = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do { _ = try await store.load(); XCTFail("Do not follow links") }
        catch { XCTAssertEqual(error as? WorkReflectionError, .invalidStore) }
        XCTAssertEqual(try String(contentsOf: target), "untouched")
        try FileManager.default.removeItem(at: link)
        let fifo = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        do { _ = try await store.load(); XCTFail("Do not block/read FIFOs") }
        catch { XCTAssertEqual(error as? WorkReflectionError, .invalidStore) }
    }

    func testBusyStoreReturnsWithoutWaitingAndCanRetry() async throws {
        let store = store()
        _ = try await store.append(draft())
        let directory = await store.directory
        let descriptor = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        do { _ = try await store.append(draft()); XCTFail("A busy store must return without an unbounded wait") }
        catch { XCTAssertEqual(error as? WorkReflectionError, .unavailable) }
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        _ = try await store.append(draft())
        let records = try await store.load()
        XCTAssertEqual(records.count, 2)
    }
}
