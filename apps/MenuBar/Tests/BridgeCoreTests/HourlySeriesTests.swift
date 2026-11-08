@testable import BridgeCore
import Foundation
import XCTest

final class HourlySeriesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func turn(_ id: String, _ start: String, minutes: Double, tokens: Int? = nil, output: Int? = nil) -> ActivityTurn {
        let begin = date(start)
        return ActivityTurn(id: id, startedAt: begin, completedAt: begin.addingTimeInterval(minutes * 60), durationSeconds: minutes * 60,
                            status: "completed", usage: TokenUsage(output: output, total: tokens, provenance: tokens == nil ? .unavailable : .providerReported))
    }

    private func session(_ id: String, _ turns: [ActivityTurn]) -> ActivitySession {
        let measured = turns.map { original -> ActivityTurn in
            var turn = original
            if turn.modelSteps == nil {
                turn.modelSteps = [ActivityModelStep(id: turn.id, timestamp: ActivityAnalytics.timestamp(turn), model: turn.model, usage: turn.usage, usageIsPartial: turn.usageIsPartial)]
                turn.modelStepsComplete = true
            }
            return turn
        }
        return ActivitySession(id: id, provider: .codex, nativeID: id, title: id, projectPath: "/p", createdAt: date("2026-11-01T00:00:00Z"),
                        updatedAt: date("2026-11-02T12:00:00Z"), observedAt: date("2026-11-02T12:00:00Z"), turns: measured, source: "test")
    }

    func testHourlyBucketsClipIntervalsAndKeepQuietHours() {
        let turns = [
            turn("a", "2026-11-02T10:40:00Z", minutes: 40, tokens: 100, output: 10),   // 10:40–11:20 spans two hours
            turn("b", "2026-11-02T12:05:00Z", minutes: 10, tokens: 50, output: 5),
        ]
        let points = ActivityAnalytics.hourly(turns, from: date("2026-11-02T10:00:00Z"), to: date("2026-11-02T13:30:00Z"), timeZone: utc)
        XCTAssertEqual(points.map(\.day), [date("2026-11-02T10:00:00Z"), date("2026-11-02T11:00:00Z"),
                                           date("2026-11-02T12:00:00Z"), date("2026-11-02T13:00:00Z")])
        XCTAssertEqual(points[0].measuredActiveSeconds, 20 * 60, "the interval is clipped at the hour boundary")
        XCTAssertEqual(points[1].measuredActiveSeconds, 20 * 60)
        XCTAssertEqual(points[1].turns, 1, "a request belongs to the hour it finished")
        XCTAssertEqual(points[1].measuredTokens, 100)
        XCTAssertEqual(points[2].measuredActiveSeconds, 10 * 60)
        XCTAssertEqual(points[3].turns, 0)
        XCTAssertNil(points[3].measuredActiveSeconds, "a quiet hour has no evidence, which the chart draws as empty")
    }

    func testOverlappingAgentsCountOnceWithinAnHour() {
        let turns = [turn("a", "2026-11-02T10:00:00Z", minutes: 30), turn("b", "2026-11-02T10:15:00Z", minutes: 30)]
        let points = ActivityAnalytics.hourly(turns, from: date("2026-11-02T10:00:00Z"), to: date("2026-11-02T11:00:00Z"), timeZone: utc)
        XCTAssertEqual(points.first?.measuredActiveSeconds, 45 * 60)
    }

    func testSeriesSwitchesBucketSizeAndTokenBreakdownFollows() {
        let turns = [turn("a", "2026-11-02T10:10:00Z", minutes: 5, tokens: 10), turn("b", "2026-11-02T15:10:00Z", minutes: 5, tokens: 20)]
        let from = date("2026-11-02T00:00:00Z"), to = date("2026-11-02T18:00:00Z")
        XCTAssertEqual(ActivityAnalytics.series(turns, from: from, to: to, granularity: .hour, timeZone: utc).count, 18)
        XCTAssertEqual(ActivityAnalytics.series(turns, from: from, to: to, granularity: .day, timeZone: utc).count, 1)
        let breakdown = ActivityAnalytics.dailyTokenBreakdown(turns, providers: ["a": .codex, "b": .claude], from: from, to: to,
                                                              granularity: .hour, timeZone: utc)
        XCTAssertEqual(breakdown.days.count, 18)
        XCTAssertEqual(breakdown.rows.filter { $0.turns > 0 }.map(\.provider).sorted { $0.rawValue < $1.rawValue }, [.claude, .codex])
        XCTAssertEqual(breakdown.period.tokens, 30)
    }

    func testShortWindowsCompareHoursNotPartialDays() {
        var turns: [ActivityTurn] = []
        for index in 0 ..< 18 { turns.append(turn("peak-\(index)", "2026-11-02T14:\(String(format: "%02d", index)):00Z", minutes: 1)) }
        for hour in [9, 10, 11, 16] { turns.append(turn("h\(hour)", "2026-11-02T\(String(format: "%02d", hour)):30:00Z", minutes: 1)) }
        turns.append(turn("y", "2026-11-01T20:30:00Z", minutes: 1))
        let input = ActivityHighlights.Input(sessions: [session("s", turns)], from: date("2026-11-01T19:00:00Z"), to: date("2026-11-02T18:00:00Z"),
                                             timeZone: utc, locale: Locale(identifier: "en_GB"))
        let highlights = ActivityHighlights.make(input, limit: 20)
        XCTAssertNil(highlights.first { $0.kind == .busiestDay }, "a rolling day spans two partial dates")
        let hour = highlights.first { $0.kind == .busiestHour }
        XCTAssertEqual(hour?.value, "18")
        XCTAssertEqual(hour?.title, "Busiest full hour: Today, 14:00–15:00")
        XCTAssertEqual(hour?.detail, "18 model steps · 18× the other hours' average")
    }

    func testBusiestHourExcludesBothPartialEdgesOfAnExactRollingDay() throws {
        var turns = (0..<18).map { turn("full-\($0)", "2026-11-02T14:10:00Z", minutes: 0) }
        for hour in [9, 10, 11, 16] { turns.append(turn("h\(hour)", "2026-11-02T\(String(format: "%02d", hour)):30:00Z", minutes: 0)) }
        for index in 0..<30 {
            turns.append(turn("first-edge-\(index)", "2026-11-01T18:40:00Z", minutes: 0))
            turns.append(turn("last-edge-\(index)", "2026-11-02T18:10:00Z", minutes: 0))
        }
        let input = ActivityHighlights.Input(sessions: [session("s", turns)], from: date("2026-11-01T18:30:00Z"), to: date("2026-11-02T18:30:00Z"),
                                             timeZone: utc, locale: Locale(identifier: "en_GB"))
        let hour = try XCTUnwrap(ActivityHighlights.make(input, limit: 20).first { $0.kind == .busiestHour })
        XCTAssertEqual(hour.value, "18", "neither 30-record partial edge can become the busiest full hour")
        XCTAssertEqual(hour.title, "Busiest full hour: Today, 14:00–15:00")
        XCTAssertTrue(hour.note?.contains("Partial edge hours are excluded") == true)
    }

    func testBusiestHourIdentifiesTheDateAcrossMidnightAndNeedsAFullHourBaseline() throws {
        var turns = (0..<20).map { turn("night-\($0)", "2026-11-01T23:20:00Z", minutes: 0) }
        turns.append(turn("baseline-a", "2026-11-02T00:20:00Z", minutes: 0))
        turns.append(turn("baseline-b", "2026-11-02T01:20:00Z", minutes: 0))
        let input = ActivityHighlights.Input(sessions: [session("s", turns)], from: date("2026-11-01T15:30:00Z"), to: date("2026-11-02T15:30:00Z"),
                                             timeZone: utc, locale: Locale(identifier: "en_GB"))
        let hour = try XCTUnwrap(ActivityHighlights.make(input, limit: 20).first { $0.kind == .busiestHour })
        XCTAssertEqual(hour.title, "Busiest full hour: Yesterday, 23:00–00:00")
        var short = input
        short.from = date("2026-11-01T22:30:00Z")
        short.to = date("2026-11-02T01:30:00Z")
        XCTAssertNil(ActivityHighlights.make(short, limit: 20).first { $0.kind == .busiestHour }, "two complete hours do not establish a baseline")
    }

    func testHourlyExclusiveBoundariesAndPartialEdgesReconcileWithPeriod() throws {
        let from = date("2026-11-01T12:30:00Z"), to = date("2026-11-02T12:30:00Z")
        let turns = [turn("before", "2026-11-01T12:29:00Z", minutes: 0, tokens: 999),
                     turn("first", "2026-11-01T12:30:00Z", minutes: 0, tokens: 10, output: 1),
                     turn("last", "2026-11-02T12:29:00Z", minutes: 0, tokens: 20, output: 2),
                     turn("end", "2026-11-02T12:30:00Z", minutes: 0, tokens: 999)]
        let points = ActivityAnalytics.hourly(turns + [turns[1]], from: from, to: to, timeZone: utc)
        let period = ActivityAnalytics.period(turns, sessions: 1, from: from, to: to)
        XCTAssertEqual(points.count, 25, "an exact rolling day can span two partial edge hours")
        XCTAssertEqual(points.reduce(0) { $0 + $1.turns }, period.turns)
        XCTAssertEqual(ActivityMetrics.knownTotal(points.map(\.measuredTokens)), period.tokens)
        XCTAssertEqual(ActivityMetrics.knownTotal(points.map(\.measuredOutputTokens)), period.outputTokens)
        XCTAssertEqual(points.first?.measuredTokens, 10)
        XCTAssertEqual(points.last?.measuredTokens, 20)
        XCTAssertNil(points[1].measuredTokens, "no receipt is unknown, not a provider-reported zero")
        XCTAssertEqual(try XCTUnwrap(points.first?.measuredActiveSeconds), 0, "a recorded zero duration remains measurable")
    }

    func testHourlyOversizedRangeIsRejectedInsteadOfReturningAPartialPrefix() {
        let from = date("2026-01-01T00:00:00Z")
        let maximumEnd = from.addingTimeInterval(24 * 366 * 3_600)
        XCTAssertEqual(ActivityAnalytics.hourly([], from: from, to: maximumEnd, timeZone: utc).count, 24 * 366)
        XCTAssertTrue(ActivityAnalytics.hourly([], from: from, to: maximumEnd.addingTimeInterval(1), timeZone: utc).isEmpty)
    }

    func testDistinctSessionLoadMergesOverlappingRequestsBeforeCountingAgents() throws {
        let from = date("2026-11-02T10:00:00Z"), to = date("2026-11-02T11:00:00Z")
        let overlap = [turn("one", "2026-11-02T10:00:00Z", minutes: 60),
                       turn("two", "2026-11-02T10:00:00Z", minutes: 60)]
        let first = session("first", overlap)
        XCTAssertEqual(try XCTUnwrap(ActivityAnalytics.averageDistinctSessionLoad([first], from: from, to: to)), 1, accuracy: 0.0001)
        let second = session("second", [turn("third", "2026-11-02T10:00:00Z", minutes: 60)])
        XCTAssertEqual(try XCTUnwrap(ActivityAnalytics.averageDistinctSessionLoad([first, second], from: from, to: to)), 2, accuracy: 0.0001)
        let prepared = ActivityAnalytics.ownedTurnsBySession(in: [first, second])
        XCTAssertEqual(ActivityAnalytics.averageDistinctSessionLoad(ownedTurns: prepared, from: from, to: to), 2)
        var copied = session("copy", overlap)
        copied.parentSessionID = first.nativeID
        XCTAssertEqual(try XCTUnwrap(ActivityAnalytics.averageDistinctSessionLoad([first, copied], from: from, to: to)), 1, accuracy: 0.0001)
    }

    func testDistinctSessionLoadUsesTheExactClippedDurationAndPreservesUnknown() throws {
        let from = date("2026-11-02T10:30:00Z"), to = date("2026-11-02T10:45:00Z")
        let timed = session("timed", [turn("work", "2026-11-02T10:00:00Z", minutes: 40)])
        XCTAssertEqual(try XCTUnwrap(ActivityAnalytics.averageDistinctSessionLoad([timed], from: from, to: to)), 2.0 / 3, accuracy: 0.0001)
        XCTAssertNil(ActivityAnalytics.averageDistinctSessionLoad([], from: from, to: to))
        let open = session("open", [ActivityTurn(id: "open", startedAt: from)])
        XCTAssertNil(ActivityAnalytics.averageDistinctSessionLoad([open], from: from, to: to))
        let zero = session("zero", [turn("zero", "2026-11-02T10:35:00Z", minutes: 0)])
        XCTAssertEqual(ActivityAnalytics.averageDistinctSessionLoad([zero], from: from, to: to), 0)
        XCTAssertNil(ActivityAnalytics.averageDistinctSessionLoad([timed], from: to, to: from))
    }

    func testMalformedSharedCopyCycleConservesEveryKnownReceiptOnce() {
        let shared = turn("shared", "2026-11-02T10:00:00Z", minutes: 10, tokens: 10)
        let ownA = turn("own-a", "2026-11-02T10:10:00Z", minutes: 10, tokens: 20)
        let ownB = turn("own-b", "2026-11-02T10:20:00Z", minutes: 10, tokens: 30)
        var a = session("a", [shared, ownA])
        var b = session("b", [shared, ownB])
        a.parentSessionID = b.nativeID
        b.parentSessionID = a.nativeID
        let parents = ActivityAnalytics.sessionParents(in: [b, a])
        XCTAssertNil(parents[a.id], "the deterministic anchor becomes a root")
        XCTAssertEqual(parents[b.id], a.id)
        let owned = ActivityAnalytics.ownedTurnsBySession(in: [b, a])
        XCTAssertEqual(owned[a.id]?.map(\.id), [ownA.id, shared.id].sorted())
        XCTAssertEqual(owned[b.id]?.map(\.id), [ownB.id])
        let values = owned.values.flatMap { $0 }
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(Set(values.map(\.id)).count, 3)
        XCTAssertEqual(ActivityMetrics.knownTotal(values.map(\.usage.total)), 60, "breaking a bad cycle must not delete the shared receipt from every owner")
        XCTAssertEqual(ActivityAnalytics.ownedTurnsBySession(in: [a, b]), owned, "input ordering cannot change cycle ownership")
    }

    func testOwnershipDoesNotGuessAnAmbiguousNativeParent() {
        let shared = turn("shared", "2026-11-02T10:00:00Z", minutes: 10, tokens: 10)
        var first = session("first", [shared])
        var second = session("second", [])
        first.nativeID = "ambiguous"
        second.nativeID = "ambiguous"
        var child = session("child", [shared])
        child.parentSessionID = "ambiguous"
        XCTAssertNil(ActivityAnalytics.sessionParents(in: [first, second, child])[child.id])
        XCTAssertEqual(ActivityAnalytics.ownedTurnsBySession(in: [first, second, child])[child.id]?.map(\.id), [shared.id], "unknown lineage preserves evidence instead of assigning it to an arbitrary parent")
    }
}
