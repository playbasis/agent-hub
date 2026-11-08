import Foundation

/// Display-only arrival effects. Recent recorded evidence is not a claim that
/// a provider process is still running, and one receipt never pulses forever.
public enum LiveAnimationPolicy {
    public static let freshnessWindow: TimeInterval = 15
    public static let pulseCount = 2

    /// Missing, malformed, and future timestamps never become "just now".
    public static func age(of evidenceAt: Date?, now: Date) -> TimeInterval? {
        guard let evidenceAt, evidenceAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let age = now.timeIntervalSince(evidenceAt)
        return age.isFinite && age >= 0 ? age : nil
    }

    public static func newestEvidence(_ dates: [Date?], now: Date) -> Date? {
        dates.compactMap { $0 }.filter { age(of: $0, now: now) != nil }.max()
    }

    public static func cycleDuration(fast: Bool) -> TimeInterval { fast ? 1.3 : 2.4 }

    /// The shorter of two rings or the remaining freshness budget. A bounded
    /// arrival effect does not inherit LiveWork's five-minute state window.
    public static func pulseDuration(evidenceAt: Date?, now: Date, fast: Bool = false) -> TimeInterval? {
        guard let age = age(of: evidenceAt, now: now), age < freshnessWindow else { return nil }
        return min(cycleDuration(fast: fast) * Double(pulseCount), freshnessWindow - age)
    }

    public static func shouldPulse(evidenceAt: Date?, after previousEvidenceAt: Date?, now: Date,
                                   working: Bool, visible: Bool, reduceMotion: Bool) -> Bool {
        guard working, visible, !reduceMotion,
              pulseDuration(evidenceAt: evidenceAt, now: now) != nil,
              let evidenceAt else { return false }
        guard let previousEvidenceAt else { return true }
        guard previousEvidenceAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        return evidenceAt > previousEvidenceAt
    }
}
