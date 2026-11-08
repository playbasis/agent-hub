import Foundation

/// Groups saved sessions by dated work evidence, never a metadata refresh.
public enum SessionActivityGrouping {
    public enum Group: String, CaseIterable, Sendable {
        case openOrRecent = "Recent or open work"
        case today = "Earlier today", yesterday = "Yesterday", week = "Earlier this week", older = "Older"
        case undated = "No dated activity"
    }
    public static func group(lastEvidence: Date?, openOrRecent: Bool, now: Date,
                             timezone: TimeZone = ActivityAnalytics.reportingTimeZone) -> Group {
        if openOrRecent { return .openOrRecent }
        guard now.timeIntervalSince1970.isFinite, let date = lastEvidence,
              date.timeIntervalSince1970.isFinite, date <= now else { return .undated }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if date >= (calendar.date(byAdding: .day, value: -1, to: today) ?? today) { return .yesterday }
        if date >= (calendar.date(byAdding: .day, value: -6, to: today) ?? today) { return .week }
        return .older
    }
}
