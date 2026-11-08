import BridgeCore
import SwiftUI

/// Shared by Accounts, Overview and the compact HUD. No parallel credit
/// arithmetic, guessed dollar conversion, or inferred consumption ledger.
struct CreditBalanceView: View {
    var estimate: QuotaEstimate?
    var account: ProviderAccountStatus?
    var now: Date
    var compact = false
    var onRefresh: (() -> Void)? = nil
    var refreshing = false
    var onVisibilityChanged: ((Bool) -> Void)? = nil
    var openHistory: (() -> Void)? = nil
    @State private var showsDetails = false

    private var presentation: CreditBalancePresentation {
        .make(estimate, now: now, expectedAccountIdentityHash: account?.creditAccountIdentityHash,
              accountVerified: account?.creditAccountIdentityHash != nil)
    }

    private var color: Color {
        if presentation.isHistorical { return BridgeTheme.textSecondary }
        if presentation.identityUnreported { return BridgeTheme.warning }
        if estimate?.spendControlReached == true || estimate?.rateLimitReachedType?.hasPrefix("workspace_") == true { return BridgeTheme.warning }
        switch presentation.state {
        case .conflicting, .depleted: return BridgeTheme.warning
        case .available, .unlimited: return BridgeTheme.codex
        default: return BridgeTheme.textSecondary
        }
    }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hub.credits")
        .onAppear { onVisibilityChanged?(true) }
        .onDisappear { onVisibilityChanged?(false) }
    }

    private var stateSymbol: String {
        let p = presentation
        if p.isHistorical { return "clock.badge.exclamationmark" }
        switch p.state {
        case .available: return "checkmark.circle.fill"
        case .unlimited: return "infinity.circle.fill"
        case .depleted: return "exclamationmark.circle.fill"
        case .conflicting, .accountMismatch: return "questionmark.circle.fill"
        case .unavailableBalance, .notReported: return "minus.circle"
        }
    }

    /// The balance leads; the state and reading age follow in one line, and
    /// methodology waits behind ⓘ. Problem states keep their explanation
    /// visible because the figure alone would mislead.
    private var fullBody: some View {
        let p = presentation
        let explains = p.state == .accountMismatch || p.state == .conflicting
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "creditcard.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 30, height: 30).background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.identityUnreported ? "Codex sign-in credits" : "ChatGPT credits")
                        .font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                    HStack(spacing: 5) {
                        Image(systemName: stateSymbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color)
                        Text(p.title).foregroundStyle(BridgeTheme.textSecondary)
                        Text("·").foregroundStyle(BridgeTheme.textTertiary)
                        Text(freshness(p, brief: true)).foregroundStyle(p.isHistorical ? BridgeTheme.warning : BridgeTheme.textTertiary)
                            .help(p.observedAt.map { "Provider reading: \(ActivityReportPresentation.exactActivityDate($0))" } ?? "No dated credit reading.")
                    }
                    .font(BridgeFont.caption).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text((p.isRounded ? "≈" : "") + p.displayBalance)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                    .help(p.exactBalance.map { "Exact provider balance: \($0) credits" } ?? p.detail)
                    .accessibilityLabel(p.state == .unlimited ? p.title : p.exactBalance.map { "\($0) credits" } ?? p.title)
                    .accessibilityIdentifier("hub.credits.balance")
                controls
            }
            if explains {
                Text(p.detail).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = p.limitMessage {
                CalloutBanner(tone: p.isHistorical ? .neutral : .warning, title: p.isHistorical ? "When read: " + message : message,
                              icon: "gauge.with.dots.needle.100percent", compact: true)
            }
            if showsDetails {
                VStack(alignment: .leading, spacing: 7) {
                    if !explains { Text(p.detail) }
                    if p.identityUnreported { Text("Reading: \(freshness(p, brief: false)).") }
                    if let exact = p.exactBalance { Text("Exact balance: \(exact) credits").textSelection(.enabled) }
                    Text("Account-wide, across devices; not limited to the selected project or dates. The rounded display never changes the saved provider value.")
                    Text("Credit charges by turn or project are not reported here. Balance changes may include purchases, grants or other account activity, so they are not treated as credits spent.")
                    Text("Codex does not share auto-reload settings through this reading. Manage them in Codex.")
                    if let resets = p.availableResetCredits { Text("Earned limit resets available: \(resets). These are separate from spendable credits.") }
                }
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).bridgeWell()
                .accessibilityIdentifier("hub.credits.details")
            }
            if let openHistory {
                Button(action: openHistory) { Label("History & forecast", systemImage: "chart.xyaxis.line") }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand)).font(BridgeFont.caption)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button { showsDetails.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(BridgeIconButtonStyle(size: 20))
                .help("About credit reporting").accessibilityLabel("About ChatGPT credits")
            if let onRefresh {
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(BridgeIconButtonStyle(size: 20)).disabled(refreshing)
                    .help("Read the current balance from Codex").accessibilityLabel("Refresh ChatGPT credits")
            }
        }
    }

    private var compactBody: some View {
        let p = presentation
        return VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(compact ? "Credits" : p.identityUnreported ? "Codex sign-in credits" : "ChatGPT credits", systemImage: "creditcard")
                    .font(compact ? BridgeFont.captionMedium : BridgeFont.secondaryMedium)
                    .foregroundStyle(BridgeTheme.textPrimary)
                Spacer(minLength: 4)
                Text((p.isRounded ? "≈" : "") + p.displayBalance)
                    .font(compact ? BridgeFont.captionMedium.monospacedDigit() : BridgeFont.heading.monospacedDigit())
                    .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
                    .help(p.exactBalance.map { "Exact provider balance: \($0) credits" } ?? p.detail)
                    .accessibilityLabel(p.state == .unlimited ? p.title : p.exactBalance.map { "\($0) credits" } ?? p.title)
                    .accessibilityIdentifier("hub.credits.balance")
                Button { showsDetails.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(BridgeIconButtonStyle(size: 20))
                    .help("About credit reporting").accessibilityLabel("About ChatGPT credits")
                if let onRefresh {
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(BridgeIconButtonStyle(size: 20)).disabled(refreshing)
                        .help("Read the current balance from Codex").accessibilityLabel("Refresh ChatGPT credits")
                }
            }
            if !compact || p.identityUnreported || p.state == .accountMismatch || p.state == .conflicting || p.state == .notReported {
                Text(p.detail).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = p.limitMessage {
                Text(p.isHistorical ? "When read: " + message : message)
                    .font(BridgeFont.micro).foregroundStyle(p.isHistorical ? BridgeTheme.textSecondary : color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Image(systemName: p.isHistorical ? "clock.badge.exclamationmark" : "clock")
                Text(freshness(p))
                    .help(p.observedAt.map { "Provider reading: \(ActivityReportPresentation.exactActivityDate($0))" } ?? "No dated credit reading.")
            }
            .font(BridgeFont.micro).foregroundStyle(p.isHistorical ? BridgeTheme.warning : BridgeTheme.textTertiary)
            if showsDetails {
                VStack(alignment: .leading, spacing: 7) {
                    if let exact = p.exactBalance { Text("Exact balance: \(exact) credits").textSelection(.enabled) }
                    Text("Account-wide, across devices; not limited to the selected project or dates. The rounded display never changes the saved provider value.")
                    Text("Credit charges by turn or project are not reported here. Balance changes may include purchases, grants or other account activity, so they are not treated as credits spent.")
                    Text("Codex does not share auto-reload settings through this reading. Manage them in Codex.")
                    if let resets = p.availableResetCredits { Text("Earned limit resets available: \(resets). These are separate from spendable credits.") }
                }
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("hub.credits.details")
            }
            if let openHistory {
                Button(action: openHistory) { Label("History & forecast", systemImage: "chart.xyaxis.line") }
                    .buttonStyle(BridgeLinkButtonStyle()).font(BridgeFont.caption)
            }
        }
    }

    private func freshness(_ p: CreditBalancePresentation, brief: Bool = false) -> String {
        if p.state == .accountMismatch { return "Account match not verified" }
        guard let date = p.observedAt else { return "No dated credit reading" }
        let age = ActivityFormat.relative(date, now: now)
        if p.identityUnreported { return brief ? "read \(age)" : "Codex reading · \(age) · identity not shared" }
        if p.freshness == .fresh { return "Provider reading · \(age)" }
        return estimate?.refreshFailedAt != nil ? "Refresh failed · last balance \(age)" : "Last known balance · \(age)"
    }
}
