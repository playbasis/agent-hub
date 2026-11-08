import Foundation
import XCTest
@testable import BridgeCore

final class GoalWorkMappingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func turn(_ id: String, at seconds: Double = -60) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: now.addingTimeInterval(seconds), status: "running",
                     modelSteps: [ActivityModelStep(id: id + ":step", timestamp: now.addingTimeInterval(seconds + 1), model: "gpt-6.1-sol")])
    }
    private func session(_ id: String, provider: AgentName = .codex, native: String? = nil, parent: String? = nil,
                         goalID: String? = nil, goalStatus: String = "active", created: Double = -3_600,
                         turns: [ActivityTurn] = []) -> ActivitySession {
        let goal = goalID.map { ActivityGoal(id: $0, sessionID: id, objective: "Recorded goal", status: goalStatus,
            createdAt: now.addingTimeInterval(created), updatedAt: now.addingTimeInterval(-1)) }
        return ActivitySession(id: id, provider: provider, nativeID: native ?? id, title: id, projectPath: "/same/project",
            createdAt: now.addingTimeInterval(-86_400), updatedAt: now.addingTimeInterval(-1), observedAt: now,
            parentSessionID: parent, goal: goal, turns: turns, source: "fixture")
    }

    func testOwnGoalAndVerifiedParentChainCarryEvidenceAndStableJobIDs() throws {
        let lead = session("lead", native: "native-lead", goalID: "goal")
        let helper = session("helper", parent: "native-lead")
        let nested = session("nested", parent: "helper")
        let mappings = GoalWorkMapping.resolve(sessions: [nested, helper, lead], now: now)
        XCTAssertEqual(mappings[lead.id]?.state, .matched)
        XCTAssertEqual(mappings[nested.id]?.goalID, "goal")
        XCTAssertEqual(mappings[nested.id]?.goalSessionID, lead.id)
        XCTAssertEqual(mappings[nested.id]?.jobID, mappings[lead.id]?.jobID)
        XCTAssertEqual(mappings[nested.id]?.evidence.filter { $0.kind == .nativeParent }.count, 2)
    }

    func testSameProjectAndSimilarDatesNeverCreateAGoalRelationship() {
        let lead = session("lead", goalID: "goal")
        let unrelated = session("unrelated", turns: [turn("work")])
        let value = GoalWorkMapping.resolve(sessions: [lead, unrelated], now: now)[unrelated.id]
        XCTAssertEqual(value?.state, .unattributed)
        XCTAssertNil(value?.goalID)
        XCTAssertEqual(value?.jobID, "session:unrelated")
    }

    func testRootTurnCorrelationDoesNotCollapseDistinctChildTurns() {
        let lead = session("lead", goalID: "goal", turns: [turn("codex:turn:root")])
        let first = session("first", turns: [turn("codex:turn:first")])
        let second = session("second", turns: [turn("codex:turn:second")])
        let links = [GoalWorkMapping.RootTurnLink(provider: .codex, sessionID: first.id, nativeTurnID: "first", rootTurnID: "root", evidenceID: "link-1"),
                     GoalWorkMapping.RootTurnLink(provider: .codex, sessionID: second.id, nativeTurnID: "second", rootTurnID: "root", evidenceID: "link-2")]
        let values = GoalWorkMapping.resolve(sessions: [lead, first, second], now: now, rootTurnLinks: links)
        XCTAssertEqual(values[first.id]?.goalID, "goal")
        XCTAssertEqual(values[second.id]?.goalID, "goal")
        XCTAssertEqual(values[first.id]?.evidence.first { $0.kind == .nativeRootTurn }?.nativeTurnID, "first")
        XCTAssertEqual(values[second.id]?.evidence.first { $0.kind == .nativeRootTurn }?.nativeTurnID, "second")
        XCTAssertEqual(first.turns[0].id, "codex:turn:first")
        XCTAssertEqual(second.turns[0].id, "codex:turn:second")
    }

    func testUnverifiedSourceTurnAndAmbiguousRootOwnersStayUnattributed() {
        let a = session("a", goalID: "goal-a", turns: [turn("root")])
        let b = session("b", goalID: "goal-b", turns: [turn("root")])
        let helper = session("helper", turns: [turn("child")])
        let bad = GoalWorkMapping.RootTurnLink(provider: .codex, sessionID: helper.id, nativeTurnID: "missing", rootTurnID: "root", evidenceID: "bad")
        XCTAssertEqual(GoalWorkMapping.resolve(sessions: [a, helper], now: now, rootTurnLinks: [bad])[helper.id]?.state, .unattributed)
        let ambiguous = GoalWorkMapping.RootTurnLink(provider: .codex, sessionID: helper.id, nativeTurnID: "child", rootTurnID: "root", evidenceID: "ambiguous")
        let value = GoalWorkMapping.resolve(sessions: [a, b, helper], now: now, rootTurnLinks: [ambiguous])[helper.id]
        XCTAssertEqual(value?.state, .ambiguous)
        XCTAssertNil(value?.goalID)
        XCTAssertEqual(value?.candidateGoalIDs, ["goal-a", "goal-b"])
    }

    func testNativeParentAliasesAreProviderScopedAndAmbiguityDoesNotGuess() {
        let codex = session("codex", native: "same", goalID: "codex-goal")
        let claude = session("claude", provider: .claude, native: "same", goalID: "claude-goal")
        let helper = session("helper", parent: "same")
        let values = GoalWorkMapping.resolve(sessions: [claude, helper, codex], now: now)
        XCTAssertEqual(values[helper.id]?.goalID, "codex-goal")
        let duplicate = session("duplicate", native: "same", goalID: "other-goal")
        let ambiguous = GoalWorkMapping.resolve(sessions: [codex, duplicate, helper], now: now)[helper.id]
        XCTAssertEqual(ambiguous?.state, .unattributed)
        XCTAssertEqual(ambiguous?.reason, "ambiguous_native_parent")
    }

    func testMalformedCyclesAndFutureOrClosedGoalsNeverBecomeVerifiedOpenGoals() {
        let a = session("a", parent: "b")
        let b = session("b", parent: "a")
        XCTAssertEqual(GoalWorkMapping.resolve(sessions: [a, b], now: now)[a.id]?.reason, "cyclic_native_parent")
        let closed = session("closed", goalID: "closed-goal", goalStatus: "complete")
        XCTAssertEqual(GoalWorkMapping.resolve(sessions: [closed], now: now)[closed.id]?.state, .unattributed)
        var future = session("future", goalID: "future-goal")
        future.goal?.createdAt = now.addingTimeInterval(10)
        future.goal?.updatedAt = now.addingTimeInterval(20)
        XCTAssertEqual(GoalWorkMapping.resolve(sessions: [future], now: now)[future.id]?.state, .unattributed)
    }

    func testExplicitGoalIDsMustResolveToExistingGoalsAndConflictsStayVisible() {
        let a = session("a", goalID: "a-goal"), b = session("b", goalID: "b-goal")
        let helper = session("helper")
        let links = [GoalWorkMapping.ExplicitGoalLink(provider: .codex, sessionID: helper.id, goalID: "a-goal", evidenceID: "native-goal-1"),
                     GoalWorkMapping.ExplicitGoalLink(provider: .codex, sessionID: helper.id, goalID: "b-goal", evidenceID: "native-goal-2")]
        let value = GoalWorkMapping.resolve(sessions: [a, b, helper], now: now, explicitGoalLinks: links)[helper.id]
        XCTAssertEqual(value?.state, .ambiguous)
        XCTAssertNil(value?.goalID)
        XCTAssertEqual(value?.candidateGoalIDs, ["a-goal", "b-goal"])
        let missing = GoalWorkMapping.ExplicitGoalLink(provider: .codex, sessionID: helper.id, goalID: "not-collected", evidenceID: "native-goal-3")
        XCTAssertEqual(GoalWorkMapping.resolve(sessions: [helper], now: now, explicitGoalLinks: [missing])[helper.id]?.state, .unattributed)
    }

    func testHistoricalTurnsDoNotInheritASessionsNewCurrentGoal() throws {
        let before = turn("old", at: -7_200), inside = turn("current", at: -60)
        let lead = session("lead", goalID: "goal", created: -3_600, turns: [before, inside])
        let prepared = try XCTUnwrap(GoalWorkMapping.resolve(sessions: [lead], now: now)[lead.id])
        let old = GoalWorkMapping.association(for: before, sessionID: lead.id, sessions: [lead], now: now, sessionAssociation: prepared)
        XCTAssertEqual(old.state, .unattributed)
        XCTAssertNil(old.goalID)
        let current = GoalWorkMapping.association(for: inside, sessionID: lead.id, sessions: [lead], now: now, sessionAssociation: prepared)
        XCTAssertEqual(current.goalID, "goal")
        XCTAssertTrue(current.evidence.contains { $0.kind == .goalLifetime && $0.nativeTurnID == inside.id })
        let stage = GoalWorkMapping.association(for: before, sessionID: lead.id, sessions: [lead], now: now,
            at: now.addingTimeInterval(-30), sessionAssociation: prepared)
        XCTAssertEqual(stage.goalID, "goal", "only the explicitly dated later stage is in the goal lifetime, not the whole historical turn")
        var undated = inside; undated.startedAt = nil
        let unknown = GoalWorkMapping.association(for: undated, sessionID: lead.id, sessions: [lead], now: now, sessionAssociation: prepared)
        XCTAssertEqual(unknown.state, .unattributed)
    }
}
