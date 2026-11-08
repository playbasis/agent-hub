@testable import BridgeCore
import Foundation
import XCTest

final class ActivityAccountAnalyticsTests: XCTestCase {
    func testProviderDatesAreStrictGregorianLabelsNotLocalCalendarDates() throws {
        XCTAssertNotNil(ActivityAnalytics.accountDate("2024-02-29"))
        for invalid in ["2026-02-29", "2026-02-31", "2026-13-01", "2026-00-01", "2026-11-00", "2026-1-01", "2026-11-01Z", "๒๐๒๖-๑๑-๐๑", "0000-01-01"] {
            XCTAssertNil(ActivityAnalytics.accountDate(invalid), invalid)
        }
        let day = try XCTUnwrap(ActivityAnalytics.accountDate("2026-11-01"))
        XCTAssertEqual(ISO8601DateFormatter().string(from: day), "2026-11-01T00:00:00Z", "coordinate only; source time zone remains unknown")
    }

    func testRepeatedDaysCountOnceButConflictsRemainUnknown() throws {
        let rows = [ActivityAccountDay(date: "2026-11-01", tokens: 10),
                    ActivityAccountDay(date: "2026-11-01", tokens: 10),
                    ActivityAccountDay(date: "2026-11-02", tokens: 20),
                    ActivityAccountDay(date: "2026-11-02", tokens: 30),
                    ActivityAccountDay(date: "2026-11-03", tokens: -1),
                    ActivityAccountDay(date: "2026-02-31", tokens: 9_999)]
        let normalized = ActivityAnalytics.accountDays(rows)
        XCTAssertEqual(normalized.map(\.date), ["2026-11-01", "2026-11-02", "2026-11-03"])
        XCTAssertEqual(normalized.map(\.tokens), [10, nil, nil])
        XCTAssertEqual(normalized.map(\.conflicting), [false, true, false])
        let summary = try XCTUnwrap(ActivityAnalytics.accountSummary(rows, from: "2026-11-01", to: "2026-11-05"))
        XCTAssertEqual(summary.tokens, 10)
        XCTAssertEqual(summary.recordedDays, 1)
        XCTAssertEqual(summary.missingDays, 3)
        XCTAssertEqual(summary.conflictingDays, 1)
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(summary.days.map(\.date), ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"])
    }

    func testExplicitZeroIsMeasuredWhileAnAbsentRowIsNot() throws {
        let zero = try XCTUnwrap(ActivityAnalytics.accountSummary([.init(date: "2026-11-01", tokens: 0)], from: "2026-11-01", to: "2026-11-02"))
        XCTAssertEqual(zero.tokens, 0)
        XCTAssertTrue(zero.isComplete)
        let missing = try XCTUnwrap(ActivityAnalytics.accountSummary([], from: "2026-11-01", to: "2026-11-02"))
        XCTAssertNil(missing.tokens)
        XCTAssertFalse(missing.isComplete)
        XCTAssertEqual(missing.missingDays, 1)
    }

    func testSelectedProviderDateBoundDoesNotBecomeAnInstantBasedFutureFilter() throws {
        // It is November 3 in Bangkok, but still November 2 in UTC. Provider
        // labels do not establish either time zone, so both chart and history
        // must use the selected date bound, not discard this row as future.
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T18:30:00Z"))
        let summary = try XCTUnwrap(ActivityAnalytics.accountSummary([.init(date: "2026-11-03", tokens: 10)], from: "2026-10-28", to: "2026-11-04"))
        let last = try XCTUnwrap(summary.days.last)
        XCTAssertEqual(last.date, "2026-11-03")
        XCTAssertEqual(last.tokens, 10)
        XCTAssertGreaterThan(last.day, now, "UTC coordinates are labels, not future usage timestamps")
    }

    func testSummaryBoundariesAndOverflowNeverInventAUsageTotal() throws {
        let rows = [ActivityAccountDay(date: "2026-10-31", tokens: 9_999),
                    ActivityAccountDay(date: "2026-11-01", tokens: Int.max),
                    ActivityAccountDay(date: "2026-11-02", tokens: 1),
                    ActivityAccountDay(date: "2026-11-03", tokens: 9_999)]
        let summary = try XCTUnwrap(ActivityAnalytics.accountSummary(rows, from: "2026-11-01", to: "2026-11-03"))
        XCTAssertEqual(summary.days.count, 2)
        XCTAssertEqual(summary.recordedDays, 2)
        XCTAssertNil(summary.tokens)
        XCTAssertTrue(summary.overflow)
        XCTAssertFalse(summary.isComplete)
        XCTAssertNil(ActivityAnalytics.accountSummary(rows, from: "2026-11-03", to: "2026-11-01"))
        XCTAssertNil(ActivityAnalytics.accountSummary(rows, from: "2026-11-01", to: "2026-11-01"))
        XCTAssertNil(ActivityAnalytics.accountSummary(rows, from: "0001-01-01", to: "9999-01-01"), "unbounded allocations are refused")
    }

    func testMalformedRunwayRatioCannotProduceAConfidentForecast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var window = QuotaWindow(id: "w", label: "Weekly", usedRatio: 0.5, resetAt: now.addingTimeInterval(3_600), durationMinutes: 300)
        for value in [-0.1, 1.1, .nan, .infinity] {
            window.usedRatio = value
            XCTAssertEqual(ActivityAnalytics.runway(window, now: now), .unknown)
        }
    }

    func testCategoryBarScaleDoesNotAssumeTheFirstCategoryIsLargest() throws {
        let scale = ActivityAnalytics.categoryBarScale([.init(name: "Execution", value: 5), .init(name: "Other", value: 100)])
        XCTAssertEqual(scale.total, 105)
        XCTAssertEqual(scale.maximum, 100)
        XCTAssertEqual(try XCTUnwrap(scale.barFraction(for: 5)), 0.05, accuracy: 0.0001)
        XCTAssertEqual(scale.barFraction(for: 100), 1)
        XCTAssertEqual(scale.barFraction(for: 200), 1, "chart coordinates remain bounded")
        XCTAssertEqual(scale.barFraction(for: 0), 0)
        XCTAssertNil(scale.barFraction(for: -1))
        XCTAssertEqual(try XCTUnwrap(scale.shareFraction(for: 5)), 5.0 / 105, accuracy: 0.0001)
    }

    func testCategoryBarScaleCannotPresentOverflowOrInvalidCountsAsPercentages() {
        let overflow = ActivityAnalytics.categoryBarScale([.init(name: "Tests", value: Int.max), .init(name: "Other", value: 1)])
        XCTAssertNil(overflow.total)
        XCTAssertEqual(overflow.maximum, Int.max)
        XCTAssertEqual(overflow.barFraction(for: Int.max), 1)
        XCTAssertNil(overflow.shareFraction(for: 1))
        let invalid = ActivityAnalytics.categoryBarScale([.init(name: "Tests", value: -1), .init(name: "Other", value: 5)])
        XCTAssertNil(invalid.total)
        XCTAssertEqual(invalid.maximum, 5)
        let empty = ActivityAnalytics.categoryBarScale([])
        XCTAssertNil(empty.total)
        XCTAssertNil(empty.barFraction(for: 0))
        let zero = ActivityAnalytics.categoryBarScale([.init(name: "Tests", value: 0)])
        XCTAssertEqual(zero.total, 0)
        XCTAssertNil(zero.shareFraction(for: 0))
    }

    func testCategoryAggregateOverflowDoesNotBecomeAnAuthoritativeSaturatedCount() throws {
        let turns = [ActivityTurn(id: "a", categories: ["Tests": Int.max]),
                     ActivityTurn(id: "b", categories: ["tests": 1])]
        let mix = ActivityAnalytics.categoryMix(turns)
        let tests = try XCTUnwrap(mix.first)
        XCTAssertEqual(tests.name, "Tests")
        XCTAssertEqual(tests.value, Int.max, "saturation remains safe for layout")
        XCTAssertTrue(tests.overflow)
        XCTAssertNil(ActivityAnalytics.categoryBarScale(mix).total)
        XCTAssertNil(ActivityAnalytics.categoryBarScale(mix).shareFraction(for: tests.value))
        let exact = try XCTUnwrap(ActivityAnalytics.categoryMix([turns[0]]).first)
        XCTAssertFalse(exact.overflow, "a measured Int.max alone is representable")
        XCTAssertEqual(ActivityAnalytics.categoryBarScale([exact]).total, Int.max)
    }
}
