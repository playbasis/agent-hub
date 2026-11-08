import XCTest
@testable import BridgeCore

final class CreditHistoryAnalyticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = CreditHistoryScope.account("fixture-account")

    private func reading(_ index: Int, minutes: Double, balance: String?, has: Bool? = true,
                         unlimited: Bool? = false, scope: CreditHistoryScope? = nil) -> CreditHistoryRecord {
        CreditHistoryRecord(sequence: index + 1, scope: scope ?? account, observedAt: now.addingTimeInterval(minutes * 60),
            reportedBalance: balance, hasCredits: has, unlimited: unlimited, warnings: [], previousHash: nil, recordHash: "fixture-\(index)")
    }
    private func report(_ records: [CreditHistoryRecord], at: Date? = nil) -> CreditHistoryReport {
        CreditHistoryAnalytics.report(records: records, now: at ?? now, from: now.addingTimeInterval(-86400), to: now)
    }
    private var declining: [CreditHistoryRecord] {
        [reading(0, minutes: -15, balance: "100"), reading(1, minutes: -10, balance: "95"),
         reading(2, minutes: -5, balance: "90"), reading(3, minutes: 0, balance: "85")]
    }

    func testFreshThreePairForecastIsExplicitlyEstimatedAndAccountWide() {
        let result = report(declining)
        XCTAssertEqual(result.schemaVersion, "credit-history/1")
        XCTAssertEqual(result.balancePoints.last?.reportedBalance, "85")
        XCTAssertEqual(result.intervals.map(\.derivedBalanceDelta), ["-5", "-5", "-5"])
        XCTAssertEqual(result.forecast.state, .estimated)
        XCTAssertEqual(result.forecast.estimatedCreditsPerHour, 60)
        XCTAssertEqual(result.forecast.estimatedSecondsRemaining, 5100)
        XCTAssertEqual(result.forecast.fasterPaceSecondsRemaining, 5100)
        XCTAssertEqual(result.forecast.slowerPaceSecondsRemaining, 5100)
        XCTAssertEqual(result.forecast.coverageRatio, 1)
        XCTAssertTrue(result.forecast.caveat.contains("not an invoice"))
        XCTAssertTrue(result.forecast.caveat.contains("other devices"))
    }

    func testInsufficientPairsOrDurationDoNotFabricateForecast() {
        XCTAssertEqual(report(Array(declining.suffix(3))).forecast.state, .insufficientEvidence)
        let short = (0..<4).map { reading($0, minutes: Double($0 - 3), balance: String(100 - $0)) }
        XCTAssertEqual(report(short).forecast.state, .insufficientEvidence)
        XCTAssertNil(report(short).forecast.estimatedSecondsRemaining)
    }

    func testStaleFutureAndImportedReadingsNeverForecast() {
        XCTAssertEqual(report(declining, at: now.addingTimeInterval(301)).forecast.reason, "latest_reading_stale")
        XCTAssertEqual(report(declining, at: now.addingTimeInterval(-1)).forecast.reason, "future_reading_or_clock_change")
        let imported = declining.map { value -> CreditHistoryRecord in var copy = value; copy.scope = .imported("explicit-qa"); return copy }
        XCTAssertEqual(report(imported).forecast.reason, "imported_scope_not_current_account")
        XCTAssertTrue(report(imported).warnings.contains("imported_scope_not_current_account"))
    }

    func testIncreaseIsUnknownFundingOrAdjustmentAndRestartsForecast() {
        var records = declining
        records.append(reading(4, minutes: 1, balance: "200"))
        let result = CreditHistoryAnalytics.report(records: records, now: now.addingTimeInterval(60),
            from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(60))
        XCTAssertEqual(result.intervals.last?.kind, .fundingOrAdjustment)
        XCTAssertEqual(result.intervals.last?.derivedBalanceDelta, "115")
        XCTAssertNil(result.intervals.last?.estimatedDrawdown)
        XCTAssertFalse(result.intervals.last!.eligibleForRate)
        XCTAssertEqual(result.forecast.eligiblePairCount, 0)
        XCTAssertEqual(result.forecast.state, .insufficientEvidence)
    }

    func testLongSamplingGapRetainsDeltaButNeverInventsPaceOrZero() {
        let result = report([reading(0, minutes: -60, balance: "100"), reading(1, minutes: 0, balance: "20")])
        XCTAssertEqual(result.intervals.first?.kind, .gap)
        XCTAssertEqual(result.intervals.first?.derivedBalanceDelta, "-80")
        XCTAssertNil(result.intervals.first?.estimatedDrawdown)
        XCTAssertTrue(result.rates.isEmpty)
        XCTAssertEqual(result.completeness.coverageRatio, 0)
        XCTAssertTrue(result.warnings.contains("sampling_gaps_are_unknown_not_zero"))
    }

    func testCoverageGateExcludesGapEvenWithEnoughPairsAndElapsedTime() {
        let rows = [reading(0, minutes: -45, balance: "100"), reading(1, minutes: -40, balance: "95"),
                    reading(2, minutes: -10, balance: "90"), reading(3, minutes: -5, balance: "85"), reading(4, minutes: 0, balance: "80")]
        let forecast = report(rows).forecast
        XCTAssertEqual(forecast.eligiblePairCount, 3)
        XCTAssertEqual(forecast.observedDurationSeconds, 900)
        XCTAssertEqual(forecast.coverageRatio, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(forecast.reason, "sampling_coverage_below_seventy_percent")
        XCTAssertNil(forecast.estimatedSecondsRemaining)
    }

    func testMissingBalanceIsNotZeroOrMeasuredDrawdown() {
        let result = report([reading(0, minutes: -15, balance: "100"), reading(1, minutes: 0, balance: nil, has: false)])
        XCTAssertNil(result.balancePoints.last?.reportedBalance)
        XCTAssertNil(result.intervals.first?.derivedBalanceDelta)
        XCTAssertNil(result.intervals.first?.estimatedDrawdown)
        XCTAssertNil(result.forecast.estimatedSecondsRemaining)
        XCTAssertTrue(result.warnings.contains("missing_balance_is_not_zero"))
    }

    func testUnlimitedAndContradictoryFlagsSuppressForecast() {
        for (balance, has, unlimited) in [("85", true, true), ("85", false, false), ("0", true, false)] {
            var rows = declining
            rows[3] = reading(3, minutes: 0, balance: balance, has: has, unlimited: unlimited)
            let result = report(rows)
            XCTAssertNotEqual(result.forecast.state, .estimated)
            XCTAssertNil(result.forecast.estimatedSecondsRemaining)
        }
        var unspecifiedCap = declining
        unspecifiedCap[3].unlimited = nil
        XCTAssertEqual(report(unspecifiedCap).forecast.reason, "need_consistent_positive_capped_balance")
    }

    func testUnchangedReadingsHaveZeroEstimatedRateButNotInfiniteRunway() {
        let rows = (0..<4).map { reading($0, minutes: Double($0 - 3) * 5, balance: "100") }
        let result = report(rows)
        XCTAssertEqual(result.rates.map(\.estimatedCreditsPerHour), [0, 0, 0])
        XCTAssertEqual(result.forecast.reason, "no_observed_drawdown_no_runway")
        XCTAssertNil(result.forecast.estimatedSecondsRemaining)
    }

    func testObservedPauseGivesOpenEndedSlowerBoundNotFalseConfidenceInterval() {
        var rows = declining
        rows[1].reportedBalance = "100"
        let result = report(rows)
        XCTAssertEqual(result.forecast.state, .estimated)
        XCTAssertNil(result.forecast.slowerPaceSecondsRemaining)
        XCTAssertNotNil(result.forecast.fasterPaceSecondsRemaining)
    }

    func testExactSubtractionPreservesHugeBalancesAndTinyChanges() {
        let first = "1234567890123456789012345678901234567890.000000000000000000000000000001"
        let second = "1234567890123456789012345678901234567890.000000000000000000000000000000"
        let result = report([reading(0, minutes: -5, balance: first), reading(1, minutes: 0, balance: second)])
        XCTAssertEqual(result.balancePoints.first?.reportedBalance, first)
        XCTAssertEqual(result.intervals.first?.derivedBalanceDelta, "-0.000000000000000000000000000001")
        XCTAssertEqual(result.intervals.first?.estimatedDrawdown, "0.000000000000000000000000000001")
        XCTAssertEqual(CreditHistoryDecimal("0009.9900")?.text, "9.99")
        XCTAssertEqual(CreditHistoryDecimal("99.999")?.add(CreditHistoryDecimal("0.001")!).text, "100")
    }

    func testUnknownIdentityEpochsAndKnownAccountsNeverPool() {
        let old = declining.map { value -> CreditHistoryRecord in var copy = value; copy.scope = .anonymous("old-process"); return copy }
        let new = reading(4, minutes: 0, balance: "70", scope: .anonymous("new-process"))
        let result = report(old + [new])
        XCTAssertEqual(result.scopes.count, 2)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertTrue(result.intervals.isEmpty)
        XCTAssertEqual(result.forecast.state, .insufficientEvidence)
        XCTAssertTrue(result.warnings.contains("identity_unreported_anonymous_epoch_only"))
        let known = report(old + [new, reading(5, minutes: 0, balance: "25")])
        XCTAssertEqual(known.selectedScope, account)
        XCTAssertEqual(known.records.count, 1)
        XCTAssertFalse(known.warnings.contains("identity_unreported_anonymous_epoch_only"))
    }

    func testExplicitScopeAndTimeRangeRemainBounded() {
        let other = reading(9, minutes: 0, balance: "700", scope: .account("other"))
        let result = CreditHistoryAnalytics.report(records: declining + [other], now: now,
            from: now.addingTimeInterval(-600), to: now, scope: account)
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.scopes.count, 2)
        XCTAssertEqual(result.records.last?.reportedBalance, "85")
        XCTAssertEqual(result.forecast.state, .insufficientEvidence)
    }

    func testClockAnomalyOrIntegrityFailureCannotBecomeZeroUsageOrForecast() {
        let backwards = [reading(0, minutes: 0, balance: "100"), reading(1, minutes: -1, balance: "90")]
        let result = report(backwards)
        XCTAssertEqual(result.intervals.first?.kind, .clockAnomaly)
        XCTAssertNil(result.intervals.first?.estimatedDrawdown)
        let corrupt = CreditHistoryAnalytics.report(records: declining, now: now, from: now.addingTimeInterval(-86400), to: now,
            integrityVerified: false, invalidLineCount: 1, tornFinalLine: true)
        XCTAssertEqual(corrupt.forecast.state, .unavailable)
        XCTAssertNil(corrupt.forecast.estimatedSecondsRemaining)
        XCTAssertFalse(corrupt.completeness.integrityVerified)
    }

    func testEmptyAndInvalidRangesAreExplicitlyUnknown() {
        let empty = report([])
        XCTAssertTrue(empty.balancePoints.isEmpty)
        XCTAssertNil(empty.forecast.reportedBalance)
        XCTAssertTrue(empty.warnings.contains("no_reported_readings_in_range"))
        let invalid = CreditHistoryAnalytics.report(records: declining, now: now, from: now, to: now.addingTimeInterval(-1))
        XCTAssertTrue(invalid.records.isEmpty)
        XCTAssertTrue(invalid.warnings.contains("invalid_date_range"))
    }
}
