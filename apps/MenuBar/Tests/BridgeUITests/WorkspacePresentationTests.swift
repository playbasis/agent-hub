import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class WorkspacePresentationTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!

    private func session(_ id: String, provider: AgentName = .codex, native: String? = nil, parent: String? = nil, project: String = "/tmp/daily",
                         turns: [ActivityTurn] = [], goal: ActivityGoal? = nil, models: [String] = []) -> ActivitySession {
        ActivitySession(id: id, provider: provider, nativeID: native ?? id, title: "Session \(id)", projectPath: project,
                        createdAt: start.addingTimeInterval(-86_400), updatedAt: start.addingTimeInterval(60),
                        observedAt: start.addingTimeInterval(60), parentSessionID: parent, models: models, goal: goal,
                        turns: turns, historyComplete: true, source: "fixture")
    }

    private func turn(_ id: String, start a: Double, end b: Double, tokens: Int) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: start.addingTimeInterval(a), completedAt: start.addingTimeInterval(b), durationSeconds: b - a,
                     status: "completed", promptCount: 1, humanPromptCount: 1, toolCount: 2, model: "gpt-6.1-terra",
                     usage: TokenUsage(total: tokens, provenance: .providerReported))
    }

    // MARK: Scope cache

    func testCacheBuildsOptionalValuesOnceAndForgetsThemWhenInputsChange() {
        let cache = ReportScopeCache()
        let empty = ActivityOverview(generatedAt: start, sessions: [])
        var key = ReportScope.Key(generatedAt: start, sessionCount: 0, pinnedSessionID: nil, provider: "all", project: "all",
                                  query: "", cutoff: nil, now: start)
        var builds = 0
        func scope() -> ReportScope { cache.scope(for: key) { builds += 1; return ReportScope.build(overview: empty, key: key) } }

        _ = scope(); _ = scope()
        XCTAssertEqual(builds, 1, "an unchanged key reuses the scope")

        var computed = 0
        let first: Int? = cache.value("optional") { computed += 1; return nil }
        let second: Int? = cache.value("optional") { computed += 1; return 7 }
        XCTAssertNil(first)
        XCTAssertNil(second, "a stored nil is a cached answer, not a miss")
        XCTAssertEqual(computed, 1)

        key.query = "terra"
        _ = scope()
        XCTAssertEqual(builds, 2)
        let rebuilt: Int? = cache.value("optional") { computed += 1; return 7 }
        XCTAssertEqual(rebuilt, 7, "derived values are rebuilt with the scope")
        XCTAssertEqual(computed, 2)
    }

    func testSnapshotRevisionExpiresScopeAndDerivedValuesWithoutTimestampOrCountChanges() {
        let cache = ReportScopeCache()
        var overview = ActivityOverview(generatedAt: start, sessions: [session("codex:s", turns: [turn("one", start: 0, end: 1, tokens: 10)])])
        var key = ReportScope.Key(generatedAt: start, sessionCount: 1, pinnedSessionID: nil, provider: "all", project: "all", query: "", cutoff: nil, now: start)
        let initial = cache.scope(for: key) { ReportScope.build(overview: overview, key: key) }
        XCTAssertEqual(initial.allTurns.first?.usage.total, 10)
        let originalDerived: Int = cache.value("receipt") { 10 }
        XCTAssertEqual(originalDerived, 10)
        overview.sessions[0].turns[0].usage.total = 20
        key.snapshotRevision = 1
        let corrected = cache.scope(for: key) { ReportScope.build(overview: overview, key: key) }
        XCTAssertEqual(corrected.allTurns.first?.usage.total, 20)
        let correctedDerived: Int = cache.value("receipt") { 20 }
        XCTAssertEqual(correctedDerived, 20)
    }

    func testProjectAndSearchFiltersUseFullSnapshotOwnershipBeforeDroppingParents() throws {
        let shared = turn("parent-work", start: 0, end: 60, tokens: 10)
        let own = turn("child-work", start: 60, end: 120, tokens: 20)
        let parent = session("codex:p", native: "p", project: "/tmp/parent", turns: [shared])
        let child = session("codex:c", native: "c", parent: "p", project: "/tmp/worktree", turns: [shared, own])
        let overview = ActivityOverview(generatedAt: start.addingTimeInterval(600), sessions: [parent, child])
        var key = ReportScope.Key(generatedAt: overview.generatedAt, sessionCount: 2, pinnedSessionID: nil, provider: "all", project: "/tmp/worktree",
                                  query: "", cutoff: start, now: start.addingTimeInterval(600))
        let childScope = ReportScope.build(overview: overview, key: key)
        XCTAssertEqual(childScope.matchingSessions.map(\.id), [child.id])
        XCTAssertEqual(childScope.allTurns.map(\.id), [own.id])
        XCTAssertEqual(childScope.turns.map(\.id), [own.id])
        XCTAssertEqual(ActivityMetrics.knownTotal(childScope.turns.map(\.usage.total)), 20)
        XCTAssertEqual(overview.sessions[1].turns.count, 2, "native inspector/audit history remains unchanged")

        key.project = "/tmp/parent"
        let parentScope = ReportScope.build(overview: overview, key: key)
        key.project = "all"
        let global = ReportScope.build(overview: overview, key: key)
        let combined = try XCTUnwrap(ActivityMetrics.knownTotal((childScope.turns + parentScope.turns).map(\.usage.total)))
        XCTAssertEqual(combined, ActivityMetrics.knownTotal(global.turns.map(\.usage.total)))
        XCTAssertEqual(combined, 30, "project subtotals reconcile to the global known-parent total")

        key.query = child.title
        let searched = ReportScope.build(overview: overview, key: key)
        XCTAssertEqual(searched.matchingSessions.map(\.id), [child.id])
        XCTAssertEqual(searched.allTurns.map(\.id), [own.id], "searching out the parent cannot move its receipts to the child")
    }

    // MARK: Session tree

    func testSubAgentsFoldUnderParentsReferencedByEitherID() {
        let parent = session("codex:parent", native: "parent")
        let byAppID = session("codex:a", native: "a", parent: "codex:parent")
        let byNativeID = session("codex:b", native: "b", parent: "parent")
        let grandchild = session("codex:c", native: "c", parent: "a")
        let orphan = session("codex:orphan", native: "orphan", parent: "missing")
        let pinned = session("codex:pinned", native: "pinned")
        let tree = ReportScope.sessionTree([parent, byAppID, byNativeID, grandchild, orphan, pinned], pinnedID: "codex:pinned")

        XCTAssertEqual(tree.roots.map(\.id), ["codex:pinned", "codex:parent", "codex:orphan"],
                       "the pinned session leads; a sub-agent whose parent isn't in view stays visible")
        XCTAssertEqual(tree.children["codex:parent"]?.map(\.id), ["codex:a", "codex:b"])
        XCTAssertEqual(tree.children["codex:a"]?.map(\.id), ["codex:c"])
    }

    func testSessionCannotBeItsOwnParent() {
        let loop = session("codex:loop", native: "loop", parent: "loop")
        XCTAssertEqual(ReportScope.sessionTree([loop], pinnedID: nil).roots.map(\.id), ["codex:loop"])
    }

    func testTwoAndThreeSessionCyclesRemainReachableOnceWithADeterministicRoot() {
        let a = session("codex:a", native: "a", parent: "b")
        let b = session("codex:b", native: "b", parent: "a")
        let two = ReportScope.sessionTree([b, a], pinnedID: nil)
        XCTAssertEqual(two.roots.map(\.id), [a.id])
        XCTAssertEqual(reachableIDs(two), [a.id, b.id])
        let c = session("codex:c", native: "c", parent: "a")
        var second = b
        second.parentSessionID = "c"
        let three = ReportScope.sessionTree([c, second, a], pinnedID: nil)
        XCTAssertEqual(three.roots.map(\.id), [a.id])
        XCTAssertEqual(reachableIDs(three), [a.id, c.id, b.id])
        let reordered = ReportScope.sessionTree([a, c, second], pinnedID: nil)
        XCTAssertEqual(reachableIDs(reordered), reachableIDs(three))
    }

    func testDuplicateSessionIDsAppearOnceAndUseTheirNewestObservation() {
        let old = session("codex:a", native: "a")
        var new = old
        new.observedAt = old.observedAt.addingTimeInterval(1)
        new.title = "Updated session"
        let child = session("codex:b", native: "b", parent: "a")
        let tree = ReportScope.sessionTree([old, child, new, child], pinnedID: nil)
        XCTAssertEqual(tree.roots.first?.title, "Updated session")
        XCTAssertEqual(reachableIDs(tree), [old.id, child.id])
    }

    func testNativeParentAliasesStayInsideTheirProviderNamespace() {
        let codex = session("codex:p", native: "shared")
        let claude = session("claude:p", provider: .claude, native: "shared")
        let codexChild = session("codex:c", parent: "shared")
        let claudeChild = session("claude:c", provider: .claude, parent: "shared")
        let orphan = session("grok:c", provider: .grok, parent: "shared")
        let wrongProvider = session("codex:foreign", parent: "claude:p")
        let tree = ReportScope.sessionTree([claude, codexChild, orphan, codex, claudeChild, wrongProvider], pinnedID: nil)
        XCTAssertEqual(tree.children[codex.id]?.map(\.id), [codexChild.id])
        XCTAssertEqual(tree.children[claude.id]?.map(\.id), [claudeChild.id])
        XCTAssertEqual(Set(tree.roots.map(\.id)), Set([claude.id, codex.id, orphan.id, wrongProvider.id]))
        XCTAssertEqual(Set(reachableIDs(tree)).count, 6)
        XCTAssertEqual(reachableIDs(tree).count, 6, "every unique session is reachable exactly once")
    }

    func testAmbiguousNativeAliasIsAnOrphanAndExactAppIDTakesPrecedence() {
        let first = session("codex:p1", native: "duplicate")
        let second = session("codex:p2", native: "duplicate")
        let ambiguous = session("codex:ambiguous", parent: "duplicate")
        let exact = session("codex:exact", parent: first.id)
        let aliasCollision = session("codex:alias", native: first.id)
        let tree = ReportScope.sessionTree([first, second, ambiguous, exact, aliasCollision], pinnedID: nil)
        XCTAssertTrue(tree.roots.contains { $0.id == ambiguous.id })
        XCTAssertEqual(tree.children[first.id]?.map(\.id), [exact.id])
        XCTAssertNil(tree.children[aliasCollision.id])
        XCTAssertEqual(Set(reachableIDs(tree)).count, 5)
        XCTAssertEqual(reachableIDs(tree).count, 5)
    }

    private func reachableIDs(_ tree: (roots: [ActivitySession], children: [String: [ActivitySession]])) -> [String] {
        var pending = tree.roots
        var ids: [String] = []
        var cursor = 0
        while cursor < pending.count, cursor < 1_024 {
            let current = pending[cursor]
            ids.append(current.id)
            pending.append(contentsOf: tree.children[current.id] ?? [])
            cursor += 1
        }
        return ids
    }

    // MARK: Daily brief digest

    func testDigestReadsHeadlineFiguresFromTheGeneratedBrief() throws {
        let now = start.addingTimeInterval(3_600)
        let goal = ActivityGoal(id: "goal", sessionID: "codex:work", objective: "Ship the Search fixes", status: "active",
                                createdAt: start.addingTimeInterval(-86_400), updatedAt: start, providerTimeSeconds: 7_260)
        var observed = [turn("one", start: 600, end: 1_800, tokens: 1_234_567), turn("two", start: 1_800, end: 2_400, tokens: 33)]
        for index in observed.indices {
            observed[index].modelSteps = [ActivityModelStep(id: "step-\(observed[index].id)", timestamp: observed[index].completedAt,
                model: observed[index].model, effort: observed[index].effort, usage: observed[index].usage, usageIsPartial: false)]
            observed[index].modelStepsComplete = true
        }
        let work = session("codex:work", project: "/tmp/sample-web-app",
                           turns: observed,
                           goal: goal)
        let brief = try ActivityJournalBuilder.build(snapshot: ActivityOverview(generatedAt: now, sessions: [work]),
                                                     now: now, timezone: TimeZone(secondsFromGMT: 0)!)
        let digest = DailyBriefDigest.parse(brief)

        XCTAssertTrue(digest.hasFigures)
        XCTAssertEqual(digest.activeMinutes, 30)
        XCTAssertEqual(digest.tokens, 1_234_600)
        XCTAssertEqual(digest.requests, 2)
        XCTAssertEqual(digest.toolUses, 4)
        XCTAssertEqual(digest.sessions, 1)
        XCTAssertEqual(digest.stepsFinished, 2)
        XCTAssertEqual(digest.fileChanges, 0)
        XCTAssertEqual(digest.projects, [.init(name: "sample-web-app", sessions: 1, models: ["gpt-6.1-terra"])],
                       "escaped Markdown in names and models is decoded")
        XCTAssertEqual(digest.goals, [.init(objective: "Ship the Search fixes", minutes: 121)])
    }

    func testDigestAlsoReadsTheFirstBriefFormat() {
        let markdown = """
        # Bridge daily report — 2026-11-02

        ## Time and usage

        - Closed-turn elapsed time (overlaps counted once): 905 min.
        - Recorded token total: 120,450,300; 40/180 turns have usage.
        - Prompt submissions: 12; verified human submissions: unavailable.
        - Observed tool calls: 512.

        ## Project activity

        - sample\\-web\\-app: 9 sessions; models: gpt\\-6\\-astra, gpt\\-6\\.1\\-terra.

        ## Goals and carry-forward

        - \\[active\\] Make the review workflow dependable — provider time 1240 min; evidence `codex:goal:1`.
        """
        let entry = ActivityJournalEntry(id: "2026-11-02:1", date: "2026-11-02", revision: 1, generatedAt: start, previousID: nil,
                                         supersedesID: nil, timezone: "Asia/Bangkok", snapshotDigest: "x",
                                         outcomes: ["11 observed sessions across 3 project folders.",
                                                    "176 recorded turns completed; 1 goals remain open.",
                                                    "0 file-change receipts; 0 repository commits observed today."],
                                         continuingGoalIDs: [], evidenceIDs: [], markdown: markdown)
        let digest = DailyBriefDigest.parse(entry)
        XCTAssertEqual(digest.activeMinutes, 905)
        XCTAssertEqual(digest.tokens, 120_450_300)
        XCTAssertEqual(digest.requests, 12)
        XCTAssertEqual(digest.toolUses, 512)
        XCTAssertEqual(digest.sessions, 11)
        XCTAssertEqual(digest.stepsFinished, 176)
        XCTAssertEqual(digest.fileChanges, 0)
        XCTAssertEqual(digest.commits, 0)
        XCTAssertEqual(digest.projects, [.init(name: "sample-web-app", sessions: 9, models: ["gpt-6-astra", "gpt-6.1-terra"])])
        XCTAssertEqual(digest.goals, [.init(objective: "Make the review workflow dependable", minutes: 1_240)])
    }

    func testDigestOfUnrecognisedTextShowsNothingRatherThanGuessing() {
        let entry = ActivityJournalEntry(id: "2026-11-01:1", date: "2026-11-01", revision: 1, generatedAt: start, previousID: nil,
                                         supersedesID: nil, timezone: "UTC", snapshotDigest: "x", outcomes: ["A quiet day."],
                                         continuingGoalIDs: [], evidenceIDs: [], markdown: "# Brief\n\n## Summary\nNothing measured.\n")
        let digest = DailyBriefDigest.parse(entry)
        XCTAssertFalse(digest.hasFigures)
        XCTAssertTrue(digest.projects.isEmpty)
        XCTAssertTrue(digest.goals.isEmpty)
    }
}
