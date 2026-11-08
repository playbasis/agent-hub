import Foundation

/// Shared API/UI gate, including retained snapshots on an offline page.
public enum CreditForecastSafety {
    public static func applying(to original: CreditHistoryForecast, now: Date, isCurrentScope: Bool,
                                integrityVerified: Bool = true, historyReadFailed: Bool = false,
                                providerReadFailed: Bool = false, recordingFailed: Bool = false) -> CreditHistoryForecast {
        var result = original
        var reason: String?
        if !integrityVerified { reason = "history_integrity_failed" }
        else if historyReadFailed { reason = "history_read_failed" }
        else if isCurrentScope && providerReadFailed { reason = "latest_provider_read_failed" }
        else if isCurrentScope && recordingFailed { reason = "latest_reading_not_saved" }
        else if let observed = original.observedAt {
            let age = now.timeIntervalSince(observed)
            if !age.isFinite || age < 0 { reason = "future_reading_or_clock_change" }
            else if age > CreditHistoryAnalytics.maximumForecastAge { reason = "latest_reading_stale" }
        } else if original.state == .estimated { reason = "missing_observation_time" }
        if let reason {
            result.state = .unavailable; result.reason = reason
            result.estimatedCreditsPerHour = nil; result.estimatedSecondsRemaining = nil
            result.fasterPaceSecondsRemaining = nil; result.slowerPaceSecondsRemaining = nil
        }
        return result
    }
}
