@testable import BridgeCore
import Foundation
import XCTest

final class HourlyAgentChartTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let locale = Locale(identifier: "en_GB")
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private let base = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
    private func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    private func turn(_ id: String, _ start: Date, _ end: Date?) -> ActivityTurn {
        ActivityTurn(id: id, startedAt: start, completedAt: end, status: end == nil ? "running" : "completed")
    }
    private func session(_ id: String, parent: String? = nil, turns: [ActivityTurn]) -> ActivitySession {
        ActivitySession(id: id, provider: .codex, nativeID: id, title: id, projectPath: "/repo",
                        createdAt: at(-86_400), updatedAt: at(172_800), observedAt: at(172_800),
                        parentSessionID: parent, turns: turns, historyComplete: true, source: "fixture")
    }
    private func series(_ sessions: [ActivitySession], from: Date, to: Date, timeZone: TimeZone? = nil) -> [HourlyAgentChart.Bucket] {
        let overview = ActivityOverview(generatedAt: to, sessions: sessions,
                                        sources: [ActivitySourceHealth(id: "fixture", status: "ready", checkedAt: to, message: "Fixture")])
        let points = ActivityAccounting.build(overview: overview, from: from, to: to)
            .series(granularity: .hour, timeZone: timeZone ?? utc).points
        return HourlyAgentChart.buckets(points, timeZone: timeZone ?? utc)
    }

    func testExactRollingDayKeepsBothPartialWidthsWithoutDilutingTheAverage() throws {
        let from = at(1_800), to = at(88_200)
        let hours = series([session("one", turns: [turn("work", at(0), at(100_000))])], from: from, to: to)
        XCTAssertEqual(hours.count, 25)
        let first = try XCTUnwrap(hours.first), last = try XCTUnwrap(hours.last)
        XCTAssertEqual(first.hourStart, at(0))
        XCTAssertEqual(first.start, from)
        XCTAssertEqual(first.end, at(3_600))
        XCTAssertEqual(first.midpoint, at(2_700))
        XCTAssertEqual(last.start, at(86_400))
        XCTAssertEqual(last.end, to)
        XCTAssertTrue(first.isPartial)
        XCTAssertTrue(last.isPartial)
        XCTAssertTrue(hours.dropFirst().dropLast().allSatisfy { !$0.isPartial })
        XCTAssertTrue(hours.allSatisfy { $0.averageAgents == 1 }, "each observed partial edge uses its actual duration, not a full-hour denominator")
        XCTAssertEqual(hours.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, 86_400)
    }

    func testDrawnBarsLeaveAGapBetweenHoursAndStayInsideTheirInterval() throws {
        let hours = series([session("one", turns: [turn("work", at(0), at(100_000))])], from: at(1_800), to: at(88_200))
        for (left, right) in zip(hours, hours.dropFirst()) {
            let gap = right.barStart.timeIntervalSince(left.barEnd)
            if left.isPartial || right.isPartial {
                XCTAssertGreaterThan(gap, HourlyAgentChart.barGap / 2, "a partial edge hour is still a separate bar")
            } else {
                XCTAssertEqual(gap, HourlyAgentChart.barGap, accuracy: 0.001, "neighbouring hours are separate bars")
            }
        }
        for hour in hours {
            XCTAssertGreaterThanOrEqual(hour.barStart, hour.start)
            XCTAssertLessThanOrEqual(hour.barEnd, hour.end)
        }
        let full = hours[1], edge = try XCTUnwrap(hours.first)
        XCTAssertEqual(full.barEnd.timeIntervalSince(full.barStart), 3_600 - HourlyAgentChart.barGap, accuracy: 0.001)
        XCTAssertEqual(edge.barEnd.timeIntervalSince(edge.barStart), 1_800 - HourlyAgentChart.barGap / 2, accuracy: 0.001, "a half-hour edge stays half as wide")
    }

    func testClippedRecordedWorkProducesAFractionalTimeAverageNotAWholeAgentCount() throws {
        let hours = series([session("one", turns: [turn("work", at(0), at(2_400))])], from: at(1_800), to: at(2_700))
        XCTAssertEqual(hours.count, 1)
        XCTAssertEqual(try XCTUnwrap(hours.first?.averageAgents), 2.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(hours.first?.start, at(1_800))
        XCTAssertEqual(hours.first?.end, at(2_700))
    }

    func testQuietOpenAndRecordedZeroRemainDifferentEvidenceStates() {
        let hours = series([session("one", turns: [turn("open", at(4_200), nil), turn("zero", at(9_000), at(9_000))])],
                           from: at(0), to: at(10_800))
        XCTAssertEqual(hours.map(\.averageAgents), [nil, nil, 0])
        XCTAssertEqual(hours.map(\.hasObservations), [false, true, true])
        XCTAssertNil(hours[1].averageAgents, "an open start never becomes inferred work through the report time")
    }

    func testCanonicalDuplicatesCopiedHistoryAndSessionOverlapsDoNotMultiplyAgents() throws {
        let shared = turn("shared", at(0), at(3_600))
        let overlap = turn("overlap", at(0), at(3_600))
        let parent = session("parent", turns: [shared, overlap, shared])
        let copy = session("copy", parent: "parent", turns: [shared, overlap])
        let other = session("other", turns: [turn("distinct", at(1_800), at(3_600))])
        let hours = series([parent, copy, other, parent], from: at(0), to: at(3_600))
        XCTAssertEqual(try XCTUnwrap(hours.first?.averageAgents), 1.5, accuracy: 0.000_001)
        XCTAssertEqual(hours, series([other, copy, parent], from: at(0), to: at(3_600)), "presentation must retain canonical ownership and input-order independence")
    }

    func testBangkokClockBoundariesAndDateLabelsIdentifyBothRollingDayEdges() throws {
        let zone = TimeZone(identifier: "Asia/Bangkok")!
        let from = date("2026-11-03T15:17:00Z"), to = date("2026-11-04T15:17:00Z")
        let hours = series([], from: from, to: to, timeZone: zone)
        XCTAssertEqual(hours.count, 25)
        XCTAssertEqual(try XCTUnwrap(hours.first).end.timeIntervalSince(from), 43 * 60)
        XCTAssertEqual(to.timeIntervalSince(try XCTUnwrap(hours.last).start), 17 * 60)
        let ticks = HourlyAgentChart.ticks(from: from, to: to, timeZone: zone, locale: locale)
        XCTAssertEqual(ticks.first?.date, from)
        XCTAssertEqual(ticks.last?.date, to)
        XCTAssertEqual(ticks.first?.timeLabel, "22:17")
        XCTAssertEqual(ticks.first?.timeLabel, ticks.last?.timeLabel)
        XCTAssertNotEqual(ticks.first?.dateLabel, ticks.last?.dateLabel, "the same clock time on different dates must not look like a repeated bucket")
        XCTAssertTrue(hours.allSatisfy { $0.averageAgents == nil }, "calendar coverage without observations is not zero-agent proof")
    }

    func testDSTRepeatedHoursKeepDistinctIntervalsAndOffsetAwareLabels() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let from = date("2026-11-01T04:30:00Z"), to = date("2026-11-01T08:30:00Z")
        let work = session("one", turns: [turn("work", date("2026-11-01T04:00:00Z"), date("2026-11-01T09:00:00Z"))])
        let hours = series([work], from: from, to: to, timeZone: zone)
        XCTAssertEqual(hours.count, 5)
        XCTAssertEqual(Set(hours.map(\.id)).count, 5)
        XCTAssertEqual(hours.map { $0.end.timeIntervalSince($0.start) }, [1_800, 3_600, 3_600, 3_600, 1_800])
        XCTAssertTrue(hours.allSatisfy { $0.averageAgents == 1 })
        XCTAssertNotEqual(HourlyAgentChart.intervalLabel(hours[1], timeZone: zone, locale: locale),
                          HourlyAgentChart.intervalLabel(hours[2], timeZone: zone, locale: locale))
        let ticks = HourlyAgentChart.ticks(from: from, to: to, timeZone: zone, locale: locale)
        let repeated = ticks.filter { [date("2026-11-01T05:00:00Z"), date("2026-11-01T06:00:00Z")].contains($0.date) }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertNotEqual(repeated[0].timeLabel, repeated[1].timeLabel, "a repeated clock hour must identify its UTC offset")
    }

    func testScaleHasZeroWholeAgentTicksHeadroomAndVisibleUpperLine() {
        let scale = HourlyAgentChart.Scale(values: [nil, 0, 2.25, 4.5])
        XCTAssertEqual(scale.upperBound, 5)
        XCTAssertEqual(scale.ticks, [0, 1, 2, 3, 4, 5])
        for peak in [0.01, 0.5, 1, 5, 6, 99, 1_000, 1_000_000_000, 1e100] {
            let result = HourlyAgentChart.Scale(values: [peak])
            XCTAssertGreaterThan(result.upperBound, peak)
            XCTAssertEqual(result.ticks.first, 0)
            XCTAssertEqual(result.ticks.last, result.upperBound)
            XCTAssertTrue(result.ticks.allSatisfy { $0.isFinite && $0 >= 0 && $0.rounded() == $0 })
            XCTAssertLessThanOrEqual(result.ticks.count, 7)
        }
    }

    func testScaleRejectsInvalidValuesAndNeverOverflowsAtExtremePeaks() {
        let empty = HourlyAgentChart.Scale(values: [nil, .nan, .infinity, -.infinity, -1])
        XCTAssertEqual(empty.upperBound, 1)
        XCTAssertEqual(empty.ticks, [0, 1])
        let scale = HourlyAgentChart.Scale(values: [.greatestFiniteMagnitude])
        XCTAssertTrue(scale.upperBound.isFinite)
        XCTAssertEqual(scale.upperBound, .greatestFiniteMagnitude)
        XCTAssertTrue(scale.ticks.allSatisfy(\.isFinite))
        XCTAssertEqual(scale.ticks.last, scale.upperBound)
        XCTAssertTrue(HourlyAgentChart.ticks(from: at(1), to: at(0), timeZone: utc).isEmpty)
    }
}
