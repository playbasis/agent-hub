import AppKit
import BridgeCore
import Foundation
import SwiftUI

enum RuntimeConnectionPhase: Equatable {
    case hydrating
    case connected
    case reconnecting(attempt: Int)
    case unavailable
    case shuttingDown
}

@MainActor
final class BridgeViewModel: ObservableObject {
    @Published var status: BridgeStatus
    @Published var projectPath: String
    @Published var goal = ""
    @Published var durationMinutes: Int
    @Published var startingAgent: AgentName
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var hooksInstalled = false
    @Published private(set) var connectionPhase: RuntimeConnectionPhase = .hydrating
    @Published private(set) var connectionMessage: String?
    @Published private(set) var hydratedFromCache = false
    @Published private(set) var isShuttingDown = false
    @Published private(set) var isQuitRequested = false
    @Published private(set) var traceSummary: TraceSummary?
    @Published private(set) var tokenSeries: TokenSeriesSnapshot = .empty
    @Published private(set) var activityInsight: ActivityInsight?
    @Published private(set) var activityOverview: ActivityOverview = .empty {
        didSet {
            activityRevision &+= 1
            projectCanonicalTokenSeries()
            guard !isRestoringActivity else { return }
            isShowingSavedActivity = false
            activitySnapshot?.save(activityOverview)
        }
    }
    /// True while pages show the snapshot saved at the last launch, until the
    /// runtime's own snapshot replaces it.
    @Published private(set) var isShowingSavedActivity = false
    private(set) var activityRevision: UInt64 = 0
    private var isRestoringActivity = false
    private let activitySnapshot: ActivitySnapshotCache?
    @Published private(set) var isRefreshingActivity = false
    @Published private(set) var isRefreshingCodexCredits = false
    @Published private(set) var isProjectingTokenSeries = false
    @Published private(set) var activityError: String?
    let dailyBrief = DailyBriefModel()
    @Published private(set) var isAnalyzingRepositories = false
    @Published var claudeModel = "sonnet"
    @Published var claudeEffort = "high"
    @Published var codexModel = "gpt-5.6-sol"
    @Published var codexReasoningEffort = "high"
    @Published var grokModel = MetaConfiguration.grokModel
    @Published var grokReasoningEffort = "high"
    @Published var requireThreeProvider = false
    @Published var requireDualProvider = true
    @Published var tokenCeilingText = ""
    @Published var turnReservationText = ""
    @Published private(set) var settingsRestartRequired = false
    @Published var panelTab: PanelTab = .activity
    /// Linked subscriptions and their in-place sign-in flows.
    let accounts = AccountsModel()
    private var lastAccountsRefresh: Date?

    private var configuration: BridgeConfiguration?
    private var client: BridgeAPIClient?
    @Published private(set) var runtimeClientID: UUID?
    private weak var workspaceController: ActivityReportsController?
    // A configured URL is not a ready service. Pages must wait for a status
    // acknowledgement, including when Journal is restored during cold start.
    var runtimeClient: BridgeAPIClient? { isReady ? client : nil }
    private var ownedRuntime: BridgeRuntime?
    private var bootstrapTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var tokenSeriesTask: Task<Void, Never>?
    private var tokenProjectionTask: Task<Void, Never>?
    private var publishedAccountingRevision: UInt64 = 0
    private let projectActivityWhileHidden: Bool
    private var wantsHUDProjection: Bool { projectActivityWhileHidden || activityConsumers.contains("panel") }
    private var activityRefreshTask: Task<Void, Never>?
    private var activityPollingTask: Task<Void, Never>?
    private var activityOperationTask: Task<Void, Never>?
    private var journalPublishTask: Task<Void, Never>?
    private var activityConsumers: Set<String> = []
    private var creditConsumers: Set<String> = []
    private var codexCreditRefreshTask: Task<Void, Never>?
    private var codexCreditRefreshGeneration: UUID?
    private var isAutomaticCreditRefresh = false
    private var lastCodexCreditRefreshAttempt: Date?
    private var activityMutationRevision: UInt64 = 0
    private var quitTask: Task<Void, Never>?
    private var isConnecting = false
    private(set) var hasCompletedShutdown = false
    private var reconnectAttempt = 0
    private let statusCacheKey = "lastBridgeStatus.v1"
    /// Plan usage is polled far more slowly than status: reading Claude costs a
    /// full CLI launch, so it runs once on connect and then on a long interval.
    private var lastPlanUsageRefresh: Date?
    private let planUsageRefreshInterval: TimeInterval = 900
    /// The token ledger is cheap after its first pass — only appended transcript
    /// bytes are read — so it can refresh far more often than plan usage.
    private var lastTokenSeriesRefresh: Date?
    private let tokenSeriesRefreshInterval: TimeInterval = 120

    init(automaticallyConnect: Bool = true, workspaceController: ActivityReportsController? = nil,
         activitySnapshot: ActivitySnapshotCache? = nil, eagerActivityProjection: Bool? = nil) {
        projectActivityWhileHidden = eagerActivityProjection ?? (!automaticallyConnect && !AcceptanceProbe.isActive)
        self.workspaceController = workspaceController ?? .shared
        // Tests construct models without connecting; they never touch the
        // person's saved snapshot unless one is injected.
        self.activitySnapshot = activitySnapshot ?? (automaticallyConnect && !AcceptanceProbe.isActive ? .standard : nil)
        let defaults = AcceptanceProbe.defaults
        if let cached = defaults.data(forKey: statusCacheKey),
           let decoded = try? BridgeJSON.decoder.decode(BridgeStatus.self, from: cached)
        {
            status = decoded
            hydratedFromCache = true
        } else {
            status = BridgeStatus(
                state: .idle,
                activeAgent: .none,
                session: nil,
                latestDecision: nil,
                quota: [:]
            )
        }
        projectPath = defaults.string(forKey: "projectPath") ?? ""
        durationMinutes = defaults.object(forKey: "durationMinutes") as? Int ?? 240
        startingAgent = AgentName(
            rawValue: defaults.string(forKey: "startingAgent") ?? "claude"
        ) ?? .claude
        TeamRoomController.shared.openInReports = { [weak self] in self?.openPage(.teamChat) }
        GLMChatController.shared.openInReports = { [weak self] in self?.openPage(.glmChat) }
        LogViewerController.shared.showHandler = { [weak self] in self?.openPage(.logs) }
        LogViewerController.shared.closeHandler = { [weak self] in self?.openPage(.overview) }
        ProviderProofController.shared.openInReports = { [weak self] in self?.openPage(.providerProof) }
        if automaticallyConnect {
            bootstrapTask = Task { [weak self] in
                await self?.bootstrap()
            }
        }
        if let snapshot = self.activitySnapshot {
            Task { [weak self] in
                guard let saved = await snapshot.load() else { return }
                self?.restoreSavedActivity(saved)
            }
        }
    }

    /// Paints the last saved snapshot while the runtime starts. Anything the
    /// runtime has already delivered wins.
    func restoreSavedActivity(_ saved: ActivityOverview) {
        guard !isShuttingDown, activityOverview.generatedAt == .distantPast,
              ActivitySnapshotCache.isValidSnapshotDate(saved.generatedAt) else { return }
        isRestoringActivity = true
        activityOverview = saved
        isRestoringActivity = false
        isShowingSavedActivity = true
    }

    /// A startup paint is not an authoritative source. The first usable runtime
    /// read replaces it even if the durable runtime snapshot is older. Once a
    /// runtime read has been accepted, normal monotonic/revision guards apply.
    @discardableResult
    func acceptRuntimeActivity(_ incoming: ActivityOverview, requestRevision: UInt64? = nil) -> Bool {
        guard !isShuttingDown, ActivitySnapshotCache.isValidSnapshotDate(incoming.generatedAt),
              requestRevision == nil || requestRevision == activityMutationRevision else { return false }
        guard isShowingSavedActivity || incoming.generatedAt >= activityOverview.generatedAt else { return false }
        if incoming == activityOverview {
            // A poll can return the same durable snapshot. Do not rebuild all
            // report projections or enqueue another full startup-cache model.
            isShowingSavedActivity = false
            return true
        }
        activityOverview = incoming
        return true
    }

    deinit {
        bootstrapTask?.cancel()
        connectionTask?.cancel()
        operationTask?.cancel()
        pollingTask?.cancel()
        tokenSeriesTask?.cancel()
        tokenProjectionTask?.cancel()
        activityRefreshTask?.cancel()
        activityPollingTask?.cancel()
        activityOperationTask?.cancel()
        journalPublishTask?.cancel()
        codexCreditRefreshTask?.cancel()
    }

    var iconName: String {
        switch connectionPhase {
        case .hydrating:
            return "arrow.triangle.2.circlepath"
        case .reconnecting, .unavailable:
            return "wifi.exclamationmark"
        case .shuttingDown:
            return "power"
        case .connected:
            break
        }
        return switch status.state {
        case .idle: "point.3.connected.trianglepath.dotted"
        case .thinking: "sparkles"
        case .running:
            switch status.activeAgent {
            case .claude: "c.circle.fill"
            case .codex: "terminal.fill"
            case .grok: "bolt.horizontal.circle.fill"
            case .none: "point.3.connected.trianglepath.dotted"
            }
        case .paused: "pause.circle.fill"
        case .parked: "hourglass.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .complete: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    var statusLabel: String {
        switch connectionPhase {
        case .hydrating:
            return hydratedFromCache ? "Restoring Agent Hub" : "Starting Agent Hub"
        case .reconnecting:
            return "Reconnecting…"
        case .unavailable:
            return "Agent Hub needs attention"
        case .shuttingDown:
            return "Closing safely…"
        case .connected:
            break
        }
        return switch status.state {
        case .idle: "Ready"
        case .thinking: "Choosing the next agent"
        case .running: "\(status.activeAgent.rawValue.capitalized) active"
        case .paused: "Session paused"
        case .parked: "Waiting for quota"
        case .error: "Needs attention"
        case .complete: "Goal complete"
        case .stopped: "Session stopped"
        }
    }

    var statusColor: Color {
        switch connectionPhase {
        case .hydrating, .reconnecting:
            return .orange
        case .unavailable:
            return .red
        case .shuttingDown:
            return .secondary
        case .connected:
            break
        }
        return switch status.state {
        case .idle, .stopped: .secondary
        case .thinking: .purple
        case .running:
            switch status.activeAgent {
            case .claude: .orange
            case .codex: .blue
            case .grok: .pink
            case .none: .secondary
            }
        case .paused: .yellow
        case .parked: .indigo
        case .error: .red
        case .complete: .green
        }
    }

    var isReady: Bool {
        connectionPhase == .connected
    }

    var connectionLabel: String {
        switch connectionPhase {
        case .hydrating:
            return hydratedFromCache ? "Restoring your last session…" : "Starting Agent Hub…"
        case .connected:
            return "Ready"
        case let .reconnecting(attempt):
            return "Reconnecting… (try \(attempt))"
        case .unavailable:
            return "Agent Hub isn't responding"
        case .shuttingDown:
            return "Pausing active work and closing…"
        }
    }

    var connectionColor: Color {
        switch connectionPhase {
        case .connected: .green
        case .hydrating, .reconnecting: .orange
        case .unavailable: .red
        case .shuttingDown: .secondary
        }
    }

    var providerStatusLabel: String {
        switch status.provider.state {
        case .checking:
            return "Checking \(status.provider.provider)"
        case .ready:
            return "\(status.provider.provider.capitalized) ready"
        case .degraded:
            return status.provider.fallbackActive
                ? "Rules fallback active"
                : "\(status.provider.provider.capitalized) unavailable"
        }
    }

    var canStart: Bool {
        let terminalStates: [SessionState] = [.idle, .complete, .stopped, .error]
        return isReady
            && !isBusy
            && !projectPath.isEmpty
            && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && terminalStates.contains(status.state)
    }

    var remainingText: String? {
        guard let deadline = status.session?.deadline else { return nil }
        let seconds = max(0, Int(deadline.timeIntervalSinceNow))
        return Duration.seconds(seconds).formatted(
            .time(pattern: .hourMinute(padHourToLength: 1))
        )
    }

    var classifierLabel: String {
        switch configuration?.meta.provider {
        case .rules, .none: "Rules (on-device)"
        case .ollama: "Ollama (on-device)"
        case .grokCLI:
            "Grok · \(configuration?.meta.model ?? MetaConfiguration.grokModel)"
        case .openAICompatible:
            configuration?.meta.coordinatorIdentifier == "gemini"
                ? "Gemini (legacy) · \(configuration?.meta.model ?? "remote")"
                : "Remote compatible API (legacy)"
        }
    }

    var codexSandboxLabel: String {
        switch configuration?.agents.codexSandbox ?? "workspace-write" {
        case "workspace-write": return "Can edit files in the project folder"
        case "read-only": return "Read-only"
        case let other: return other.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    var claudePermissionLabel: String {
        switch configuration?.agents.claudePermissionMode ?? "acceptEdits" {
        case "acceptEdits": return "Can edit files; asks before other actions"
        case "plan": return "Plans only; makes no changes"
        case "default": return "Asks before every change"
        case let other: return other
        }
    }

    func bootstrap() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        do {
            let configuration = try ConfigurationStore.load(create: !AcceptanceProbe.isActive)
            guard !isShuttingDown, !Task.isCancelled else { return }
            self.configuration = configuration
            claudeModel = configuration.agents.claudeModel
            claudeEffort = configuration.agents.claudeEffort
            codexModel = configuration.agents.codexModel
            codexReasoningEffort = configuration.agents.codexReasoningEffort
            grokModel = configuration.agents.grokModel
            grokReasoningEffort = configuration.agents.grokReasoningEffort
            requireThreeProvider = configuration.trace.requireThreeProvider
            requireDualProvider = configuration.trace.requireDualProvider
            tokenCeilingText = configuration.trace.totalTokenCeiling.map(String.init) ?? ""
            turnReservationText = configuration.trace.perTurnTokenReservation.map(String.init) ?? ""
            if projectPath.isEmpty, let recent = configuration.recentProjects.first {
                projectPath = recent
            }
            // Do not probe a persisted project during launch. On macOS even a
            // harmless existence/read check can produce a Files & Folders
            // prompt for Desktop, Documents, or Downloads. The hook state is
            // checked after the user explicitly chooses a project.
            hooksInstalled = false
            let client = BridgeAPIClient(configuration: configuration)
            self.client = client
            accounts.configure(configuration)
            accounts.onLinked = { [weak self] _ in
                // A fresh link means fresh plan windows; read them now rather
                // than waiting for the 15-minute schedule.
                self?.lastPlanUsageRefresh = nil
                self?.refreshPlanUsage()
            }
            if !AcceptanceProbe.isActive { Task { [accounts] in await accounts.refreshAll() } }
            await connectOrRecover(initial: true)
            guard !isShuttingDown, !Task.isCancelled else { return }
            startPolling()
            if !activityConsumers.isEmpty { refreshActivity(force: false) }
        } catch {
            guard !isShuttingDown else { return }
            connectionPhase = .unavailable
            connectionMessage = error.localizedDescription
            present(error)
        }
    }

    /// Called each time the panel opens. Account state is cheap to read, so
    /// it is re-checked after a minute of staleness — e.g. after the user
    /// signed out in a terminal.
    func panelDidOpen() {
        guard !isShuttingDown else { return }
        if let last = lastAccountsRefresh, Date().timeIntervalSince(last) < 60 { return }
        lastAccountsRefresh = Date()
        Task { [accounts] in await accounts.refreshAll() }
    }

    func refresh() async {
        guard !isShuttingDown, let client else { return }
        do {
            accept(try await client.status())
            let summary = try? await client.traceSummary()
            if summary != traceSummary { traceSummary = summary }
        } catch {
            markDisconnected(error)
        }
    }

    func retryConnection() {
        guard !isShuttingDown else { return }
        connectionPhase = .hydrating
        connectionMessage = nil
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            await self?.connectOrRecover(initial: false)
        }
    }

    func retryProvider() {
        perform { [self] in
            guard let client = self.client else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            self.accept(try await client.retryProvider())
        }
    }

    func refreshPlanUsage() {
        perform { [self] in
            guard let client = self.client else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            self.accept(try await client.refreshPlanUsage())
        }
    }

    /// Refresh the signed-in Codex account only, never Claude or model work.
    func refreshCodexCredits() {
        startCodexCreditsRefresh(automatic: false)
    }

    var hasVisibleCreditSurface: Bool {
        let workspace = workspaceController ?? .shared
        return CreditRefreshPolicy.hasVisibleSurface(
            registered: creditConsumers,
            hubVisible: workspace.isCreditSurfaceExposed,
            hubPage: workspace.page,
            panelVisible: MenuBarController.shared.isCreditSurfaceExposed,
            panelShowsCredits: panelTab == .activity
        )
    }

    /// A SwiftUI registration is interest only; actual AppKit window exposure
    /// is checked again on each status tick before starting a provider read.
    func observeCreditBalance(_ consumer: String, visible: Bool) {
        guard ["accounts", "overview", "credits", "panel"].contains(consumer) else { return }
        if visible { creditConsumers.insert(consumer) }
        else { creditConsumers.remove(consumer) }
        refreshCodexCreditsIfStale()
    }

    private func refreshCodexCreditsIfStale() {
        if !hasVisibleCreditSurface || (accounts.status(.codex)?.isSubscription != true && status.quota[AgentName.codex.rawValue]?.credits == nil) {
            if isAutomaticCreditRefresh { cancelCodexCreditsRefresh() }
            return
        }
        let identity = accounts.status(.codex)?.creditAccountIdentityHash
        let reading = status.quota[AgentName.codex.rawValue]
        guard CreditRefreshPolicy.shouldRefresh(
            now: Date(), isVisible: true, isReady: isReady && !isShuttingDown,
            isRefreshing: isRefreshingCodexCredits,
            lastAttemptAt: lastCodexCreditRefreshAttempt,
            estimate: reading?.accountIdentityHash == identity ? reading : nil
        ) else { return }
        startCodexCreditsRefresh(automatic: true)
    }

    private func startCodexCreditsRefresh(automatic: Bool) {
        guard !AcceptanceProbe.isActive, !isShuttingDown, isReady,
              codexCreditRefreshTask == nil, let client else { return }
        let generation = UUID()
        codexCreditRefreshGeneration = generation
        isAutomaticCreditRefresh = automatic
        lastCodexCreditRefreshAttempt = Date()
        isRefreshingCodexCredits = true
        codexCreditRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.codexCreditRefreshGeneration == generation {
                    self.codexCreditRefreshTask = nil
                    self.codexCreditRefreshGeneration = nil
                    self.isAutomaticCreditRefresh = false
                    self.isRefreshingCodexCredits = false
                }
            }
            do {
                let reading = try await client.refreshCodexUsage()
                guard !Task.isCancelled, !self.isShuttingDown,
                      self.codexCreditRefreshGeneration == generation else { return }
                self.accept(reading)
            } catch {
                guard !Task.isCancelled, !self.isShuttingDown,
                      self.codexCreditRefreshGeneration == generation else { return }
                // Transport failure is also a failed refresh, not confirmation
                // that a previously cached balance is still current.
                var estimate = self.status.quota[AgentName.codex.rawValue] ?? QuotaEstimate(agent: .codex)
                estimate.refreshFailedAt = Date()
                estimate.statusMessage = "Codex credits did not refresh. Last reading retained."
                self.status.quota[AgentName.codex.rawValue] = estimate
            }
        }
    }

    private func cancelCodexCreditsRefresh() {
        codexCreditRefreshGeneration = nil
        codexCreditRefreshTask?.cancel()
        codexCreditRefreshTask = nil
        isAutomaticCreditRefresh = false
        isRefreshingCodexCredits = false
    }

    func startSession() {
        perform { [self] in
            guard let client = self.client else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            self.persistPreferences()
            let request = try SessionRequest(
                projectPath: self.projectPath,
                goal: self.goal,
                durationMinutes: self.durationMinutes,
                startingAgent: self.startingAgent
            )
            _ = try await client.start(request)
            self.goal = ""
        }
    }

    func pauseSession() {
        perform { [self] in
            guard let client = self.client else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            _ = try await client.pause()
        }
    }

    func resumeSession() {
        perform { [self] in
            guard let client = self.client else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            _ = try await client.resume()
        }
    }

    func stopSession() {
        perform { [self] in
            guard let client = self.client else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            _ = try await client.stop()
        }
    }

    func forceHandoff(to agent: AgentName) {
        perform { [self] in
            guard let client = self.client else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            _ = try await client.handoff(
                agent: agent,
                reason: "Manual override from the menu-bar app"
            )
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project"
        panel.message = "The bridge keeps its shared context inside this directory."
        panel.prompt = "Choose Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.standardizedFileURL.path
            persistPreferences()
            hooksInstalled = hasInstalledHooks(projectPath: projectPath)
        }
    }

    func installHooks() {
        guard !AcceptanceProbe.isActive else { return }
        do {
            guard let configuration else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            _ = try HookInstaller.install(
                projectPath: projectPath,
                configuration: configuration
            )
            hooksInstalled = true
            errorMessage = nil
        } catch {
            present(error)
        }
    }

    func openProject() {
        guard !projectPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: projectPath))
    }

    func openLogs() {
        openPage(.logs)
    }

    func openProviderProof() {
        openPage(.providerProof)
    }

    func openActivityReports(sessionID: String? = nil) {
        (workspaceController ?? .shared).show(model: self, page: sessionID == nil ? .overview : nil, sessionID: sessionID)
    }

    func reopenWorkspace() { (workspaceController ?? .shared).show(model: self) }

    func openPage(_ page: BridgePage) { (workspaceController ?? .shared).show(model: self, page: page) }

    /// Collection can take seconds; it must never block the runtime's status loop.
    func observeActivity(_ consumer: String, visible: Bool) {
        if visible { activityConsumers.insert(consumer) }
        else { activityConsumers.remove(consumer) }
        if consumer == "panel" {
            if visible { projectCanonicalTokenSeries() }
            else if !projectActivityWhileHidden { activityInsight = nil }
        }
        guard !activityConsumers.isEmpty, !isShuttingDown else {
            activityPollingTask?.cancel()
            activityPollingTask = nil
            return
        }
        // The acceptance runner owns its explicit refresh cycles. A second
        // timer would move the target dataset while it measures readiness.
        if AcceptanceProbe.isActive {
            if !RefreshAcceptance.isReplayMode && activityOverview.generatedAt == .distantPast { refreshActivity(force: false) }
            return
        }
        guard activityPollingTask == nil else { return }
        refreshActivity(force: false)
        activityPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
                self.refreshActivity()
            }
        }
    }

    func refreshActivity(force: Bool = true) {
        guard !isShuttingDown, activityRefreshTask == nil, activityOperationTask == nil, let client else { return }
        let revision = activityMutationRevision
        isRefreshingActivity = true
        activityError = nil
        activityRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshingActivity = false; self.activityRefreshTask = nil }
            do {
                // Hydrate durable receipts first so opening the HUD is immediate.
                // Once the runtime's own snapshot is showing, that read would
                // only transfer and decode the same snapshot a second time.
                var latest = self.activityOverview.generatedAt
                if self.isShowingSavedActivity || latest == .distantPast {
                    let cached = try await self.readActivity(client: client, refresh: false)
                    guard !Task.isCancelled, !self.isShuttingDown else { return }
                    self.acceptRuntimeActivity(cached, requestRevision: revision)
                    latest = cached.generatedAt
                }
                if force || Date().timeIntervalSince(latest) > 60 {
                    let fresh = try await self.readActivity(client: client, refresh: true)
                    guard !Task.isCancelled, !self.isShuttingDown else { return }
                    self.acceptRuntimeActivity(fresh, requestRevision: revision)
                }
            } catch {
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.activityError = error.localizedDescription
            }
        }
    }

    /// The runtime this app hosts hands over its snapshot directly; encoding
    /// and decoding it as JSON cost seconds of CPU a minute. A runtime owned by
    /// another process is read over HTTP as before.
    private func readActivity(client: BridgeAPIClient, refresh: Bool) async throws -> ActivityOverview {
        if let runtime = ownedRuntime {
            let service = ActivityReportingService.shared
            return refresh ? try await service.refresh(configuration: runtime.configuration.agents, force: true) : try await service.overview()
        }
        return refresh ? try await client.refreshActivity() : try await client.activity()
    }

    func pinActivity(_ sessionID: String?) {
        guard !isShuttingDown, activityOperationTask == nil, let client else { return }
        activityMutationRevision &+= 1
        activityError = nil
        activityOperationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activityOperationTask = nil }
            do {
                let updated = try await client.pinActivity(sessionID: sessionID)
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.acceptRuntimeActivity(updated)
            } catch { if !Task.isCancelled { self.activityError = error.localizedDescription } }
        }
    }

    func analyzeActivityRepositories() {
        guard !isShuttingDown, activityOperationTask == nil, let client else { return }
        activityMutationRevision &+= 1
        activityError = nil
        isAnalyzingRepositories = true
        activityOperationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isAnalyzingRepositories = false; self.activityOperationTask = nil }
            do {
                let updated = try await client.activityRepositories()
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.acceptRuntimeActivity(updated)
            } catch { if !Task.isCancelled { self.activityError = error.localizedDescription } }
        }
    }

    func loadActivityJournal() async {
        guard !isShuttingDown, isReady else { return }
        await dailyBrief.load()
    }

    /// Publish one identity per usable connection, not per status poll. A new
    /// identity restarts visible-page reads after startup or reconnection and
    /// invalidates any late response from the preceding connection.
    func bindReadyRuntimeClient(_ readyClient: BridgeAPIClient) {
        let newConnection = !isReady || runtimeClientID == nil
        client = readyClient
        if newConnection {
            let id = UUID()
            dailyBrief.connect(client: readyClient, id: id)
            runtimeClientID = id
        }
        if connectionPhase != .connected { connectionPhase = .connected }
    }

    func publishActivityJournal() {
        guard !AcceptanceProbe.isActive else { return }
        guard !isShuttingDown, journalPublishTask == nil else { return }
        journalPublishTask = Task { [weak self] in
            guard let self else { return }
            defer { self.journalPublishTask = nil }
            await self.dailyBrief.publish()
        }
    }

    func reportActivityExportError(_ error: Error) { activityError = error.localizedDescription }

    func persistPreferences() {
        guard !AcceptanceProbe.isActive else { return }
        let defaults = AcceptanceProbe.defaults
        defaults.set(projectPath, forKey: "projectPath")
        defaults.set(durationMinutes, forKey: "durationMinutes")
        defaults.set(startingAgent.rawValue, forKey: "startingAgent")
    }

    func persistProviderSettings() {
        guard !AcceptanceProbe.isActive else { return }
        do {
            guard var updated = configuration else {
                throw BridgeError.configuration("Runtime is not ready")
            }
            let cleanedClaude = claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedCodex = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedGrok = grokModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedClaude.isEmpty, !cleanedCodex.isEmpty, !cleanedGrok.isEmpty else {
                throw BridgeError.invalidRequest("Provider model names cannot be empty.")
            }
            let ceiling = try positiveInteger(tokenCeilingText, label: "Token ceiling")
            let reservation = try positiveInteger(
                turnReservationText,
                label: "Turn reservation"
            )
            guard ceiling == nil || reservation != nil else {
                throw BridgeError.invalidRequest(
                    "A token ceiling requires a positive per-turn reservation."
                )
            }
            updated.agents.claudeModel = cleanedClaude
            updated.agents.claudeEffort = claudeEffort
            updated.agents.codexModel = cleanedCodex
            updated.agents.codexReasoningEffort = codexReasoningEffort
            updated.agents.grokModel = cleanedGrok
            updated.agents.grokReasoningEffort = grokReasoningEffort
            // `agents.grok*` is the third coding agent; `meta.*` is the
            // coordinator. They are configured separately, so saving agent
            // identity must leave the configured coordinator untouched.
            updated.trace.requireThreeProvider = requireThreeProvider
            updated.trace.requireDualProvider = requireDualProvider
            updated.trace.totalTokenCeiling = ceiling
            updated.trace.perTurnTokenReservation = reservation
            try ConfigurationStore.save(updated)
            configuration = updated
            settingsRestartRequired = true
            errorMessage = nil
        } catch {
            present(error)
        }
    }

    private func positiveInteger(_ raw: String, label: String) throws -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard let value = Int(cleaned), value > 0 else {
            throw BridgeError.invalidRequest("\(label) must be a positive integer.")
        }
        return value
    }

    func dismissError() {
        errorMessage = nil
    }

    func requestQuit() {
        guard quitTask == nil, beginQuitRequest() else { return }
        // Set synchronously, before the shutdown Task gets a run-loop turn.
        // A concurrent relaunch must not mistake a queued quit for readiness.
        quitTask = Task { [weak self] in
            guard let self else { return }
            await shutdown()
            NSApplication.shared.terminate(nil)
        }
    }

    @discardableResult
    func beginQuitRequest() -> Bool {
        guard !isQuitRequested, !hasCompletedShutdown else { return false }
        isQuitRequested = true
        return true
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isQuitRequested = true
        isShuttingDown = true
        connectionPhase = .shuttingDown
        await ActivityReportingService.shared.stopConnectionMonitoring()
        connectionMessage = "Pausing active work and closing the local runtime."
        isBusy = false

        let polling = pollingTask
        let bootstrap = bootstrapTask
        let connection = connectionTask
        let operation = operationTask
        let creditRefresh = codexCreditRefreshTask
        cancelCodexCreditsRefresh()
        activityPollingTask?.cancel()
        activityPollingTask = nil
        activityRefreshTask?.cancel()
        activityOperationTask?.cancel()
        journalPublishTask?.cancel()
        tokenSeriesTask?.cancel()
        tokenProjectionTask?.cancel()
        pollingTask?.cancel()
        pollingTask = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        operationTask?.cancel()
        operationTask = nil

        await polling?.value
        await connection?.value
        await operation?.value
        await bootstrap?.value
        await creditRefresh?.value

        let runtime = ownedRuntime
        ownedRuntime = nil
        if let runtime {
            await runtime.stop()
        }

        persistPreferences()
        hasCompletedShutdown = true
        connectionMessage = "Closed safely."
    }

    func prepareForImmediateTermination() {
        if !isShowingSavedActivity {
            activitySnapshot?.save(activityOverview, force: true)
        }
        activitySnapshot?.flush()
        bootstrapTask?.cancel()
        connectionTask?.cancel()
        operationTask?.cancel()
        pollingTask?.cancel()
        activityPollingTask?.cancel()
        activityRefreshTask?.cancel()
        activityOperationTask?.cancel()
        journalPublishTask?.cancel()
        tokenSeriesTask?.cancel()
        tokenProjectionTask?.cancel()
        cancelCodexCreditsRefresh()
        ownedRuntime?.stopImmediately()
        ownedRuntime = nil
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !AcceptanceProbe.isActive else { return }
        guard !isBusy, !isShuttingDown else { return }
        isBusy = true
        errorMessage = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isBusy = false
                operationTask = nil
            }
            do {
                try await operation()
                guard !Task.isCancelled, !isShuttingDown else { return }
                await self.refresh()
            } catch {
                guard !isShuttingDown else { return }
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        isBusy = false
    }

    private func startPolling() {
        guard !isShuttingDown else { return }
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let delay = isReady
                    ? 2
                    : min(30, 1 << min(max(reconnectAttempt, 1), 4))
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                if isReady {
                    await refresh()
                    await refreshPlanUsageIfStale()
                    refreshCodexCreditsIfStale()
                    refreshTokenSeriesIfStale()
                } else {
                    await connectOrRecover(initial: false)
                }
            }
        }
    }

    /// Read the same durable snapshot as Reports. GET never launches a second
    /// scanner or advances an independent token-ledger clock.
    private func refreshTokenSeriesIfStale() {
        guard !AcceptanceProbe.isActive else { return }
        guard !isShuttingDown, activityOperationTask == nil, let client, tokenSeriesTask == nil else { return }
        let now = Date()
        if let last = lastTokenSeriesRefresh,
           now.timeIntervalSince(last) < tokenSeriesRefreshInterval
        {
            return
        }
        lastTokenSeriesRefresh = now
        let revision = activityMutationRevision
        tokenSeriesTask = Task { [weak self] in
            let snapshot = try? await self?.readActivity(client: client, refresh: false)
            guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
            if let snapshot { self.acceptRuntimeActivity(snapshot, requestRevision: revision) }
            self.tokenSeriesTask = nil
        }
    }

    func refreshTokenSeries() {
        refreshActivity(force: true)
    }

    /// One active projection plus the latest snapshot, not a queue of captured
    /// overviews. Publishing is revision-checked, including same-time fixes.
    private func projectCanonicalTokenSeries() {
        guard !isShuttingDown, wantsHUDProjection, activityOverview.generatedAt != .distantPast, tokenProjectionTask == nil else { return }
        isProjectingTokenSeries = true
        tokenProjectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.tokenProjectionTask = nil; self.isProjectingTokenSeries = false
                if self.wantsHUDProjection && self.publishedAccountingRevision < self.activityRevision { self.projectCanonicalTokenSeries() }
            }
            while !Task.isCancelled && !self.isShuttingDown && self.wantsHUDProjection {
                let snapshot = self.activityOverview
                let revision = self.activityRevision
                let projection = await Task.detached(priority: .utility) {
                    (TokenAccountingSeriesAdapter.build(overview: snapshot), ActivityInsight(snapshot, now: snapshot.generatedAt))
                }.value
                guard !Task.isCancelled, !self.isShuttingDown, self.wantsHUDProjection else { return }
                if revision >= self.publishedAccountingRevision {
                    self.publishedAccountingRevision = revision
                    self.activityInsight = projection.1
                    self.tokenSeries = projection.0
                    self.lastTokenSeriesRefresh = Date()
                }
                // Progress through complete snapshots instead of starving the
                // HUD when metadata arrives faster than a large projection.
                if revision == self.activityRevision { return }
            }
        }
    }

    /// Test/read synchronization without initiating provider work.
    func awaitAccountingProjection() async {
        await tokenProjectionTask?.value
    }

    /// Refreshes provider-owned plan usage without borrowing the busy state or
    /// raising an alert: this reading is scheduled, not something the user asked
    /// for, so a failure should leave the previous card and its age in place.
    private func refreshPlanUsageIfStale() async {
        guard !AcceptanceProbe.isActive else { return }
        guard !isShuttingDown, let client else { return }
        let now = Date()
        if let last = lastPlanUsageRefresh,
           now.timeIntervalSince(last) < planUsageRefreshInterval
        {
            return
        }
        lastPlanUsageRefresh = now
        guard let status = try? await client.refreshPlanUsage() else { return }
        guard !Task.isCancelled, !isShuttingDown else { return }
        accept(status)
    }

    private func connectOrRecover(initial: Bool) async {
        guard !isShuttingDown,
              !isConnecting,
              let client,
              let configuration
        else { return }
        isConnecting = true
        defer { isConnecting = false }

        if initial {
            connectionPhase = .hydrating
            connectionMessage = nil
        }
        do {
            do {
                accept(try await client.status())
                return
            } catch {
                guard !Task.isCancelled, !isShuttingDown else { return }
                if (try? await client.health()) == true {
                    connectionPhase = .unavailable
                    connectionMessage = """
                    A bridge service is running on the configured port, but its credentials \
                    do not match this app. The app will keep retrying.
                    """
                    reconnectAttempt += 1
                    return
                }
            }

            guard !Task.isCancelled, !isShuttingDown else { return }
            if let previousRuntime = ownedRuntime {
                await previousRuntime.stop()
                ownedRuntime = nil
            }
            guard !AcceptanceProbe.isActive else {
                connectionPhase = .unavailable
                connectionMessage = "The test run only connects to an existing runtime; it never starts one."
                return
            }
            let runtime = BridgeRuntime(configuration: configuration)
            do {
                try await runtime.start()
                guard !Task.isCancelled, !isShuttingDown else {
                    await runtime.stop()
                    return
                }
                ownedRuntime = runtime
            } catch {
                guard !Task.isCancelled, !isShuttingDown else {
                    await runtime.stop()
                    return
                }
                if (try? await client.health()) != true {
                    throw error
                }
            }
            accept(try await client.status())
        } catch {
            guard !Task.isCancelled, !isShuttingDown else { return }
            markDisconnected(error)
        }
    }

    private func accept(_ freshStatus: BridgeStatus) {
        guard !isShuttingDown else { return }
        var freshStatus = freshStatus
        freshStatus.quota = QuotaSnapshotOrdering.merging(current: status.quota, incoming: freshStatus.quota)
        // The status poll runs every two seconds. Publishing only real changes
        // keeps every observing view (the Hub window included) from redrawing
        // and recomputing its reports on an idle tick.
        if status != freshStatus {
            status = freshStatus
            if let encoded = try? BridgeJSON.compactEncoder.encode(freshStatus) {
                AcceptanceProbe.defaults.set(encoded, forKey: statusCacheKey)
            }
        }
        if let session = freshStatus.session, projectPath != session.projectPath {
            projectPath = session.projectPath
        }
        if let client { bindReadyRuntimeClient(client) }
        if connectionMessage != nil { connectionMessage = nil }
        reconnectAttempt = 0
        if freshStatus.state != .error, errorMessage != nil {
            errorMessage = nil
        }
    }

    private func markDisconnected(_ error: Error) {
        guard !isShuttingDown else { return }
        reconnectAttempt += 1
        connectionPhase = .reconnecting(attempt: reconnectAttempt)
        connectionMessage = String(error.localizedDescription.prefix(400))
    }

    private func hasInstalledHooks(projectPath: String) -> Bool {
        guard !projectPath.isEmpty else { return false }
        let settings = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".claude/settings.local.json")
        guard let content = try? String(contentsOf: settings, encoding: .utf8) else {
            return false
        }
        return content.contains("/hooks/claude/")
    }
}
