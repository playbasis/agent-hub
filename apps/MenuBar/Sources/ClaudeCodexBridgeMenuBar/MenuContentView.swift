import AppKit
import BridgeCore
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case bridge, accounts, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bridge: return "Start"
        case .accounts: return "Accounts"
        case .activity: return "Activity"
        }
    }
}

/// A pure, narrowly scoped acceptance hook. It changes presentation only;
/// production notifications and commands for another surface are ignored.
enum PanelDisclosureAcceptance {
    struct Response { var expanded: Bool; var supported: Bool }
    static func response(name: String?, scope: String, active: Bool, expanded: Bool) -> Response? {
        guard active, scope == "panel" else { return nil }
        switch name {
        case "disclosure.open": return .init(expanded: true, supported: true)
        case "report": return .init(expanded: expanded, supported: true)
        default: return .init(expanded: expanded, supported: false)
        }
    }
}

struct MenuContentView: View {
    @ObservedObject var model: BridgeViewModel
    @ObservedObject private var windowController = MenuBarController.shared
    @State private var tokenHistoryExpanded = AcceptanceProbe.isActive

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            Group {
                if model.panelTab == .activity {
                    ActivityCompactHeader(model: model)
                } else {
                    BridgeHero(
                        model: model,
                        claudeLinked: model.accounts.isLinked(.claude) || !model.accounts.hasLoaded,
                        codexLinked: model.accounts.isLinked(.codex) || !model.accounts.hasLoaded
                    )
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                }
            }
            .overlay(alignment: .topTrailing) { detachControls }

            SegmentedTabs(
                selection: $model.panelTab,
                title: \.title,
                badge: { tab in
                    tab == .accounts && model.accounts.hasLoaded ? LinkedProvider.allCases.count - model.accounts.linkedCount : 0
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    banners
                    switch model.panelTab {
                    case .bridge: bridgeTab
                    case .accounts: AccountsView(model: model, accounts: model.accounts)
                    case .activity: activityTab
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            Hairline()
            footer
        }
        .frame(
            width: MenuBarPanelLayout.cardSize.width,
            height: MenuBarPanelLayout.cardSize.height
        )
        .liquidGlassCard(
            elevation: windowController.isDetached ? .floating : .anchored
        )
        .environment(\.colorScheme, .dark)
        .tint(Color.white.opacity(0.85))
        .padding(
            EdgeInsets(
                top: MenuBarPanelLayout.topInset,
                leading: MenuBarPanelLayout.horizontalInset,
                bottom: MenuBarPanelLayout.bottomInset,
                trailing: MenuBarPanelLayout.horizontalInset
            )
        )
        .background(PanelClearer())
        .onChange(of: model.panelTab) { tab in
            model.observeActivity("panel", visible: windowController.isPanelVisible && tab == .activity)
        }
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            guard let response = PanelDisclosureAcceptance.response(name: AcceptanceProbe.requestName(note),
                    scope: AcceptanceProbe.requestScope(note), active: AcceptanceProbe.isActive, expanded: tokenHistoryExpanded) else { return }
            tokenHistoryExpanded = response.expanded
            AcceptanceProbe.record(note, scope: "panel", state: ["expanded": String(response.expanded)], supported: response.supported)
        }
    }

    // MARK: Chrome

    private var dragHandle: some View {
        ZStack {
            DragHandle()
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 32, height: 4)
                .allowsHitTesting(false)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
        .help(windowController.isDetached ? "Drag to move" : "Drag to detach")
    }

    @ViewBuilder
    private var detachControls: some View {
        if windowController.isDetached {
            Button { windowController.reattach() } label: { Image(systemName: "pin.fill") }
                .buttonStyle(BridgeIconButtonStyle())
                .padding(.trailing, 14)
                .help("Snap back to the menu bar")
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if !model.isReady {
            NoticeBanner(
                icon: "arrow.triangle.2.circlepath",
                color: BridgeTheme.warning,
                title: "Reconnecting",
                detail: model.hydratedFromCache
                    ? "Your last session stays visible while Agent Hub reconnects."
                    : "Agent Hub is starting its background service and will connect automatically.",
                extra: model.connectionMessage,
                actionTitle: "Retry",
                action: { model.retryConnection() }
            )
        }
        if model.status.provider.state == .degraded {
            NoticeBanner(
                icon: "shield.lefthalf.filled",
                color: BridgeTheme.gemini,
                title: model.status.provider.fallbackActive ? "Using built-in routing" : "Routing assistant unavailable",
                detail: model.status.provider.message
                    ?? "Agent Hub will keep choosing the next agent with its built-in rules.",
                actionTitle: "Retry",
                action: { model.retryProvider() }
            )
        }
        if let error = model.errorMessage {
            NoticeBanner(
                icon: "exclamationmark.triangle.fill",
                color: BridgeTheme.danger,
                title: "Something needs attention",
                detail: error,
                actionTitle: "Dismiss",
                action: { model.dismissError() }
            )
        }
    }

    // MARK: Bridge tab

    @ViewBuilder
    private var bridgeTab: some View {
        if model.accounts.hasLoaded, model.accounts.linkedCount == 0 {
            onboardingCard
        }
        if let session = model.status.session,
           ![SessionState.idle, .stopped].contains(model.status.state)
        {
            activeSession(session)
        } else {
            sessionComposer
        }
        if let decision = model.status.latestDecision {
            decisionCard(decision)
        }
        glmChatLauncher
        teamRoomLauncher
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link your plans to start")
                .font(BridgeFont.heading)
                .foregroundStyle(BridgeTheme.textPrimary)
            Text("Agent Hub passes work between Claude Code and Codex using the Claude and ChatGPT plans you already have. Sign in once, in your browser.")
                .font(BridgeFont.secondary)
                .foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Link accounts") { withAnimation { model.panelTab = .accounts } }
                .buttonStyle(BridgePrimaryButtonStyle())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bridgeCard()
    }

    private var sessionComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "New session")

            Button { model.chooseProject() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BridgeTheme.textSecondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.projectPath.isEmpty ? "Choose a project" : projectName)
                            .font(BridgeFont.bodyMedium)
                            .foregroundStyle(BridgeTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.projectPath.isEmpty ? "Both agents work in this folder" : model.projectPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(BridgeFont.caption)
                            .foregroundStyle(BridgeTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BridgeTheme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .bridgeWell()
            .accessibilityHint("Opens a directory chooser")

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.goal)
                    .font(BridgeFont.body)
                    .foregroundStyle(BridgeTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 76)
                    .padding(6)
                    .accessibilityLabel("Session goal")
                if model.goal.isEmpty {
                    Text("What should Claude and Codex get done?")
                        .font(BridgeFont.body)
                        .foregroundStyle(BridgeTheme.textTertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .bridgeWell()

            HStack(spacing: 8) {
                Menu {
                    ForEach([60, 120, 240, 360, 480, 720], id: \.self) { minutes in
                        Button(durationLabel(minutes)) { model.durationMinutes = minutes; model.persistPreferences() }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 10, weight: .medium))
                        Text(durationLabel(model.durationMinutes))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(BridgeFont.secondaryMedium)
                    .foregroundStyle(BridgeTheme.textPrimary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BridgeTheme.control))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Time limit for this session")
                Spacer()
                Text("Start with")
                    .font(BridgeFont.caption)
                    .foregroundStyle(BridgeTheme.textTertiary)
                AgentToggle(selection: $model.startingAgent)
            }

            if !model.projectPath.isEmpty {
                HStack(spacing: 6) {
                    StatusDot(
                        text: model.hooksInstalled ? "Claude is connected to this project" : "Claude isn't connected to this project yet",
                        color: model.hooksInstalled ? BridgeTheme.success : BridgeTheme.textTertiary
                    )
                    Spacer()
                    if !model.hooksInstalled {
                        Button("Connect") { model.installHooks() }
                            .buttonStyle(BridgeLinkButtonStyle())
                    }
                }
            }

            Button { model.startSession() } label: {
                HStack(spacing: 6) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text("Start session")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(BridgePrimaryButtonStyle())
            .disabled(!model.canStart)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .bridgeCard()
    }

    private func durationLabel(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    private func activeSession(_ session: RuntimeSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Current goal")
                Spacer()
                Button { model.openProject() } label: { Image(systemName: "arrow.up.forward") }
                    .buttonStyle(BridgeIconButtonStyle())
                    .help("Open project")
            }
            Text(session.goal)
                .font(BridgeFont.body)
                .foregroundStyle(BridgeTheme.textPrimary)
                .lineLimit(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                StatusDot(
                    text: model.status.activeAgent == .none
                        ? model.status.state.rawValue.capitalized
                        : "\(model.status.activeAgent.rawValue.capitalized) active",
                    color: model.statusColor
                )
                Tag(text: "Step \(session.turnCount)")
                Tag(text: URL(fileURLWithPath: session.projectPath).lastPathComponent)
                Spacer()
            }
            HStack(spacing: 8) {
                if [.running, .thinking].contains(model.status.state) {
                    Button("Pause") { model.pauseSession() }
                        .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                } else if [.paused, .parked].contains(model.status.state) {
                    Button("Resume") { model.resumeSession() }
                        .buttonStyle(BridgePrimaryButtonStyle(compact: true))
                }
                Menu {
                    Button("Hand off to Claude") { model.forceHandoff(to: .claude) }
                    Button("Hand off to Codex") { model.forceHandoff(to: .codex) }
                } label: {
                    HStack(spacing: 4) {
                        Text("Hand off")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(BridgeFont.secondaryMedium)
                    .foregroundStyle(BridgeTheme.textPrimary)
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: BridgeTheme.radiusControl, style: .continuous).fill(BridgeTheme.control))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Button("Stop") { model.stopSession() }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.danger))
            }
            .disabled(model.isBusy || !model.isReady)
        }
        .bridgeCard()
    }

    private func decisionCard(_ decision: Decision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Why this agent", icon: "arrow.triangle.branch")
                Spacer()
                Text("\(Int(decision.confidence * 100))% sure")
                    .font(BridgeFont.caption.monospacedDigit())
                    .foregroundStyle(BridgeTheme.textTertiary)
            }
            HStack(spacing: 6) {
                Tag(text: decision.label.rawValue.capitalized)
                Tag(text: decision.action.rawValue.capitalized)
                if decision.nextAgent != .none {
                    StatusDot(text: "Next: \(decision.nextAgent.rawValue.capitalized)", color: BridgeTheme.color(for: decision.nextAgent))
                }
            }
            Text(decision.reason)
                .font(BridgeFont.secondary)
                .foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .bridgeCard()
    }

    private var teamRoomLauncher: some View {
        Button { model.openPage(.teamChat) } label: {
            HStack(spacing: 10) {
                HStack(spacing: -6) {
                    AgentAvatar(name: "Claude", size: 18)
                    AgentAvatar(name: "Codex", size: 18)
                    AgentAvatar(name: "Gemini", size: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Team Chat").font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
                    Text("Plan and build with Claude, Codex and Gemini").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BridgeTheme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .bridgeCard(padding: 12)
        .help("Open the team lobby window")
    }

    private var glmChatLauncher: some View {
        Button { model.openPage(.glmChat) } label: {
            HStack(spacing: 10) {
                ZaiMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GLM Chat").font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
                    Text("Talk with GLM-5.3 Flash").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BridgeTheme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .bridgeCard(padding: 12)
        .help("Open a direct chat with DigitalOcean Inference")
    }

    // MARK: Activity tab

    @ViewBuilder
    private var activityTab: some View {
        ActivityHUDView(model: model)
        DisclosureGroup("Token history & provider proof", isExpanded: $tokenHistoryExpanded) {
            TokenActivityChart(
                snapshot: model.tokenSeries,
                isBusy: model.isBusy || model.isRefreshingActivity || model.isProjectingTokenSeries,
                isReady: model.isReady,
                onRefresh: { model.refreshTokenSeries() }
            )
            .acceptanceProbe("panel.token-chart")
            providerProof
        }
        .font(BridgeFont.caption)
        .foregroundStyle(BridgeTheme.textSecondary)
    }

    private var providerProof: some View {
        navigationRow(
            icon: model.traceSummary?.dualProviderVerified == true ? "checkmark.seal.fill" : "checkmark.seal",
            iconColor: model.traceSummary?.dualProviderVerified == true ? BridgeTheme.success : BridgeTheme.textSecondary,
            title: model.traceSummary?.dualProviderVerified == true ? "Dual-provider verified" : "Provider proof",
            subtitle: providerProofSubtitle,
            action: { model.openProviderProof() }
        )
        .accessibilityHint("Opens provider identities, token usage, tool receipts, and audit status")
    }

    private func navigationRow(icon: String, iconColor: Color = BridgeTheme.textSecondary, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
                    Text(subtitle).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .bridgeCard(padding: 12)
    }

    private var providerProofSubtitle: String {
        guard let summary = model.traceSummary, summary.records > 0 else {
            return "No trace receipts yet"
        }
        let tokens = summary.totalTokens.flatMap { $0 >= 0 ? $0 : nil }.map { "\(summary.completeness == .complete ? "" : "≥")\($0.formatted()) known trace tokens" } ?? "trace usage unavailable"
        return "Bridge-managed trace only · \(summary.records) receipts · \(tokens)"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button { model.openLogs() } label: { Label("Logs", systemImage: "doc.text") }
                .buttonStyle(.plain)
            Button {
                model.openPage(.settings)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button(model.isShuttingDown ? "Closing…" : "Quit") { model.requestQuit() }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
                .disabled(model.isShuttingDown)
        }
        .font(BridgeFont.secondary)
        .foregroundStyle(BridgeTheme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var projectName: String {
        URL(fileURLWithPath: model.projectPath).lastPathComponent
    }
}

/// Compact two-way switch for the starting agent.
struct AgentToggle: View {
    @Binding var selection: AgentName

    var body: some View {
        HStack(spacing: 2) {
            ForEach([AgentName.claude, .codex], id: \.self) { agent in
                let selected = selection == agent
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = agent } } label: {
                    HStack(spacing: 5) {
                        Circle().fill(BridgeTheme.color(for: agent)).frame(width: 6, height: 6)
                        Text(agent.rawValue.capitalized)
                            .font(BridgeFont.secondaryMedium)
                            .foregroundStyle(selected ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.10) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start with \(agent.rawValue.capitalized)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(BridgeTheme.wellBorder, lineWidth: 1))
        .help("Which agent takes the first turn")
    }
}

struct NoticeBanner: View {
    var icon: String
    var color: Color
    var title: String
    var detail: String
    var extra: String? = nil
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
                Text(detail).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let extra, !extra.isEmpty {
                    Text(extra).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(3)
                }
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .buttonStyle(BridgeLinkButtonStyle())
        }
        .bridgeCard(padding: 12)
    }
}
