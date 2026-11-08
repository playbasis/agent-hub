import Foundation

/// A visible credit surface may request a narrow provider read. Hidden views
/// and a recently completed or failed attempt do not launch extra CLI probes.
public enum CreditRefreshPolicy {
    public static let interval: TimeInterval = 120

    public static func shouldRefresh(
        now: Date,
        isVisible: Bool,
        isReady: Bool,
        isRefreshing: Bool,
        lastAttemptAt: Date?,
        estimate: QuotaEstimate?
    ) -> Bool {
        guard isVisible, isReady, !isRefreshing,
              now.timeIntervalSinceReferenceDate.isFinite else { return false }
        let latest = [lastAttemptAt, estimate?.fetchedAt, estimate?.refreshFailedAt]
            .compactMap { $0 }
            .filter { $0.timeIntervalSinceReferenceDate.isFinite }
            .max()
        guard let latest else { return true }
        let age = now.timeIntervalSince(latest)
        return age.isFinite && age >= interval
    }

    /// Registration expresses interest, not visibility. A view retained by
    /// SwiftUI cannot keep background credit polling alive after its window
    /// closes, minimizes, or changes page.
    public static func hasVisibleSurface(
        registered: Set<String>,
        hubVisible: Bool,
        hubPage: BridgePage?,
        panelVisible: Bool,
        panelShowsCredits: Bool
    ) -> Bool {
        if panelVisible, panelShowsCredits, registered.contains("panel") { return true }
        guard hubVisible, let hubPage, [.accounts, .overview, .credits].contains(hubPage) else { return false }
        return registered.contains(hubPage.id)
    }
}
