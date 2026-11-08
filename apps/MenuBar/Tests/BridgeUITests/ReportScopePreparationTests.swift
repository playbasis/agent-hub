import Foundation
import XCTest
import Combine
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class ReportScopePreparationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_664_000)

    private func key(_ revision: UInt64 = 0, at date: Date? = nil, period: ReportPeriod = .day) -> PreparedReportScope.Key {
        let stamp = date ?? now
        return .init(scope: .init(generatedAt: stamp, sessionCount: 0, pinnedSessionID: nil, provider: "all", project: "all", query: "",
                           cutoff: period.cutoff(at: stamp), now: stamp, snapshotRevision: revision),
              chartCutoff: period.cutoff(at: stamp) ?? stamp.addingTimeInterval(-30 * 86_400), hourly: period == .day, period: period)
    }

    private func snapshot(tokens: Int, at date: Date) -> ActivityOverview {
        let usage = TokenUsage(total: tokens, provenance: .providerReported)
        let step = ActivityModelStep(id: "stable-step", timestamp: date.addingTimeInterval(-5), model: "fixture-model", usage: usage)
        let turn = ActivityTurn(id: "stable-turn", startedAt: date.addingTimeInterval(-10), completedAt: date.addingTimeInterval(-1),
                                usage: usage, modelSteps: [step], modelStepsComplete: true)
        let session = ActivitySession(id: "stable-session", provider: .codex, nativeID: "synthetic-native", title: "Snapshot \(tokens)",
            projectPath: "/synthetic/project", createdAt: date.addingTimeInterval(-10), updatedAt: date,
            observedAt: date, turns: [turn], historyComplete: true, source: "fixture")
        return ActivityOverview(generatedAt: date, sessions: [session])
    }

    func testPreparedChartsAndCohortsUseTheSameCanonicalReport() async throws {
        var key = key()
        key.scope.sessionCount = 1
        let usage = TokenUsage(total: 42, provenance: .providerReported)
        let step = ActivityModelStep(id: "preparation-step", timestamp: now.addingTimeInterval(-5), model: "fixture-model", usage: usage)
        let turn = ActivityTurn(id: "preparation-turn", startedAt: now.addingTimeInterval(-10), completedAt: now.addingTimeInterval(-1),
                                usage: usage, modelSteps: [step], modelStepsComplete: true)
        let session = ActivitySession(id: "preparation-session", provider: .codex, nativeID: "preparation-native", title: "Synthetic",
                                      projectPath: "/synthetic/project", createdAt: now.addingTimeInterval(-10), updatedAt: now,
                                      observedAt: now, turns: [turn], historyComplete: true, source: "fixture")
        let overview = ActivityOverview(generatedAt: now, sessions: [session])
        let capturedKey = key
        let result = await Task.detached { PreparedReportScope.build(overview: overview, key: capturedKey, assignments: [:]) }.value
        let expected = result.chartAccounting.series(granularity: .hour)
        XCTAssertEqual(result.chartSeries.points.map(\.modelStepCount), expected.points.map(\.modelStepCount))
        XCTAssertEqual(result.chartSeries.points.map { $0.usage.tokensKnown }, expected.points.map { $0.usage.tokensKnown })
        XCTAssertEqual(result.bySession.count, result.scope.accounting.bySession().count)
        XCTAssertEqual(result.byProject.count, result.scope.accounting.byProject().count)
        XCTAssertEqual(result.roster.accounting.evidenceDigest, result.scope.accounting.evidenceDigest)
        XCTAssertEqual(result.chartSeries.points.compactMap(\.tokensKnown).reduce(0, +), 42)
    }

    @MainActor func testOneWorkerCoalescesPendingSnapshotsAndRejectsStaleSuccess() async {
        let gate = PreparationGate()
        let model = ReportScopePreparation { overview, key in await gate.build(overview: overview, key: key) }
        let overview = ActivityOverview(generatedAt: now)
        model.request(overview: overview, key: key(0))
        await gate.waitUntilBlocked()
        model.request(overview: overview, key: key(1))
        model.request(overview: overview, key: key(2))
        XCTAssertNil(model.prepared)
        await gate.releaseFirst()
        await model.waitUntilIdle()
        let starts = await gate.startedRevisions
        XCTAssertEqual(starts, [0, 2], "Only the latest pending snapshot is retained")
        XCTAssertEqual(model.prepared?.key.scope.snapshotRevision, 2)
        XCTAssertFalse(model.isPreparing)
        let concurrent = await gate.maximumConcurrentBuilds
        XCTAssertEqual(concurrent, 1)
    }

    @MainActor func testDeactivateDiscardsLateResultAndReopenStillHasOneWorker() async {
        let gate = PreparationGate()
        let model = ReportScopePreparation { overview, key in await gate.build(overview: overview, key: key) }
        let overview = ActivityOverview(generatedAt: now)
        model.request(overview: overview, key: key(0))
        await gate.waitUntilBlocked()
        model.deactivate()
        XCTAssertNil(model.prepared)
        XCTAssertFalse(model.isPreparing)
        model.request(overview: overview, key: key(3))
        await gate.releaseFirst()
        await model.waitUntilIdle()
        XCTAssertEqual(model.prepared?.key.scope.snapshotRevision, 3)
        let starts = await gate.startedRevisions
        XCTAssertEqual(starts, [0, 3])
        model.deactivate()
        XCTAssertNil(model.prepared)
    }

    @MainActor func testHiddenWindowNeverPublishesItsFinishedReport() async {
        let gate = PreparationGate()
        let model = ReportScopePreparation { overview, key in await gate.build(overview: overview, key: key) }
        model.request(overview: .init(generatedAt: now), key: key())
        await gate.waitUntilBlocked()
        model.deactivate()
        await gate.releaseFirst()
        await model.waitUntilIdle()
        XCTAssertNil(model.prepared)
        XCTAssertFalse(model.isPreparing)
    }

    @MainActor func testRefreshKeepsCompleteDisplayedSnapshotAndCacheUntilAtomicReplacement() async throws {
        let gate = PreparationGate(blockingRevision: 1)
        let model = ReportScopePreparation { overview, key in await gate.build(overview: overview, key: key) }
        let originalKey = key()
        let nextKey = key(1, at: now.addingTimeInterval(60))
        model.request(overview: snapshot(tokens: 10, at: now), key: originalKey)
        await model.waitUntilIdle()
        let original = try XCTUnwrap(model.prepared)
        let cache = ReportScopeCache()
        _ = cache.scope(for: original.key.scope) { original.scope }
        XCTAssertEqual(cache.value("card.tokens") { 10 }, 10)

        // SwiftUI can render the new requested key before its .task executes.
        XCTAssertEqual(model.displayed(for: nextKey)?.key, originalKey)
        model.request(overview: snapshot(tokens: 20, at: nextKey.scope.now), key: nextKey)
        await gate.waitUntilBlocked()
        let displayed = try XCTUnwrap(model.displayed(for: nextKey))
        XCTAssertTrue(model.isPreparing)
        XCTAssertEqual(displayed.scope.accounting.totals.tokensKnown, 10)
        XCTAssertEqual(displayed.overview.sessions.first?.title, "Snapshot 10")
        XCTAssertEqual(displayed.overview.generatedAt, now)
        XCTAssertEqual(displayed.key.scope.now, now, "Axis bounds/recency use the displayed clock, not the incoming one")
        XCTAssertEqual(displayed.chartSeries.scope, original.chartSeries.scope)
        XCTAssertEqual(displayed.scope.accounting.evidenceDigest, original.scope.accounting.evidenceDigest,
                       "Exports remain attached to the complete displayed snapshot")
        _ = cache.scope(for: displayed.key.scope) { displayed.scope }
        XCTAssertEqual(cache.value("card.tokens") { XCTFail("Refreshing must not clear displayed chart/KPI caches"); return -1 }, 10)

        await gate.releaseFirst()
        await model.waitUntilIdle()
        let updated = try XCTUnwrap(model.displayed(for: nextKey))
        XCTAssertEqual(updated.key, nextKey)
        XCTAssertEqual(updated.overview.sessions.first?.title, "Snapshot 20")
        XCTAssertEqual(updated.scope.accounting.totals.tokensKnown, 20)
        _ = cache.scope(for: updated.key.scope) { updated.scope }
        XCTAssertEqual(cache.value("card.tokens") { 20 }, 20, "A newly published report must never reuse the old KPI memo")
        XCTAssertFalse(model.isPreparing)
    }

    @MainActor func testRapidRefreshesRetainReadyReportAndPublishMonotonicCompleteSnapshots() async {
        let gate = PreparationGate(blockingRevision: 1)
        let model = ReportScopePreparation { overview, key in await gate.build(overview: overview, key: key) }
        model.request(overview: snapshot(tokens: 10, at: now), key: key())
        await model.waitUntilIdle()
        var published: [UInt64] = []
        let subscription = model.$prepared.compactMap { $0?.key.scope.snapshotRevision }.sink { published.append($0) }
        defer { subscription.cancel() }
        model.request(overview: snapshot(tokens: 20, at: now), key: key(1))
        await gate.waitUntilBlocked()
        model.request(overview: snapshot(tokens: 30, at: now), key: key(2))
        model.request(overview: snapshot(tokens: 40, at: now), key: key(3))
        XCTAssertEqual(model.displayed(for: key(3))?.scope.accounting.totals.tokensKnown, 10)
        await gate.releaseFirst()
        await model.waitUntilIdle()
        XCTAssertEqual(model.prepared?.key, key(3))
        XCTAssertEqual(model.prepared?.scope.accounting.totals.tokensKnown, 40)
        let starts = await gate.startedRevisions
        let maximum = await gate.maximumConcurrentBuilds
        XCTAssertEqual(starts, [0, 1, 3])
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(published, [0, 1, 3], "A newer complete same-view result must advance the UI while the latest input is still pending")
    }

    @MainActor func testFilterOrPeriodChangeNeverShowsOldNumbersUnderNewLabels() async {
        let model = ReportScopePreparation()
        model.request(overview: snapshot(tokens: 10, at: now), key: key())
        await model.waitUntilIdle()
        var changed = key(1)
        changed.scope.provider = "claude"
        XCTAssertNil(model.displayed(for: changed))
        changed = key(1); changed.scope.project = "/synthetic/other"
        XCTAssertNil(model.displayed(for: changed))
        changed = key(1); changed.scope.query = "different search"
        XCTAssertNil(model.displayed(for: changed))
        for period in [ReportPeriod.week, .month, .all] {
            XCTAssertNil(model.displayed(for: key(1, period: period)))
        }
        let week = key(period: .week), month = key(period: .month)
        XCTAssertFalse(week.hasSameSelection(as: month), "Week/month both use daily bars but are distinct selections")
        model.deactivate()
        XCTAssertNil(model.displayed(for: key()))
    }

    @MainActor func testMidnightRefreshRetainsTheOldWindowAndMetadataUntilReady() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ActivityAnalytics.reportingTimeZone
        let midnight = calendar.startOfDay(for: now)
        let before = midnight.addingTimeInterval(-30), after = midnight.addingTimeInterval(30)
        let old = key(at: before, period: .week), next = key(1, at: after, period: .week)
        XCTAssertNotEqual(old.scope.cutoff, next.scope.cutoff)
        let gate = PreparationGate(blockingRevision: 1)
        let model = ReportScopePreparation { overview, key in await gate.build(overview: overview, key: key) }
        model.request(overview: snapshot(tokens: 10, at: before), key: old)
        await model.waitUntilIdle()
        model.request(overview: snapshot(tokens: 20, at: after), key: next)
        await gate.waitUntilBlocked()
        let shown = try XCTUnwrap(model.displayed(for: next))
        XCTAssertEqual(shown.key, old)
        XCTAssertEqual(shown.chartSeries.scope.from, old.scope.cutoff)
        XCTAssertEqual(shown.overview.generatedAt, before)
        await gate.releaseFirst()
        await model.waitUntilIdle()
        XCTAssertEqual(model.displayed(for: next)?.key, next)
    }
}

extension ReportScopePreparationTests {
    @MainActor func testReturningToAnotherSelectionShowsItsKeptViewWithoutRebuilding() async {
        let gate = PreparationGate(blockingRevision: 99)
        let model = ReportScopePreparation { overview, key in await gate.build(overview: overview, key: key) }
        let overview = ActivityOverview(generatedAt: now)
        let day = key(1, period: .day)
        let week = key(1, period: .week)
        model.request(overview: overview, key: day)
        await model.waitUntilIdle()
        model.request(overview: overview, key: week)
        await model.waitUntilIdle()
        model.suspend()
        XCTAssertNotNil(model.displayed(for: day), "A kept view paints in the first frame of a page change")
        model.request(overview: overview, key: day)
        XCTAssertEqual(model.prepared?.key, day)
        XCTAssertFalse(model.isPreparing)
        let starts = await gate.startedRevisions
        XCTAssertEqual(starts.count, 2, "Going back doesn't rebuild")
        model.deactivate()
        XCTAssertNil(model.displayed(for: day))
    }
}

private actor PreparationGate {
    private(set) var startedRevisions: [UInt64] = []
    private(set) var maximumConcurrentBuilds = 0
    private var active = 0
    private var release: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private let blockingRevision: UInt64
    private var didBlock = false

    init(blockingRevision: UInt64 = 0) { self.blockingRevision = blockingRevision }

    func waitUntilBlocked() async {
        if didBlock { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func releaseFirst() { release?.resume(); release = nil }

    func build(overview: ActivityOverview, key: PreparedReportScope.Key) async -> PreparedReportScope {
        active += 1
        maximumConcurrentBuilds = max(maximumConcurrentBuilds, active)
        startedRevisions.append(key.scope.snapshotRevision)
        if key.scope.snapshotRevision == blockingRevision && !didBlock {
            didBlock = true
            await withCheckedContinuation { continuation in
                release = continuation
                startWaiter?.resume(); startWaiter = nil
            }
        }
        let value = await Task.detached { PreparedReportScope.build(overview: overview, key: key, assignments: [:]) }.value
        active -= 1
        return value
    }
}
