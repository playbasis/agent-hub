import XCTest
@testable import BridgeCore

final class LiveWorkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, provider: AgentName = .codex, parent: String? = nil, updated: TimeInterval,
                         turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: provider, nativeID: id, title: "Job \(id)", projectPath: "/work/app",
                        createdAt: now.addingTimeInterval(-7_200), updatedAt: now.addingTimeInterval(updated),
                        observedAt: now, runtimeState: "notLoaded", parentSessionID: parent, turns: turns, source: "test")
    }

    private func turn(_ id: String, start: TimeInterval, end: TimeInterval? = nil, status: String = "running",
                      categories: [String: Int] = [:], steps: [TimeInterval] = [], tools: Int? = nil) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: now.addingTimeInterval(start), completedAt: end.map { now.addingTimeInterval($0) },
                     status: status, toolCount: tools, model: "gpt-6.1-sol", categories: categories,
                     modelSteps: steps.enumerated().map { ActivityModelStep(id: "\(id):\($0.offset)", timestamp: now.addingTimeInterval($0.element), model: "gpt-6.1-sol") })
    }

    func testRecentOpenTurnIsWorkingEvenWhenRuntimeSaysNotLoaded() throws {
        let agent = try XCTUnwrap(LiveWork.agent(session("a", updated: -40, turns: [
            turn("t", start: -1_800, categories: ["review": 11, "research": 13, "other tools": 30], steps: [-1_700, -600, -90, -40]),
        ]), now: now))
        XCTAssertEqual(agent.state, .working)
        XCTAssertNil(agent.focus, "whole open-turn tool aggregates have no dated current-action proof")
        XCTAssertNil(agent.toolCallCount, "category sums are not exact tool-call receipts")
        XCTAssertFalse(agent.executionVerified)
        XCTAssertEqual(agent.evidenceState, .recentModelSteps)
        XCTAssertEqual(agent.pulse?.count, LiveWork.pulseMinutes)
        // One bar per minute ending now: -40 s is this minute, -90 s the one before.
        XCTAssertEqual(agent.pulse?.suffix(2), [1, 1])
        XCTAssertEqual(agent.stepsLastFiveMinutes, 2)
    }

    func testOpenTurnGoesQuietThenDropsOut() throws {
        let quiet = try XCTUnwrap(LiveWork.agent(session("q", updated: -900, turns: [turn("t", start: -1_200, steps: [-900])]), now: now))
        XCTAssertEqual(quiet.state, .quiet)
        XCTAssertNil(LiveWork.agent(session("old", updated: -7_200, turns: [turn("t", start: -7_300, steps: [-7_200])]), now: now))
    }

    func testFinishedTurnIsFinishedHoweverRecentAndFailuresAreMarked() throws {
        let done = try XCTUnwrap(LiveWork.agent(session("d", updated: -60, turns: [turn("t", start: -900, end: -60, status: "completed")]), now: now))
        XCTAssertEqual(done.state, .finished)
        XCTAssertFalse(done.failed)
        let failed = try XCTUnwrap(LiveWork.agent(session("f", updated: -600, turns: [turn("t", start: -900, end: -600, status: "failed")]), now: now))
        XCTAssertTrue(failed.failed)
        XCTAssertNil(LiveWork.agent(session("x", updated: -5_000, turns: [turn("t", start: -6_000, end: -5_000, status: "completed")]), now: now))
    }

    func testMetadataAfterAFinishedTurnDoesNotInventTheNextTurn() throws {
        let agent = try XCTUnwrap(LiveWork.agent(session("n", updated: -20, turns: [turn("t", start: -900, end: -300, status: "completed")]), now: now))
        XCTAssertEqual(agent.state, .finished)
        XCTAssertEqual(agent.lastActivity, now.addingTimeInterval(-300))
    }

    func testStretchStartsAfterTheLastLongGap() throws {
        let agent = try XCTUnwrap(LiveWork.agent(session("s", updated: -30, turns: [
            turn("t", start: -2_400, steps: [-2_400, -1_500, -1_000, -500, -30]),
        ]), now: now))
        // -2_400 → -1_500 is a 15-minute gap; the stretch begins at -1_500.
        XCTAssertEqual(agent.stretchStart, now.addingTimeInterval(-1_500))
    }

    func testOneRequestTurnsDescribeRecentWorkAndPulseFromRequests() throws {
        // Claude: one turn per request, no model-step timestamps, no end times.
        let turns = (0..<6).map { turn("c\($0)", start: Double(-60 * (6 - $0)), categories: $0 < 4 ? ["implementation": 1] : ["execution": 1], tools: 1) }
        let agent = try XCTUnwrap(LiveWork.agent(session("c", provider: .claude, updated: -60, turns: turns.map { var t = $0; t.modelSteps = nil; return t }), now: now))
        XCTAssertEqual(agent.state, .working)
        XCTAssertEqual(agent.focus, .writingCode)
        XCTAssertEqual(agent.toolCalls, 6)
        XCTAssertEqual(agent.pulse?.reduce(0, +), 6)
    }

    func testJobsGroupWorkingSubAgentsUnderTheirLeadAndSortWorkingFirst() {
        let lead = session("lead", updated: -7_000, turns: [turn("t", start: -7_100, end: -7_000, status: "completed")])
        let helper = session("helper", parent: "lead", updated: -30, turns: [turn("h", start: -300, categories: ["tests": 3], steps: [-30])])
        let done = session("done", updated: -600, turns: [turn("d", start: -900, end: -600, status: "completed")])
        let summary = LiveWork.summary(roots: [done, lead], children: ["lead": [helper]], now: now)
        XCTAssertEqual(summary.jobs.map(\.id), ["session:lead", "session:done"])
        XCTAssertEqual(summary.jobs.first?.state, .working)
        XCTAssertEqual(summary.jobs.first?.helpers.map(\.focus), [nil], "unplaced whole-turn tools are not an exact current stage")
        XCTAssertEqual(summary.workingAgents, 1)
        XCTAssertEqual(summary.workingSubAgents, 1)
        XCTAssertEqual(summary.active.map(\.id), ["session:lead"])
        XCTAssertEqual(summary.finished.map(\.id), ["session:done"])
    }

    func testMetadataOnlyUpdatesAndCodexNativeTurnsNeverCreateModelRequests() throws {
        XCTAssertNil(LiveWork.agent(session("metadata", updated: -1, turns: []), now: now))
        let native = try XCTUnwrap(LiveWork.agent(session("native", updated: -1, turns: [turn("t", start: -30)]), now: now))
        XCTAssertEqual(native.evidenceState, .recentTurnStart)
        XCTAssertNil(native.pulse)
        XCTAssertNil(native.stepsLastFiveMinutes)
        XCTAssertNil(native.model, "session/native model hints do not fill missing model-step identity")
        let mixed = try XCTUnwrap(LiveWork.agent(session("mixed", updated: -1, turns: [
            turn("old", start: -900, end: -600, status: "completed", steps: [-610]), turn("new", start: -20),
        ]), now: now))
        XCTAssertNil(mixed.model, "a new unknown turn must not borrow the prior turn's model")
        XCTAssertEqual(mixed.evidenceState, .recentTurnStart)
    }

    func testFutureNonfiniteAndCorruptTimestampsDoNotCreateRecentActivityOrIntegerTraps() {
        XCTAssertNil(LiveWork.agent(session("future", updated: 30, turns: [turn("t", start: 10, steps: [20])]), now: now))
        var invalid = turn("bad", start: -30)
        invalid.startedAt = Date(timeIntervalSince1970: .nan)
        invalid.modelSteps = [ActivityModelStep(id: "bad", timestamp: Date(timeIntervalSince1970: .infinity), model: "unknown")]
        XCTAssertNil(LiveWork.agent(session("bad", updated: -1, turns: [invalid]), now: now))
        XCTAssertNil(LiveWork.agent(session("clock", updated: -1, turns: [turn("t", start: -30)]), now: Date(timeIntervalSince1970: .nan)))
    }

    func testToolOverflowRemainsUnknownWhileExplicitZeroIsMeasured() throws {
        let a = turn("a", start: -120, end: -100, categories: ["tests": Int.max], steps: [-110], tools: Int.max)
        let b = turn("b", start: -90, end: -60, categories: ["tests": 1], steps: [-80], tools: 1)
        let overflow = try XCTUnwrap(LiveWork.agent(session("overflow", updated: -1, turns: [a, b]), now: now))
        XCTAssertNil(overflow.toolCallCount)
        XCTAssertTrue(overflow.toolCallsArePartial)
        let zero = try XCTUnwrap(LiveWork.agent(session("zero", updated: -1, turns: [turn("z", start: -60, end: -30, tools: 0)]), now: now))
        XCTAssertEqual(zero.toolCallCount, 0)
    }

    func testFullOwnershipContextDoesNotCreditInheritedParentStepsToAChild() throws {
        let shared = turn("shared", start: -120, end: -100, steps: [-110])
        let lead = session("lead", updated: -100, turns: [shared])
        let child = session("child", parent: "lead", updated: -1, turns: [shared])
        XCTAssertNil(LiveWork.agent(child, now: now, ownershipContext: [lead, child]))
        let summary = LiveWork.summary(roots: [lead], children: [lead.id: [child]], now: now)
        XCTAssertEqual(summary.jobs.flatMap(\.agents).flatMap(\.modelStepIDs).count, 1)
    }

    func testFocusVocabularyMatchesWorkMixCategories() {
        XCTAssertEqual(LiveWork.Focus(category: "inspection"), .readingCode)
        XCTAssertEqual(LiveWork.Focus(category: "delegation"), .coordinating)
        XCTAssertEqual(LiveWork.Focus(category: "other tools"), .usingTools)
        XCTAssertEqual(LiveWork.Focus.dominant(["other tools": 9]), .usingTools)
        XCTAssertNil(LiveWork.Focus.dominant([:]))
        // Ties resolve by name, so the label doesn't flicker between refreshes.
        XCTAssertEqual(LiveWork.Focus.dominant(["tests": 2, "review": 2]), LiveWork.Focus.dominant(["review": 2, "tests": 2]))
    }
}
