import Foundation

public struct QuotaTracker: Sendable {
    /// A failed provider probe may be transient, but a provider-owned plan
    /// percentage becomes misinformation once it is old. Keep it briefly to
    /// avoid a flickering card during one failed refresh. Credit-bearing
    /// readings may remain as explicitly stale history, never current funds.
    static let unavailableReadingGrace: TimeInterval = 15 * 60

    private let cooldown: TimeInterval
    private var estimates: [AgentName: QuotaEstimate] = [
        .claude: QuotaEstimate(agent: .claude),
        .codex: QuotaEstimate(agent: .codex),
        // The third agent is optional and frequently absent, so it stays out of
        // routing until a probe proves the CLI is actually installed.
        .grok: QuotaEstimate(agent: .grok, available: false),
    ]

    public init(cooldownMinutes: Int) {
        cooldown = TimeInterval(cooldownMinutes * 60)
    }

    public mutating func update(event: BridgeEvent, now: Date = Date()) {
        refresh(now: now)
        let agent: AgentName
        switch event.source {
        case .claude: agent = .claude
        case .codex: agent = .codex
        case .grok: agent = .grok
        case .bridge: return
        }
        guard var estimate = estimates[agent] else { return }
        switch event.type {
        case .rateLimit:
            estimate.available = false
            estimate.remainingRatio = 0
            estimate.limitedUntil = parseReset(event) ?? now.addingTimeInterval(cooldown)
            estimate.observedLimits += 1
            if estimate.windows.isEmpty && estimate.credits == nil {
                estimate.source = .observed
            }
            estimate.statusMessage = "A provider limit was observed during a bridge turn."
        case .turnComplete:
            estimate.observedTurns += 1
        default:
            break
        }
        estimates[agent] = estimate
    }

    public mutating func applyProviderUsage(_ incoming: QuotaEstimate, now: Date = Date()) {
        guard incoming.agent != .none,
              var current = estimates[incoming.agent]
        else { return }

        if incoming.source == .unavailable,
           incoming.accountIdentityHash == nil || incoming.accountIdentityHash == current.accountIdentityHash,
           current.credits != nil || (
               !current.windows.isEmpty
                   && current.fetchedAt.map { now.timeIntervalSince($0) <= Self.unavailableReadingGrace } == true
           )
        {
            // Keep the last provider-owned reading visible and dated instead
            // of replacing it with zero after failure. The failure marker
            // makes even a recent retained reading immediately stale.
            current.planName = incoming.planName ?? current.planName
            current.statusMessage = incoming.statusMessage
            current.refreshFailedAt = now
            estimates[incoming.agent] = current
            return
        }

        let observedTurns = current.observedTurns
        let observedLimits = current.observedLimits
        current = incoming
        current.observedTurns = observedTurns
        current.observedLimits = observedLimits
        estimates[incoming.agent] = current
    }

    public mutating func applyProviderUsage(_ incoming: [String: QuotaEstimate], now: Date = Date()) {
        for estimate in incoming.values {
            applyProviderUsage(estimate, now: now)
        }
    }

    public mutating func refresh(now: Date = Date()) {
        for agent in [AgentName.claude, .codex, .grok] {
            guard var estimate = estimates[agent],
                  let limitedUntil = estimate.limitedUntil,
                  now >= limitedUntil
            else { continue }
            // A window reset is not permission to spend credits or bypass a
            // provider-owned account/workspace spending restriction.
            if estimate.rateLimitReachedType == nil && estimate.spendControlReached != true {
                estimate.available = true
            }
            estimate.limitedUntil = nil
            estimates[agent] = estimate
        }
    }

    public mutating func bestAvailable(preferred: AgentName) -> AgentName {
        refresh()
        let available = estimates.values.filter(\.available)
        return available.max {
            if $0.remainingRatio == $1.remainingRatio {
                return $0.agent != preferred && $1.agent == preferred
            }
            return $0.remainingRatio < $1.remainingRatio
        }?.agent ?? .none
    }

    public mutating func earliestReset() -> Date? {
        refresh()
        return estimates.values.compactMap(\.limitedUntil).min()
    }

    public mutating func snapshot() -> [String: QuotaEstimate] {
        refresh()
        return Dictionary(uniqueKeysWithValues: estimates.map { ($0.key.rawValue, $0.value) })
    }

    private func parseReset(_ event: BridgeEvent) -> Date? {
        guard let raw = event.metadata["reset_at"]?.stringValue else { return nil }
        return ISO8601.date(raw)
    }
}
