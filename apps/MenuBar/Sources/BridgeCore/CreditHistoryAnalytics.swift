import Foundation

/// Pure derivation. No token ledger, model prices, quota percentages, or local
/// project activity participates in credit history or its forecast.
public enum CreditHistoryAnalytics {
    public static let maximumPairGap: TimeInterval = 15 * 60
    public static let maximumForecastAge: TimeInterval = 5 * 60
    public static let recentForecastWindow: TimeInterval = 60 * 60

    public static func report(records all: [CreditHistoryRecord], now: Date, from: Date, to: Date,
                              scope requested: CreditHistoryScope? = nil,
                              integrityVerified: Bool = true, invalidLineCount: Int = 0,
                              tornFinalLine: Bool = false) -> CreditHistoryReport {
        let grouped = Dictionary(grouping: all, by: \.scope)
        var scopes: [CreditHistoryScopeSummary] = []
        for (scope, values) in grouped {
            let dates: [Date] = values.map(\.observedAt)
            guard let first = dates.min(), let last = dates.max() else { continue }
            scopes.append(CreditHistoryScopeSummary(scope: scope, readingCount: values.count,
                firstObservedAt: first, lastObservedAt: last))
        }
        scopes.sort { lhs, rhs in
            lhs.lastObservedAt == rhs.lastObservedAt ? lhs.id < rhs.id : lhs.lastObservedAt > rhs.lastObservedAt
        }
        // Append order, rather than wall-clock sort, determines the active local
        // scope. A newly started anonymous epoch cannot inherit old balances.
        let selected = requested ?? all.last?.scope
        let scoped = all.filter { $0.scope == selected }
        let validRange = from.timeIntervalSinceReferenceDate.isFinite && to.timeIntervalSinceReferenceDate.isFinite && from <= to
        let records = validRange ? scoped.filter { $0.observedAt >= from && $0.observedAt <= to } : []
        let points = records.map { record in
            CreditHistoryBalancePoint(id: record.id, observedAt: record.observedAt,
                reportedBalance: record.reportedBalance, hasCredits: record.hasCredits,
                unlimited: record.unlimited, isConsistent: consistent(record))
        }
        let intervals = pairs(records).map(interval)
        let rates = intervals.compactMap(rate)
        let duration = eligibleDuration(intervals)
        let span = records.count > 1 ? max(0, records.last!.observedAt.timeIntervalSince(records.first!.observedAt)) : 0
        let coverage = span > 0 ? min(1, duration / span) : 0
        var warnings: [String] = []
        if !validRange { warnings.append("invalid_date_range") }
        if !integrityVerified { warnings.append("history_integrity_failed") }
        if tornFinalLine { warnings.append("incomplete_final_line") }
        if selected?.kind == .anonymous { warnings.append("identity_unreported_anonymous_epoch_only") }
        if selected?.kind == .imported { warnings.append("imported_scope_not_current_account") }
        if records.isEmpty { warnings.append("no_reported_readings_in_range") }
        if intervals.contains(where: { $0.kind == .gap }) { warnings.append("sampling_gaps_are_unknown_not_zero") }
        if intervals.contains(where: { $0.kind == .fundingOrAdjustment }) { warnings.append("balance_increase_unknown_funding_or_adjustment") }
        if intervals.contains(where: { $0.kind == .conflicting || $0.kind == .clockAnomaly }) { warnings.append("conflicting_or_out_of_order_readings") }
        if records.contains(where: { !consistent($0) }) { warnings.append("inconsistent_provider_flags") }
        if records.contains(where: { $0.reportedBalance == nil }) { warnings.append("missing_balance_is_not_zero") }
        warnings += records.flatMap(\.warnings)
        var forecast = forecast(records: records, now: now)
        if !integrityVerified {
            forecast.state = .unavailable; forecast.reason = "history_integrity_failed"
            forecast.estimatedCreditsPerHour = nil; forecast.estimatedSecondsRemaining = nil
            forecast.fasterPaceSecondsRemaining = nil; forecast.slowerPaceSecondsRemaining = nil
        }
        return CreditHistoryReport(generatedAt: now, from: from, to: to, selectedScope: selected, scopes: scopes,
            records: records, balancePoints: points, intervals: intervals, rates: rates, forecast: forecast,
            completeness: .init(integrityVerified: integrityVerified, retainedRecordCount: all.count,
                selectedRecordCount: records.count, invalidLineCount: invalidLineCount, tornFinalLine: tornFinalLine,
                firstObservedAt: records.first?.observedAt, lastObservedAt: records.last?.observedAt,
                eligibleDurationSeconds: duration, coverageRatio: coverage), warnings: Array(Set(warnings)).sorted())
    }

    static func consistent(_ value: CreditHistoryRecord) -> Bool {
        guard let raw = value.reportedBalance, let amount = CreditHistoryDecimal(raw) else { return true }
        let zero = amount.isZero
        return !((value.hasCredits == false && !zero) || (value.hasCredits == true && zero && value.unlimited != true))
    }

    private static func pairs(_ records: [CreditHistoryRecord]) -> [(CreditHistoryRecord, CreditHistoryRecord)] {
        guard records.count > 1 else { return [] }
        return Array(zip(records, records.dropFirst()))
    }

    private static func interval(_ pair: (CreditHistoryRecord, CreditHistoryRecord)) -> CreditHistoryInterval {
        let (a, b) = pair
        var result = CreditHistoryInterval(id: a.id + ":" + b.id, from: a.observedAt, to: b.observedAt,
            kind: .unavailable, derivedBalanceDelta: nil, estimatedDrawdown: nil, eligibleForRate: false)
        let elapsed = b.observedAt.timeIntervalSince(a.observedAt)
        guard elapsed.isFinite, elapsed > 0 else { result.kind = .clockAnomaly; return result }
        guard consistent(a), consistent(b), a.hasCredits == b.hasCredits, a.unlimited == b.unlimited else {
            result.kind = .conflicting; return result
        }
        guard let first = a.reportedBalance.flatMap(CreditHistoryDecimal.init),
              let second = b.reportedBalance.flatMap(CreditHistoryDecimal.init) else { return result }
        let comparison = second.compare(first)
        let amount = comparison >= 0 ? second.subtract(first) : first.subtract(second)
        result.derivedBalanceDelta = comparison < 0 ? "-" + amount : amount
        if comparison > 0 {
            result.kind = .fundingOrAdjustment
            return result
        }
        // A delta across a long gap is still mathematically derived, but is
        // never counted as a measured pace or replaced with zero activity.
        guard elapsed <= maximumPairGap else { result.kind = .gap; return result }
        guard a.unlimited == false, b.unlimited == false else { return result }
        result.kind = comparison < 0 ? .decrease : .unchanged
        result.estimatedDrawdown = amount
        result.eligibleForRate = true
        return result
    }

    private static func rate(_ value: CreditHistoryInterval) -> CreditHistoryRate? {
        guard value.eligibleForRate, let raw = value.estimatedDrawdown,
              let amount = CreditHistoryDecimal(raw)?.estimatedDouble else { return nil }
        let perHour = amount / value.to.timeIntervalSince(value.from) * 3600
        guard perHour.isFinite, perHour >= 0, amount == 0 || perHour > 0 else { return nil }
        return .init(id: value.id, from: value.from, to: value.to,
            estimatedDrawdown: raw, estimatedCreditsPerHour: perHour)
    }

    private static func eligibleDuration(_ intervals: [CreditHistoryInterval]) -> Double {
        intervals.filter(\.eligibleForRate).reduce(0) { $0 + $1.to.timeIntervalSince($1.from) }
    }

    private static func forecast(records: [CreditHistoryRecord], now: Date) -> CreditHistoryForecast {
        var value = CreditHistoryForecast(state: .insufficientEvidence, reason: "need_three_pairs_over_ten_minutes",
            reportedBalance: records.last?.reportedBalance, observedAt: records.last?.observedAt,
            eligiblePairCount: 0, observedDurationSeconds: 0, coverageRatio: 0)
        guard let latest = records.last else { return value }
        guard latest.scope.kind != .imported else { value.state = .unavailable; value.reason = "imported_scope_not_current_account"; return value }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            value.state = .unavailable; value.reason = "invalid_current_clock"; return value
        }
        let age = now.timeIntervalSince(latest.observedAt)
        guard age.isFinite, age >= 0, age <= maximumForecastAge else {
            value.state = .unavailable; value.reason = age < 0 ? "future_reading_or_clock_change" : "latest_reading_stale"; return value
        }
        guard consistent(latest), latest.unlimited == false, latest.hasCredits != false,
              let exactBalance = latest.reportedBalance.flatMap(CreditHistoryDecimal.init), !exactBalance.isZero else {
            value.state = .unavailable; value.reason = "need_consistent_positive_capped_balance"; return value
        }
        let cutoff = latest.observedAt.addingTimeInterval(-recentForecastWindow)
        var recent = records.filter { $0.observedAt >= cutoff }
        // Increases, unknown numeric readings and changing flags end the old
        // forecast segment. They never become inferred purchases or usage.
        var segmentStart = 0
        if recent.count > 1 {
            for index in 1..<recent.count {
                let item = interval((recent[index - 1], recent[index]))
                if [.fundingOrAdjustment, .conflicting, .clockAnomaly, .unavailable].contains(item.kind) { segmentStart = index }
            }
        }
        recent = Array(recent.dropFirst(segmentStart))
        let intervals = pairs(recent).map(interval)
        let eligible = intervals.filter(\.eligibleForRate)
        let elapsed = recent.count > 1 ? recent.last!.observedAt.timeIntervalSince(recent.first!.observedAt) : 0
        let duration = eligibleDuration(eligible)
        value.eligiblePairCount = eligible.count
        value.observedDurationSeconds = duration
        value.coverageRatio = elapsed > 0 ? min(1, duration / elapsed) : 0
        guard eligible.count >= 3, elapsed >= 10 * 60 else { return value }
        guard value.coverageRatio >= 0.7 else { value.reason = "sampling_coverage_below_seventy_percent"; return value }
        var total = CreditHistoryDecimal("0")!
        for pair in eligible {
            guard let amount = pair.estimatedDrawdown.flatMap(CreditHistoryDecimal.init) else {
                value.reason = "arithmetic_unrepresentable"; return value
            }
            total = total.add(amount)
        }
        guard !total.isZero else { value.reason = "no_observed_drawdown_no_runway"; return value }
        let rates = eligible.compactMap(rate)
        guard let balance = exactBalance.estimatedDouble, let decline = total.estimatedDouble,
              rates.count == eligible.count else { value.reason = "arithmetic_unrepresentable"; return value }
        let perSecond = decline / duration
        let runway = balance / perSecond
        let perHour = perSecond * 3600
        guard perSecond.isFinite, perSecond > 0, runway.isFinite, runway > 0, perHour.isFinite, perHour > 0 else {
            value.reason = "arithmetic_unrepresentable"; return value
        }
        let fastest = rates.map(\.estimatedCreditsPerHour).max() ?? 0
        let slowest = rates.map(\.estimatedCreditsPerHour).min() ?? 0
        let faster = fastest > 0 ? balance / fastest * 3600 : .infinity
        let slower = slowest > 0 ? balance / slowest * 3600 : .infinity
        guard faster.isFinite, faster > 0 else { value.reason = "arithmetic_unrepresentable"; return value }
        value.state = .estimated; value.reason = "recent_account_wide_net_decline"
        value.estimatedCreditsPerHour = perHour
        value.estimatedSecondsRemaining = runway
        value.fasterPaceSecondsRemaining = faster
        value.slowerPaceSecondsRemaining = slower.isFinite && slower > 0 ? slower : nil
        return value
    }
}

/// Small bounded unsigned decimal arithmetic. Subtraction and summation retain
/// every provider digit, including amounts outside Foundation Decimal's range.
struct CreditHistoryDecimal {
    let whole: String
    let fraction: String
    init?(_ raw: String) {
        guard QuotaCredits.validatedBalance(raw) != nil else { return nil }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts[0].drop(while: { $0 == "0" })
        whole = integer.isEmpty ? "0" : String(integer)
        fraction = parts.count > 1 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
    }
    var text: String { whole + (fraction.isEmpty ? "" : "." + fraction) }
    var isZero: Bool { whole == "0" && fraction.isEmpty }
    /// Conversion occurs only for explicitly approximate rate/forecast output.
    /// Non-finite values or positive values rounded to zero suppress arithmetic.
    var estimatedDouble: Double? {
        guard let value = Double(text), value.isFinite, value >= 0, isZero || value > 0 else { return nil }
        return value
    }
    private func digits(scale: Int, width: Int) -> [Int] {
        let string = String(repeating: "0", count: width - whole.count) + whole + fraction + String(repeating: "0", count: scale - fraction.count)
        return string.utf8.map { Int($0) - 48 }
    }
    func compare(_ other: Self) -> Int {
        let scale = max(fraction.count, other.fraction.count), width = max(whole.count, other.whole.count)
        let a = digits(scale: scale, width: width), b = other.digits(scale: scale, width: width)
        for (left, right) in zip(a, b) where left != right { return left < right ? -1 : 1 }
        return 0
    }
    func subtract(_ other: Self) -> String {
        let scale = max(fraction.count, other.fraction.count), width = max(whole.count, other.whole.count)
        var a = digits(scale: scale, width: width)
        let b = other.digits(scale: scale, width: width)
        var borrow = 0
        for index in stride(from: a.count - 1, through: 0, by: -1) {
            let digit = a[index] - b[index] - borrow
            a[index] = digit < 0 ? digit + 10 : digit
            borrow = digit < 0 ? 1 : 0
        }
        return Self.render(a, scale: scale)
    }
    func add(_ other: Self) -> Self {
        let scale = max(fraction.count, other.fraction.count), width = max(whole.count, other.whole.count)
        var a = digits(scale: scale, width: width)
        let b = other.digits(scale: scale, width: width)
        var carry = 0
        for index in stride(from: a.count - 1, through: 0, by: -1) {
            let digit = a[index] + b[index] + carry
            a[index] = digit % 10; carry = digit / 10
        }
        if carry > 0 { a.insert(carry, at: 0) }
        // Totals can exceed a single provider balance's 128-character bound.
        return Self(unchecked: Self.render(a, scale: scale))
    }
    private init(unchecked raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        whole = String(parts[0]); fraction = parts.count > 1 ? String(parts[1]) : ""
    }
    private static func render(_ digits: [Int], scale: Int) -> String {
        let raw = digits.map(String.init).joined()
        let split = raw.index(raw.endIndex, offsetBy: -scale)
        let integer = raw[..<split].drop(while: { $0 == "0" })
        let tail = raw[split...].reversed().drop(while: { $0 == "0" }).reversed()
        return (integer.isEmpty ? "0" : String(integer)) + (tail.isEmpty ? "" : "." + String(tail))
    }
}
