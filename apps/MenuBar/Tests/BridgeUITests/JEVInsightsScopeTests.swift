import Foundation
import XCTest
import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

/// No filesystem, provider process, or network access is involved. Controlled
/// continuations model out-of-order loads and a delayed user-selected import.
final class JEVInsightsScopeTests: XCTestCase {
    private actor Reads {
        private var blocked = Set<String>()
        private var failing = Set<String>()
        private var failingMetadata = Set<String>()
        private var failingHistorical = Set<String>()
        private var seen = Set<String>()
        private var starts: [String: CheckedContinuation<Void, Never>] = [:]
        private var releases: [String: CheckedContinuation<Void, Never>] = [:]
        private(set) var calls: [String] = []

        func block(_ key: String) { blocked.insert(key) }
        func fail(_ key: String) { failing.insert(key) }
        func failMetadata(_ key: String) { failingMetadata.insert(key) }
        func failHistorical(_ key: String) { failingHistorical.insert(key) }
        private func recordStartWaiter(_ key: String, _ continuation: CheckedContinuation<Void, Never>) { starts[key] = continuation }
        private func recordReleaseWaiter(_ key: String, _ continuation: CheckedContinuation<Void, Never>) { releases[key] = continuation }
        func waitForStart(_ key: String) async {
            if seen.contains(key) { return }
            await withCheckedContinuation { recordStartWaiter(key, $0) }
        }
        func release(_ key: String) { releases.removeValue(forKey: key)?.resume() }
        func load(_ overview: ActivityOverview, _ ids: Set<String>) async -> (JEVAssessmentDisplay?, JEVHistoricalData?) {
            let key = ids.sorted().joined(separator: ",") + ":" + String(Int(overview.generatedAt.timeIntervalSince1970))
            calls.append(key); seen.insert(key); starts.removeValue(forKey: key)?.resume()
            if blocked.contains(key) { await withCheckedContinuation { recordReleaseWaiter(key, $0) } }
            if failing.contains(key) { return (nil, nil) }
            var display = JEVAssessmentDisplay(); display.currentEvidence = Int(overview.generatedAt.timeIntervalSince1970)
            let historical = JEVHistoricalData(pages: [], summary: JEVHistoricalToolSummary.build(receipts: [], sessionIDs: ids), navigableEvidenceIDs: [])
            return (failingMetadata.contains(key) ? nil : display, failingHistorical.contains(key) ? nil : historical)
        }
    }

    private actor ImportGate {
        private var started = false
        private var start: CheckedContinuation<Void, Never>?
        private var finish: CheckedContinuation<Void, Never>?
        func waitForStart() async {
            if started { return }
            await withCheckedContinuation { start = $0 }
        }
        func perform() async -> Int {
            started = true; start?.resume(); start = nil
            await withCheckedContinuation { finish = $0 }
            return 1
        }
        func release() { finish?.resume(); finish = nil }
    }

    private actor ImportFailures {
        private var count = 0
        struct Failed: Error {}
        func perform() throws -> Int { count += 1; if count == 1 { throw Failed() }; return 1 }
    }

    private func snapshot(_ seconds: Int) -> ActivityOverview {
        ActivityOverview(generatedAt: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    func testTaskIdentityCannotCollideWhenSessionIDsContainSeparators() {
        let date = Date(timeIntervalSince1970: 1)
        let left = JEVInsightsScopeKey(revision: 1, generatedAt: date, sessionIDs: ["a|b", "c"])
        let right = JEVInsightsScopeKey(revision: 1, generatedAt: date, sessionIDs: ["a", "b|c"])
        XCTAssertNotEqual(left, right)
        XCTAssertEqual(left, JEVInsightsScopeKey(revision: 1, generatedAt: date, sessionIDs: ["c", "a|b", "a|b"]))
    }

    func testHistoricalNavigationFailsClosedForConflictingSessionIdentity() {
        let when = Date(timeIntervalSince1970: 100), hash = String(repeating: "a", count: 64)
        let turn = ActivityTurn(id: "turn", status: "completed")
        let session = ActivitySession(id: "session", provider: .codex, nativeID: "native", title: "Fixture",
            createdAt: when, updatedAt: when, observedAt: when, turns: [turn], source: "fixture")
        let conflicting = ActivitySession(id: "session", provider: .claude, nativeID: "other", title: "Fixture",
            createdAt: when, updatedAt: when, observedAt: when, turns: [turn], source: "fixture")
        let evidenceID = JEVAssessmentEvidence.evidenceID(sessionID: "session", turnID: "turn")
        let receipt = JEVToolPageAssessment(id: "receipt", sessionID: "session", turnID: "turn", evidenceID: evidenceID,
            captureID: hash, model: "jev-1.14.0", rubricHash: hash, stateHash: hash, requestHash: hash, assessedAt: nil,
            pagePartial: true, toolFactsTruncated: false, artifactCountIsPartial: true, factCount: 1,
            answers: .init(listedNonzeroExit: .no, listedCompletedTool: .no, artifactRecorded: .no, goalStatusRecordedCompleted: .no,
                           listedMissingDuration: .no, recordedModelsPresent: .no, turnElapsedMissing: .no),
            noul: .init(listedNonzeroExit: 0, listedCompletedTool: 0, artifactRecorded: 0, goalStatusRecordedCompleted: 0,
                        listedMissingDuration: 0, recordedModelsPresent: 0, turnElapsedMissing: 0))
        let safe = JEVAssessmentEvidence.currentDigests(overview: ActivityOverview(generatedAt: when, sessions: [session]), restrictingTo: [evidenceID])
        XCTAssertEqual(JEVHistoricalData.navigableIDs(receipts: [receipt], sessionIDs: ["session"], currentDigests: safe), [evidenceID])
        for sessions in [[session, conflicting], [conflicting, session]] {
            let ambiguous = JEVAssessmentEvidence.currentDigests(overview: ActivityOverview(generatedAt: when, sessions: sessions), restrictingTo: [evidenceID])
            XCTAssertTrue(JEVHistoricalData.navigableIDs(receipts: [receipt], sessionIDs: ["session"], currentDigests: ambiguous).isEmpty)
        }
        XCTAssertTrue(JEVHistoricalData.navigableIDs(receipts: [receipt], sessionIDs: ["other"], currentDigests: safe).isEmpty)
    }

    func testHistoricalFlaggedCapturesAppearFirstAndKeepModelDissent() {
        let hash = String(repeating: "a", count: 64)
        func receipt(_ turn: String, model: String, flag: Bool, date: TimeInterval) -> JEVToolPageAssessment {
            let session = "session", evidence = JEVAssessmentEvidence.evidenceID(sessionID: session, turnID: turn)
            return JEVToolPageAssessment(id: turn + model, sessionID: session, turnID: turn, evidenceID: evidence,
                captureID: hash, model: model, rubricHash: hash, stateHash: hash, requestHash: hash,
                assessedAt: Date(timeIntervalSince1970: date), pagePartial: true, toolFactsTruncated: false,
                artifactCountIsPartial: true, factCount: 1,
                answers: .init(listedNonzeroExit: flag ? .yes : .no, listedCompletedTool: .no, artifactRecorded: .no,
                    goalStatusRecordedCompleted: .no, listedMissingDuration: .no, recordedModelsPresent: .no, turnElapsedMissing: .no),
                noul: .init(listedNonzeroExit: flag ? 1 : 0, listedCompletedTool: 0, artifactRecorded: 0,
                    goalStatusRecordedCompleted: 0, listedMissingDuration: 0, recordedModelsPresent: 0, turnElapsedMissing: 0))
        }
        let olderFlag = receipt("flagged", model: "jev-1.13", flag: true, date: 1)
        let dissent = receipt("flagged", model: "jev-1.14", flag: false, date: 1)
        let others = (0..<24).map { receipt("turn\($0)", model: "jev-1.14", flag: false, date: 10) }
        let forward = JEVToolPageGroup.build(others + [dissent, olderFlag], sessionIDs: ["session"])
        let reverse = JEVToolPageGroup.build(Array((others + [dissent, olderFlag]).reversed()), sessionIDs: ["session"])
        XCTAssertEqual(forward.count, 25)
        XCTAssertEqual(forward.map(\.id), reverse.map(\.id))
        XCTAssertEqual(forward.first?.first.turnID, "flagged")
        XCTAssertTrue(forward.first?.exitFlagged == true)
        XCTAssertTrue(forward.first?.exitOpinionsDiffer == true)
        XCTAssertEqual(forward.first?.receipts.count, 2)
        XCTAssertEqual(Set(forward.first?.receipts.map(\.model) ?? []), ["jev-1.13", "jev-1.14"])
    }

    @MainActor func testScopeSwitchMasksOldValuesAndSameScopeFailureRetainsLastGood() async {
        let reads = Reads()
        let model = JEVInsightsModel(operations: .init(load: { await reads.load($0, $1) }, importMetadata: { _ in 0 }, importToolPages: { _ in 0 }))
        await model.load(overview: snapshot(1), sessionIDs: ["A"]).value
        XCTAssertEqual(model.display?.currentEvidence, 1)
        XCTAssertNotNil(model.historical)
        // Even before the new view's asynchronous task invokes load, the UI
        // must mask values associated with a different selected session set.
        XCTAssertFalse(model.matchesScope(["B"]))
        await reads.block("B:2")
        let pending = model.load(overview: snapshot(2), sessionIDs: ["B"])
        await reads.waitForStart("B:2")
        XCTAssertNil(model.display); XCTAssertNil(model.historical)
        XCTAssertTrue(model.loading); XCTAssertFalse(model.metadataReadFailed); XCTAssertFalse(model.toolReadFailed)
        await reads.release("B:2"); await pending.value
        XCTAssertEqual(model.display?.currentEvidence, 2); XCTAssertNotNil(model.historical)

        await reads.fail("B:3")
        await model.load(overview: snapshot(3), sessionIDs: ["B"]).value
        XCTAssertEqual(model.display?.currentEvidence, 2); XCTAssertNotNil(model.historical)
        XCTAssertTrue(model.metadataReadFailed); XCTAssertTrue(model.toolReadFailed)
        let next = model.load(overview: snapshot(4), sessionIDs: ["C"])
        XCTAssertNil(model.display); XCTAssertNil(model.historical)
        XCTAssertFalse(model.metadataReadFailed); XCTAssertFalse(model.toolReadFailed)
        await next.value
    }

    @MainActor func testLateEarlierRevisionCannotOverwriteNewerSameScope() async {
        let reads = Reads(); await reads.block("A:1")
        let model = JEVInsightsModel(operations: .init(load: { await reads.load($0, $1) }, importMetadata: { _ in 0 }, importToolPages: { _ in 0 }))
        let old = model.load(overview: snapshot(1), sessionIDs: ["A"])
        await reads.waitForStart("A:1")
        await model.load(overview: snapshot(2), sessionIDs: ["A"]).value
        XCTAssertEqual(model.display?.currentEvidence, 2)
        await reads.release("A:1"); await old.value
        XCTAssertEqual(model.display?.currentEvidence, 2)
        XCTAssertFalse(model.loading)
    }

    @MainActor func testNavigationRequiresCurrentSnapshotAndSuccessfulRelevantRead() async {
        let reads = Reads()
        let model = JEVInsightsModel(operations: .init(load: { await reads.load($0, $1) }, importMetadata: { _ in 0 }, importToolPages: { _ in 0 }))
        let firstKey = JEVInsightsScopeKey(revision: 1, generatedAt: snapshot(1).generatedAt, sessionIDs: ["A"])
        let nextKey = JEVInsightsScopeKey(revision: 2, generatedAt: snapshot(2).generatedAt, sessionIDs: ["A"])
        await model.load(overview: snapshot(1), sessionIDs: ["A"], snapshotRevision: 1).value
        XCTAssertTrue(model.canInspectMetadata(for: firstKey)); XCTAssertTrue(model.canInspectHistorical(for: firstKey))
        // The view may already have the new key before the new .task runs.
        XCTAssertFalse(model.canInspectMetadata(for: nextKey)); XCTAssertFalse(model.canInspectHistorical(for: nextKey))
        XCTAssertTrue(model.hasPreviousResults(for: nextKey))
        await reads.block("A:2")
        let pending = model.load(overview: snapshot(2), sessionIDs: ["A"], snapshotRevision: 2)
        await reads.waitForStart("A:2")
        XCTAssertFalse(model.canInspectMetadata(for: nextKey)); XCTAssertFalse(model.canInspectHistorical(for: nextKey))
        await reads.release("A:2"); await pending.value
        XCTAssertTrue(model.canInspectMetadata(for: nextKey)); XCTAssertTrue(model.canInspectHistorical(for: nextKey))
        XCTAssertFalse(model.hasPreviousResults(for: nextKey))

        let thirdKey = JEVInsightsScopeKey(revision: 3, generatedAt: snapshot(3).generatedAt, sessionIDs: ["A"])
        await reads.failMetadata("A:3")
        await model.load(overview: snapshot(3), sessionIDs: ["A"], snapshotRevision: 3).value
        XCTAssertEqual(model.display?.currentEvidence, 2)
        XCTAssertFalse(model.canInspectMetadata(for: thirdKey)); XCTAssertTrue(model.canInspectHistorical(for: thirdKey))
        let fourthKey = JEVInsightsScopeKey(revision: 4, generatedAt: snapshot(4).generatedAt, sessionIDs: ["A"])
        await reads.failHistorical("A:4")
        await model.load(overview: snapshot(4), sessionIDs: ["A"], snapshotRevision: 4).value
        XCTAssertTrue(model.canInspectMetadata(for: fourthKey)); XCTAssertFalse(model.canInspectHistorical(for: fourthKey))
        XCTAssertNotNil(model.historical)
    }

    @MainActor func testDelayedImportReloadsLatestFilterForBothImportTypes() async {
        for historical in [false, true] {
            let reads = Reads(), gate = ImportGate()
            let model = JEVInsightsModel(operations: .init(load: { await reads.load($0, $1) },
                importMetadata: { _ in await gate.perform() }, importToolPages: { _ in await gate.perform() }))
            await model.load(overview: snapshot(1), sessionIDs: ["A"]).value
            let importing = Task { await model.importFile(URL(fileURLWithPath: "/fixture-only"), historical: historical) }
            await gate.waitForStart()
            await model.load(overview: snapshot(2), sessionIDs: ["B"]).value
            await gate.release(); await importing.value; await model.waitUntilIdle()
            XCTAssertTrue(model.matchesScope(["B"]))
            XCTAssertEqual(model.display?.currentEvidence, 2)
            let calls = await reads.calls
            XCTAssertEqual(calls, ["A:1", "B:2", "B:2"])
            XCTAssertFalse(model.busy)
        }
    }

    @MainActor func testSuccessfulImportClearsPreviousWarning() async {
        let reads = Reads(), imports = ImportFailures()
        let model = JEVInsightsModel(operations: .init(load: { await reads.load($0, $1) },
            importMetadata: { _ in try await imports.perform() }, importToolPages: { _ in 0 }))
        await model.load(overview: snapshot(1), sessionIDs: ["A"]).value
        await model.importFile(URL(fileURLWithPath: "/fixture-only"), historical: false)
        XCTAssertNotNil(model.message)
        await model.importFile(URL(fileURLWithPath: "/fixture-only"), historical: false)
        await model.waitUntilIdle()
        XCTAssertNil(model.message)
        XCTAssertEqual(model.display?.currentEvidence, 1)
    }
}
