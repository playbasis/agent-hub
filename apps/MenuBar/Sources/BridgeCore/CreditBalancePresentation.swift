import Foundation

/// One account-scoped presentation contract. Credits are not local tokens,
/// quota percentages, an invoice, or a measured per-project charge.
public struct CreditBalancePresentation: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case available, unavailableBalance, depleted, unlimited, conflicting, accountMismatch, notReported
    }
    public var state: State
    public var freshness: ActivityPresentationPolicy.ReadingState
    public var exactBalance: String?
    public var displayBalance: String
    public var isRounded: Bool
    public var title: String
    public var detail: String
    public var observedAt: Date?
    public var limitMessage: String?
    public var availableResetCredits: Int?
    public var identityUnreported: Bool = false
    public var isHistorical: Bool { freshness != .fresh }

    public static func make(_ estimate: QuotaEstimate?, now: Date, expectedAccountIdentityHash: String? = nil,
                            accountVerified: Bool = true) -> Self {
        var value = Self(state: .notReported, freshness: .unavailable, exactBalance: nil,
            displayBalance: "—", isRounded: false, title: "Credit balance not reported",
            detail: "Codex has not supplied a credit balance. Missing is not zero.", observedAt: estimate?.fetchedAt,
            limitMessage: nil, availableResetCredits: nil)
        guard let estimate, estimate.agent == .codex else { return value }
        // A freshly displayed account must never inherit another sign-in's
        // credit balance. A reader without an identity cannot prove a match.
        // Codex can successfully return credits while account/read returns
        // account:null. A very recent such reading is useful for the CLI's
        // sign-in, but must not be attributed to a cached named profile.
        let anonymousReading = estimate.accountIdentityHash == nil && estimate.limitID == "codex" && estimate.source == .live
            && estimate.refreshFailedAt == nil
            && ActivityPresentationPolicy.isRecent(estimate.fetchedAt, now: now, within: CreditRefreshPolicy.interval + 60)
        let wrongScope = estimate.accountIdentityHash == nil ? !anonymousReading
            : (!accountVerified || expectedAccountIdentityHash.map({ $0 != estimate.accountIdentityHash }) == true)
        if (estimate.credits != nil || estimate.availableResetCredits != nil), wrongScope {
            value.state = .accountMismatch
            value.title = "Refresh credits for this account"
            value.detail = "The saved balance is not verified for the linked account and is hidden."
            return value
        }
        value.freshness = ActivityPresentationPolicy.creditsState(estimate, now: now)
        value.identityUnreported = anonymousReading
        value.availableResetCredits = estimate.availableResetCredits.flatMap { $0 >= 0 ? $0 : nil }
        guard let credits = estimate.credits else { return value }
        value.exactBalance = validBalance(credits.balance)
        if let balance = value.exactBalance {
            let formatted = formattedBalance(balance)
            value.displayBalance = formatted.text; value.isRounded = formatted.rounded
        }
        let positive = value.exactBalance?.contains(where: { $0 >= "1" && $0 <= "9" }) ?? false
        let zero = value.exactBalance != nil && !positive
        let contradictory = (credits.hasCredits == false && positive) || (credits.hasCredits == true && zero && credits.unlimited != true)
        if contradictory {
            value.state = .conflicting; value.title = "Credit reading needs checking"
            value.detail = "Codex's balance and availability flags disagree. Refresh before relying on this reading."
        } else if credits.unlimited == true {
            value.state = .unlimited; value.title = "No credit cap reported"
            value.displayBalance = "Uncapped"; value.isRounded = false
            value.detail = "Codex reports unlimited credits for this account. This is not an unlimited token allowance."
        } else if credits.hasCredits == false || (zero && credits.hasCredits != true) {
            value.state = .depleted; value.title = "No credits available"
            value.detail = "Codex reports no spendable credits. An omitted amount remains unknown, not zero."
        } else if credits.hasCredits == true || positive {
            value.state = .available; value.title = "Credits available"
            value.detail = value.exactBalance == nil
                ? "Codex reports credits available, but did not share an amount. This is separate from your included plan allowance."
                : "Account-wide balance reported by Codex. It is separate from your included plan allowance."
        } else {
            value.state = .unavailableBalance; value.title = "Credit balance unavailable"
            value.detail = "Codex did not report a usable balance or availability. This is not a zero balance."
        }
        if let message = reachedMessage(estimate) {
            value.limitMessage = message
        } else if estimate.windows.contains(where: { ActivityPresentationPolicy.isCurrentWindow($0, now: now) && $0.usedRatio >= 1 }) {
            value.limitMessage = "Included allowance used up. Credits are reported separately."
        }
        if value.identityUnreported {
            value.detail += " Codex did not share the sign-in identity; this amount is not matched to a named account."
        }
        return value
    }

    /// A deliberately narrow ASCII decimal grammar excludes exponents, locale
    /// separators, signs and nonfinite values. Keep exact original digits.
    public static func validBalance(_ raw: String?) -> String? {
        QuotaCredits.validatedBalance(raw)
    }

    private static func formattedBalance(_ raw: String) -> (text: String, rounded: Bool) {
        // String arithmetic preserves all 128 allowed digits; Decimal/Double
        // formatting would silently round sufficiently large provider balances.
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0].drop(while: { $0 == "0" }))
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        var digits = ((whole.isEmpty ? "0" : whole) + String((fraction + "00").prefix(2))).utf8.map { Int($0) - 48 }
        if fraction.count > 2, fraction[fraction.index(fraction.startIndex, offsetBy: 2)] >= "5" {
            var carry = true
            for index in stride(from: digits.count - 1, through: 0, by: -1) {
                if digits[index] == 9 { digits[index] = 0 }
                else { digits[index] += 1; carry = false; break }
            }
            if carry { digits.insert(1, at: 0) }
        }
        let integer = digits.dropLast(2).map(String.init).joined()
        var grouped = ""
        for (offset, character) in integer.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        let tail = String(digits.suffix(2).map(String.init).joined().reversed().drop(while: { $0 == "0" }).reversed())
        let text = String(grouped.reversed()) + (tail.isEmpty ? "" : "." + tail)
        return (text, fraction.dropFirst(2).contains(where: { $0 != "0" }))
    }

    private static func reachedMessage(_ estimate: QuotaEstimate) -> String? {
        if estimate.spendControlReached == true { return "Codex reports that an account spending control was reached." }
        switch estimate.rateLimitReachedType {
        case "workspace_owner_credits_depleted": return "Codex reports that workspace credits are depleted."
        case "workspace_member_credits_depleted": return "Codex reports that this member's credit allowance is depleted."
        case "workspace_owner_usage_limit_reached": return "Codex reports that the workspace usage limit was reached."
        case "workspace_member_usage_limit_reached": return "Codex reports that this member's usage limit was reached."
        case "rate_limit_reached": return "Included allowance used up. Credit availability is shown separately."
        case .some: return "Codex reports an account limit. Check the provider's usage page for details."
        case .none: return nil
        }
    }
}
