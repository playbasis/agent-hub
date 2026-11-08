import AppKit
import BridgeCore
import SwiftUI

/// The Accounts tab: one card per subscription with plan gauges and an
/// in-place sign-in flow, plus the Gemini coordinator key.
struct AccountsView: View {
    @ObservedObject var model: BridgeViewModel
    @ObservedObject var accounts: AccountsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AccountCard(provider: .claude, model: model, accounts: accounts, quota: model.status.quota["claude"])
            AccountCard(provider: .codex, model: model, accounts: accounts, quota: model.status.quota["codex"])
            TimelineView(.periodic(from: .now, by: 30)) { context in
                CreditBalanceView(estimate: model.status.quota["codex"], account: accounts.status(.codex), now: context.date,
                    onRefresh: { model.refreshCodexCredits() }, refreshing: model.isRefreshingCodexCredits || !model.isReady,
                    onVisibilityChanged: { model.observeCreditBalance("accounts", visible: $0) },
                    openHistory: { model.openPage(.credits) })
            }
            .bridgeCard()
            GeminiKeyCard(accounts: accounts)
            Text("You sign in through Claude Code and Codex in your browser. They keep your credentials; Agent Hub never sees or stores a password or token.")
                .font(BridgeFont.caption)
                .foregroundStyle(BridgeTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            // All account controls authenticate or manage credentials.
            AcceptanceProbe.handleSafe(note, scope: "accounts", state: {
                ["supportReason": "No safe local-only account control; authentication and keys were not touched."]
            }, exercise: { false })
        }
    }
}

struct AccountCard: View {
    var provider: LinkedProvider
    @ObservedObject var model: BridgeViewModel
    @ObservedObject var accounts: AccountsModel
    var quota: QuotaEstimate?

    private var status: ProviderAccountStatus? { accounts.status(provider) }
    private var phase: AccountLinkPhase { accounts.phase(provider) }
    private var tint: Color { BridgeTheme.color(for: provider.agent) }
    private var linked: Bool { status?.linked == true }
    private var avatarName: String { provider == .claude ? "Claude" : "Codex" }
    private var usageReadableWithoutIdentity: Bool {
        provider == .codex && quota?.credits != nil && quota?.source == .live && quota?.refreshFailedAt == nil
            && ActivityPresentationPolicy.isRecent(quota?.fetchedAt, now: Date(), within: CreditRefreshPolicy.interval + 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if phase.isActive {
                LinkFlowView(provider: provider, accounts: accounts)
            } else if case let .failed(reason) = phase {
                outcome(title: "Sign-in didn't complete", detail: reason, color: BridgeTheme.danger)
            } else if case .cancelled = phase {
                outcome(title: "Sign-in cancelled", detail: nil, color: BridgeTheme.textSecondary)
            } else if linked {
                linkedBody
            } else if usageReadableWithoutIdentity {
                infoRow("Codex is returning usage, but its sign-in identity isn't reported. You can refresh credits without signing in again.")
            } else {
                unlinkedBody
            }
        }
        .bridgeCard()
        .animation(.easeOut(duration: 0.2), value: phase)
        .animation(.easeOut(duration: 0.2), value: linked)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentAvatar(name: avatarName, size: 26, thinking: phase.isActive)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(provider.accountName)
                        .font(BridgeFont.heading)
                        .foregroundStyle(BridgeTheme.textPrimary)
                    if let plan = planLabel, linked {
                        Tag(text: plan)
                    }
                }
                Text(subtitle)
                    .font(BridgeFont.secondary)
                    .foregroundStyle(BridgeTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            statusIndicator
        }
    }

    private var planLabel: String? {
        guard let plan = status?.planName ?? quota?.planName else { return nil }
        return plan.replacingOccurrences(of: "\(provider.accountName) ", with: "") + " plan"
    }

    private var subtitle: String {
        if let email = status?.email, linked { return email }
        if status?.installed == false { return "\(provider.toolName) not found on this Mac" }
        if linked { return "Signed in via \(provider.toolName)" }
        return "\(provider.toolName)\(status?.cliVersion.map { " \($0)" } ?? "")"
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if accounts.refreshing.contains(provider) {
            ProgressView().controlSize(.small)
        } else if phase.isActive {
            StatusDot(text: "Linking", color: tint)
        } else if linked {
            StatusDot(text: status?.isSubscription == true ? "Linked" : "API billing", color: BridgeTheme.success)
        } else if usageReadableWithoutIdentity {
            StatusDot(text: "Usage readable", color: BridgeTheme.warning)
        } else if status?.installed == false {
            StatusDot(text: "Not installed", color: BridgeTheme.warning)
        } else if status == nil {
            StatusDot(text: "Checking", color: BridgeTheme.textTertiary)
        } else {
            StatusDot(text: "Not linked", color: BridgeTheme.textTertiary)
        }
    }

    /// The same pace forecast the Overview raises, shown where people manage
    /// the plan: only when a limit could run out before it resets.
    @ViewBuilder
    private func paceNotice(_ quota: QuotaEstimate, now: Date) -> some View {
        if let item = ActivityHighlights.make(.init(sessions: [], from: nil, to: now, quotas: [provider.agent: quota]))
            .first(where: { $0.kind == .planPace || $0.kind == .planLow }) {
            CalloutBanner(tone: item.tone, title: item.title, detail: item.detail, note: item.note)
        }
    }

    // MARK: Linked

    private var linkedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let quota, !quota.windows.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(quota.windows) { window in
                                UsageWindowGauge(window: window, tint: tint, now: context.date)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        paceNotice(quota, now: context.date)
                    }
                }
            } else if status?.isSubscription == false {
                infoRow("This sign-in uses API billing, so the provider does not publish plan windows here.")
            } else if let message = quota?.statusMessage, quota?.source != .live {
                infoRow(message)
            } else {
                infoRow("Plan windows load on the next usage refresh.")
            }

            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    freshnessLabel(now: context.date)
                }
                Spacer()
                Button {
                    Task { await accounts.refresh(provider) }
                    model.refreshPlanUsage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(BridgeIconButtonStyle())
                .disabled(accounts.refreshing.contains(provider) || model.isBusy)
                .help("Refresh account and plan usage")
                .accessibilityLabel("Refresh \(provider.accountName)")
                Menu {
                    Button("Unlink \(provider.accountName)…", role: .destructive) { accounts.unlink(provider) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(accounts.refreshing.contains(provider))
                .help("More")
                .accessibilityLabel("More options for \(provider.accountName)")
            }
        }
    }

    @ViewBuilder
    private func freshnessLabel(now: Date) -> some View {
        if model.status.activeAgent == provider.agent, model.status.state == .running {
            StatusDot(text: "Working now", color: tint)
        } else if let fetched = quota?.fetchedAt {
            let stale = quota?.refreshFailedAt != nil || quota?.source != .live || !ActivityPresentationPolicy.isRecent(fetched, now: now)
            StatusDot(
                text: "Usage \(stale ? "read" : "live") · \(Self.compactAge(from: fetched, to: now))",
                color: stale ? BridgeTheme.warning : BridgeTheme.success
            )
        } else {
            StatusDot(text: "No usage reading yet", color: BridgeTheme.textTertiary)
        }
    }

    static func compactAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3_600) hr ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }

    // MARK: Unlinked

    @ViewBuilder
    private var unlinkedBody: some View {
        if status?.installed == false {
            VStack(alignment: .leading, spacing: 10) {
                infoRow(status?.message ?? "\(provider.toolName) is required to use this account.")
                HStack(spacing: 8) {
                    Button("Install \(provider.toolName)") { NSWorkspace.shared.open(provider.installURL) }
                        .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                    Button("Check again") { Task { await accounts.refresh(provider) } }
                        .buttonStyle(BridgeLinkButtonStyle())
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(provider == .claude
                    ? "Link your Claude subscription so Agent Hub can run Claude Code and show and show your plan limits."
                    : "Link your ChatGPT subscription so Agent Hub can run Codex and show and show your plan limits.")
                    .font(BridgeFont.secondary)
                    .foregroundStyle(BridgeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = status?.message, status?.linked == false, !message.lowercased().contains("sign in") {
                    infoRow(message)
                }
                Button("Link \(provider.accountName)") { accounts.beginLink(provider) }
                    .buttonStyle(BridgePrimaryButtonStyle())
                    .disabled(status == nil || accounts.anyLinkInProgress || !model.isReady)
                    .keyboardShortcut(provider == .claude ? "1" : "2", modifiers: [.command, .shift])
            }
        }
    }

    private func outcome(title: String, detail: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusDot(text: title, color: color, font: BridgeFont.bodyMedium)
            if let detail {
                Text(detail).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("Try again") { accounts.beginLink(provider) }
                    .buttonStyle(BridgePrimaryButtonStyle(compact: true))
                Button("Dismiss") { accounts.dismissOutcome(provider) }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
            }
        }
    }

    private func infoRow(_ text: String) -> some View {
        Text(text)
            .font(BridgeFont.secondary)
            .foregroundStyle(BridgeTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plan window: ring, label and reset countdown in a well.
private struct UsageWindowGauge: View {
    var window: QuotaWindow
    var tint: Color
    var now: Date

    var body: some View {
        HStack(spacing: 10) {
            if ActivityPresentationPolicy.isCurrentWindow(window, now: now) {
                RingGauge(usedRatio: window.usedRatio, tint: tint, size: 40, lineWidth: 4, label: window.label)
            } else {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 28)).foregroundStyle(BridgeTheme.textTertiary)
                    .frame(width: 40, height: 40).accessibilityLabel("Current capacity not available")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(window.label)
                    .font(BridgeFont.captionMedium)
                    .foregroundStyle(BridgeTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ActivityPresentationPolicy.isCurrentWindow(window, now: now)
                     ? "\(Int(((RingGauge.remainingRatio(window.usedRatio) ?? 0) * 100).rounded()))% left" : "Refresh for a new reading")
                    .font(BridgeFont.caption)
                    .foregroundStyle(BridgeTheme.textSecondary)
                if let reset = window.resetAt {
                    HStack(spacing: 3) {
                        Text(reset > now ? "Resets in" : "Reset due")
                        Text(reset, style: .relative)
                    }
                    .font(BridgeFont.micro)
                    .foregroundStyle(BridgeTheme.textTertiary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .bridgeWell()
    }
}

/// The in-card sign-in flow. One line of state, one sentence of guidance,
/// and only the controls that apply right now.
struct LinkFlowView: View {
    var provider: LinkedProvider
    @ObservedObject var accounts: AccountsModel
    @FocusState private var codeFieldFocused: Bool

    private var phase: AccountLinkPhase { accounts.phase(provider) }
    private var tint: Color { BridgeTheme.color(for: provider.agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if case .verifying = phase {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(BridgeTheme.success)
                } else {
                    ThinkingRing(tint: tint).frame(width: 14, height: 14)
                }
                Text(title).font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
            }
            Text(detail).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if case let .awaitingBrowser(_, code?) = phase {
                deviceCode(code)
            }
            if case .awaitingCode = phase {
                codeEntry
            } else if case .awaitingBrowser = phase, provider == .claude {
                DisclosureGroup("Have a code to paste?") { codeEntry.padding(.top, 6) }
                    .font(BridgeFont.secondary)
                    .foregroundStyle(BridgeTheme.textSecondary)
            }
            HStack(spacing: 10) {
                if case .awaitingBrowser = phase {
                    Button("Open sign-in page") { accounts.openSignInPage(provider) }
                        .buttonStyle(BridgePrimaryButtonStyle(compact: true))
                } else if case .awaitingCode = phase {
                    Button("Reopen page") { accounts.openSignInPage(provider) }
                        .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                }
                Spacer()
                Button("Cancel") { accounts.cancelLink(provider) }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .bridgeWell()
    }

    private var title: String {
        switch phase {
        case .preparing: return "Starting \(provider.toolName)…"
        case .awaitingBrowser: return "Finish signing in to \(provider.accountName)"
        case .awaitingCode: return "Paste the authorization code"
        case .verifying: return "Confirming your account…"
        default: return ""
        }
    }

    private var detail: String {
        switch phase {
        case .preparing:
            return "Preparing a private sign-in session."
        case .awaitingBrowser:
            return provider.cliOpensBrowser
                ? "A browser tab should have opened. Approve access there and this card updates by itself."
                : "Your browser opened the ChatGPT sign-in. Approve access there and this card updates by itself."
        case .awaitingCode:
            return "The browser could not reach this Mac automatically. Copy the code shown on the page and paste it here."
        case .verifying:
            return "Reading the account \(provider.toolName) just linked."
        default:
            return ""
        }
    }

    private func deviceCode(_ code: String) -> some View {
        HStack(spacing: 8) {
            Text(code)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(BridgeTheme.textPrimary)
            Button { accounts.copyValue(code) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(BridgeIconButtonStyle())
                .help("Copy code")
        }
    }

    private var codeEntry: some View {
        HStack(spacing: 8) {
            TextField("Authorization code", text: $accounts.pastedCode)
                .textFieldStyle(.plain)
                .font(BridgeFont.mono)
                .foregroundStyle(BridgeTheme.textPrimary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(BridgeTheme.wellBorder, lineWidth: 1))
                .focused($codeFieldFocused)
                .onSubmit { accounts.submitPastedCode(provider) }
                .accessibilityLabel("Authorization code")
            Button("Submit") { accounts.submitPastedCode(provider) }
                .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                .disabled(accounts.pastedCode.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { codeFieldFocused = true }
    }
}

/// Gemini is not a subscription the CLIs can sign into; it is the Team Room
/// coordinator, keyed by an API key kept in the private credential file.
struct GeminiKeyCard: View {
    @ObservedObject var accounts: AccountsModel
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatar(name: "Gemini", size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gemini").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                    Text("Leads team chats · API key").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                }
                Spacer()
                StatusDot(
                    text: accounts.geminiKeyStored ? "Key saved" : "Optional",
                    color: accounts.geminiKeyStored ? BridgeTheme.success : BridgeTheme.textTertiary
                )
            }
            if editing {
                HStack(spacing: 8) {
                    SecureField("Paste a Google AI Studio key", text: $draft)
                        .textFieldStyle(.plain)
                        .font(BridgeFont.mono)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.25)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(BridgeTheme.wellBorder, lineWidth: 1))
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(BridgePrimaryButtonStyle(compact: true))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { editing = false; draft = "" }
                        .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
                }
            } else {
                HStack(spacing: 10) {
                    if let message = accounts.geminiMessage {
                        Text(message).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    Spacer()
                    Button(accounts.geminiKeyStored ? "Replace key" : "Add key") { editing = true }
                        .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                    if accounts.geminiKeyStored {
                        Button("Forget") { accounts.forgetGeminiKey() }
                            .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
                    }
                }
            }
        }
        .bridgeCard()
    }

    private func save() {
        accounts.saveGeminiKey(draft)
        draft = ""
        editing = false
    }
}
