import Foundation
import XCTest
@testable import BridgeCore

final class GoalReplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func turn(_ id: String, at offset: Double? = -100, steps: [ActivityModelStep]? = nil,
                      completeSteps: Bool? = nil, tools: Int? = nil) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: offset.map { now.addingTimeInterval($0) }, status: "completed",
                     toolCount: tools, modelSteps: steps, modelStepsComplete: completeSteps)
    }
    private func session(_ id: String, provider: AgentName = .codex, native: String? = nil, parent: String? = nil,
                         goal: String? = nil, goalStatus: String = "active", turns: [ActivityTurn] = [],
                         complete: Bool = true) -> ActivitySession {
        ActivitySession(id: id, provider: provider, nativeID: native ?? id, title: id, projectPath: "/same/project",
            createdAt: now.addingTimeInterval(-86_400), updatedAt: now.addingTimeInterval(-1), observedAt: now,
            parentSessionID: parent,
            goal: goal.map { ActivityGoal(id: $0, sessionID: id, objective: "Goal", status: goalStatus,
                createdAt: now.addingTimeInterval(-1_000), updatedAt: now.addingTimeInterval(-50)) },
            turns: turns, historyComplete: complete, source: "fixture")
    }
    private func index(_ sessions: [ActivitySession], root: String = "root", maximumRows: Int = 20_000) -> GoalReplayIndex {
        GoalReplayIndex.build(overview: ActivityOverview(generatedAt: now, sessions: sessions), rootSessionID: root, maximumRows: maximumRows)
    }

    func testGoalChronologyCombinesExplicitHelpersNotSameProjectOrCrossProvider() {
        let root = session("root", native: "native-root", goal: "goal", turns: [turn("lead", at: -300)])
        let helper = session("helper", parent: "native-root", turns: [turn("helper-work", at: -200)])
        let nested = session("nested", parent: "helper", turns: [turn("nested-work", at: -100)])
        let unrelated = session("unrelated", turns: [turn("unrelated-work", at: -250)])
        let foreign = session("foreign", provider: .claude, parent: "root", turns: [turn("foreign-work", at: -250)])
        let value = index([nested, unrelated, foreign, helper, root])
        XCTAssertEqual(value.rows.map(\.nativeTurnID), ["lead", "helper-work", "nested-work"])
        XCTAssertEqual(value.rows.map(\.sessionID), ["root", "helper", "nested"])
        XCTAssertTrue(value.rows.allSatisfy { $0.association.goalID == "goal" && $0.association.state == .matched })
        XCTAssertEqual(value.rows.last?.association.evidence.filter { $0.kind == .nativeParent }.count, 2)
        XCTAssertEqual(value.summary.sessionCount, 3)
        XCTAssertEqual(value.rows.map(\.id), index([root, helper, nested, foreign, unrelated]).rows.map(\.id))
    }

    func testInheritedForkTurnBelongsOnlyToCanonicalAncestor() {
        let shared = turn("shared", at: -300)
        let root = session("root", goal: "goal", turns: [shared])
        let helper = session("helper", parent: "root", turns: [shared, turn("own", at: -200)])
        let value = index([helper, root])
        XCTAssertEqual(value.rows.map(\.nativeTurnID), ["shared", "own"])
        XCTAssertEqual(value.rows.first?.sessionID, "root")
        XCTAssertEqual(value.summary.knownTurnCount, 2)
    }

    func testInspectionRetainsCanonicalCopiedCorrectionsNotTheFirstRawTurn() throws {
        var original = turn("shared", at: -300, steps: [ActivityModelStep(id: "step", timestamp: now.addingTimeInterval(-299),
            model: "old-model", usage: TokenUsage(total: 1, provenance: .providerReported))], completeSteps: true, tools: 1)
        original.model = "old-model"
        var correction = original
        correction.model = "corrected-model"; correction.toolCount = 3
        correction.modelSteps = [ActivityModelStep(id: "step", timestamp: now.addingTimeInterval(-299),
            model: "corrected-model", usage: TokenUsage(total: 99, provenance: .providerReported))]
        var root = session("root", goal: "goal", turns: [original])
        root.observedAt = now.addingTimeInterval(-10)
        let helper = session("helper", parent: "root", turns: [correction, turn("own", at: -200)])
        let value = index([root, helper])
        let row = try XCTUnwrap(value.rows.first { $0.nativeTurnID == "shared" })
        let canonical = try XCTUnwrap(ActivityAnalytics.ownedTurnsBySession(in: [root, helper])[root.id]?.first { $0.id == "shared" })
        XCTAssertEqual(row.sourceTurn, canonical, "Inspection uses the shared canonical record, including its provenance rules")
        XCTAssertEqual(row.sessionID, "root")
        XCTAssertEqual(row.sourceTurn.model, "corrected-model")
        XCTAssertEqual(row.sourceTurn.toolCount, 3)
        XCTAssertEqual(row.sourceTurn.modelSteps?.first?.usage.total, 99)
        XCTAssertEqual(row.model, row.sourceTurn.model)
        XCTAssertEqual(root.turns[0].model, "old-model", "The frozen input observation is not rewritten")
        XCTAssertEqual(value.rows.filter { $0.nativeTurnID == "shared" }.count, 1)
    }

    func testCompletedAndClearedGoalsHaveHistoricalReplayWithoutBecomingLiveOpenGoals() {
        for status in ["complete", "completed", "cleared"] {
            let root = session("root", goal: "goal", goalStatus: status, turns: [turn("before", at: -1_001), turn("inside", at: -200), turn("after", at: -49)])
            let helper = session("helper", parent: "root", turns: [turn("helper", at: -100)])
            let value = index([root, helper])
            XCTAssertEqual(value.goalID, "goal")
            XCTAssertEqual(value.rows.map(\.nativeTurnID), ["inside", "helper"])
            XCTAssertTrue(value.rows.allSatisfy { $0.association.reason == "verified_historical_native_relationship" })
            XCTAssertEqual(value.summary.excludedOutsideLifetime, 2)
            XCTAssertTrue(value.summary.warnings.contains { $0.contains("closed-state") })
            XCTAssertEqual(GoalWorkMapping.resolve(sessions: [root, helper], now: now)[root.id]?.state, .unattributed)
        }
    }

    func testLifetimeEdgesAreInclusiveAndCurrentGoalsDoNotInheritOldHistory() {
        let root = session("root", goal: "goal", goalStatus: "complete", turns: [turn("start", at: -1_000), turn("end", at: -50), turn("old", at: -2_000)])
        let value = index([root])
        XCTAssertEqual(value.rows.map(\.nativeTurnID), ["start", "end"])
        XCTAssertEqual(value.summary.excludedOutsideLifetime, 1)
    }

    func testUnknownDatesStayExplicitAndSortAfterDatedRowsWithoutGoalAttribution() {
        var completedOnly = turn("completed-only", at: nil)
        completedOnly.completedAt = now.addingTimeInterval(-80)
        let unknown = turn("undated", at: nil)
        let root = session("root", goal: "goal", turns: [unknown, completedOnly, turn("dated", at: -100)])
        let value = index([root])
        XCTAssertEqual(value.rows.map(\.nativeTurnID), ["dated", "completed-only", "undated"])
        XCTAssertEqual(value.rows[1].timestampBasis, .completed)
        XCTAssertEqual(value.rows[2].timestampBasis, .unavailable)
        XCTAssertTrue(value.rows[2].coverage.contains(.unknownTime))
        XCTAssertEqual(value.rows[1].association.state, .unattributed)
        XCTAssertEqual(value.rows[2].association.state, .unattributed)
        XCTAssertEqual(value.summary.undatedTurnCount, 1)
        XCTAssertEqual(value.summary.associationUncertainCount, 2)
        XCTAssertTrue(value.summary.isPartial)
    }

    func testUnknownMeasurementsAreNotZeroAndCheckpointsAreNotNativeRequests() {
        let root = session("root", goal: "goal", turns: [turn("legacy", at: -200), turn("zero", at: -100, steps: [], completeSteps: true, tools: 0)])
        let value = index([root])
        XCTAssertNil(value.rows[0].modelStepCount)
        XCTAssertNil(value.rows[0].toolCount)
        XCTAssertTrue(value.rows[0].coverage.contains(.unmeasuredModelSteps))
        XCTAssertTrue(value.rows[0].modelStepsArePartial)
        XCTAssertEqual(value.rows[1].modelStepCount, 0)
        XCTAssertEqual(value.rows[1].toolCount, 0)
        XCTAssertFalse(value.rows[1].modelStepsArePartial)
    }

    func testCheckpointIdentityIsDeduplicatedAndMixedModelsNeverBecomeOneModel() {
        let first = ActivityModelStep(id: "same", timestamp: now.addingTimeInterval(-90), model: "model-a", effort: "high")
        let second = ActivityModelStep(id: "other", timestamp: now.addingTimeInterval(-80), model: "model-b", effort: "low")
        let root = session("root", goal: "goal", turns: [turn("mixed", steps: [first, first, second], completeSteps: true)])
        let row = index([root]).rows[0]
        XCTAssertEqual(row.modelStepCount, 2)
        XCTAssertEqual(row.models, ["model-a", "model-b"])
        XCTAssertEqual(row.efforts, ["high", "low"])
        XCTAssertNil(row.model)
        XCTAssertNil(row.effort)
        XCTAssertTrue(row.coverage.contains(.mixedModels))
    }

    func testAllKnownRecordsBeyondOld160LimitCanBePagedWithoutIdentityChanges() {
        let turns = (0..<205).map { turn("turn-\($0)", at: -900 + Double($0)) }
        let value = index([session("root", goal: "goal", turns: Array(turns.reversed()))])
        XCTAssertEqual(value.summary.knownTurnCount, 205)
        XCTAssertEqual(value.summary.omittedTurnCount, 0)
        var all: [String] = [], offset = 0
        while true {
            let page = value.page(offset: offset, limit: 40)
            all += page.rows.map(\.id)
            guard let next = page.nextOffset else { break }
            offset = next
        }
        XCTAssertEqual(all, value.rows.map(\.id))
        XCTAssertEqual(Set(all).count, 205)
        XCTAssertEqual(value.rows.first?.nativeTurnID, "turn-0")
        XCTAssertEqual(value.rows.last?.nativeTurnID, "turn-204")
    }

    func testIndexAndPageBoundsAreExplicitNotSilentTruncation() {
        let root = session("root", goal: "goal", turns: (0..<10).map { turn("turn-\($0)", at: -900 + Double($0)) })
        let value = index([root], maximumRows: 3)
        XCTAssertEqual(value.rows.count, 3)
        XCTAssertEqual(value.summary.knownTurnCount, 10)
        XCTAssertEqual(value.summary.omittedTurnCount, 7)
        XCTAssertTrue(value.summary.warnings.contains { $0.contains("7 known turns") })
        XCTAssertEqual(value.page(offset: Int.max, limit: Int.max).rows.count, 0)
        XCTAssertNil(value.page(offset: Int.max, limit: Int.max).nextOffset)
        XCTAssertTrue(value.page(offset: -1).rows.isEmpty)
        XCTAssertTrue(value.page(limit: 0).rows.isEmpty)
        XCTAssertEqual(index([root], maximumRows: -1).summary.omittedTurnCount, 10)
    }

    func testNativeAliasesAreProviderScopedAndAmbiguityDoesNotGuessAHelper() {
        let root = session("root", native: "same", goal: "goal", turns: [turn("root-work")])
        let helper = session("helper", parent: "same", turns: [turn("helper-work")])
        let foreign = session("foreign", provider: .claude, native: "same", goal: "foreign-goal")
        XCTAssertEqual(Set(index([root, helper, foreign]).rows.map(\.sessionID)), ["root", "helper"])
        let duplicate = session("duplicate", native: "same")
        XCTAssertEqual(index([root, helper, duplicate]).rows.map(\.sessionID), ["root"])
    }

    func testCyclesAndIndependentNestedGoalsAreNotAssignedToTheRootGoal() {
        let root = session("root", goal: "goal", turns: [turn("lead")])
        let a = session("a", parent: "b", turns: [turn("a-work")])
        let b = session("b", parent: "a", turns: [turn("b-work")])
        let independent = session("independent", parent: "root", goal: "other-goal", turns: [turn("other")])
        let child = session("child", parent: "independent", turns: [turn("child-work")])
        XCTAssertEqual(index([root, a, b, independent, child]).rows.map(\.nativeTurnID), ["lead"])
        let cyclicRoot = session("root", parent: "helper", goal: "goal", turns: [turn("lead")])
        let cyclicHelper = session("helper", parent: "root", turns: [turn("helper")])
        let cyclic = index([cyclicRoot, cyclicHelper])
        XCTAssertEqual(cyclic.rows.map(\.nativeTurnID), ["lead"])
        XCTAssertTrue(cyclic.summary.warnings.contains { $0.contains("cyclic") })
    }

    func testFutureAndInvalidTimesNeverManufactureAGoalMatch() {
        var future = turn("future", at: 10)
        future.completedAt = now.addingTimeInterval(-10)
        var invalid = turn("invalid", at: nil)
        invalid.startedAt = Date(timeIntervalSince1970: .nan)
        let value = index([session("root", goal: "goal", turns: [future, invalid])])
        XCTAssertTrue(value.rows.allSatisfy { $0.association.state == .unattributed && $0.coverage.contains(.inconsistentTime) })
        var badSession = session("root", goal: "goal")
        badSession.observedAt = now.addingTimeInterval(1)
        XCTAssertTrue(index([badSession]).rows.isEmpty)
        XCTAssertTrue(index([badSession]).summary.isPartial)
    }

    func testConflictingLatestIdentityAndCopiedGoalMetadataDoNotGuessOwnership() {
        let root = session("root", native: "one", goal: "goal", turns: [turn("turn")])
        var conflict = root; conflict.nativeID = "two"
        let a = index([root, conflict]), b = index([conflict, root])
        XCTAssertTrue(a.rows.isEmpty)
        XCTAssertEqual(a.summary.warnings, b.summary.warnings)
        var copied = root; copied.goal?.sessionID = "absent-owner"
        let value = index([copied])
        XCTAssertNil(value.goalID)
        XCTAssertEqual(value.rows.first?.association.state, .unattributed)
    }

    func testMissingGoalAndPartialSourceRemainUsefulButUnverified() {
        let root = session("root", turns: [turn("work")], complete: false)
        let value = index([root])
        XCTAssertEqual(value.rows.count, 1)
        XCTAssertNil(value.goalID)
        XCTAssertFalse(value.summary.historyComplete)
        XCTAssertTrue(value.summary.isPartial)
        XCTAssertTrue(value.rows[0].coverage.contains(.partialHistory))
        XCTAssertEqual(value.rows[0].association.reason, "selected_goal_unavailable")
    }

    func testClosedGoalOverrunIsExplicitAndSourceCountsStayNativeScoped() {
        var long = turn("long", at: -100, tools: 10)
        long.completedAt = now.addingTimeInterval(-20)
        let row = index([session("root", goal: "goal", goalStatus: "complete", turns: [long])]).rows[0]
        XCTAssertTrue(row.coverage.contains(.extendsPastGoalEnd))
        XCTAssertEqual(row.toolCount, 10, "This is the recorded whole-turn pool, not an invented goal-scoped allocation")
    }

    func testEqualDatesHaveDeterministicSourceIdentityOrderAndBlankModelsStayUnknown() {
        let root = session("root", goal: "goal", turns: [turn("b"), turn("a")])
        let helper = session("helper", parent: "root", turns: [turn("helper")])
        let first = index([root, helper]), second = index([helper, root])
        XCTAssertEqual(first.rows.map(\.id), second.rows.map(\.id))
        XCTAssertEqual(Set(first.rows.map(\.id)).count, 3)
        XCTAssertTrue(first.rows.allSatisfy { $0.model == nil && $0.coverage.contains(.modelIdentityMissing) })
    }
}
