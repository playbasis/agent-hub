import XCTest
@testable import BridgeCore

final class TurnInspectionTests: XCTestCase {
    func testMixedCheckpointModelsAreNotGuessedAsTheLastModel() {
        let value = ActivityTurn(id: "mixed", modelSteps: [
            ActivityModelStep(id: "one", timestamp: nil, model: "gpt-6-astra"),
            ActivityModelStep(id: "two", timestamp: nil, model: "gpt-6.1-sol"),
        ])
        XCTAssertNil(GoalTurnList.singleModel(value))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    private func step(_ id: String, _ offset: TimeInterval?) -> ActivityModelStep {
        ActivityModelStep(id: id, timestamp: offset.map(at), model: "gpt-6.1-sol")
    }

    private func item(_ id: String, _ kind: WorkEvidenceItem.Kind, _ offset: TimeInterval?, status: String = "recorded",
                      native: String? = nil, related: String? = nil, exit: Int? = nil) -> WorkEvidenceItem {
        WorkEvidenceItem(id: "codex:item:" + id, nativeID: native ?? id, kind: kind, title: id, status: status,
                         timestamp: offset.map(at), relatedID: related, exitCode: exit, durationSeconds: nil, preview: nil, digest: nil)
    }

    private func session(_ id: String, parent: String? = nil, created: TimeInterval = -7_200, updated: TimeInterval = -10,
                         title: String? = nil, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: .codex, nativeID: id, title: title ?? "Job \(id)", projectPath: "/work/app",
                        createdAt: at(created), updatedAt: at(updated), observedAt: now, parentSessionID: parent,
                        turns: turns, source: "test")
    }

    private func turn(_ id: String, start: TimeInterval?, end: TimeInterval? = nil, status: String = "completed",
                      tools: Int? = nil) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: start.map(at), completedAt: end.map(at), status: status, toolCount: tools)
    }

    // MARK: Timeline

    func testTimelineMergesStepsAndToolsInOrderAndGroupsConsecutiveSteps() {
        let steps = [step("s1", -100), step("s2", -90), step("s3", -40), step("s3", -40)]
        let items = [
            item("req", .request, -110),
            item("call", .toolCall, -80, status: "completed", exit: 0),
            item("reply", .response, -10),
        ]
        let entries = TurnTimeline.build(steps: steps, items: items, now: now)
        XCTAssertEqual(entries.map(\.id), ["op:codex:item:req", "steps:s1", entries[2].id, "steps:s3", "op:codex:item:reply"])
        guard case let .steps(first) = entries[1], case let .operation(tool) = entries[2], case let .steps(second) = entries[3] else {
            return XCTFail("unexpected entry kinds")
        }
        XCTAssertEqual(first.steps.map(\.id), ["s1", "s2"])
        XCTAssertEqual(first.first, at(-100)); XCTAssertEqual(first.last, at(-90))
        XCTAssertEqual(second.steps.count, 1, "duplicate checkpoint identities are merged")
        XCTAssertEqual(tool.outcome, .success)
        let counts = TurnTimeline.counts(entries)
        XCTAssertEqual(counts.steps, 3); XCTAssertEqual(counts.tools, 1); XCTAssertEqual(counts.succeeded, 1)
    }

    func testResultsJoinTheirCallOnlyThroughExplicitIDs() {
        let items = [
            item("use-1", .toolCall, -50, native: "toolu_1"),
            item("result-1", .toolResult, -45, status: "failed", native: "r1", related: "toolu_1"),
            item("orphan", .toolResult, -44, status: "completed", native: "r2", related: "toolu_missing"),
        ]
        let operations = TurnTimeline.build(steps: nil, items: items, now: now).compactMap { entry -> TurnTimeline.Operation? in
            if case let .operation(operation) = entry { return operation }
            return nil
        }
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0].records.map(\.id), ["codex:item:use-1", "codex:item:result-1"])
        XCTAssertEqual(operations[0].outcome, .failure)
        XCTAssertEqual(operations[1].records.map(\.id), ["codex:item:orphan"], "a result never attaches by time")
        let counts = TurnTimeline.counts(TurnTimeline.build(steps: nil, items: items, now: now))
        XCTAssertEqual(counts.failed, 1); XCTAssertEqual(counts.succeeded, 1)
    }

    func testUndatedAndFutureEvidenceGoesLastWithoutReordering() {
        let entries = TurnTimeline.build(steps: [step("late", 30), step("dated", -20)],
                                         items: [item("b", .notice, nil), item("a", .notice, nil)], now: now)
        XCTAssertEqual(entries.map(\.id), ["steps:dated", "op:codex:item:b", "op:codex:item:a", "steps:late"])
        XCTAssertNil(entries.last?.timestamp, "a future checkpoint has no usable time")
    }

    func testStepsAloneBuildATimelineBeforeEvidenceIsRead() {
        let entries = TurnTimeline.build(steps: [step("a", -9), step("b", -8)], items: nil, now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(TurnTimeline.counts(entries).tools, 0)
    }

    func testNativeReadClockDoesNotMoveTheMetadataSnapshotClock() {
        let entries = TurnTimeline.build(steps: [step("future-step", 20)],
                                         items: [item("new-native", .notice, 10), item("future-native", .notice, 40)],
                                         now: now, nativeReadAt: at(30))
        XCTAssertEqual(entries.first?.timestamp, at(10), "a native record can legitimately be newer than the snapshot")
        XCTAssertEqual(entries.first?.id, "op:codex:item:new-native")
        XCTAssertNil(entries.first(where: { $0.id == "op:codex:item:future-native" })?.timestamp)
        XCTAssertNil(entries.first(where: { $0.id == "steps:future-step" })?.timestamp,
                     "reading native evidence must not validate future metadata checkpoints")
    }

    // MARK: Status

    func testTurnStatusUsesPlainWordsAndNeverCallsUnknownFinished() {
        XCTAssertEqual(TurnStatus("completed", completedAt: now), .finished)
        XCTAssertEqual(TurnStatus("Errored", completedAt: now), .failed)
        XCTAssertEqual(TurnStatus("cancelled", completedAt: nil), .interrupted)
        XCTAssertEqual(TurnStatus("in_progress", completedAt: nil), .inProgress)
        XCTAssertEqual(TurnStatus("in_progress", completedAt: now), .unknown, "contradictory records stay unknown")
        XCTAssertEqual(TurnStatus("unknown", completedAt: nil), .unknown)
        XCTAssertEqual(TurnStatus("unknown", completedAt: now), .unknown, "a completion date is not a recorded success status")
        XCTAssertTrue(TurnStatus.failed.isProblem)
    }

    // MARK: Goal turns

    func testGoalTurnsAreNewestFirstClippedToRangeAndCreditCopiesOnce() {
        let shared = turn("shared", start: -3_000, end: -2_900)
        let lead = session("lead", created: -9_000, turns: [shared, turn("old", start: -90_000, end: -89_000), turn("undated", start: nil)])
        let child = session("child", parent: "lead", created: -5_000, turns: [shared, turn("c1", start: -600, end: -60, status: "failed", tools: 4)])
        let rows = GoalTurnList.rows(sessions: [lead, child, child], from: at(-3_600), to: now, now: now)
        XCTAssertEqual(rows.map(\.turnID), ["c1", "shared"])
        XCTAssertEqual(rows.last?.sessionID, "lead", "the inherited copy belongs to the earliest session")
        XCTAssertEqual(rows.first?.duration, 540)
        XCTAssertTrue(GoalTurnList.matches(rows[0], .problems))
        XCTAssertTrue(GoalTurnList.matches(rows[0], .tools))
        XCTAssertFalse(GoalTurnList.matches(rows[1], .long))
    }

    func testSequenceOrdersDatedTurnsThenUndatedInSourceOrder() {
        let value = session("s", turns: [turn("c", start: -10), turn("x", start: nil), turn("a", start: -30), turn("y", start: nil), turn("a", start: -30)])
        XCTAssertEqual(TurnSequence.ordered(value, now: now).map(\.id), ["a", "c", "x", "y"])
    }

    func testCanonicalOwnerUsesNativeParentEdgesAndMergedCorrectionsNotCreationOrder() throws {
        var lead = session("codex:lead", created: -100, turns: [turn("shared", start: -90, end: -80, tools: 3)])
        lead.nativeID = "native-lead"; lead.observedAt = at(-20)
        let child = session("codex:child", parent: "native-lead", created: -500,
                            turns: [turn("shared", start: nil, end: -70, status: "failed", tools: 0)])
        let records = TurnInspectionRecords([child, lead])
        XCTAssertEqual(records.parents[child.id], lead.id)
        XCTAssertEqual(records.owner(of: "shared", in: child.id)?.id, lead.id)
        let row = try XCTUnwrap(GoalTurnList.rows(sessions: [child, lead], from: at(-1_000), to: now, now: now).first)
        XCTAssertEqual(row.sessionID, lead.id)
        XCTAssertEqual(row.start, at(-90))
        XCTAssertEqual(row.end, at(-70))
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.toolCount, 0, "an explicit correction to zero remains measured zero")
        XCTAssertEqual(records.turns(in: child.id).first?.status, "failed")
        XCTAssertEqual(LiveFeed.events(sessions: [child, lead], now: now).filter { $0.kind != .joined }.map(\.sessionID), [lead.id, lead.id])
    }

    func testUnrelatedCopiesAndCrossProviderParentsDoNotStealOwnership() {
        let receipt = turn("same-id", start: -90, end: -80)
        let first = session("codex:first", turns: [receipt])
        let unrelated = session("codex:second", turns: [receipt])
        var otherProvider = session("claude:lead", turns: [receipt]); otherProvider.provider = .claude
        let child = session("codex:child", parent: otherProvider.id, turns: [receipt])
        let sessions = [first, unrelated, otherProvider, child]
        let records = TurnInspectionRecords(sessions)
        XCTAssertNil(records.parents[child.id])
        XCTAssertEqual(records.owner(of: receipt.id, in: child.id)?.id, child.id)
        let rows = GoalTurnList.rows(sessions: sessions, from: at(-1_000), to: now, now: now)
        XCTAssertEqual(Set(rows.map(\.sessionID)), Set(sessions.map(\.id)))
        XCTAssertEqual(Set(rows.map(\.id)).count, 4)
        XCTAssertEqual(rows, GoalTurnList.rows(sessions: Array(sessions.reversed()), from: at(-1_000), to: now, now: now))
    }

    func testPartialSessionObservationsRetainEarlierTurnsAndValidateBounds() {
        var earlier = session("lead", turns: [turn("earlier", start: -300, end: -200)])
        earlier.observedAt = at(-100)
        let latest = session("lead", turns: [turn("latest", start: -90, end: -80)])
        let rows = GoalTurnList.rows(sessions: [latest, earlier], from: at(-1_000), to: now, now: now)
        XCTAssertEqual(rows.map(\.turnID), ["latest", "earlier"])
        XCTAssertTrue(GoalTurnList.rows(sessions: [latest], from: now, to: at(-1), now: now).isEmpty)
        XCTAssertTrue(GoalTurnList.rows(sessions: [latest], from: at(-1_000), to: now, now: now, limit: -1).isEmpty)
        XCTAssertTrue(LiveFeed.events(sessions: [latest], now: now, window: .infinity).isEmpty)
    }

    // MARK: Feed

    func testFeedNarratesStartsFinishesAndNewHelpersNewestFirst() {
        let lead = session("lead", created: -9_000, turns: [turn("t1", start: -1_200, end: -300), turn("t2", start: -120, end: nil, status: "running")])
        let helper = session("helper", parent: "lead", created: -200, title: "Codex 01a1a665",
                             turns: [turn("h1", start: -190, end: -20, status: "failed")])
        let events = LiveFeed.events(sessions: [lead, helper], now: now)
        XCTAssertEqual(events.map(\.kind), [.failed, .started, .started, .joined, .finished, .started])
        XCTAssertEqual(events.first?.title, "Helping with “Job lead”")
        XCTAssertTrue(events.first?.isHelper ?? false)
    }

    func testFeedFoldsRepeatsWithAStableIdentityAndIgnoresOldOrFutureTimes() {
        let requests = (0 ..< 5).map { turn("r\($0)", start: Double(-500 + $0 * 60), end: nil, status: "running") }
        let first = LiveFeed.events(sessions: [session("claude", turns: requests)], now: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].count, 5)
        let more = LiveFeed.events(sessions: [session("claude", turns: requests + [turn("r5", start: -10, status: "running")])], now: now)
        XCTAssertEqual(more[0].id, first[0].id, "a growing group keeps its row identity")
        XCTAssertEqual(more[0].count, 6)
        XCTAssertTrue(LiveFeed.events(sessions: [session("old", updated: -9_000, turns: [turn("o", start: -9_100, end: -9_000)])], now: now).isEmpty)
        XCTAssertTrue(LiveFeed.events(sessions: [session("future", turns: [turn("f", start: 60)])], now: now).isEmpty)
    }

    func testFeedCreditsCopiedTurnsOnce() {
        let shared = turn("shared", start: -100, end: -50)
        let events = LiveFeed.events(sessions: [session("lead", created: -9_000, turns: [shared]),
                                                session("child", parent: "lead", created: -5_000, turns: [shared])], now: now)
        XCTAssertEqual(events.filter { $0.kind != .joined }.map(\.sessionID), ["lead", "lead"])
    }

    func testFeedDoesNotInventFinishedEventsForUnknownOrContradictoryRecords() {
        let turns = [turn("unknown", start: -100, end: -50, status: "unknown"),
                     turn("contradictory", start: -40, end: -60, status: "completed")]
        let events = LiveFeed.events(sessions: [session("lead", turns: turns)], now: now)
        XCTAssertTrue(events.allSatisfy { $0.kind == .started })
    }

    // MARK: Titles

    func testTitlesReplaceWrappersAndGeneratedNames() {
        let wrapper = "Read the Codex goal objective file at /Users/[REDACTED]/.codex/attachments/9b94/goal-objective.md before continuing."
        XCTAssertTrue(ActivityTitles.isCodexGoalWrapper(wrapper))
        XCTAssertTrue(ActivityTitles.isCodexGoalWrapper("Read the Codex goal objective file at /Users/[REDACTED]/.codex/attachments/9b9474d9-ab1e-43d3-855c-f"),
                      "titles truncated before the file name are still the preamble")
        XCTAssertEqual(ActivityTitles.display(wrapper, provider: .codex, projectPath: nil), ActivityTitles.codexGoalTitle)
        XCTAssertEqual(ActivityTitles.display("Codex 01a1a665", provider: .codex, projectPath: "/w/sample-web-app"),
                       "Codex session in sample-web-app")
        XCTAssertEqual(ActivityTitles.display("Codex 01a1a665", provider: .codex, projectPath: nil, parentTitle: wrapper),
                       "Helping with a Codex goal")
        XCTAssertEqual(ActivityTitles.display("Fix the login bug", provider: .claude, projectPath: "/w/app"), "Fix the login bug")
        XCTAssertFalse(ActivityTitles.isPlaceholder("Add cafe menu"), "ordinary words that happen to be hex are kept")
        XCTAssertFalse(ActivityTitles.isPlaceholder("terra ops review"))
    }
}
