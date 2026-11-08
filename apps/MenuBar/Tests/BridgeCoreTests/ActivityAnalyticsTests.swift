@testable import BridgeCore
import Foundation
import XCTest

final class ActivityAnalyticsTests: XCTestCase {

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
    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func turn(_ id: String, _ start: String?, _ end: String? = nil, tokens: Int? = nil, output: Int? = nil, model: String? = nil, categories: [String: Int] = [:]) -> ActivityTurn {
        ActivityTurn(
            id: id,
            startedAt: start.map(date),
            completedAt: end.map(date),
            durationSeconds: { if let s = start.map(date), let e = end.map(date) { return e.timeIntervalSince(s) } else { return nil } }(),
            status: "completed",
            model: model,
            usage: TokenUsage(output: output, total: tokens),
            categories: categories
        )
    }

    func testDailySeriesKeepsEmptyDaysAndCountsOverlapOnce() {
        let turns = [
            turn("a", "2026-11-01T10:00:00Z", "2026-11-01T11:00:00Z", tokens: 100, output: 10),
            turn("b", "2026-11-01T10:30:00Z", "2026-11-01T11:30:00Z", tokens: 50),
            turn("c", "2026-11-03T09:00:00Z", nil, tokens: nil),
        ]
        let points = ActivityAnalytics.daily(turns, days: 3, endingAt: date("2026-11-03T12:00:00Z"), timeZone: utc)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].turns, 2)
        XCTAssertEqual(points[0].tokens, 150)
        XCTAssertEqual(points[0].outputTokens, 10)
        XCTAssertEqual(points[0].activeSeconds, 5_400, accuracy: 0.1, "overlapping hours count once")
        XCTAssertEqual(points[1].turns, 0)
        XCTAssertEqual(points[2].turns, 1)
        XCTAssertEqual(points[2].activeSeconds, 0, "an open interval is never extended")
    }

    func testRollingWindowIncludesBothPartialEdgeDaysAndReconcilesDailyTotals() {
        let start = date("2026-10-26T15:30:00Z"), end = date("2026-11-02T15:30:00Z")
        let turns = [
            turn("before", "2026-10-26T15:29:59Z", tokens: 9_999),
            turn("first", "2026-10-26T15:30:00Z", tokens: 10, output: 2),
            turn("middle", "2026-10-30T00:00:00Z", tokens: 20, output: 3),
            turn("last", "2026-11-02T15:29:59Z", tokens: 30, output: 5),
            turn("at-end", "2026-11-02T15:30:00Z", tokens: 9_999),
        ]
        let points = ActivityAnalytics.daily(turns, from: start, to: end, timeZone: utc)
        let period = ActivityAnalytics.period(turns, sessions: 1, from: start, to: end)
        XCTAssertEqual(points.count, 8, "a rolling seven-day window spans eight calendar dates")
        XCTAssertEqual(points.reduce(0) { $0 + $1.turns }, period.turns)
        XCTAssertEqual(ActivityMetrics.knownTotal(points.map(\.measuredTokens)), period.tokens)
        XCTAssertEqual(ActivityMetrics.knownTotal(points.map(\.measuredOutputTokens)), period.outputTokens)
        XCTAssertEqual(points.first?.measuredTokens, 10)
        XCTAssertEqual(points.last?.measuredTokens, 30)
        let clipped = ActivityAnalytics.daily(turns, days: 8, endingAt: end, startingAt: start, timeZone: utc)
        XCTAssertEqual(clipped, points)
    }

    func testSharedScopeUsesExclusiveEndAndDoesNotDateUnknownReceipts() {
        let start = date("2026-11-01T00:00:00Z"), end = date("2026-11-02T00:00:00Z")
        let turns = [turn("before", "2026-10-31T23:59:59Z", tokens: 90),
                     turn("start", "2026-11-01T00:00:00Z", tokens: 10),
                     turn("end", "2026-11-02T00:00:00Z", tokens: 90),
                     turn("undated", nil, tokens: 90)]
        let scoped = ActivityAnalytics.scopedTurns(turns + [turns[1]], from: start, to: end)
        XCTAssertEqual(scoped.map(\.id), ["start"])
        XCTAssertEqual(ActivityMetrics.knownTotal(scoped.map(\.usage.total)),
                       ActivityAnalytics.period(turns, sessions: 1, from: start, to: end).tokens)
        XCTAssertFalse(ActivityAnalytics.scopedTurns(turns, from: nil, to: end).contains { $0.id == "undated" })
        XCTAssertTrue(ActivityAnalytics.scopedTurns(turns, from: nil, to: nil).contains { $0.id == "undated" })
    }

    func testExactDailyWindowClipsIntervalsAndHonorsBangkokMidnight() {
        let start = date("2026-11-01T16:30:00Z"), end = date("2026-11-02T17:00:00Z")
        let turns = [
            turn("crossing", "2026-11-01T16:00:00Z", "2026-11-01T18:00:00Z", tokens: 10),
            turn("boundary", "2026-11-02T17:00:00Z", tokens: 100),
        ]
        let points = ActivityAnalytics.daily(turns, from: start, to: end)
        XCTAssertEqual(points.map(\.day), [date("2026-10-31T17:00:00Z"), date("2026-11-01T17:00:00Z")])
        XCTAssertEqual(points.map(\.activeSeconds), [1_800, 3_600])
        XCTAssertEqual(points.reduce(0) { $0 + $1.activeSeconds }, ActivityAnalytics.period(turns, sessions: 1, from: start, to: end).activeSeconds)
        XCTAssertEqual(points.reduce(0) { $0 + $1.turns }, 1)
        XCTAssertTrue(ActivityAnalytics.daily(turns, from: end, to: start).isEmpty)
    }

    func testProviderDailyStacksReconcileAfterDeduplicationWithoutCacheDoubleCounting() {
        let start = date("2026-10-30T00:00:00Z"), end = date("2026-11-02T12:00:00Z")
        var bounded = turn("claude", "2026-10-31T09:00:00Z", tokens: 10, output: 2)
        bounded.usageIsPartial = true
        bounded.usage.input = 3
        bounded.usage.cachedInput = 5
        bounded.usage.reasoning = 1
        let codex = turn("codex", "2026-11-02T09:00:00Z", tokens: 20, output: 4)
        let unknown = turn("unknown", "2026-10-30T09:00:00Z")
        let zero = turn("zero", "2026-11-01T09:00:00Z", tokens: 0)
        let breakdown = ActivityAnalytics.dailyTokenBreakdown([bounded, bounded, codex, unknown, zero],
            providers: ["claude": .claude, "codex": .codex, "unknown": .codex, "zero": .claude], from: start, to: end, timeZone: utc)
        XCTAssertEqual(breakdown.period.turns, 4)
        XCTAssertEqual(breakdown.period.tokens, 30, "cache and reasoning subsets are not added to the authoritative total")
        XCTAssertEqual(breakdown.period.tokenReceipts, 3)
        XCTAssertEqual(breakdown.rows.count, 8, "each observed provider retains every date coordinate")
        XCTAssertEqual(ActivityMetrics.knownTotal(breakdown.rows.map(\.tokens)), breakdown.period.tokens)
        XCTAssertEqual(ActivityMetrics.knownTotal(breakdown.days.map(\.measuredTokens)), breakdown.period.tokens)
        XCTAssertEqual(breakdown.rows.first { $0.provider == .codex && $0.day == start }?.tokenReceipts, 0)
        XCTAssertNil(breakdown.rows.first { $0.provider == .codex && $0.day == start }?.tokens)
        let zeroRow = breakdown.rows.first { $0.provider == .claude && $0.day == date("2026-11-01T00:00:00Z") }
        XCTAssertEqual(zeroRow?.tokens, 0)
        XCTAssertEqual(zeroRow?.tokenCoverage, 1)
        XCTAssertTrue(breakdown.rows.contains { $0.partialTokenReceipts == 1 && $0.isPartial })
        XCTAssertEqual(breakdown.days.reduce(0) { $0 + $1.partialTokenReceipts }, 1)
    }

    func testProviderDailyUsageKeepsUnattributedEvidenceAndSignalsOverflow() {
        let start = date("2026-11-02T00:00:00Z"), end = date("2026-11-02T12:00:00Z")
        let values = [turn("one", "2026-11-02T08:00:00Z", tokens: Int.max), turn("two", "2026-11-02T09:00:00Z", tokens: 1)]
        let breakdown = ActivityAnalytics.dailyTokenBreakdown(values, providers: [:], from: start, to: end, timeZone: utc)
        XCTAssertEqual(breakdown.rows.count, 1)
        XCTAssertEqual(breakdown.rows.first?.provider, AgentName.none)
        XCTAssertEqual(breakdown.period.tokenReceipts, 2)
        XCTAssertNil(breakdown.period.tokens)
        XCTAssertNil(breakdown.rows.first?.tokens, "overflow must not silently drop the receipt that failed addition")
        XCTAssertNil(breakdown.days.first?.measuredTokens)
        XCTAssertTrue(breakdown.days.first?.tokenOverflow == true)
    }

    func testSparseTrendRetainsIsolatedReceiptsAndDistinguishesMissingFromZero() {
        let points = ActivityAnalytics.trend([nil, 10, nil, 0, 5, .nan, -.infinity, -1, 20])
        XCTAssertEqual(points.map(\.index), Array(0 ..< 9))
        XCTAssertEqual(points.compactMap(\.value), [10, 0, 5, 20])
        XCTAssertEqual(points[3].segment, points[4].segment, "adjacent measured points may connect")
        XCTAssertNotEqual(points[1].segment, points[3].segment, "a missing day never gets interpolated")
        XCTAssertNotEqual(points[4].segment, points[8].segment)
        XCTAssertEqual(points[3].value, 0, "a reported zero is not a missing marker")
        XCTAssertEqual(points.filter { $0.value == nil }.count, 5)
    }

    func testHeatmapHasEveryCellAndBucketsByHour() {
        let turns = [
            turn("a", "2026-11-02T08:15:00Z", tokens: 5),
            turn("b", "2026-11-02T08:45:00Z", tokens: 7),
            turn("c", "2026-11-01T23:59:00Z"),
        ]
        let cells = ActivityAnalytics.heatmap(turns, days: 2, endingAt: date("2026-11-02T20:00:00Z"), timeZone: utc)
        XCTAssertEqual(cells.count, 48)
        let morning = cells.first { $0.dayIndex == 1 && $0.hour == 8 }
        XCTAssertEqual(morning?.turns, 2)
        XCTAssertEqual(morning?.tokens, 12)
        XCTAssertEqual(cells.first { $0.dayIndex == 0 && $0.hour == 23 }?.turns, 1)
    }

    func testCategoryAndModelMixIgnoreUnknowns() {
        let turns = [
            turn("a", "2026-11-02T08:00:00Z", tokens: 10, model: "gpt-6-astra", categories: ["tests": 2, "other tools": 1]),
            turn("b", "2026-11-02T09:00:00Z", tokens: 30, model: "gpt-6-astra", categories: ["tests": 1, "other": 2]),
            turn("c", "2026-11-02T10:00:00Z", tokens: 99),
        ]
        let categories = ActivityAnalytics.categoryMix(turns)
        XCTAssertEqual(categories.first, .init(name: "Tests", value: 3))
        XCTAssertEqual(categories.last, .init(name: "Other", value: 3), "other and other tools merge and trail")
        let models = ActivityAnalytics.modelMix(turns, providers: ["a": .codex, "b": .codex])
        XCTAssertEqual(models, [.init(model: "gpt-6-astra", provider: .codex, turns: 2, tokens: 40, tokenReceipts: 2)])
    }

    private func session(_ id: String, title: String, parent: String? = nil, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: "codex:\(id)", provider: .codex, nativeID: id, title: title, createdAt: date("2026-10-01T00:00:00Z"), updatedAt: date("2026-11-02T12:00:00Z"), parentSessionID: parent, turns: turns, source: "test")
    }

    func testLanesClipIntervalsAndKeepOpenStartsSeparate() {
        let parent = session("p", title: "Goal", turns: [
            turn("p1", "2026-11-02T08:00:00Z", "2026-11-02T10:00:00Z"),
        ])
        let child = session("c", title: "Child", parent: "p", turns: [
            turn("c1", "2026-11-02T09:00:00Z", "2026-11-02T09:30:00Z"),
            turn("c2", "2026-11-02T09:45:00Z"),
        ])
        let idle = session("i", title: "Old", parent: "p", turns: [
            turn("i1", "2026-10-01T09:00:00Z", "2026-10-01T09:30:00Z"),
        ])
        let lanes = ActivityAnalytics.lanes(for: parent, in: [parent, child, idle], from: date("2026-11-02T09:00:00Z"), to: date("2026-11-02T12:00:00Z"))
        XCTAssertEqual(lanes.map(\.title), ["Goal", "Child"], "lanes with nothing in range are dropped")
        XCTAssertEqual(lanes[0].intervals.first?.start, date("2026-11-02T09:00:00Z"), "clipped to the window")
        XCTAssertEqual(lanes[1].openStarts, [date("2026-11-02T09:45:00Z")])
        XCTAssertEqual(lanes[1].busySeconds, 1_800, accuracy: 0.1)

        let curve = ActivityAnalytics.concurrency(lanes, from: date("2026-11-02T09:00:00Z"), to: date("2026-11-02T10:00:00Z"), buckets: 4)
        XCTAssertEqual(curve.map(\.agents), [2, 1, 0])
        XCTAssertEqual(curve.map(\.time), [date("2026-11-02T09:00:00Z"), date("2026-11-02T09:30:00Z"), date("2026-11-02T10:00:00Z")])
    }

    func testRunwayProjectsFromAveragePaceAndRefusesThinEvidence() {
        let now = date("2026-11-02T12:00:00Z")
        // Weekly window opened 2 days ago, 40% used: pace exhausts in 3 days, before reset in 5.
        let fast = QuotaWindow(id: "w", label: "Weekly", usedRatio: 0.4, resetAt: now.addingTimeInterval(5 * 86_400), durationMinutes: 10_080)
        guard case let .exhausts(when) = ActivityAnalytics.runway(fast, now: now) else { return XCTFail("expected exhaustion") }
        XCTAssertEqual(when.timeIntervalSince(now), 3 * 86_400, accuracy: 1)

        let slow = QuotaWindow(id: "w", label: "Weekly", usedRatio: 0.1, resetAt: now.addingTimeInterval(5 * 86_400), durationMinutes: 10_080)
        XCTAssertEqual(ActivityAnalytics.runway(slow, now: now), .lastsUntilReset(now.addingTimeInterval(5 * 86_400)))

        let noReset = QuotaWindow(id: "w", label: "5-hour", usedRatio: 0.5, durationMinutes: 300)
        XCTAssertEqual(ActivityAnalytics.runway(noReset, now: now), .unknown)
    }

    func testTokenDeltaRequiresComparableReceiptCoverage() {
        let full = (0 ..< 10).map { turn("f\($0)", "2026-11-02T0\($0 % 10):00:00Z", tokens: 10) }
        let sparse = (0 ..< 10).map { turn("s\($0)", "2026-11-01T0\($0 % 10):00:00Z", tokens: $0 < 2 ? 10 : nil) }
        let current = ActivityAnalytics.period(full, sessions: 1, from: nil, to: nil)
        let wellMeasured = ActivityAnalytics.period(full, sessions: 1, from: nil, to: nil)
        let poorlyMeasured = ActivityAnalytics.period(sparse, sessions: 1, from: nil, to: nil)
        XCTAssertEqual(current.tokenCoverage, 1)
        XCTAssertTrue(ActivityAnalytics.comparableTokenDelta(current, wellMeasured))
        XCTAssertFalse(ActivityAnalytics.comparableTokenDelta(current, poorlyMeasured), "20% vs 100% coverage is not comparable")
        XCTAssertFalse(ActivityAnalytics.comparableTokenDelta(current, nil))
    }

    func testLaneSegmentsCarryCategoriesAndLoadIsExact() {
        let parent = session("p", title: "Goal", turns: [
            turn("p1", "2026-11-02T09:00:00Z", "2026-11-02T09:30:00Z", categories: ["tests": 3, "execution": 1]),
        ])
        let child = session("c", title: "Child", parent: "p", turns: [
            turn("c1", "2026-11-02T09:15:00Z", "2026-11-02T09:45:00Z", categories: ["research": 2]),
            turn("c2", "2026-11-02T09:20:00Z", "2026-11-02T09:25:00Z"),
        ])
        let from = date("2026-11-02T09:00:00Z"), to = date("2026-11-02T10:00:00Z")
        let lanes = ActivityAnalytics.lanes(for: parent, in: [parent, child], from: from, to: to)
        XCTAssertEqual(lanes[0].segments.map(\.category), ["Tests"])
        XCTAssertEqual(lanes[0].segments.first?.toolCalls, 4)
        XCTAssertEqual(lanes[1].segments.count, 2, "segments keep each turn even when intervals merge")
        XCTAssertEqual(lanes[1].intervals.count, 1)
        XCTAssertEqual(lanes[1].turnCount, 2)

        let load = ActivityAnalytics.load(lanes, from: from, to: to, bucketSeconds: 900)
        XCTAssertEqual(load.count, 4)
        // 09:00-09:15 parent only; 09:15-09:30 both; 09:30-09:45 child only; then idle.
        XCTAssertEqual(load.map(\.meanAgents), [1, 2, 1, 0])
    }

    func testDeltaNeedsAKnownPositiveBase() {
        XCTAssertEqual(ActivityAnalytics.delta(150, 100)!, 0.5, accuracy: 1e-9)
        XCTAssertNil(ActivityAnalytics.delta(10, 0))
        XCTAssertNil(ActivityAnalytics.delta(nil, 10))
        XCTAssertNil(ActivityAnalytics.delta(.nan, 10))
        XCTAssertNil(ActivityAnalytics.delta(10, .infinity))
        XCTAssertNil(ActivityAnalytics.delta(-1, 10))
    }

    func testDailyAndHeatmapRespectExactEndAndExposeMissingMeasurements() {
        let end = date("2026-11-02T12:00:00Z")
        let turns = [
            turn("known-zero", "2026-11-01T09:00:00Z", "2026-11-01T09:00:00Z", tokens: 0, output: 0),
            turn("unknown", "2026-11-02T10:00:00Z"),
            turn("crossing", "2026-11-02T11:00:00Z", "2026-11-02T13:00:00Z", tokens: 5),
            turn("boundary", "2026-11-02T12:00:00Z", tokens: 100),
            turn("future", "2026-11-02T14:00:00Z", tokens: 200),
        ]
        let points = ActivityAnalytics.daily(turns, days: 3, endingAt: end, timeZone: utc)
        XCTAssertNil(points[0].measuredTokens)
        XCTAssertNil(points[0].measuredActiveSeconds)
        XCTAssertEqual(points[1].measuredTokens, 0)
        XCTAssertEqual(points[1].measuredOutputTokens, 0)
        XCTAssertEqual(points[1].measuredActiveSeconds, 0)
        XCTAssertEqual(points[2].turns, 1, "tokens/turns follow their receipt timestamp, never a future completion")
        XCTAssertNil(points[2].measuredTokens)
        XCTAssertEqual(points[2].measuredActiveSeconds, 3_600, "known closed intervals can overlap a cutoff without completing inside it")
        let cells = ActivityAnalytics.heatmap(turns, days: 2, endingAt: end, timeZone: utc)
        XCTAssertEqual(cells.reduce(0) { $0 + $1.turns }, 2)
        XCTAssertEqual(cells.first { $0.dayIndex == 0 && $0.hour == 9 }?.measuredTokens, 0)
        XCTAssertNil(cells.first { $0.dayIndex == 1 && $0.hour == 10 }?.measuredTokens)
        XCTAssertEqual(cells.first { $0.dayIndex == 1 && $0.hour == 12 }?.turns, 0)
    }

    func testPeriodClipsTheSameIntervalEvidenceForActiveAndAgentTime() {
        let turns = [
            turn("cross-start", "2026-11-01T23:00:00Z", "2026-11-02T01:00:00Z", tokens: 20),
            turn("cross-end", "2026-11-02T23:00:00Z", "2026-11-03T01:00:00Z", tokens: 40),
            turn("parallel", "2026-11-02T00:30:00Z", "2026-11-02T01:00:00Z", tokens: 30),
            ActivityTurn(id: "duration-only", durationSeconds: 100_000),
        ]
        let value = ActivityAnalytics.period(turns, sessions: 3, from: date("2026-11-02T00:00:00Z"), to: date("2026-11-03T00:00:00Z"))
        XCTAssertEqual(value.turns, 2)
        XCTAssertEqual(value.tokens, 50, "token receipts belong to completion, not proportionally invented across days")
        XCTAssertEqual(value.activeSeconds, 7_200)
        XCTAssertEqual(value.agentSeconds, 9_000)
        XCTAssertEqual(value.agentSeconds! / value.activeSeconds!, 1.25)
        let invalid = ActivityAnalytics.period(turns, sessions: 3, from: date("2026-11-03T00:00:00Z"), to: date("2026-11-02T00:00:00Z"))
        XCTAssertNil(invalid.activeSeconds)
        XCTAssertNil(invalid.agentSeconds)
        XCTAssertEqual(invalid.turns, 0)
    }

    func testGoalDescendantsAvoidCyclesProviderCollisionsAndInheritedTurns() {
        let inherited = turn("root-turn", "2026-11-02T08:00:00Z", "2026-11-02T09:00:00Z")
        let root = session("root", title: "Root", parent: "grandchild", turns: [inherited])
        let child = session("child", title: "Child", parent: root.id, turns: [inherited])
        let grandchild = session("grandchild", title: "Grandchild", parent: "child", turns: [
            inherited, turn("own", "2026-11-02T08:15:00Z", "2026-11-02T08:45:00Z"),
        ])
        var otherProvider = session("foreign", title: "Foreign", parent: "root", turns: [inherited])
        otherProvider.provider = .claude
        let family = [grandchild, child, root, child, otherProvider]
        XCTAssertEqual(ActivityAnalytics.descendants(of: root, in: family).map(\.id), [child.id, grandchild.id])
        let lanes = ActivityAnalytics.lanes(for: root, in: family, from: date("2026-11-02T08:00:00Z"), to: date("2026-11-02T09:00:00Z"))
        XCTAssertEqual(lanes.map(\.id), [root.id, grandchild.id], "fork-only inherited history does not fabricate child work")
        XCTAssertEqual(lanes.map(\.busySeconds), [3_600, 1_800])
        XCTAssertEqual(ActivityAnalytics.concurrency(lanes, from: date("2026-11-02T08:00:00Z"), to: date("2026-11-02T09:00:00Z")).map(\.agents).max(), 2)
    }

    func testLanesUnionOneAgentAndDiscardMalformedAndBoundaryIntervals() {
        var root = session("root", title: "Root", turns: [
            turn("a", "2026-11-02T08:00:00Z", "2026-11-02T09:00:00Z", model: "new-model"),
            turn("b", "2026-11-02T08:30:00Z", "2026-11-02T09:30:00Z", model: "newest-model"),
            turn("invalid", "2026-11-02T09:40:00Z", "2026-11-02T09:20:00Z"),
            turn("ending-at-start", "2026-11-02T07:00:00Z", "2026-11-02T08:00:00Z"),
            turn("open-at-end", "2026-11-02T10:00:00Z"),
        ])
        root.models = ["new-model", "newest-model", "z-old-model"]
        let lanes = ActivityAnalytics.lanes(for: root, in: [root], from: date("2026-11-02T08:00:00Z"), to: date("2026-11-02T10:00:00Z"))
        XCTAssertEqual(lanes[0].intervals.count, 1)
        XCTAssertEqual(lanes[0].busySeconds, 5_400)
        XCTAssertTrue(lanes[0].openStarts.isEmpty)
        XCTAssertEqual(lanes[0].model, "newest-model", "models are observed chronologically, not alphabetically")
        XCTAssertTrue(ActivityAnalytics.lanes(for: root, in: [root], from: date("2026-11-02T10:00:00Z"), to: date("2026-11-02T08:00:00Z")).isEmpty)
    }

    func testExactConcurrencyRetainsShortBurstsAndDoesNotCountDuplicateLanes() {
        let root = session("root", title: "Root", turns: [turn("brief", "2026-11-02T08:00:01Z", "2026-11-02T08:00:02Z")])
        let start = date("2026-11-02T08:00:00Z"), end = date("2026-11-02T09:00:00Z")
        let lanes = ActivityAnalytics.lanes(for: root, in: [root], from: start, to: end)
        let points = ActivityAnalytics.concurrency(lanes + lanes, from: start, to: end, buckets: 1)
        XCTAssertEqual(points.map(\.agents), [0, 1, 0, 0])
        XCTAssertEqual(points.map(\.time), [start, start.addingTimeInterval(1), start.addingTimeInterval(2), end])
        XCTAssertEqual(points.map(\.agents).max(), 1)
    }

    func testModelProviderKeysCategoryNormalizationAndDuplicateCorrections() {
        let a = turn("a", "2026-11-02T08:00:00Z", tokens: 5, model: " shared ", categories: [" TESTS ": 2])
        let corrected = turn("a", "2026-11-02T08:00:00Z", tokens: 10, model: "shared", categories: ["tests": 2])
        let b = turn("b", "2026-11-02T08:00:00Z", model: "shared", categories: ["tests": 1, " ": 2])
        let models = ActivityAnalytics.modelMix([a, corrected, b], providers: ["a": .codex, "b": .claude])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(Set(models.map(\.id)).count, 2)
        XCTAssertEqual(models.first { $0.provider == .codex }?.measuredTokens, 10)
        XCTAssertNil(models.first { $0.provider == .claude }?.measuredTokens)
        XCTAssertEqual(ActivityAnalytics.categoryMix([a, corrected, b]), [.init(name: "Tests", value: 3), .init(name: "Other", value: 2)])
        XCTAssertEqual(ActivityAnalytics.period([a, corrected], sessions: 1, from: nil, to: nil).tokens, 10)
    }

    func testTokenComparisonRejectsEqualSparseAndExplicitlyPartialEvidence() {
        let sparse = [turn("a", nil, tokens: 10), turn("b", nil)]
        let partial = ActivityAnalytics.period(sparse, sessions: 1, from: nil, to: nil)
        XCTAssertFalse(ActivityAnalytics.comparableTokenDelta(partial, partial))
        var bounded = turn("a", nil, tokens: 10, output: 5)
        bounded.usageIsPartial = true
        let subtotal = ActivityAnalytics.period([bounded], sessions: 1, from: nil, to: nil)
        XCTAssertEqual(subtotal.tokens, 10)
        XCTAssertFalse(ActivityAnalytics.comparableTokenDelta(subtotal, subtotal))
        XCTAssertFalse(ActivityAnalytics.comparableOutputTokenDelta(subtotal, subtotal))
        let totalOnly = ActivityAnalytics.period([turn("a", nil, tokens: 10)], sessions: 1, from: nil, to: nil)
        XCTAssertTrue(ActivityAnalytics.comparableTokenDelta(totalOnly, totalOnly))
        XCTAssertFalse(ActivityAnalytics.comparableOutputTokenDelta(totalOnly, totalOnly))
        let outputOnly = ActivityAnalytics.period([turn("a", nil, output: 5)], sessions: 1, from: nil, to: nil)
        XCTAssertFalse(ActivityAnalytics.comparableTokenDelta(outputOnly, outputOnly))
        XCTAssertTrue(ActivityAnalytics.comparableOutputTokenDelta(outputOnly, outputOnly))
    }

    func testProviderAttributionMatchesDeterministicMergeTieBreak() {
        var a = session("a", title: "A", turns: [turn("shared", nil, model: "claude-model")])
        a.provider = .claude
        var b = session("b", title: "B", turns: [turn("shared", nil, model: "codex-model")])
        a.observedAt = date("2026-11-02T00:00:00Z")
        b.observedAt = a.observedAt
        XCTAssertEqual(ActivityAnalytics.providers([b, a]), ActivityAnalytics.providers([a, b]))
        XCTAssertEqual(ActivityAnalytics.providers([b, a])["shared"], .codex)
        XCTAssertEqual(ActivityMetrics.uniqueTurns([b, a]).first?.model, "codex-model")
    }

    func testNegativeAndOverflowingMetricsDoNotCrashOrInventMeasurements() {
        let invalid = turn("negative", "2026-11-02T09:00:00Z", tokens: -1, output: -1)
        let unknown = ActivityAnalytics.period([invalid], sessions: 1, from: nil, to: nil)
        XCTAssertNil(unknown.tokens)
        XCTAssertEqual(unknown.tokenReceipts, 0)
        let huge = [turn("a", "2026-11-02T09:00:00Z", tokens: Int.max), turn("b", "2026-11-02T09:30:00Z", tokens: 1)]
        XCTAssertNil(ActivityAnalytics.period(huge, sessions: 1, from: nil, to: nil).tokens)
        let points = ActivityAnalytics.daily(huge, days: 1, endingAt: date("2026-11-02T12:00:00Z"), timeZone: utc)
        XCTAssertEqual(points[0].tokens, Int.max)
        XCTAssertNil(points[0].measuredTokens)
    }

    func testSegmentCategoriesNormalizeBeforeRankingAndToolMeasurementsKeepUnknowns() {
        var reported = turn("reported", "2026-11-02T09:10:00Z", "2026-11-02T09:11:00Z", categories: ["tests": 1])
        reported.toolCount = 12
        var zero = turn("zero", "2026-11-02T09:20:00Z", "2026-11-02T09:21:00Z")
        zero.toolCount = 0
        let root = session("root", title: "Goal", turns: [
            turn("normalized", "2026-11-02T09:00:00Z", "2026-11-02T09:01:00Z", categories: [" TESTS ": 2, "tests": 2, "research": 3]),
            reported, zero,
            turn("unknown", "2026-11-02T09:30:00Z", "2026-11-02T09:31:00Z"),
            turn("overflow", "2026-11-02T09:40:00Z", "2026-11-02T09:41:00Z", categories: ["tests": Int.max, "research": 1]),
        ])
        let segments = ActivityAnalytics.lanes(for: root, in: [root], from: date("2026-11-02T09:00:00Z"), to: date("2026-11-02T10:00:00Z"))[0].segments
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.turnID, $0) })
        XCTAssertEqual(byID["normalized"]?.category, "Tests", "spelling variants describe one category")
        XCTAssertEqual(byID["normalized"]?.measuredToolCalls, 7)
        XCTAssertEqual(byID["reported"]?.measuredToolCalls, 12, "reported count includes uncategorized calls")
        XCTAssertEqual(byID["zero"]?.measuredToolCalls, 0)
        XCTAssertNil(byID["unknown"]?.measuredToolCalls)
        XCTAssertEqual(byID["unknown"]?.toolCalls, 0, "legacy coordinate does not imply a measurement")
        XCTAssertNil(byID["overflow"]?.measuredToolCalls)
        XCTAssertEqual(byID["overflow"]?.toolCalls, Int.max, "enormous category counts cannot trap")
    }

    func testLoadMergesAgentSnapshotsAndWeightsPartialFinalBucketExactly() {
        let root = session("root", title: "Goal", turns: [turn("a", "2026-11-02T09:10:00Z", "2026-11-02T09:35:00Z")])
        let child = session("child", title: "Child", parent: "root", turns: [turn("b", "2026-11-02T09:20:00Z", "2026-11-02T09:25:00Z")])
        let from = date("2026-11-02T09:00:00Z"), to = date("2026-11-02T09:35:00Z")
        let lanes = ActivityAnalytics.lanes(for: root, in: [root, child], from: from, to: to)
        var copy = lanes[0]
        copy.intervals = [
            .init(start: date("2026-11-02T09:12:00Z"), end: date("2026-11-02T09:20:00Z")),
            .init(start: from, end: Date(timeIntervalSinceReferenceDate: .infinity)),
            .init(start: to, end: from),
        ]
        let buckets = ActivityAnalytics.load(lanes + [copy, lanes[1]], from: from, to: to)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].meanAgents, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(buckets[1].meanAgents, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(buckets[2].meanAgents, 1, accuracy: 1e-9)
        XCTAssertEqual(buckets.map(\.durationSeconds), [900, 900, 300])
        XCTAssertEqual(buckets.last?.end, to)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.meanAgents * $1.durationSeconds }, 1_800, accuracy: 1e-9,
                       "integrated load reconciles exactly to unique-agent recorded time")
        XCTAssertEqual(ActivityAnalytics.concurrency(lanes + [copy, lanes[1]], from: from, to: to).map(\.agents).max(), 2)
    }

    func testLoadRejectsNonfiniteAndUnboundedRequestsBeforeIntegerConversion() {
        let from = date("2026-11-02T09:00:00Z"), to = date("2026-11-02T10:00:00Z")
        for size in [Double.nan, .infinity, 0, -1, .leastNonzeroMagnitude, 3_600.0 / 4_097.0] {
            XCTAssertTrue(ActivityAnalytics.load([], from: from, to: to, bucketSeconds: size).isEmpty)
        }
        let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertTrue(ActivityAnalytics.load([], from: from, to: invalid).isEmpty)
        XCTAssertTrue(ActivityAnalytics.concurrency([], from: from, to: invalid).isEmpty)
        XCTAssertTrue(ActivityAnalytics.load([], from: to, to: from).isEmpty)
        XCTAssertEqual(ActivityAnalytics.load([], from: from, to: to).map(\.meanAgents), [0, 0, 0, 0])
        XCTAssertEqual(ActivityAnalytics.load([], from: from, to: from.addingTimeInterval(4_096), bucketSeconds: 1).count, 4_096)
    }

    func testLaneRetainsTimestampOnlyChildAndUsesModelOfClippedCrossingTurn() {
        var root = session("root", title: "Goal", turns: [
            turn("crossing", "2026-11-02T08:00:00Z", "2026-11-02T11:00:00Z", model: "current-model"),
            ActivityTurn(id: "invalid", startedAt: Date(timeIntervalSinceReferenceDate: -.infinity), completedAt: date("2026-11-02T09:45:00Z")),
        ])
        root.models = ["current-model", "older-model"]
        let child = session("child", title: "Timing unavailable", parent: "root", turns: [
            ActivityTurn(id: "completion-only", completedAt: date("2026-11-02T09:30:00Z")),
        ])
        let from = date("2026-11-02T09:00:00Z"), to = date("2026-11-02T10:00:00Z")
        let lanes = ActivityAnalytics.lanes(for: root, in: [root, child], from: from, to: to)
        XCTAssertEqual(lanes.count, 2, "missing duration must not erase recorded child participation")
        XCTAssertEqual(lanes[0].model, "current-model")
        XCTAssertEqual(lanes[0].segments.map(\.turnID), ["crossing"], "nonfinite timing cannot create a visual bar")
        XCTAssertEqual(lanes[0].busySeconds, 3_600)
        XCTAssertEqual(lanes[1].turnCount, 1)
        XCTAssertTrue(lanes[1].intervals.isEmpty)
        XCTAssertEqual(lanes[1].lastActivity, date("2026-11-02T09:30:00Z"))
    }

    func testOwnedTurnsExcludeObservedAncestorCopiesAndPreserveCorrectedEvidence() {
        let shared = turn("shared", "2026-11-02T08:00:00Z", "2026-11-02T08:10:00Z", tokens: 100, model: "initial")
        var corrected = shared
        corrected.usage.total = 200
        corrected.model = "resolved"
        var root = session("root", title: "Root", turns: [shared])
        var child = session("child", title: "Child", parent: root.id, turns: [
            corrected, turn("child-own", "2026-11-02T09:00:00Z", "2026-11-02T09:10:00Z", tokens: 30),
        ])
        let grandchild = session("grandchild", title: "Grandchild", parent: child.nativeID, turns: [
            corrected, child.turns[1], turn("grandchild-own", "2026-11-02T10:00:00Z", "2026-11-02T10:10:00Z", tokens: 40),
        ])
        root.observedAt = date("2026-11-02T12:00:00Z")
        child.observedAt = date("2026-11-02T13:00:00Z")
        var foreign = session("foreign", title: "Foreign", parent: root.nativeID, turns: [corrected])
        foreign.provider = .claude
        foreign.turns[0].usage.total = 999
        let snapshot = [grandchild, child, root, foreign]
        let owned = ActivityAnalytics.ownedTurnsBySession(in: snapshot)
        XCTAssertEqual(owned[root.id]?.map(\.id), ["shared"])
        XCTAssertEqual(owned[root.id]?.first?.usage.total, 200, "the original owner receives the corrected canonical receipt")
        XCTAssertEqual(owned[root.id]?.first?.model, "resolved")
        XCTAssertEqual(owned[child.id]?.map(\.id), ["child-own"])
        XCTAssertEqual(owned[grandchild.id]?.map(\.id), ["grandchild-own"])
        XCTAssertEqual(owned[foreign.id]?.map(\.id), ["shared"], "native IDs and receipt corrections stay inside provider scope")
        XCTAssertEqual(ActivityAnalytics.ownedTurns(for: child, in: snapshot), owned[child.id])
        XCTAssertEqual(child.turns.count, 2, "ownership is a projection; copied audit receipts remain untouched")

        let noAncestor = ActivityAnalytics.ownedTurnsBySession(in: [child])
        XCTAssertEqual(Set(noAncestor[child.id]?.map(\.id) ?? []), ["shared", "child-own"],
                       "a missing ancestor cannot justify discarding observed receipts")

        var bounded = child
        bounded.observedAt = child.observedAt.addingTimeInterval(60)
        bounded.turns = [turn("child-later", "2026-11-02T11:00:00Z", "2026-11-02T11:10:00Z")]
        bounded.historyComplete = false
        XCTAssertEqual(ActivityAnalytics.ownedTurnsBySession(in: [root, bounded, child])[child.id]?.map(\.id), ["child-later", "child-own"],
                       "a newer bounded snapshot retains older owned receipts")
        bounded.historyComplete = true
        XCTAssertEqual(ActivityAnalytics.ownedTurnsBySession(in: [root, bounded, child])[child.id]?.map(\.id), ["child-later"],
                       "a complete provider snapshot can authoritatively remove prior receipts")
    }
}
