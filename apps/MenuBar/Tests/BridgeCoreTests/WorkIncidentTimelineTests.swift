import Foundation
import XCTest
@testable import BridgeCore

final class WorkIncidentTimelineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(_ id: String, kind: WorkEvidenceItem.Kind = .toolCall, native: String? = nil,
                      related: String? = nil, status: String = "not recorded", exit: Int? = nil,
                      text: String? = nil, time: Double? = nil) -> WorkEvidenceItem {
        .init(id: "codex:item:" + id, nativeID: native ?? id, kind: kind, title: "Command", status: status,
              timestamp: time.map(Date.init(timeIntervalSince1970:)), relatedID: related, exitCode: exit,
              durationSeconds: nil, preview: text, digest: nil)
    }
    private func page(_ items: [WorkEvidenceItem], partial: Bool = false, cursor: String? = nil) -> WorkEvidenceBatch {
        .init(items: items, isPartial: partial, message: "Fixture", adapterVersion: "fixture/1", nextCursor: cursor)
    }
    private func index(_ turns: [String]) -> GoalReplayIndex {
        let session = ActivitySession(id: "root", provider: .codex, nativeID: "root", title: "Root", projectPath: nil,
            createdAt: now.addingTimeInterval(-1_000), updatedAt: now.addingTimeInterval(-1), observedAt: now,
            goal: ActivityGoal(id: "goal", sessionID: "root", objective: "Goal", status: "active",
                               createdAt: now.addingTimeInterval(-900), updatedAt: now.addingTimeInterval(-1)),
            turns: turns.enumerated().map { i, id in ActivityTurn(id: id, startedAt: now.addingTimeInterval(Double(i) - 500), status: "completed") },
            historyComplete: true, source: "fixture")
        return GoalReplayIndex.build(overview: ActivityOverview(generatedAt: now, sessions: [session]), rootSessionID: "root")
    }

    func testFailedThenSuccessfulToolIsNotAnInferredRecoveryOrTaskFailure() {
        // An expected-negative test may return a nonzero exit. This is an
        // observed tool result only, never a conclusion that the task failed.
        let result = WorkIncidentTimeline.build(batch: page([item("negative-test", exit: 1, time: 10), item("later", exit: 0, time: 20)]), scopeID: "one")
        XCTAssertEqual(result.events.map(\.kind), [.toolFailure, .toolSuccess])
        XCTAssertEqual(result.events.map(\.title), ["Tool reported an error", "Tool completed"])
        XCTAssertTrue(result.events.allSatisfy(\.isObservedTool))
        XCTAssertEqual(result.events[0].timeBasis, .recordedToolItem)
        XCTAssertEqual(result.events[0].evidenceIDs, ["codex:item:negative-test"])
    }

    func testExplicitResultJoinAndConflictsStayUncertain() {
        let call = item("call", native: "tool", status: "failed", time: 10)
        let result = item("result", kind: .toolResult, related: "tool", status: "completed", time: 20)
        let value = WorkIncidentTimeline.build(batch: page([call, result]), scopeID: "one")
        XCTAssertEqual(value.events.count, 1)
        XCTAssertEqual(value.events[0].kind, .toolUnknown)
        XCTAssertTrue(value.events[0].hasConflict)
        XCTAssertEqual(value.events[0].timestamp, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(value.events[0].timeBasis, .recordedToolItem)
        XCTAssertTrue(value.isPartial)
    }

    func testHintsRequireConsentAndCarryExactItemTimeOnly() {
        let message = item("msg", kind: .response, text: "The build failed, but I retried and checked it.", time: 20)
        let noText = WorkIncidentTimeline.build(batch: page([message]), scopeID: "one")
        XCTAssertTrue(noText.events.isEmpty)
        let optIn = WorkIncidentTimeline.build(batch: page([message]), includeLexicalHints: true, scopeID: "one")
        XCTAssertEqual(Set(optIn.events.map(\.kind)), Set([.agentFailureMention, .retryMention, .verificationMention]))
        XCTAssertTrue(optIn.events.allSatisfy { !$0.isObservedTool && $0.timestamp == Date(timeIntervalSince1970: 20) && $0.timeBasis == .visibleAgentMessage })
        XCTAssertTrue(optIn.events.allSatisfy { !$0.title.contains("build") && $0.evidenceIDs == ["codex:item:msg"] })
        let duplicate = WorkIncidentTimeline.build(batch: page([message, message]), includeLexicalHints: true, scopeID: "one")
        XCTAssertEqual(duplicate.events.count, optIn.events.count)
        XCTAssertTrue(duplicate.events.allSatisfy { $0.timestamp == nil && $0.timeBasis == .unavailable })
        let summary = WorkOutcomeSignals.summarize([message], includeLexicalHints: true)
        XCTAssertFalse(summary.hints.isEmpty)
        XCTAssertTrue(summary.withoutLexicalHints().hints.isEmpty)
        XCTAssertEqual(summary.withoutLexicalHints().executions, summary.executions)
    }

    func testPartialCursorAndMissingCallAreNeverComplete() {
        let resultOnly = item("result", kind: .toolResult, related: "not-in-page", status: "completed")
        let value = WorkIncidentTimeline.build(batch: page([resultOnly], cursor: "next"), scopeID: "one")
        XCTAssertEqual(value.partialPageCount, 1)
        XCTAssertTrue(value.isPartial)
        XCTAssertTrue(value.events[0].callNotInPage)
        XCTAssertNil(value.events[0].timestamp)
        XCTAssertEqual(value.events[0].timeBasis, .unavailable)
    }

    func testOnlyRetainedMatchingMostRecentlyInspectedPagesAreIncluded() throws {
        let goal = index(["one", "two", "three"])
        let first = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "one" })
        let second = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "two" })
        let scope = "codex:root:one"
        let old = WorkOutcomeSignals.summarize([item("old", exit: 1)], scopeID: scope)
        let latest = WorkOutcomeSignals.summarize([item("new", exit: 0)], isPartial: true, scopeID: scope)
        let wrong = WorkOutcomeSignals.summarize([item("wrong", exit: 1)], scopeID: "codex:other:two")
        XCTAssertNotEqual(old.executions[0].id, latest.executions[0].id)
        let value = WorkIncidentTimeline.build(index: goal, summaries: [first.id: latest, second.id: wrong, "evicted-row": old])
        XCTAssertEqual(value.indexedTurnCount, 3)
        XCTAssertEqual(value.inspectedPageCount, 1)
        XCTAssertEqual(value.uninspectedTurnCount, 2)
        XCTAssertEqual(value.partialPageCount, 1)
        XCTAssertEqual(value.events.count, 1)
        XCTAssertEqual(value.events[0].kind, .toolSuccess)
        XCTAssertEqual(value.events[0].rowID, first.id)
        XCTAssertEqual(value.events[0].sessionID, "root")
        XCTAssertEqual(value.events[0].turnID, "one")
        XCTAssertEqual(value.events[0].goalAttributionUncertain, false)
        XCTAssertTrue(value.isPartial)
    }

    func testUnattributedOrPastClosedGoalTurnsRemainLabeledUncertain() throws {
        let session = ActivitySession(id: "root", provider: .codex, nativeID: "root", title: "Root", projectPath: nil,
            createdAt: now.addingTimeInterval(-1_000), updatedAt: now.addingTimeInterval(-1), observedAt: now,
            goal: ActivityGoal(id: "goal", sessionID: "root", objective: "Goal", status: "complete",
                               createdAt: now.addingTimeInterval(-900), updatedAt: now.addingTimeInterval(-100)),
            turns: [ActivityTurn(id: "undated", status: "completed"),
                    ActivityTurn(id: "overlap", startedAt: now.addingTimeInterval(-200), completedAt: now.addingTimeInterval(-50), status: "completed")],
            historyComplete: true, source: "fixture")
        let goal = GoalReplayIndex.build(overview: ActivityOverview(generatedAt: now, sessions: [session]), rootSessionID: "root")
        let a = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "undated" })
        let b = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "overlap" })
        let aSummary = WorkOutcomeSignals.summarize([item("a", exit: 1)], scopeID: "codex:root:undated")
        let bSummary = WorkOutcomeSignals.summarize([item("b", exit: 1)], scopeID: "codex:root:overlap")
        let result = WorkIncidentTimeline.build(index: goal, summaries: [a.id: aSummary, b.id: bSummary])
        XCTAssertEqual(result.events.count, 2)
        XCTAssertTrue(result.events.allSatisfy { $0.goalAttributionUncertain == true })
        let pageOnly = WorkIncidentTimeline.build(batch: page([item("a", exit: 1)]), scopeID: "page")
        XCTAssertNil(pageOnly.events[0].goalAttributionUncertain)
    }

    func testGoalWideHintsDoNotBorrowTurnTimestamp() throws {
        let goal = index(["one"]), row = try XCTUnwrap(goal.rows.first)
        let summary = WorkOutcomeSignals.summarize([item("msg", kind: .response, text: "I retried.", time: 20)],
            includeLexicalHints: true, scopeID: "codex:root:one")
        let result = WorkIncidentTimeline.build(index: goal, summaries: [row.id: summary])
        XCTAssertEqual(result.events.first?.kind, .retryMention)
        XCTAssertNil(result.events.first?.timestamp)
        XCTAssertEqual(result.events.first?.timeBasis, .unavailable)
    }

    func testPageAndGoalBoundsAccountForOmissionsAndKeepLatestDatedEvents() throws {
        let tooMany = (0...WorkOutcomeSignals.maximumItems).map { item("over-\($0)", exit: 1) }
        XCTAssertTrue(WorkIncidentTimeline.build(batch: page(tooMany), scopeID: "one").isPartial)
        let goal = index(["one", "two", "three"])
        var summaries: [String: WorkOutcomeSignals.Summary] = [:]
        for (offset, row) in goal.rows.enumerated() {
            let base = Double((2 - offset) * WorkOutcomeSignals.maximumItems)
            let entries = (0..<WorkOutcomeSignals.maximumItems).map { i in item("\(offset)-\(i)", exit: 0, time: base + Double(i)) }
            summaries[row.id] = WorkOutcomeSignals.summarize(entries, scopeID: "codex:root:\(row.nativeTurnID)")
        }
        let value = WorkIncidentTimeline.build(index: goal, summaries: summaries)
        XCTAssertEqual(value.events.count, WorkIncidentTimeline.maximumEvents)
        XCTAssertEqual(value.omittedEventCount, 2 * WorkOutcomeSignals.maximumItems)
        XCTAssertEqual(value.events.first?.timestamp, Date(timeIntervalSince1970: Double(2 * WorkIncidentTimeline.maximumEvents)))
        XCTAssertEqual(value.events.last?.timestamp, Date(timeIntervalSince1970: Double(3 * WorkIncidentTimeline.maximumEvents - 1)))
        XCTAssertTrue(value.isPartial)
    }

    func testBoundKeepsUndatedOnlyWhenThereIsRoomWithoutAssigningTime() throws {
        let goal = index(["one", "two"])
        let first = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "one" })
        let second = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "two" })
        let dated = (0..<(WorkIncidentTimeline.maximumEvents - 1)).map { item("dated-\($0)", exit: 0, time: Double($0)) }
        let unknown = [item("unknown-a", exit: 0), item("unknown-b", exit: 0)]
        let values = [first.id: WorkOutcomeSignals.summarize(dated, scopeID: "codex:root:one"),
                      second.id: WorkOutcomeSignals.summarize(unknown, scopeID: "codex:root:two")]
        let result = WorkIncidentTimeline.build(index: goal, summaries: values)
        XCTAssertEqual(result.events.count, WorkIncidentTimeline.maximumEvents)
        XCTAssertEqual(result.omittedEventCount, 1)
        XCTAssertEqual(result.events.filter { $0.timestamp != nil }.count, WorkIncidentTimeline.maximumEvents - 1)
        XCTAssertEqual(result.events.filter { $0.timestamp == nil }.count, 1)
        XCTAssertNil(result.events.last?.timestamp)
        XCTAssertEqual(result.events.last?.timeBasis, .unavailable)
        XCTAssertTrue(result.isPartial)
    }

    func testOlderToolErrorSurvivesMoreThanLimitOfNewerCompletedTools() throws {
        let goal = index(["one", "two"])
        let first = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "one" })
        let second = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "two" })
        let completed = (0..<WorkIncidentTimeline.maximumEvents).map { item("success-\($0)", exit: 0, time: Double(100 + $0)) }
        let failure = item("old-failure", exit: 1, time: 1)
        let result = WorkIncidentTimeline.build(index: goal, summaries: [
            first.id: WorkOutcomeSignals.summarize(completed, scopeID: "codex:root:one"),
            second.id: WorkOutcomeSignals.summarize([failure], scopeID: "codex:root:two")
        ])
        XCTAssertEqual(result.events.count, WorkIncidentTimeline.maximumEvents)
        XCTAssertEqual(result.omittedEventCount, 1)
        XCTAssertEqual(result.events.filter { $0.kind == .toolFailure }.count, 1)
        XCTAssertEqual(result.events.first?.evidenceIDs, ["codex:item:old-failure"])
        XCTAssertFalse(result.events.contains { $0.evidenceIDs == ["codex:item:success-0"] })
        XCTAssertTrue(result.isPartial)
    }

    func testReviewSignalOverflowKeepsLatestSignalsBeforeNewerSuccesses() throws {
        let goal = index(["one", "two"])
        let first = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "one" })
        let second = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "two" })
        let failures = (0..<WorkIncidentTimeline.maximumEvents).map { item("failure-\($0)", exit: 1, time: Double($0)) }
        let later = [item("latest-failure", exit: 1, time: 9_000), item("newer-success", exit: 0, time: 10_000)]
        let result = WorkIncidentTimeline.build(index: goal, summaries: [
            first.id: WorkOutcomeSignals.summarize(failures, scopeID: "codex:root:one"),
            second.id: WorkOutcomeSignals.summarize(later, scopeID: "codex:root:two")
        ])
        XCTAssertEqual(result.events.count, WorkIncidentTimeline.maximumEvents)
        XCTAssertEqual(result.omittedEventCount, 2)
        XCTAssertTrue(result.events.allSatisfy { $0.kind == .toolFailure })
        XCTAssertEqual(result.events.first?.timestamp, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(result.events.last?.timestamp, Date(timeIntervalSince1970: 9_000))
    }

    func testUndatedReviewSignalPrecedesSuccessWithoutInventingTime() throws {
        let goal = index(["one", "two"])
        let first = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "one" })
        let second = try XCTUnwrap(goal.rows.first { $0.nativeTurnID == "two" })
        let completed = (0..<WorkIncidentTimeline.maximumEvents).map { item("success-\($0)", exit: 0, time: Double($0)) }
        let result = WorkIncidentTimeline.build(index: goal, summaries: [
            first.id: WorkOutcomeSignals.summarize(completed, scopeID: "codex:root:one"),
            second.id: WorkOutcomeSignals.summarize([item("undated-error", exit: 1)], scopeID: "codex:root:two")
        ])
        let undated = try XCTUnwrap(result.events.first { $0.evidenceIDs == ["codex:item:undated-error"] })
        XCTAssertNil(undated.timestamp)
        XCTAssertEqual(undated.timeBasis, .unavailable)
        XCTAssertEqual(result.omittedEventCount, 1)
        XCTAssertEqual(result.events.last?.id, undated.id)
    }
}
