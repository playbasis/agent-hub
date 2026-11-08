import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class CanonicalActivitySurfaceTests: XCTestCase {

    // These expectations are written for Bangkok (UTC+7) day boundaries; pin the
    // reporting zone so they hold on a Mac in any time zone.
    private var hostReportingZone = ActivityAnalytics.reportingTimeZone
    override func setUp() {
        super.setUp()
        hostReportingZone = ActivityAnalytics.reportingTimeZone
        ActivityAnalytics.reportingTimeZone = TimeZone(identifier: "Asia/Bangkok")!
    }
    override func tearDown() {
        ActivityAnalytics.reportingTimeZone = hostReportingZone
        super.tearDown()
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRosterMemberAndGroupUseCanonicalOwnershipAndTotals() throws {
        let (overview, parent, child) = family()
        let roster = TeamRosterView.Roster.build(sessions: [parent, child], overview: overview, assignments: [:], now: now, after: now.addingTimeInterval(-60))
        let own = try XCTUnwrap(roster.members.first { $0.id == child.id })
        let canonical = ActivityAccounting.build(overview: overview, sessionIDs: [child.id], from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(own.tokens, canonical.totals.tokensKnown)
        XCTAssertEqual(own.tokens, 20)
        XCTAssertEqual(own.turns, 1)
        XCTAssertEqual(own.accounting.totals.observedModelSteps, 1)
        XCTAssertEqual(own.recordedSeconds, canonical.sessionWorkSeconds[child.id])
        XCTAssertEqual(own.models, ["gpt-6.1-sol"])
        XCTAssertEqual(own.efforts, ["high"])
        XCTAssertEqual(roster.accounting.totals.tokensKnown, 30)
        XCTAssertEqual(roster.activeSeconds, roster.accounting.totals.activeSeconds)
        XCTAssertLessThan(try XCTUnwrap(roster.activeSeconds), roster.members.compactMap(\.recordedSeconds).reduce(0, +), "Overlapping member time is not added into group wall clock")
    }

    func testLegacyCrossBoundaryMemberDoesNotGuessTokensStepCountOrDefaultModel() throws {
        var legacy = record("legacy", total: 100, model: "configured-but-unmeasured", start: -120)
        legacy.modelSteps = nil; legacy.modelStepsComplete = nil
        var observed = session("codex:legacy", turns: [legacy]); observed.models = ["gpt-6-astra"]
        let overview = ActivityOverview(generatedAt: now, sessions: [observed])
        let roster = TeamRosterView.Roster.build(sessions: [observed], overview: overview, assignments: [:], now: now, after: now.addingTimeInterval(-60))
        let member = try XCTUnwrap(roster.members.first)
        XCTAssertNil(member.tokens)
        XCTAssertEqual(ActivityReportPresentation.steps(member.accounting), "—")
        XCTAssertTrue(member.models.isEmpty)
        XCTAssertEqual(member.accounting.summary.unallocatedTokens, 100)
        XCTAssertEqual(member.accounting.summary.unmeasuredTurns, 1)
    }

    func testRoleMixUsesOnlyDateSafeNativeCounterFacts() throws {
        var spanning = record("spanning", total: 20, model: "gpt-6-astra", start: -120)
        spanning.categories = ["tests": 7]; spanning.toolCount = 7
        let observed = session("codex:one", turns: [spanning])
        let overview = ActivityOverview(generatedAt: now, sessions: [observed])
        let roster = TeamRosterView.Roster.build(sessions: [observed], overview: overview, assignments: [:], now: now, after: now.addingTimeInterval(-60))
        let member = try XCTUnwrap(roster.members.first)
        XCTAssertEqual(member.tokens, 20, "The model step's own timestamp is in scope")
        XCTAssertTrue(member.mix.isEmpty, "A whole-turn tool total cannot be dated by the model step")
        XCTAssertNil(member.accounting.totals.toolCalls)
        XCTAssertEqual(member.accounting.totals.unallocatedNativeCounters.toolCalls, 7)
    }

    func testInspectorOwnWorkScopeUsesSnapshotEpochAndSeparatesProviderGoalCounter() {
        var (overview, _, child) = family()
        child.goal = ActivityGoal(id: "goal", sessionID: child.id, objective: "Fixture", status: "active", createdAt: now.addingTimeInterval(-10_000), updatedAt: now,
            providerTimeSeconds: 999, tokensUsed: 999_999)
        overview.sessions[1] = child
        let own = ActivityReportPresentation.ownWork(child.id, overview: overview)
        XCTAssertNil(own.scope.from)
        XCTAssertEqual(own.scope.to, overview.generatedAt)
        XCTAssertEqual(own.totals.tokensKnown, 20)
        XCTAssertEqual(own.totals.observedModelSteps, 1)
        XCTAssertEqual(own.totals.nativeRecords, 1)
        XCTAssertEqual(ActivityReportPresentation.models(own), ["gpt-6.1-sol"])
        XCTAssertTrue(ActivityReportPresentation.providerGoalCounter(child.goal!).hasPrefix("Provider goal counter"))
        XCTAssertFalse(ActivityReportPresentation.tokens(own).contains("999"))
    }

    func testHUDTodayAndDailySeriesUseTheSameCoreReport() {
        let (overview, _, _) = family()
        let insight = ActivityInsight(overview, now: now)
        let canonical = ActivityAccounting.build(overview: overview, from: insight.todayReport.scope.from, to: overview.generatedAt)
        XCTAssertEqual(insight.todayReport.totals.tokensKnown, canonical.totals.tokensKnown)
        XCTAssertEqual(insight.todayReport.totals.observedModelSteps, 2)
        XCTAssertEqual(insight.todayReport.totals.tokensKnown, 30)
        XCTAssertEqual(insight.daily7.compactMap(\.tokensKnown).reduce(0, +), 30)
        XCTAssertEqual(insight.daily7.map(\.modelStepCount).reduce(0, +), 2)
        XCTAssertEqual(ActivityReportPresentation.steps(insight.todayReport), "2")
    }

    func testHUDDoesNotPushCrossDayNativeRemainderIntoTodayOrDailyBars() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ActivityAnalytics.reportingTimeZone
        let midnight = calendar.startOfDay(for: now)
        var value = record("long", total: 100, model: "gpt-6-astra")
        value.startedAt = midnight.addingTimeInterval(-3_600)
        value.modelSteps = [ActivityModelStep(id: "known", timestamp: now.addingTimeInterval(-20), model: "gpt-6-astra", usage: TokenUsage(total: 20, provenance: .providerReported))]
        value.modelStepsComplete = false
        let overview = ActivityOverview(generatedAt: now, sessions: [session("codex:one", turns: [value])])
        let insight = ActivityInsight(overview, now: now)
        XCTAssertEqual(insight.todayReport.totals.tokensKnown, 20)
        XCTAssertEqual(insight.todayReport.summary.unallocatedTokens, 80)
        let weekly = insight.weekReport.series(granularity: .day)
        XCTAssertEqual(insight.weekReport.totals.tokensKnown, 100)
        XCTAssertEqual(weekly.unallocated.tokensKnown, 80)
        XCTAssertEqual(insight.daily7.compactMap(\.tokensKnown).reduce(0, +), 20)
    }

    func testInspectorMemoReusesEpochAndAcceptsSameTimestampCorrectionRevision() {
        let (overview, _, child) = family()
        let cache = InspectorAccountingCache()
        let original = cache.value(sessionID: child.id, overview: overview, revision: 0)
        var corrected = overview
        corrected.sessions[1].turns[1].usage.total = 40
        corrected.sessions[1].turns[1].modelSteps?[0].usage.total = 40
        XCTAssertEqual(cache.value(sessionID: child.id, overview: corrected, revision: 0).totals.tokensKnown, original.totals.tokensKnown)
        XCTAssertEqual(cache.value(sessionID: child.id, overview: corrected, revision: 1).totals.tokensKnown, 40)
        cache.reset()
        XCTAssertEqual(cache.value(sessionID: child.id, overview: corrected, revision: 1).totals.tokensKnown, 40)
    }

    func testInspectorFamilyDatesUseOwnEvidenceRatherThanMetadataOrInheritedParentWork() {
        let old = now.addingTimeInterval(-8 * 86_400)
        let shared = datedRecord("shared", at: now.addingTimeInterval(-1))
        let parent = session("codex:parent", turns: [shared])
        var oldChild = session("codex:old", turns: [shared, datedRecord("old-own", at: old)])
        oldChild.parentSessionID = parent.id; oldChild.createdAt = old.addingTimeInterval(-100); oldChild.updatedAt = now
        var recentChild = session("codex:recent", turns: [shared, datedRecord("recent-own", at: now.addingTimeInterval(-30))])
        recentChild.parentSessionID = parent.id; recentChild.updatedAt = old
        var inheritedOnly = session("codex:inherited", turns: [shared]); inheritedOnly.parentSessionID = parent.id
        let overview = ActivityOverview(generatedAt: now, sessions: [oldChild, inheritedOnly, parent, recentChild])
        let cache = InspectorAccountingCache()
        let prepared = cache.prepared(sessionID: parent.id, overview: overview, revision: 1)
        XCTAssertEqual(prepared.lastActivityBySession[oldChild.id], old, "A metadata touch is not new child work")
        XCTAssertEqual(prepared.lastActivityBySession[recentChild.id], now.addingTimeInterval(-30), "Old metadata must not hide recent dated work")
        XCTAssertNil(prepared.lastActivityBySession[inheritedOnly.id], "Copied parent history does not establish any child activity")
        XCTAssertEqual(prepared.descendants.map(\.id), [recentChild.id, oldChild.id, inheritedOnly.id])
        let canonical = ActivityReportPresentation.ownWork(parent.id, overview: overview)
        XCTAssertEqual(prepared.ownWork.evidenceDigest, canonical.evidenceDigest, "Adding descendant dates must not add descendant usage to the selected session")
        XCTAssertEqual(prepared.ownWork.totals.tokensKnown, 1)
        let childOwn = cache.value(sessionID: oldChild.id, overview: overview, revision: 1)
        XCTAssertEqual(childOwn.totals.tokensKnown, 1)
        XCTAssertEqual(childOwn.totals.observedModelSteps, 1)
        XCTAssertEqual(ActivityReportPresentation.lastActivity(childOwn), old)
    }

    func testInspectorChildOrderKeepsRecentEvidenceVisibleAndUndatedRowsLast() {
        let parent = session("codex:parent", turns: [])
        var children = (0..<14).map { index -> ActivitySession in
            var child = session(String(format: "codex:child-%02d", index), turns: [datedRecord("child-\(index)", at: now.addingTimeInterval(-1000 + Double(index)))])
            child.parentSessionID = parent.id
            return child
        }
        for id in ["codex:tie-b", "codex:tie-a"] {
            var child = session(id, turns: [datedRecord(id, at: now.addingTimeInterval(-2))])
            child.parentSessionID = parent.id
            children.append(child)
        }
        var undatedOld = session("codex:undated-old", turns: []); undatedOld.parentSessionID = parent.id
        var undatedNew = session("codex:undated-new", turns: []); undatedNew.parentSessionID = parent.id; undatedNew.createdAt = now.addingTimeInterval(-1)
        let overview = ActivityOverview(generatedAt: now, sessions: [parent, undatedNew] + Array(children.reversed()) + [undatedOld])
        let prepared = InspectorAccountingCache().prepared(sessionID: parent.id, overview: overview, revision: 1)
        XCTAssertEqual(Array(prepared.descendants.prefix(3).map(\.id)), ["codex:tie-a", "codex:tie-b", "codex:child-13"])
        XCTAssertFalse(prepared.descendants.prefix(12).contains { $0.id == "codex:child-00" })
        XCTAssertEqual(Array(prepared.descendants.suffix(2).map(\.id)), [undatedNew.id, undatedOld.id], "A recent creation without work evidence remains undated, not active")
        var reordered = overview; reordered.sessions.reverse()
        XCTAssertEqual(InspectorAccountingCache().prepared(sessionID: parent.id, overview: reordered, revision: 1).descendants.map(\.id), prepared.descendants.map(\.id))
    }

    func testInspectorDateIndexRejectsUndatedFutureAndSnapshotBoundaryFacts() {
        let parent = session("codex:parent", turns: [])
        var children = [
            session("codex:future", turns: [datedRecord("future", at: now.addingTimeInterval(60))]),
            session("codex:boundary", turns: [datedRecord("boundary", at: now)]),
            session("codex:undated", turns: [ActivityTurn(id: "undated", status: "completed")]),
        ]
        for index in children.indices { children[index].parentSessionID = parent.id }
        let overview = ActivityOverview(generatedAt: now, sessions: [parent] + children)
        let report = ActivityAccounting.build(overview: overview, from: nil, to: now)
        let dates = ActivityReportPresentation.lastActivityBySession(report)
        XCTAssertTrue(dates.isEmpty)
        for child in children { XCTAssertNil(ActivityReportPresentation.lastActivity(report, sessionID: child.id)) }
        let prepared = InspectorAccountingCache().prepared(sessionID: parent.id, overview: overview, revision: 1)
        XCTAssertTrue(prepared.lastActivityBySession.isEmpty)
        XCTAssertEqual(prepared.descendants.count, 3, "Undated children stay inspectable")
    }

    func testInspectorFamilyPreparationReusesSnapshotAndInvalidatesDatesAndSelection() {
        let (initial, parent, child) = family()
        var overview = initial
        let cache = InspectorAccountingCache()
        let first = cache.prepared(sessionID: parent.id, overview: overview, revision: 1)
        for _ in 0..<10 {
            XCTAssertEqual(cache.prepared(sessionID: parent.id, overview: overview, revision: 1).lastActivityBySession, first.lastActivityBySession)
            XCTAssertEqual(cache.value(sessionID: parent.id, overview: overview, revision: 1).evidenceDigest, first.ownWork.evidenceDigest)
        }
        XCTAssertEqual(cache.preparationCount, 1, "Timer ticks and child rows reuse one family normalization")
        overview.sessions[1].turns[1].completedAt = now.addingTimeInterval(-5)
        overview.sessions[1].turns[1].modelSteps?[0].timestamp = now.addingTimeInterval(-5)
        XCTAssertEqual(cache.prepared(sessionID: parent.id, overview: overview, revision: 1).lastActivityBySession, first.lastActivityBySession)
        let corrected = cache.prepared(sessionID: parent.id, overview: overview, revision: 2)
        XCTAssertEqual(corrected.lastActivityBySession[child.id], now.addingTimeInterval(-5))
        XCTAssertEqual(corrected.ownWork.evidenceDigest, first.ownWork.evidenceDigest)
        XCTAssertEqual(cache.preparationCount, 2)
        overview.generatedAt = now.addingTimeInterval(60)
        _ = cache.prepared(sessionID: parent.id, overview: overview, revision: 2)
        XCTAssertEqual(cache.preparationCount, 3)
        XCTAssertEqual(cache.prepared(sessionID: child.id, overview: overview, revision: 2).ownWork.totals.tokensKnown, 20)
        XCTAssertEqual(cache.preparationCount, 4)
        cache.reset()
        _ = cache.prepared(sessionID: child.id, overview: overview, revision: 2)
        XCTAssertEqual(cache.preparationCount, 5)
    }

    func testInspectorActivityDatesExplainEvidenceAndExposeExactReportingAndSystemTimes() throws {
        let bangkok = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = now.addingTimeInterval(-8 * 86_400)
        XCTAssertEqual(ActivityReportPresentation.recordedActivityLabel(date, now: now), "Last recorded activity 8d ago")
        XCTAssertEqual(ActivityReportPresentation.recordedActivityLabel(nil, now: now), "No dated activity")
        let missing = ActivityReportPresentation.recordedActivityHelp(nil)
        XCTAssertTrue(missing.contains("does not establish whether the agent is idle"))
        let help = ActivityReportPresentation.recordedActivityHelp(date, systemTimeZone: utc)
        XCTAssertTrue(help.contains("Asia/Bangkok"))
        XCTAssertTrue(help.contains("system time:"))
        XCTAssertTrue(help.contains(utc.identifier))
        XCTAssertTrue(help.contains("own saved evidence; not a live process check"))
        XCTAssertFalse(ActivityReportPresentation.recordedActivityHelp(date, systemTimeZone: bangkok).contains("system time:"))
    }

    func testBriefV3KeepsModelStepsNativeFinishedRecordsAndSubmissionsDistinct() {
        let entry = brief(outcomes: ["2 sessions in scope across 1 project folder.", "1,528 observed model steps; 10 native records finished; 1 goal remains open."], markdown: """
        # Daily brief
        ## Time and usage
        - Recorded time (overlaps counted once): 30 min.
        - Recorded tokens (known subtotal): 100; 2 of 3 normalized usage records reported totals.
        - Observed model steps: 1,528 (known lower bound); native records supporting this window: 10.
        - Requests sent: 3; confirmed human requests: unavailable.
        - Recorded tool uses: 4.
        """)
        let digest = DailyBriefDigest.parse(entry)
        XCTAssertEqual(digest.modelSteps, 1_528)
        XCTAssertEqual(digest.nativeRecordsFinished, 10)
        XCTAssertEqual(digest.stepsFinished, 10)
        XCTAssertEqual(digest.requests, 3)
        XCTAssertTrue(digest.modelStepsArePartial)
        XCTAssertTrue(digest.tokensArePartial)
        XCTAssertEqual(digest.sessions, 2)
    }

    func testBriefLegacyFormatsNeverInventModelStepCounts() {
        let entry = brief(outcomes: ["1 observed session across 1 project folder.", "2 recorded turns completed; 0 goals remain open."], markdown: """
        # Bridge daily report
        ## Time and usage
        - Recorded token total: 42; 1/2 turns have usage.
        - Prompt submissions: 5; verified human submissions: unavailable.
        """)
        let digest = DailyBriefDigest.parse(entry)
        XCTAssertNil(digest.modelSteps)
        XCTAssertNil(digest.nativeRecordsFinished)
        XCTAssertEqual(digest.stepsFinished, 2)
        XCTAssertEqual(digest.requests, 5)
        XCTAssertEqual(digest.tokens, 42)
        let short = DailyBriefDigest.parse(brief(outcomes: [], markdown: "## Time and usage\n- Recorded time (overlaps counted once): less than 1 min.\n"))
        XCTAssertEqual(short.activeMinutes, 0)
        XCTAssertTrue(short.activeTimeBelowMinute, "The UI can render <1m, not an invented exact zero duration")
    }

    private func family() -> (ActivityOverview, ActivitySession, ActivitySession) {
        var shared = record("parent", total: 10, model: "gpt-6-astra", start: -50)
        shared.categories = ["research": 2]
        let parent = session("codex:p", turns: [shared])
        var own = record("child", total: 20, model: "gpt-6.1-sol", start: -30)
        own.categories = ["tests": 3]
        var child = session("codex:c", turns: [shared, own]); child.parentSessionID = parent.id
        child.models = ["wrong-history-default"]
        return (ActivityOverview(generatedAt: now, sessions: [parent, child], sources: [ActivitySourceHealth(id: "codex-activity", status: "ready", checkedAt: now, message: "Fixture")]), parent, child)
    }
    private func record(_ id: String, total: Int, model: String, start: Double = -50) -> ActivityTurn {
        ActivityTurn(id: "codex:turn:\(id)", startedAt: now.addingTimeInterval(start), completedAt: now.addingTimeInterval(-10), status: "completed",
            promptCount: 1, toolCount: 1, model: model, usage: TokenUsage(total: total, provenance: .providerReported), usageIsPartial: false,
            modelSteps: [ActivityModelStep(id: "step-\(id)", timestamp: now.addingTimeInterval(-20), model: model, effort: "high", usage: TokenUsage(total: total, provenance: .providerReported), usageIsPartial: false)],
            modelStepsComplete: true)
    }
    private func datedRecord(_ id: String, at date: Date) -> ActivityTurn {
        var turn = record(id, total: 1, model: "gpt-6.1-sol")
        turn.startedAt = date.addingTimeInterval(-1); turn.completedAt = date
        turn.modelSteps?[0].timestamp = date
        return turn
    }
    private func session(_ id: String, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: .codex, nativeID: id, title: id, projectPath: "/fixture", createdAt: now.addingTimeInterval(-86_400), updatedAt: now, observedAt: now,
            turns: turns, historyComplete: true, source: "fixture")
    }
    private func brief(outcomes: [String], markdown: String) -> ActivityJournalEntry {
        ActivityJournalEntry(id: "fixture", date: "2026-11-03", revision: 1, generatedAt: now, previousID: nil, supersedesID: nil,
            timezone: "Asia/Bangkok", snapshotDigest: "fixture", outcomes: outcomes, continuingGoalIDs: [], evidenceIDs: [], markdown: markdown)
    }
}
