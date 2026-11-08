import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class SharedAccountingViewModelTests: XCTestCase {
    @MainActor
    func testHiddenWidgetDefersLargeProjectionAndReleasesDetailsWithoutLosingSmallChartCache() async {
        let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let model = BridgeViewModel(automaticallyConnect: false, activitySnapshot: nil, eagerActivityProjection: false)
        XCTAssertTrue(model.acceptRuntimeActivity(fixture(at: at, count: 3)))
        await model.awaitAccountingProjection()
        XCTAssertNil(model.activityInsight)
        XCTAssertFalse(model.isProjectingTokenSeries)
        model.observeActivity("panel", visible: true)
        await model.awaitAccountingProjection()
        XCTAssertEqual(model.activityInsight?.report.totals.observedModelSteps, 3)
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.tokensKnown, 30)
        model.observeActivity("panel", visible: false)
        XCTAssertNil(model.activityInsight, "Hidden widgets must release their large report/detail graph")
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.tokensKnown, 30, "Retain only the compact ready chart")
        XCTAssertTrue(model.acceptRuntimeActivity(fixture(at: at.addingTimeInterval(60), count: 4)))
        await model.awaitAccountingProjection()
        XCTAssertNil(model.activityInsight)
        XCTAssertEqual(model.tokenSeries.generatedAt, at)
        model.observeActivity("panel", visible: true)
        await model.awaitAccountingProjection()
        XCTAssertEqual(model.tokenSeries.generatedAt, at.addingTimeInterval(60))
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.tokensKnown, 40)
        await model.shutdown()
    }
    private func fixture(at: Date, count: Int, project: String? = "/tmp/example") -> ActivityOverview {
        let usage = TokenUsage(input: 8, output: 2, cachedInput: 4, total: 10, provenance: .providerReported)
        let steps = (0..<count).map { ActivityModelStep(id: "step-\($0)", timestamp: at.addingTimeInterval(-10 - Double($0)),
            model: "gpt-6-astra", effort: "high", usage: usage, usageIsPartial: false) }
        let turn = ActivityTurn(id: "native-one", startedAt: at.addingTimeInterval(-30), completedAt: at.addingTimeInterval(-1),
            status: "completed", toolCount: 1, modelSteps: steps, modelStepsComplete: true)
        let session = ActivitySession(id: "codex:one", provider: .codex, nativeID: "one", title: "Synthetic example", projectPath: project,
            createdAt: at.addingTimeInterval(-100), updatedAt: at, turns: [turn], historyComplete: true, source: "synthetic")
        return ActivityOverview(generatedAt: at, sessions: [session])
    }

    @MainActor
    func testToolbarAndReportUseExactlyTheAcceptedSnapshotWindowAndTotals() async {
        let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let snapshot = fixture(at: at, count: 3)
        let model = BridgeViewModel(automaticallyConnect: false, activitySnapshot: nil)
        XCTAssertTrue(model.acceptRuntimeActivity(snapshot))
        await model.awaitAccountingProjection()
        let report = ActivityAccounting.build(overview: snapshot, from: at.addingTimeInterval(-86_400), to: at)
        XCTAssertEqual(model.tokenSeries.generatedAt, report.scope.asOf)
        XCTAssertEqual(model.tokenSeries.hourlyScope, report.scope)
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.tokensKnown, report.totals.tokensKnown)
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.modelStepCount, report.totals.observedModelSteps)
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.outputKnown, report.totals.outputKnown)
        XCTAssertEqual(model.activityInsight?.asOf, report.scope.asOf)
        XCTAssertEqual(model.activityInsight?.report.totals.tokensKnown, 30)
        XCTAssertEqual(model.activityInsight?.sessionReports["codex:one"]?.totals.observedModelSteps, 3)
    }

    @MainActor
    func testSupersededProjectionCannotPublishOlderOrSameTimeIncorrectMetrics() async {
        let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let model = BridgeViewModel(automaticallyConnect: false, activitySnapshot: nil)
        XCTAssertTrue(model.acceptRuntimeActivity(fixture(at: at, count: 1)))
        XCTAssertTrue(model.acceptRuntimeActivity(fixture(at: at, count: 2)))
        XCTAssertTrue(model.acceptRuntimeActivity(fixture(at: at.addingTimeInterval(1), count: 4)))
        await model.awaitAccountingProjection()
        XCTAssertEqual(model.activityOverview.generatedAt, at.addingTimeInterval(1))
        XCTAssertEqual(model.tokenSeries.generatedAt, at.addingTimeInterval(1))
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.tokensKnown, 40)
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.modelStepCount, 4)
        XCTAssertEqual(model.activityInsight?.asOf, at.addingTimeInterval(1))
        XCTAssertEqual(model.activityInsight?.report.totals.observedModelSteps, 4)
    }

    @MainActor
    func testSavedHistoryUsesSameProjectionWithoutAProviderConnection() async {
        let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
        let model = BridgeViewModel(automaticallyConnect: false, activitySnapshot: nil)
        model.restoreSavedActivity(fixture(at: at, count: 2))
        await model.awaitAccountingProjection()
        XCTAssertTrue(model.isShowingSavedActivity)
        XCTAssertEqual(model.tokenSeries.generatedAt, at)
        XCTAssertEqual(model.tokenSeries.hourly.authoritativeTotals?.tokensKnown, 20)
        XCTAssertNil(model.runtimeClient)
    }

    func testUnattributedProjectFilterPreservesCanonicalReceiptOwnership() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = fixture(at: at, count: 2, project: nil)
        let scope = ReportScope.build(overview: snapshot, key: .init(generatedAt: at, sessionCount: 1, provider: "all",
            project: ActivityAccountingQuery.unattributedProjectID, query: "", cutoff: at.addingTimeInterval(-86_400), now: at))
        XCTAssertEqual(scope.sessions.count, 1)
        XCTAssertEqual(scope.accounting.totals.observedModelSteps, 2)
        XCTAssertEqual(scope.accounting.totals.tokensKnown, 20)
        XCTAssertEqual(scope.accounting.scope.source, .localNativeHistory)
    }

    func testHUDClockTicksReuseFrozenAccountingAcrossMidnightInsteadOfRebuildingHistory() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let insight = ActivityInsight(fixture(at: at, count: 3), now: at)
        let tick = insight.withClock(at.addingTimeInterval(86_400))
        XCTAssertEqual(tick.now, at.addingTimeInterval(86_400))
        XCTAssertEqual(tick.report.evidenceDigest, insight.report.evidenceDigest)
        XCTAssertEqual(tick.weekReport.evidenceDigest, insight.weekReport.evidenceDigest)
        XCTAssertEqual(tick.todayReport.evidenceDigest, insight.todayReport.evidenceDigest)
        XCTAssertEqual(try BridgeJSON.compactEncoder.encode(tick.daily7), try BridgeJSON.compactEncoder.encode(insight.daily7))
        XCTAssertEqual(tick.sessionReports["codex:one"]?.evidenceDigest, insight.sessionReports["codex:one"]?.evidenceDigest)
        XCTAssertEqual(tick.asOf, at)
        XCTAssertEqual(insight.snapshotDayTitle, "Today")
        XCTAssertEqual(tick.snapshotDayTitle, "Snapshot day", "A saved prior-day subtotal must not be relabeled as today's activity")
    }

    func testGoalProjectionReusesTheSameSnapshotAndInvalidatesCorrectionsRangeAndReset() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = fixture(at: at, count: 3)
        var builds = 0
        let cache = GoalAccountingCache(build: { overview, id, from, to in
            builds += 1
            return ActivityAccounting.build(overview: overview, sessionIDs: [id], from: from, to: to)
        })
        let start = at.addingTimeInterval(-86_400)
        for _ in 0..<10 {
            XCTAssertEqual(cache.value(overview: snapshot, sessionID: "codex:one", revision: 1, from: start, to: at).totals.observedModelSteps, 3)
        }
        XCTAssertEqual(builds, 1, "Ordinary timer/status redraws must not normalize history again")
        _ = cache.value(overview: fixture(at: at, count: 4), sessionID: "codex:one", revision: 2, from: start, to: at)
        XCTAssertEqual(builds, 2, "Same-time corrections must expire the cache")
        _ = cache.value(overview: snapshot, sessionID: "codex:one", revision: 2, from: start.addingTimeInterval(1), to: at)
        XCTAssertEqual(builds, 3)
        cache.reset()
        _ = cache.value(overview: snapshot, sessionID: "codex:one", revision: 2, from: start.addingTimeInterval(1), to: at)
        XCTAssertEqual(builds, 4)
    }

    func testGoalPresentationIndexesReuseTheSnapshotAndMatchCanonicalFacts() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = fixture(at: at, count: 3)
        let from = at.addingTimeInterval(-86_400)
        let cache = GoalAccountingCache(assignments: { _ in [:] })
        let first = cache.prepared(overview: snapshot, sessionID: "codex:one", revision: 1, from: from, to: at)
        XCTAssertEqual(first.modelsBySession["codex:one"], ActivityReportPresentation.models(first.report, sessionID: "codex:one"))
        XCTAssertEqual(first.effortsBySession["codex:one"], ActivityReportPresentation.efforts(first.report, sessionID: "codex:one"))
        XCTAssertEqual(first.lastActivityBySession["codex:one"], ActivityReportPresentation.lastActivity(first.report, sessionID: "codex:one"))
        XCTAssertEqual(first.mix, first.report.categoryMix)
        XCTAssertEqual(first.load, ActivityAnalytics.load(first.lanes, from: from, to: at, bucketSeconds: 900))
        for _ in 0..<20 {
            let tick = cache.prepared(overview: snapshot, sessionID: "codex:one", revision: 1, from: from, to: at)
            XCTAssertEqual(tick.report.evidenceDigest, first.report.evidenceDigest)
            XCTAssertEqual(tick.lanes, first.lanes)
        }
        XCTAssertEqual(cache.preparationCount, 1, "Clock, grouping and disclosure changes must reuse the heavy presentation")
        let corrected = cache.prepared(overview: fixture(at: at, count: 4), sessionID: "codex:one", revision: 2, from: from, to: at)
        XCTAssertEqual(corrected.report.totals.observedModelSteps, 4)
        XCTAssertEqual(cache.preparationCount, 2)
        _ = cache.prepared(overview: snapshot, sessionID: "codex:one", revision: 2, from: from.addingTimeInterval(1), to: at)
        XCTAssertEqual(cache.preparationCount, 3)
        cache.reset()
        _ = cache.prepared(overview: snapshot, sessionID: "codex:one", revision: 2, from: from, to: at)
        XCTAssertEqual(cache.preparationCount, 4, "A hidden card releases its presentation rather than retaining history indefinitely")
    }

    func testSwimlaneLayoutsAndHelpReuseRevisionRangeAndQuantizedWidth() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = fixture(at: at, count: 3)
        let from = at.addingTimeInterval(-86_400)
        let session = try XCTUnwrap(snapshot.sessions.first)
        let lane = try XCTUnwrap(ActivityAnalytics.lanes(for: session, in: snapshot.sessions, from: from, to: at).first)
        let cache = SwimlanePresentationCache()
        var descriptions = 0
        func help(_ chip: ActivityTimelineLayout.Chip) -> String { descriptions += 1; return "Recorded \(chip.segments.count)" }
        let first = cache.chips(lane: lane, revision: 1, from: from, to: at, width: 400, help: help)
        XCTAssertFalse(first.isEmpty)
        let initialDescriptions = descriptions
        for _ in 0..<20 {
            let tick = cache.chips(lane: lane, revision: 1, from: from, to: at, width: 400.001, help: help)
            XCTAssertEqual(tick.map(\.help), first.map(\.help))
        }
        XCTAssertEqual(cache.layoutBuildCount, 1)
        XCTAssertEqual(descriptions, initialDescriptions, "Tooltip and accessibility share one prepared description")
        _ = cache.chips(lane: lane, revision: 1, from: from, to: at, width: 420, help: help)
        _ = cache.chips(lane: lane, revision: 2, from: from, to: at, width: 420, help: help)
        _ = cache.chips(lane: lane, revision: 2, from: from.addingTimeInterval(1), to: at, width: 420, help: help)
        XCTAssertEqual(cache.layoutBuildCount, 4)
        XCTAssertEqual(cache.retainedLaneCount, 1)
        cache.reset()
        XCTAssertEqual(cache.retainedLaneCount, 0)
        XCTAssertEqual(cache.retainedSegmentCount, 0)
    }

    func testSwimlanePresentationCachesAreBoundedAndReleaseWhenHidden() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = fixture(at: at, count: 3)
        let from = at.addingTimeInterval(-86_400)
        let session = try XCTUnwrap(snapshot.sessions.first)
        var lane = try XCTUnwrap(ActivityAnalytics.lanes(for: session, in: snapshot.sessions, from: from, to: at).first)
        let cache = SwimlanePresentationCache(maximumLanes: 2, maximumSegments: 2)
        for index in 0..<10 {
            lane.id = "lane-\(index)"
            _ = cache.chips(lane: lane, revision: 1, from: from, to: at, width: 400) { _ in "saved evidence" }
            XCTAssertLessThanOrEqual(cache.retainedLaneCount, 2)
            XCTAssertLessThanOrEqual(cache.retainedSegmentCount, 2)
        }
        for index in 0..<700 { _ = cache.label(at.addingTimeInterval(Double(index)), template: "HH:mm") }
        XCTAssertLessThanOrEqual(cache.retainedLabelCount, 512)
        XCTAssertEqual(cache.retainedFormatterCount, 1)
        XCTAssertEqual(cache.label(Date(timeIntervalSince1970: .infinity), template: "HH:mm"), "Time unavailable")
        cache.reset()
        XCTAssertEqual(cache.retainedLabelCount, 0)
        XCTAssertEqual(cache.retainedFormatterCount, 0)
        XCTAssertEqual(cache.retainedLaneCount, 0)
    }
}
