import Foundation

/// Shared evidence rules for the HUD and reports. Recent receipts establish
/// activity, not that another process is running at this instant.
public enum ActivityPresentationPolicy {
    public enum ReadingState: String, Sendable { case fresh, stale, unavailable }

    /// A slow refresh must not undo a later pin or repository action, even
    /// when both responses carry the same collection timestamp.
    public static func acceptsSnapshot(generatedAt: Date, currentGeneratedAt: Date, requestRevision: UInt64, currentRevision: UInt64) -> Bool {
        requestRevision == currentRevision && generatedAt >= currentGeneratedAt
    }

    public static func isRecent(_ date: Date?, now: Date, within seconds: TimeInterval = 900) -> Bool {
        guard let date, seconds.isFinite, seconds >= 0 else { return false }
        let age = now.timeIntervalSince(date)
        return age.isFinite && age >= 0 && age <= seconds
    }

    public static func recentSessions(_ sessions: [ActivitySession], now: Date) -> [ActivitySession] {
        sessions.filter { session in
            session.turns.contains { isRecent(ActivityAnalytics.timestamp($0), now: now) }
        }
    }

    public static func remainingFraction(_ window: QuotaWindow) -> Double? {
        guard window.usedRatio.isFinite, (0...1).contains(window.usedRatio) else { return nil }
        return 1 - window.usedRatio
    }

    /// An otherwise recent response can still describe a window that reset
    /// since it was fetched. Keep that reading visible as history, not as the
    /// current allowance. A missing reset is unknown, rather than expired.
    public static func isCurrentWindow(_ window: QuotaWindow, now: Date) -> Bool {
        guard remainingFraction(window) != nil, now.timeIntervalSinceReferenceDate.isFinite else { return false }
        guard let reset = window.resetAt else { return true }
        return reset.timeIntervalSinceReferenceDate.isFinite && reset > now
    }

    // The UI polls plan usage every fifteen minutes; allow one minute for
    // collection before marking a normal scheduled reading stale.
    public static func quotaState(_ estimate: QuotaEstimate?, now: Date, maximumAge: TimeInterval = 960) -> ReadingState {
        guard let estimate, estimate.windows.contains(where: { remainingFraction($0) != nil }) else { return .unavailable }
        guard estimate.refreshFailedAt == nil, estimate.source == .live, let fetched = estimate.fetchedAt,
              isRecent(fetched, now: now, within: maximumAge),
              estimate.windows.contains(where: { isCurrentWindow($0, now: now) }) else { return .stale }
        return .fresh
    }

    /// Balance freshness is independent of subscription reset windows. A failed
    /// refresh is immediately historical, even inside the regular polling age.
    public static func creditsState(_ estimate: QuotaEstimate?, now: Date, maximumAge: TimeInterval = 960) -> ReadingState {
        guard let estimate, estimate.agent == .codex,
              estimate.credits != nil || estimate.availableResetCredits != nil else { return .unavailable }
        guard estimate.source == .live, estimate.refreshFailedAt == nil,
              isRecent(estimate.fetchedAt, now: now, within: maximumAge) else { return .stale }
        return .fresh
    }

    /// Forecast from the timestamp of the measurement, never from an aging
    /// cached percentage. Stale readings and expired windows cannot forecast.
    public static func runway(_ window: QuotaWindow, estimate: QuotaEstimate?, now: Date) -> ActivityAnalytics.Runway {
        guard quotaState(estimate, now: now) == .fresh,
              estimate?.windows.contains(window) == true,
              isCurrentWindow(window, now: now),
              let measuredAt = estimate?.fetchedAt,
              let reset = window.resetAt, reset > now else { return .unknown }
        return ActivityAnalytics.runway(window, now: measuredAt)
    }

    /// Compare today's progress with the same local clock time yesterday,
    /// not a partial day against a complete one. A daylight-saving transition
    /// can make the two elapsed spans differ by an hour.
    public static func dayComparison(now: Date, timeZone: TimeZone = ActivityAnalytics.reportingTimeZone) -> (currentStart: Date, previousStart: Date, previousEnd: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: now)
        guard let previousStart = calendar.date(byAdding: .day, value: -1, to: start),
              let previousEnd = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        return (start, previousStart, min(start, max(previousStart, previousEnd)))
    }
}
