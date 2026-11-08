import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class AgentRosterAccountingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var cutoff: Date { now.addingTimeInterval(-60) }

    func testDiscoveredSideChatKeepsNativeIdentityWithoutInventingMetricsOrRole() throws {
        var side = session("side", title: "Compare camera options")
        side.goal = goal(side.id, objective: "Read the Codex goal objective file at /old/goal.txt")
        side.models = ["configured-model-not-observed"]
        side.runtimeState = "unknown"
        let snapshot = overview([side])
        let roster = TeamRosterView.Roster.build(sessions: [side], overview: snapshot,
            assignments: AgentPersonaCatalog.assign([side]), now: now, after: cutoff)
        let member = try XCTUnwrap(roster.members.first)
        XCTAssertEqual(member.id, side.id)
        XCTAssertEqual(member.nativeIdentity, "Codex · side")
        XCTAssertEqual(member.displayTitle, "Compare camera options", "An attached old goal must not replace a native side-chat title")
        XCTAssertEqual(member.evidence, .metadataOnly)
        XCTAssertFalse(member.hasPeriodWork)
        XCTAssertFalse(member.recent)
        XCTAssertNil(member.lastActivity)
        XCTAssertNil(member.role, "A goal with no owned tool evidence is not an observed coordinator")
        XCTAssertNil(member.tokens)
        XCTAssertNil(member.recordedSeconds)
        XCTAssertTrue(member.models.isEmpty)
        XCTAssertTrue(member.mix.isEmpty)
        XCTAssertFalse(member.evidence.title.lowercased().contains("idle"))
        XCTAssertTrue(member.evidence.explanation.contains("Missing usage is not zero"))
    }

    func testIndependentSideChatsConserveCanonicalPeriodTotals() throws {
        let left = session("left", title: "Side chat", turns: [turn("left", total: 20)])
        let right = session("right", title: "Side chat", turns: [turn("right", total: 30)])
        let snapshot = overview([left, right])
        let prepared = prepare(snapshot)
        XCTAssertEqual(Set(prepared.roster.members.map(\.id)), [left.id, right.id])
        XCTAssertTrue(prepared.roster.members.allSatisfy(\.hasPeriodWork))
        XCTAssertEqual(Set(prepared.roster.members.map(\.nativeIdentity)).count, 2, "Same titles must retain distinct native identities")
        XCTAssertEqual(prepared.roster.accounting.evidenceDigest, prepared.scope.accounting.evidenceDigest)
        XCTAssertEqual(prepared.roster.members.compactMap(\.tokens).reduce(0, +), 50)
        XCTAssertEqual(prepared.roster.accounting.totals.tokensKnown, 50)
        XCTAssertEqual(prepared.roster.members.map { $0.accounting.totals.observedModelSteps }.reduce(0, +), 2)
        XCTAssertEqual(prepared.roster.accounting.totals.observedModelSteps, 2)
        XCTAssertTrue(prepared.roster.members.allSatisfy { $0.role == nil }, "A model response is not tool-category evidence for a role")
    }

    func testCopiedParentHistoryStaysWithParentEvenWhenProjectFilterExcludesIt() throws {
        var shared = turn("shared", total: 40)
        shared.categories = ["tests": 5]
        var parent = session("parent", title: "Parent", turns: [shared])
        parent.projectPath = "/fixtures/parent"
        var child = session("child", title: "Side discussion", turns: [shared])
        child.parentSessionID = parent.nativeID
        child.projectPath = "/fixtures/child"
        child.goal = goal(child.id, objective: "Old attached objective")
        let snapshot = overview([parent, child])
        let all = prepare(snapshot)
        let copied = try XCTUnwrap(all.roster.members.first { $0.id == child.id })
        XCTAssertEqual(copied.evidence, .sharedHistory)
        XCTAssertFalse(copied.hasPeriodWork)
        XCTAssertNil(copied.tokens)
        XCTAssertNil(copied.role)
        XCTAssertTrue(copied.models.isEmpty)
        XCTAssertEqual(all.roster.accounting.totals.tokensKnown, 40)
        XCTAssertEqual(all.roster.accounting.totals.nativeRecords, 1)
        let filtered = prepare(snapshot, project: "/fixtures/child")
        XCTAssertEqual(filtered.roster.members.map(\.id), [child.id])
        XCTAssertEqual(filtered.roster.members.first?.evidence, .sharedHistory)
        XCTAssertNil(filtered.roster.accounting.totals.tokensKnown)
        XCTAssertEqual(filtered.roster.accounting.totals.observedModelSteps, 0)
        XCTAssertEqual(filtered.roster.accounting.totals.nativeRecords, 0)
        XCTAssertNil(filtered.roster.members.first?.role)
    }

    func testOutsidePeriodSessionRemainsDiscoverableWithoutEnteringPeriodTotals() throws {
        var old = session("old-side", title: "Earlier side chat", turns: [turn("old", total: 70, start: -600, finish: -500)])
        old.updatedAt = now.addingTimeInterval(-500)
        let current = session("current", title: "Current work", turns: [turn("current", total: 30)])
        let snapshot = overview([old, current])
        let prepared = prepare(snapshot)
        XCTAssertFalse(prepared.scope.sessions.contains { $0.id == old.id })
        XCTAssertEqual(prepared.roster.members.count, 2)
        let member = try XCTUnwrap(prepared.roster.members.first { $0.id == old.id })
        XCTAssertEqual(member.evidence, .outsidePeriod)
        XCTAssertFalse(member.hasPeriodWork)
        XCTAssertNil(member.tokens)
        XCTAssertNil(member.role)
        XCTAssertFalse(member.recent)
        XCTAssertEqual(prepared.roster.accounting.totals.tokensKnown, 30)
        let allHistory = prepare(snapshot, after: nil)
        XCTAssertTrue(try XCTUnwrap(allHistory.roster.members.first { $0.id == old.id }).hasPeriodWork)
        XCTAssertEqual(allHistory.roster.accounting.totals.tokensKnown, 100)
    }

    func testBoundedReplayRetainsMergedOwnWorkAndOneNativeSession() throws {
        var earlier = session("replay", title: "Side research", turns: [turn("retained", total: 25)])
        earlier.observedAt = now.addingTimeInterval(-5)
        var tail = earlier
        tail.observedAt = now
        tail.historyComplete = false
        tail.turns = []
        let snapshot = overview([tail, earlier])
        let prepared = prepare(snapshot)
        XCTAssertEqual(prepared.roster.members.count, 1)
        let member = try XCTUnwrap(prepared.roster.members.first)
        XCTAssertEqual(member.evidence, .recorded)
        XCTAssertEqual(member.tokens, 25)
        XCTAssertEqual(member.turns, 1)
        XCTAssertEqual(member.session.turns.map(\.id), ["turn-retained"])
        XCTAssertEqual(member.models, ["gpt-6.1-sol"])
        XCTAssertEqual(member.accounting.evidenceDigest, prepared.bySession[earlier.id]?.evidenceDigest)
    }

    func testUndatedRecordsAreNotReportedAsIdleOrOutsidePeriod() throws {
        let undated = session("undated", title: "Undated side chat", turns: [ActivityTurn(id: "undated-native")])
        let prepared = prepare(overview([undated]))
        let member = try XCTUnwrap(prepared.roster.members.first)
        XCTAssertEqual(member.evidence, .datesUnavailable)
        XCTAssertFalse(member.hasPeriodWork)
        XCTAssertNil(member.lastActivity)
        XCTAssertNil(member.tokens)
        XCTAssertNil(member.role)
    }

    func testUnplacedUsageStaysOutOfPeriodTotalsButIsAvailableInAllHistory() throws {
        let running = ActivityTurn(id: "running-native", startedAt: now.addingTimeInterval(-600), status: "running",
            usage: TokenUsage(total: 200, provenance: .providerReported))
        let source = session("running", title: "Long side task", turns: [running])
        let snapshot = overview([source])
        let member = try XCTUnwrap(prepare(snapshot).roster.members.first)
        XCTAssertEqual(member.evidence, .unplacedUsage)
        XCTAssertNil(member.tokens)
        XCTAssertEqual(member.accounting.summary.unallocatedTokens, 200)
        XCTAssertEqual(ActivityReportPresentation.steps(member.accounting), "—")
        XCTAssertTrue(member.models.isEmpty)
        let all = try XCTUnwrap(prepare(snapshot, after: nil).roster.members.first)
        XCTAssertEqual(all.evidence, .recorded)
        XCTAssertEqual(all.tokens, 200)
    }

    func testRolesUseOnlyOwnedDateSafeCategoriesAndNeverInheritedOrConfiguredDefaults() throws {
        var ancestorTurn = turn("ancestor", total: 10)
        ancestorTurn.categories = ["tests": 100]
        let parent = session("parent", title: "Parent", turns: [ancestorTurn])
        var ownTurn = turn("research", total: 20)
        ownTurn.categories = ["research": 2]
        var child = session("child", title: "Research side chat", turns: [ancestorTurn, ownTurn])
        child.parentSessionID = parent.id
        child.goal = goal(child.id, objective: "Attached goal does not override observed role")
        let member = try XCTUnwrap(prepare(overview([parent, child])).roster.members.first { $0.id == child.id })
        XCTAssertEqual(member.role, .analyst)
        XCTAssertEqual(member.tokens, 20)
        var spanning = ownTurn
        spanning.startedAt = now.addingTimeInterval(-600)
        let partial = session("spanning", title: "Spanning task", turns: [spanning])
        let unplacedCategory = try XCTUnwrap(prepare(overview([partial])).roster.members.first)
        XCTAssertTrue(unplacedCategory.hasPeriodWork, "The response checkpoint has its own in-period date")
        XCTAssertNil(unplacedCategory.role, "A whole-turn category total must not be placed by its response date")
    }

    func testProjectProviderAndSearchFiltersPreserveDiscoveredSessionBoundaries() {
        var first = session("one", title: "Camera side chat")
        first.projectPath = "/fixtures/camera"
        var other = session("two", title: "Budget side chat")
        other.projectPath = "/fixtures/budget"
        var claude = other
        claude.id = "claude:two"; claude.nativeID = "two"; claude.provider = .claude
        let snapshot = overview([first, other, claude])
        XCTAssertEqual(prepare(snapshot, project: "/fixtures/camera").roster.members.map(\.id), [first.id])
        XCTAssertEqual(prepare(snapshot, query: "camera").roster.members.map(\.id), [first.id])
        XCTAssertEqual(prepare(snapshot, provider: "claude").roster.members.map(\.id), [claude.id])
        XCTAssertEqual(prepare(snapshot).roster.members.count, 3)
    }

    func testGoalWrapperIsNeutralUnlessARealObjectiveIsKnown() {
        var source = session("wrapper", title: "Read the Codex goal objective file at /old/objective.txt")
        XCTAssertEqual(AgentRosterEvidence.displayTitle(source), ActivityTitles.codexGoalTitle)
        source.goal = goal(source.id, objective: "Review source adapters")
        XCTAssertEqual(AgentRosterEvidence.displayTitle(source), "Review source adapters")
        source.title = "Independent side discussion"
        XCTAssertEqual(AgentRosterEvidence.displayTitle(source), "Independent side discussion")
    }

    private func prepare(_ snapshot: ActivityOverview, project: String = "all", provider: String = "all",
                         query: String = "", after: Date? = Date(timeIntervalSince1970: 1_799_999_940)) -> PreparedReportScope {
        let key = ReportScope.Key(generatedAt: now, sessionCount: snapshot.sessions.count, provider: provider,
            project: project, query: query, cutoff: after, now: now)
        return PreparedReportScope.build(overview: snapshot,
            key: .init(scope: key, chartCutoff: after ?? now.addingTimeInterval(-86_400), hourly: true, period: after == nil ? .all : .day),
            assignments: [:])
    }

    private func overview(_ sessions: [ActivitySession]) -> ActivityOverview {
        ActivityOverview(generatedAt: now, sessions: sessions,
            sources: [.init(id: "codex-activity", status: "ready", checkedAt: now, message: "Fixture only")])
    }

    private func goal(_ sessionID: String, objective: String) -> ActivityGoal {
        ActivityGoal(id: "goal-" + sessionID, sessionID: sessionID, objective: objective, status: "active",
            createdAt: now.addingTimeInterval(-86_400), updatedAt: now)
    }

    private func session(_ native: String, title: String, turns: [ActivityTurn] = []) -> ActivitySession {
        ActivitySession(id: "codex:" + native, provider: .codex, nativeID: native, title: title,
            projectPath: "/fixtures/side-chats", createdAt: now.addingTimeInterval(-86_400), updatedAt: now,
            observedAt: now, turns: turns, historyComplete: true, source: "fixture")
    }

    private func turn(_ id: String, total: Int, start: Double = -50, finish: Double = -10) -> ActivityTurn {
        let usage = TokenUsage(total: total, provenance: .providerReported)
        return ActivityTurn(id: "turn-" + id, startedAt: now.addingTimeInterval(start), completedAt: now.addingTimeInterval(finish),
            status: "completed", toolCount: 1, usage: usage, usageIsPartial: false,
            modelSteps: [.init(id: "step-" + id, timestamp: now.addingTimeInterval(finish - 1), model: "gpt-6.1-sol",
                usage: usage, usageIsPartial: false)], modelStepsComplete: true)
    }
}
