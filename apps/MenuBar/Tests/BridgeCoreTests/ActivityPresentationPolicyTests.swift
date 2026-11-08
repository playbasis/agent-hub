import XCTest
@testable import BridgeCore

final class ActivityPresentationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testStaleRefreshCannotUndoANewerUserAction() {
        XCTAssertFalse(ActivityPresentationPolicy.acceptsSnapshot(generatedAt: now, currentGeneratedAt: now, requestRevision: 1, currentRevision: 2))
        XCTAssertFalse(ActivityPresentationPolicy.acceptsSnapshot(generatedAt: now.addingTimeInterval(-1), currentGeneratedAt: now, requestRevision: 2, currentRevision: 2))
        XCTAssertTrue(ActivityPresentationPolicy.acceptsSnapshot(generatedAt: now, currentGeneratedAt: now, requestRevision: 2, currentRevision: 2))
    }

    func testRecentEvidenceExcludesFutureAndStaleDates() {
        XCTAssertTrue(ActivityPresentationPolicy.isRecent(now, now: now))
        XCTAssertTrue(ActivityPresentationPolicy.isRecent(now.addingTimeInterval(-900), now: now))
        XCTAssertFalse(ActivityPresentationPolicy.isRecent(now.addingTimeInterval(-901), now: now))
        XCTAssertFalse(ActivityPresentationPolicy.isRecent(now.addingTimeInterval(1), now: now))
        XCTAssertFalse(ActivityPresentationPolicy.isRecent(nil, now: now))
    }

    func testQuotaFreshnessRequiresTimestampAndLiveSource() {
        let window = QuotaWindow(id: "weekly", label: "Weekly", usedRatio: 0.8, resetAt: now.addingTimeInterval(600), durationMinutes: 60)
        var estimate = QuotaEstimate(agent: .codex, windows: [window], source: .live, fetchedAt: now)
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(estimate, now: now), .fresh)
        estimate.fetchedAt = now.addingTimeInterval(-961)
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(estimate, now: now), .stale)
        XCTAssertEqual(ActivityPresentationPolicy.runway(window, estimate: estimate, now: now), .unknown)
        estimate.fetchedAt = now.addingTimeInterval(10)
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(estimate, now: now), .stale)
        estimate.fetchedAt = now; estimate.source = .observed
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(estimate, now: now), .stale)
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(nil, now: now), .unavailable)
    }

    func testRunwayDoesNotDriftAsTheSameMeasurementAges() {
        let reset = now.addingTimeInterval(1_200)
        let window = QuotaWindow(id: "hour", label: "Hourly", usedRatio: 0.9, resetAt: reset, durationMinutes: 60)
        let estimate = QuotaEstimate(agent: .codex, windows: [window], source: .live, fetchedAt: now)
        let first = ActivityPresentationPolicy.runway(window, estimate: estimate, now: now)
        XCTAssertEqual(first, ActivityPresentationPolicy.runway(window, estimate: estimate, now: now.addingTimeInterval(100)))
        XCTAssertEqual(ActivityPresentationPolicy.runway(window, estimate: estimate, now: reset), .unknown)
    }

    func testMalformedQuotaCannotEscapeMeterBounds() {
        var window = QuotaWindow(id: "bad", label: "Bad", usedRatio: 0)
        for value in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            window.usedRatio = value
            XCTAssertNil(ActivityPresentationPolicy.remainingFraction(window))
        }
        window.usedRatio = 1
        XCTAssertEqual(ActivityPresentationPolicy.remainingFraction(window), 0)
        window.usedRatio = 0
        XCTAssertEqual(ActivityPresentationPolicy.remainingFraction(window), 1)
    }

    func testExpiredAndMalformedResetWindowsStayStaleEvenAfterARecentFetch() {
        let expired = QuotaWindow(id: "expired", label: "Weekly", usedRatio: 0.99, resetAt: now)
        let reading = QuotaEstimate(agent: .codex, windows: [expired], source: .live, fetchedAt: now)
        XCTAssertFalse(ActivityPresentationPolicy.isCurrentWindow(expired, now: now))
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(reading, now: now), .stale)
        var invalid = expired
        invalid.resetAt = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertFalse(ActivityPresentationPolicy.isCurrentWindow(invalid, now: now))
        XCTAssertEqual(ActivityPresentationPolicy.quotaState(QuotaEstimate(agent: .codex, windows: [invalid], source: .live, fetchedAt: now), now: now), .stale)
    }

    func testRunwayCannotBorrowFreshnessFromAnUnrelatedReading() {
        let fresh = QuotaWindow(id: "fresh", label: "Hourly", usedRatio: 0.1, resetAt: now.addingTimeInterval(1_800), durationMinutes: 60)
        let old = QuotaWindow(id: "old", label: "Hourly", usedRatio: 0.9, resetAt: now.addingTimeInterval(1_800), durationMinutes: 60)
        let estimate = QuotaEstimate(agent: .codex, windows: [fresh], source: .live, fetchedAt: now)
        XCTAssertEqual(ActivityPresentationPolicy.runway(old, estimate: estimate, now: now), .unknown)
    }

    func testLegacyMetricOutliersAreUnknownRatherThanTrapping() {
        XCTAssertNil(ActivityMetrics.knownTotal([Int.max, 1]))
        XCTAssertNil(ActivityMetrics.knownTotal([-1, nil]))
        XCTAssertEqual(ActivityMetrics.knownTotal([0, nil]), 0)
        XCTAssertEqual(ActivityMetrics.knownTotal([10, -1, 20]), 30)
        XCTAssertNil(ActivityMetrics.summedSeconds([ActivityTurn(id: "bad", durationSeconds: .infinity)]))
        XCTAssertNil(ActivityMetrics.mean([.nan, 1]))
        XCTAssertNil(ActivityMetrics.median([1, .infinity]))
        XCTAssertEqual(ActivityMetrics.median([Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude]), Double.greatestFiniteMagnitude)
    }

    func testDayComparisonUsesSameLocalTimeYesterday() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 13, minute: 45)))
        let window = try XCTUnwrap(ActivityPresentationPolicy.dayComparison(now: date, timeZone: zone))
        XCTAssertEqual(date.timeIntervalSince(window.currentStart), window.previousEnd.timeIntervalSince(window.previousStart))
        XCTAssertEqual(calendar.component(.hour, from: window.previousEnd), 13)
        XCTAssertEqual(calendar.component(.day, from: window.previousEnd), 1)
    }

    func testDayComparisonKeepsCivilClockTimeAcrossDaylightSavingChanges() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        for (month, day) in [(3, 8), (11, 1)] {
            let current = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 13, minute: 45)))
            let window = try XCTUnwrap(ActivityPresentationPolicy.dayComparison(now: current, timeZone: zone))
            XCTAssertEqual(calendar.component(.hour, from: window.previousEnd), 13)
            XCTAssertEqual(calendar.component(.minute, from: window.previousEnd), 45)
            XCTAssertEqual(abs(current.timeIntervalSince(window.currentStart) - window.previousEnd.timeIntervalSince(window.previousStart)), 3_600, accuracy: 0.001)
        }
    }
}
