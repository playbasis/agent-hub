import AppKit
import BridgeCore
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Presentation of the already-scoped accounting/1 subtotal. This is not an
/// independent counter and does not turn missing measurements into zero.
struct OverviewToolCallKPI: Equatable {
    let value: String
    let detail: String

    static func make(_ report: ActivityAccounting.Report) -> Self {
        guard report.isValid, let calls = report.totals.toolCalls else {
            return Self(value: "—", detail: "Count unavailable")
        }
        // Native-counter coverage is deliberately broad: it can also reflect
        // missing prompt metadata, unallocated turns, or source availability.
        let partial = report.sourceCoverageIsPartial || report.totals.nativeCountersArePartial
        return Self(value: (partial ? "≥" : "") + calls.formatted(),
                    detail: partial ? "Coverage may be partial" : "Recorded locally")
    }

    static let explanation = "Recorded tool-call counts from the same local accounting report and selected period as the other activity figures. A dash means a count is unavailable, not zero. ≥ marks a subtotal when source or native-counter coverage may be partial; the coverage flag can also reflect missing prompt metadata or unallocated turns. These counts are not model requests, task completions, or tool successes."
}

/// Reporting periods. Raw values stay stable for saved preferences.
enum ReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case day = "24 hours", week = "7 days", month = "30 days", all = "All imported"
    var id: String { rawValue }
    var short: String {
        switch self { case .day: return "24h"; case .week: return "7 days"; case .month: return "30 days"; case .all: return "All" }
    }
    var phrase: String {
        switch self { case .day: return "the last 24 hours"; case .week: return "the last 7 days"; case .month: return "the last 30 days"; case .all: return "all saved history" }
    }
    /// Charts for a day read hour by hour; longer periods day by day.
    var granularity: ActivityAnalytics.Granularity { self == .day ? .hour : .day }
    /// Preserve an exact trailing day. Clock-hour charts retain both partial
    /// edge hours (25 bins except at the top of an hour), not a shortened day.
    func cutoff(at now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ActivityAnalytics.reportingTimeZone
        switch self {
        case .day: return now.addingTimeInterval(-86_400)
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .all: return nil
        }
    }
}

struct ActivityReportsView: View {
    @ObservedObject var model: BridgeViewModel
    @ObservedObject var navigation: ActivityReportsController
    @AppStorage("activityReports.period") private var periodRaw = ReportPeriod.week.rawValue
    @State private var query = ""
    /// The search text after a short pause, so typing doesn't rebuild every
    /// report on each keystroke.
    @State private var appliedQuery = ""
    @State private var provider = "all"
    @State private var project = "all"
    @StateObject private var preparation = ReportScopePreparation()
    @State private var cache = ReportScopeCache()
    @State private var expandedParents: Set<String> = []
    @State private var aboutExpanded = false

    private var section: BridgePage { navigation.page }
    private var period: ReportPeriod { ReportPeriod(rawValue: periodRaw) ?? .week }
    private var periodBinding: Binding<ReportPeriod> { Binding(get: { period }, set: { periodRaw = $0.rawValue }) }
    private var incomingOverview: ActivityOverview { model.activityOverview }
    private var requestedNow: Date { ActivityAccountingPrecision.date(incomingOverview.generatedAt) ?? .distantPast }
    /// Pin metadata, axis bounds and measurements to the same complete report
    /// while the next runtime snapshot is prepared off the UI thread.
    private var overview: ActivityOverview { prepared?.overview ?? incomingOverview }
    private var reportNow: Date { prepared?.key.scope.now ?? requestedNow }
    private var cutoff: Date? { period.cutoff(at: reportNow) }
    private var isFiltered: Bool { !appliedQuery.isEmpty || project != "all" }

    private var scopeKey: ReportScope.Key {
        .init(generatedAt: incomingOverview.generatedAt, sessionCount: incomingOverview.sessions.count, pinnedSessionID: incomingOverview.pinnedSessionID,
              // The Skills page searches skills, not sessions.
              provider: section == .credits ? "codex" : provider, project: project, query: section == .skills ? "" : appliedQuery,
              cutoff: period.cutoff(at: requestedNow), now: requestedNow,
              snapshotRevision: model.activityRevision)
    }
    private var preparationKey: PreparedReportScope.Key? {
        guard navigation.isWindowVisible, section.needsActivityCollection, section != .journal,
              incomingOverview.generatedAt != .distantPast else { return nil }
        if navigation.replaySelection != nil { return preparation.prepared?.key }
        return .init(scope: scopeKey, chartCutoff: period.cutoff(at: requestedNow) ?? requestedNow.addingTimeInterval(-30 * 86_400),
                     hourly: isHourly, period: period, includeCreditEstimates: section == .credits)
    }
    private var prepared: PreparedReportScope? {
        preparation.displayed(for: preparationKey)
    }
    private var isUpdatingReport: Bool { prepared.map { $0.key != preparationKey } ?? false }
    // These getters are used only inside the matching-ready branch below.
    // Never rebuild a real snapshot synchronously as a rendering fallback.
    private var readyReport: PreparedReportScope { prepared! }
    private var scope: ReportScope { readyReport.scope }
    private var accounting: ActivityAccounting.Report { scope.accounting }
    private var chartAccounting: ActivityAccounting.Report { readyReport.chartAccounting }
    private var stepPace: String {
        guard let rate = accounting.averageStepsPerHour else { return "\(accounting.totals.nativeRecords.formatted()) saved records" }
        return rate < 1 ? "Fewer than one observed step an hour" : "About \(rate.formatted(.number.precision(.fractionLength(0)))) an hour"
    }
    /// A value derived from the current scope, computed once until the
    /// snapshot or a filter changes.
    private func memo<T>(_ name: String, _ build: () -> T) -> T {
        // Invalidate when the displayed snapshot changes, not when a new one
        // is merely requested. Old charts remain intact until atomic publish.
        _ = cache.scope(for: readyReport.key.scope) { readyReport.scope }
        return cache.value(name, build: build)
    }
    private func memo<T>(_ name: String, tag: String, _ build: () -> T) -> T {
        _ = cache.scope(for: readyReport.key.scope) { readyReport.scope }
        return cache.value(name, tag: tag, build: build)
    }
    private var matchingSessions: [ActivitySession] { scope.matchingSessions }
    private var sessions: [ActivitySession] { scope.sessions }
    private var turns: [ActivityTurn] { scope.turns }
    /// The prepared scope already holds these; recompute only before it exists.
    private var projects: [String] { prepared?.scope.projects ?? Array(Set(overview.sessions.compactMap(\.projectPath))).sorted() }
    private var selected: ActivitySession? { overview.sessions.first { $0.id == navigation.selectedSessionID } }
    private var quotaMap: [AgentName: QuotaEstimate] {
        Dictionary(uniqueKeysWithValues: AgentName.allCases.compactMap { agent in model.status.quota[agent.rawValue].map { (agent, $0) } })
    }
    private var availableProviders: [AgentName] {
        let present = Set(overview.sessions.map(\.provider))
        return [AgentName.claude, .codex, .grok].filter { $0 != .grok || present.contains(.grok) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea(edges: .top)
            VStack(spacing: 0) {
                header
                Divider()
                banners
                // A closed or minimised window keeps its hosting view; don't
                // rebuild pages nobody can see.
                if !navigation.isWindowVisible {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if section == .credits {
                    CreditHistoryView(model: model, localEstimates: prepared?.creditEstimates,
                        localUpdating: preparation.isPreparing || prepared == nil,
                        localScopeLabel: "Local token filters · \(period.phrase) · snapshot \(ActivityFormat.relative(overview.generatedAt))",
                        sessions: overview.sessions,
                        openSession: { id in navigation.navigate(to: .goals); navigation.selectedSessionID = id })
                } else if section.needsActivityCollection {
                    ZStack {
                        // Keep the chart/goal view mounted while inspecting so
                        // Back restores scroll, expansion, range and grouping.
                        activityContent
                            .environment(\.activityContentVisible, navigation.replaySelection == nil)
                            .environment(\.inspectedTurn, navigation.turnInspection.map { InspectedTurn(sessionID: $0.sessionID, turnID: $0.turnID) })
                            .opacity(navigation.replaySelection == nil ? 1 : 0)
                            .allowsHitTesting(navigation.replaySelection == nil)
                            .accessibilityHidden(navigation.replaySelection != nil)
                        if navigation.replaySelection == nil, let inspection = navigation.turnInspection {
                            turnDrawer(inspection)
                        }
                        if let replay = navigation.replaySelection {
                            GoalReplayView(selection: replay, model: model, close: { navigation.goBack() })
                                .id(replay.id).background(BridgeTheme.ink)
                        }
                    }
                    .animation(BridgeTheme.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.9),
                               value: navigation.turnInspection == nil)
                    .onChange(of: prepared?.key.scope.snapshotRevision) { revision in
                        if let revision { navigation.rebaseTurnInspection(on: overview, revision: revision) }
                    }
                } else {
                    workspaceContent
                }
                Divider()
                footer
            }
        }
        .background(BridgeTheme.ink)
        .environment(\.colorScheme, .dark)
        .tint(BridgeTheme.brand)
        .frame(minWidth: BridgeWorkspaceLayout.minimumContentSize.width, minHeight: BridgeWorkspaceLayout.minimumContentSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.workspace")
        .task(id: "\(section.id):\(model.runtimeClientID?.uuidString ?? "connecting"):\(navigation.isWindowVisible)") {
            if section == .journal, navigation.isWindowVisible, model.runtimeClient != nil {
                await model.loadActivityJournal()
            }
        }
        .task(id: preparationKey) {
            // Other pages and a hidden window keep the prepared view: coming
            // back shows it at once while any newer snapshot is prepared.
            if let key = preparationKey { preparation.request(overview: incomingOverview, key: key) }
            else { preparation.suspend() }
        }
        .onDisappear { preparation.deactivate(); cache.reset() }
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            guard AcceptanceProbe.isActive, AcceptanceProbe.requestScope(note) == "hub" else { return }
            var supported = true
            let value = AcceptanceProbe.requestValue(note)
            switch AcceptanceProbe.requestName(note) ?? "" {
            case "state.reset":
                provider = "all"; project = "all"; query = ""; appliedQuery = ""; expandedParents = []; aboutExpanded = false; navigation.selectedSessionID = nil
            case "filter.codex": provider = AgentName.codex.rawValue
            case "filter.provider":
                if let value, ["all", "codex", "claude", "grok"].contains(value) { provider = value } else { supported = false }
            case "filter.project":
                if let value, value == "all" || value == ActivityAccountingQuery.unattributedProjectID || projects.contains(value) { project = value } else { supported = false }
            case "filter.query":
                if let value, value.count <= 200 { query = value; appliedQuery = value } else { supported = false }
            case "filter.period":
                if let value, ReportPeriod(rawValue: value) != nil { periodRaw = value } else { supported = false }
            case "expand.first":
                if prepared != nil, let parent = sessionTree.roots.first(where: { !(sessionTree.children[$0.id] ?? []).isEmpty }) { expandedParents.insert(parent.id) }
                else { supported = false }
            case "inspect.first":
                if prepared != nil, let first = sessions.first { navigation.selectedSessionID = first.id } else { supported = false }
            case "about.open":
                if section == .overview { aboutExpanded = true } else { supported = false }
            case "report": break
            default: supported = false
            }
            let state = ["page": section.id, "provider": provider, "project": project, "query": appliedQuery, "queryDraft": query,
                         "expanded": expandedParents.sorted().joined(separator: ","), "selected": navigation.selectedSessionID ?? "", "period": periodRaw,
                         "aboutOpen": String(aboutExpanded), "preparing": String(prepared == nil || isUpdatingReport),
                         "renderedRevision": prepared.map { String($0.key.scope.snapshotRevision) } ?? "none",
                         "preparedMatchesInputs": String(prepared != nil && prepared?.key == preparationKey)]
            AcceptanceProbe.hubState = state
            AcceptanceProbe.record(note, scope: "hub", state: state, supported: supported)
        }
        .task(id: query) {
            guard query != appliedQuery else { return }
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(220)) }
            guard !Task.isCancelled else { return }
            appliedQuery = query
        }
    }

    // MARK: Chrome

    @ViewBuilder private var banners: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { model.dismissError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss error")
            }
            .foregroundStyle(BridgeTheme.warning).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BridgeTheme.warning.opacity(0.08))
            .accessibilityIdentifier("bridge.workspace.error")
            Divider()
        }
        if section.needsActivityCollection, let error = model.activityError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
        }
    }

    /// One grid for the whole sidebar: rows, headings, the brand and the
    /// footer share a leading edge, a 20pt glyph column and a label column,
    /// so every mark and every label lines up exactly.
    private enum SidebarGrid {
        static let width: CGFloat = 220
        /// Sidebar edge to row highlight.
        static let margin: CGFloat = 10
        /// Row highlight to glyph column.
        static let inset: CGFloat = 8
        static let glyph: CGFloat = 20
        static let gap: CGFloat = 8
        static let row: CGFloat = 28
        /// Shared with the page status bar so both top lines meet.
        static let statusBar: CGFloat = 34
    }

    /// Below the titlebar band a small margin is enough; in full screen there
    /// is no band, so the page and sidebar keep a full margin of their own.
    private var topMargin: CGFloat { navigation.isFullScreen ? 22 : 6 }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SidebarGrid.gap) {
                // Centred on the glyph column; the label edge matches the rows.
                BrandMark(size: 24).frame(width: SidebarGrid.glyph)
                VStack(alignment: .leading, spacing: 0) {
                    Text(BridgeBrand.shortName).font(.system(size: 13, weight: .semibold)).foregroundStyle(BridgeTheme.textPrimary)
                    Text(BridgeBrand.company).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
            .padding(.horizontal, SidebarGrid.inset).padding(.top, topMargin).padding(.bottom, 16)
            .help(BridgeBrand.productName)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(BridgeBrand.productName)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(BridgePageGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.rawValue).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textTertiary)
                                .padding(.horizontal, SidebarGrid.inset).padding(.bottom, 5)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.pages) { item in sidebarItem(item) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            sidebarFooter
        }
        .padding(.horizontal, SidebarGrid.margin)
        .frame(width: SidebarGrid.width).frame(maxHeight: .infinity, alignment: .top)
        // The sidebar runs the full height of the window, under the traffic
        // lights, like a native macOS sidebar.
        .background(BridgeTheme.inkRaised.ignoresSafeArea(edges: .top))
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, -SidebarGrid.margin)
            sidebarStatus
        }
        .help("\(overview.sessions.count.formatted()) sessions · \(model.accounts.linkedCount) of \(LinkedProvider.allCases.count) plans linked")
        .accessibilityElement(children: .contain)
    }

    private var sidebarStatus: some View {
        HStack(spacing: SidebarGrid.gap) {
            Circle().fill(model.isReady ? BridgeTheme.success : BridgeTheme.warning).frame(width: 6, height: 6)
                .frame(width: SidebarGrid.glyph)
            Text(model.isReady ? "Connected" : "Connecting…").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { exportSnapshot() } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(BridgeIconButtonStyle(size: 24))
                .disabled(prepared == nil || overview.sessions.isEmpty)
                .help("Export these scoped accounting/1 metrics as private JSON")
                .accessibilityLabel("Export activity data")
        }
        .padding(.leading, SidebarGrid.inset).frame(height: SidebarGrid.statusBar)
    }

    private func sidebarItem(_ item: BridgePage) -> some View {
        let selected = section == item
        let shortcut = item.shortcutNumber.map { KeyEquivalent(Character(String($0))) }
        return Button { navigation.navigate(to: item) } label: {
            HStack(spacing: SidebarGrid.gap) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? BridgeTheme.brand : BridgeTheme.textSecondary)
                    .frame(width: SidebarGrid.glyph)
                // One weight for every state: selection changes colour, never
                // width, so labels don't shift.
                Text(item.title).font(BridgeFont.body)
                    .foregroundStyle(selected ? BridgeTheme.textPrimary : BridgeTheme.textPrimary.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                sidebarBadge(item, selected: selected)
            }
            .padding(.horizontal, SidebarGrid.inset).frame(height: SidebarGrid.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
        .modifier(OptionalShortcut(key: shortcut))
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("bridge.sidebar.\(item.id)")
        .help(shortcut.map { "\(item.subtitle)  ⌘\($0.character)" } ?? item.subtitle)
    }

    @ViewBuilder private func sidebarBadge(_ item: BridgePage, selected: Bool) -> some View {
        switch item {
        case .goals:
            let open = overview.activeGoals.count
            if open > 0 {
                Text("\(open)").font(BridgeFont.captionMedium.monospacedDigit())
                    .foregroundStyle(selected ? BridgeTheme.textSecondary : BridgeTheme.textTertiary)
                    .help("\(open) open \(open == 1 ? "goal" : "goals")")
            }
        case .now:
            // From the prepared view only: never computed in the sidebar body.
            if let working = prepared?.liveWork.workingAgents, working > 0 {
                HStack(spacing: 4) {
                    Circle().fill(BridgeTheme.success).frame(width: 6, height: 6)
                    Text("\(working)").font(BridgeFont.captionMedium.monospacedDigit())
                        .foregroundStyle(selected ? BridgeTheme.textSecondary : BridgeTheme.textTertiary)
                }
                .help("\(working) \(working == 1 ? "agent" : "agents") recently active")
                .accessibilityLabel("\(working) recently active")
            }
        case .accounts:
            if model.accounts.hasLoaded && model.accounts.linkedCount < LinkedProvider.allCases.count {
                Circle().fill(BridgeTheme.warning).frame(width: 6, height: 6).help("A plan isn't linked yet")
            }
        default:
            EmptyView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 11) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(navigation.replaySelection == nil ? section.title : "Goal Replay").font(.system(size: 19, weight: .semibold)).foregroundStyle(BridgeTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(navigation.replaySelection == nil ? section.subtitle : "Follow the steps, inspect outcomes, learn what to ask next")
                        .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if section.needsActivityCollection && section != .journal {
                    Button {
                        if section == .journal { Task { await model.loadActivityJournal() } } else { model.refreshActivity() }
                    } label: {
                        if model.isRefreshingActivity { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(BridgeIconButtonStyle(size: 28)).disabled(model.isRefreshingActivity)
                    .keyboardShortcut("r", modifiers: .command).help("Refresh activity (⌘R)").accessibilityLabel("Refresh")
                }
                HStack(spacing: 4) {
                    Button { navigation.goBack() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(BridgeIconButtonStyle(size: 28)).disabled(!navigation.canGoBack)
                        .accessibilityLabel("Back").keyboardShortcut("[", modifiers: .command).help("Back (⌘[)")
                    Button { navigation.goForward() } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(BridgeIconButtonStyle(size: 28)).disabled(!navigation.canGoForward)
                        .accessibilityLabel("Forward").keyboardShortcut("]", modifiers: .command).help("Forward (⌘])")
                }
            }
            if section.showsActivityFilters && navigation.isWindowVisible && navigation.replaySelection == nil {
                activityFilters
            }
        }
        // Top edge matches the sidebar brand row under the titlebar band.
        .padding(.horizontal, 22).padding(.top, topMargin).padding(.bottom, 14)
    }

    private var activitySearch: some View {
        HubSearchField(prompt: section == .skills ? (navigation.skillsShowsInstructions ? "Search projects" : "Search skills") : "Search sessions, goals, models", text: $query)
            .frame(minWidth: 150, maxWidth: .infinity).accessibilityLabel("Search activity")
    }

    private var periodControl: some View {
        SegmentedTabs(selection: periodBinding, title: \.short).frame(width: 236)
            .help("24h is exactly the preceding 24 hours. Its first and last clock-hour bars may be partial.")
    }

    @ViewBuilder private var clearFilterButton: some View {
        if !query.isEmpty || project != "all" || provider != "all" {
            Button("Clear") { query = ""; appliedQuery = ""; provider = "all"; project = "all" }
                .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
        }
    }

    private var activityFilters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                activitySearch.frame(maxWidth: 280); periodControl
                if section == .credits { Tag(text: "Local Codex usage") }
                else { ProviderScopeControl(selection: $provider, providers: availableProviders) }
                projectMenu; clearFilterButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { activitySearch; periodControl }
                HStack(spacing: 8) {
                    if section == .credits { Tag(text: "Local Codex usage") }
                    else { ProviderScopeControl(selection: $provider, providers: availableProviders) }
                    projectMenu; Spacer(minLength: 0); clearFilterButton
                }
            }
        }
    }

    private var projectMenu: some View {
        Menu {
            Button("All projects") { project = "all" }
            Divider()
            ForEach(projects, id: \.self) { path in
                Button(projectName(path)) { project = path }
            }
            if overview.sessions.contains(where: { $0.projectPath == nil }) {
                Button("Unattributed project") { project = ActivityAccountingQuery.unattributedProjectID }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: project == "all" ? "folder" : "folder.fill").font(.system(size: 11))
                Text(project == "all" ? "All projects" : projectName(project)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(BridgeTheme.textTertiary)
            }
            .font(BridgeFont.secondaryMedium)
            .foregroundStyle(project == "all" ? BridgeTheme.textSecondary : BridgeTheme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 220, alignment: .leading)
        .padding(.horizontal, 8).frame(height: 26)
        .bridgeWell(cornerRadius: 7)
        .help(project == "all" ? "Filter by project" : project)
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                if navigation.replaySelection != nil {
                    Image(systemName: "list.number").font(.system(size: 9))
                    Text("Read-only replay · each observation retains its source and time")
                } else if section.needsActivityCollection && isUpdatingReport {
                    ProgressView().controlSize(.mini)
                    Text("Updating… · showing data from \(ActivityFormat.relative(reportNow, now: context.date))")
                        .accessibilityIdentifier("bridge.report.updating")
                        .help("The last complete report stays visible until the new measurements are ready.")
                } else if section.needsActivityCollection && model.isShowingSavedActivity {
                    if model.isRefreshingActivity { ProgressView().controlSize(.mini) }
                    else { Image(systemName: model.activityError == nil ? "clock" : "exclamationmark.circle").font(.system(size: 9)) }
                    Text("Saved data from \(ActivityFormat.relative(overview.generatedAt, now: context.date)) · \(model.isRefreshingActivity ? "refreshing" : model.activityError != nil ? "refresh failed" : model.isReady ? "waiting for refresh" : "waiting for connection")")
                } else if section.needsActivityCollection && overview.generatedAt != .distantPast {
                    if model.isRefreshingActivity { ProgressView().controlSize(.mini) } else { Image(systemName: "clock").font(.system(size: 9)) }
                    Text("Updated \(ActivityFormat.relative(overview.generatedAt, now: context.date))")
                } else {
                    Image(systemName: model.isReady ? "bolt.horizontal.circle" : "hourglass").font(.system(size: 9))
                    Text(model.connectionLabel)
                }
                Spacer()
                if section.needsActivityCollection {
                    Image(systemName: "lock").font(.system(size: 9))
                    Text("Stored on this Mac · \(ActivityAnalytics.reportingTimeZone.localizedName(for: .shortGeneric, locale: .current) ?? "local time")")
                } else {
                    Text(BridgeBrand.productName)
                }
            }
            .font(.caption).foregroundStyle(BridgeTheme.textTertiary).padding(.horizontal, 20).frame(height: SidebarGrid.statusBar)
        }
    }

    private var activityContent: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if overview.generatedAt == .distantPast && section != .journal {
                        ActivityLoadingView(page: section, message: loadingMessage,
                                            isReading: model.activityError == nil && model.connectionPhase != .unavailable)
                        if model.activityError != nil || model.connectionPhase == .unavailable {
                            Button(model.isReady ? "Retry activity read" : "Retry connection") {
                                if model.isReady { model.refreshActivity() } else { model.retryConnection() }
                            }.buttonStyle(BridgePrimaryButtonStyle(compact: true))
                        }
                    } else if section != .journal && prepared == nil {
                        ActivityLoadingView(page: section, message: "Preparing your report. You can keep using the sidebar while it loads.")
                    } else {
                    switch section {
                    case .overview: overviewContent.acceptanceProbe("page.overview")
                    case .team:
                        TeamRosterView(roster: readyReport.roster, now: reportNow,
                                       selectedID: navigation.selectedSessionID,
                                       select: { navigation.selectedSessionID = $0 },
                                       trends: readyReport.sessionTrends, trendUnit: isHourly ? "hour" : "day")
                            .acceptanceProbe("page.agents")
                    case .now: sessionsContent.acceptanceProbe("page.now")
                    case .goals: goalContent.acceptanceProbe("page.goals")
                    case .projects: projectContent.acceptanceProbe("page.projects")
                    case .models: modelContent.acceptanceProbe("page.models")
                    case .skills: skillsContent.acceptanceProbe("page.skills")
                    case .journal: journalContent.acceptanceProbe("page.journal")
                    default: EmptyView()
                    }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 380)
            if prepared != nil, let selected, section.supportsSessionInspector {
                ActivitySessionInspector(session: selected, overview: overview, model: model, snapshotRevision: readyReport.key.scope.snapshotRevision,
                                         shipped: readyReport.shipped,
                                         selectSession: { navigation.selectedSessionID = $0 },
                                         close: { navigation.selectedSessionID = nil })
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                    .acceptanceProbe("inspector")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.page.\(section.id)")
    }

    /// The turn drawer overlays the page's trailing edge. Empty space passes
    /// clicks through, so another swimlane block can be chosen while it's open.
    private func turnDrawer(_ inspection: TurnInspectionSelection) -> some View {
        GeometryReader { proxy in
            TurnDrawer(selection: inspection,
                       focus: { navigation.focusTurn($0) },
                       close: { navigation.closeTurnInspection() },
                       openReplay: { session, turn in
                           navigation.openReplay(overview: inspection.overview, sessionID: session, focusTurnIDs: turn.map { [$0] } ?? [])
                       },
                       showSession: { navigation.selectedSessionID = $0 })
                .frame(width: min(460, max(340, proxy.size.width * 0.46)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .transition(BridgeTheme.reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        .zIndex(2)
        .acceptanceProbe("turn-drawer")
    }

    private var loadingMessage: String {
        if model.connectionPhase == .unavailable { return "Connection unavailable. Your saved work hasn't been changed." }
        if model.activityError != nil { return "The activity read didn't finish. Retry when you're ready." }
        if case .reconnecting = model.connectionPhase { return "Waiting to reconnect to the local service…" }
        if !model.isReady { return "Starting Agent Hub…" }
        return model.isRefreshingActivity ? "Reading your sessions…" : "Waiting for your first activity read…"
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch section {
        case .teamChat:
            TeamRoomView(model: TeamRoomController.shared.model).acceptanceProbe("page.team-chat")
        case .glmChat:
            GLMChatView(model: GLMChatController.shared.model, embedded: true).acceptanceProbe("page.glm-chat")
        case .logs:
            RuntimeLogsView(isActive: navigation.isWindowVisible).acceptanceProbe("page.logs")
        case .settings:
            SettingsView(model: model, openAccounts: { model.openPage(.accounts) }).acceptanceProbe("page.settings")
        case .accounts:
            ScrollView {
                AccountsView(model: model, accounts: model.accounts)
                    .padding(22).frame(maxWidth: 880)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task { model.panelDidOpen() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bridge.page.accounts")
            .acceptanceProbe("page.accounts")
        case .providerProof:
            ProviderProofPage(client: model.runtimeClient, clientID: model.runtimeClientID).acceptanceProbe("page.provider-proof")
        default:
            EmptyView()
        }
    }

    // MARK: Skills

    private var skillsContent: some View {
        SkillsPage(sessions: sessions, overview: overview, revision: readyReport.key.scope.snapshotRevision,
                   from: cutoff, to: reportNow, hourly: isHourly, periodPhrase: period.phrase,
                   provider: provider, project: project, query: appliedQuery,
                   catalogProjects: projects, projectLabels: projectLabels,
                   showsInstructions: Binding(get: { navigation.skillsShowsInstructions }, set: { navigation.skillsShowsInstructions = $0 }),
                   skillSelection: Binding(get: { navigation.skillSelection }, set: { navigation.skillSelection = $0 }),
                   instructionSelection: Binding(get: { navigation.instructionSelection }, set: { navigation.instructionSelection = $0 }),
                   showSession: { navigation.selectedSessionID = $0 })
    }

    // MARK: Overview

    private var chartCutoff: Date { cutoff ?? reportNow.addingTimeInterval(-30 * 86_400) }
    private var granularity: ActivityAnalytics.Granularity { period.granularity }
    private var isHourly: Bool { granularity == .hour }
    private var reportCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ActivityAnalytics.reportingTimeZone
        return calendar
    }
    /// Start of the bucket after `date` (next hour or next day).
    private func nextBucket(after date: Date) -> Date {
        reportCalendar.date(byAdding: isHourly ? .hour : .day, value: 1, to: date) ?? date
    }
    private var chartDateDomain: ClosedRange<Date> {
        let calendar = reportCalendar
        let unit: Calendar.Component = isHourly ? .hour : .day
        let start = calendar.dateInterval(of: unit, for: chartCutoff)?.start ?? chartCutoff
        let last = calendar.dateInterval(of: unit, for: reportNow)?.start ?? reportNow
        let end = reportNow == last ? last : nextBucket(after: last)
        return start ... max(start.addingTimeInterval(1), end)
    }
    private var previousWindow: (from: Date, to: Date)? {
        guard let cutoff else { return nil }
        return (cutoff.addingTimeInterval(-reportNow.timeIntervalSince(cutoff)), cutoff)
    }
    private var deltaLabel: String { "vs the period before" }

    private var quotaFingerprint: String {
        // Source, reset time and availability can change independently of a
        // ratio. Encode the full input so memoized forecasts cannot stay stale.
        (try? BridgeJSON.compactEncoder.encode(model.status.quota)).map { $0.base64EncodedString() } ?? "invalid-quotas"
    }

    private var overviewContent: some View {
        let current = accounting.totals
        let daily = readyReport.chartSeries.points
        let tokenData = memo("overview.tokens") { tokenBars }
        let showsAccount = !isFiltered && (provider == "all" || provider == "codex")
        let highlights = memo("overview.highlights", tag: "\(quotaFingerprint):\(Int(Date().timeIntervalSince1970 / 60))") {
            ActivityHighlights.make(.init(sessions: matchingSessions, from: cutoff, to: reportNow, quotas: provider == "all" && !isFiltered ? quotaMap : [:],
                                          account: showsAccount ? overview.accountUsage : nil, accounting: accounting, providerNow: Date()), limit: 4)
        }
        return VStack(alignment: .leading, spacing: 20) {
            if !highlights.isEmpty { highlightSection(highlights) }
            kpiGrid(current: current, daily: daily)
            HStack(alignment: .top, spacing: 12) {
                if isHourly {
                    agentsPerHourChart(memo("overview.agentsPerHour") { agentsAtWork(daily) })
                } else {
                    agentsPerDayChart(daily)
                }
                tokensPerDayChart(tokenData)
            }
            .fixedSize(horizontal: false, vertical: true)
            if !overview.sessions.compactMap(\.projectPath).isEmpty {
                ShippedOverviewCard(result: readyReport.shipped, periodPhrase: period.phrase, now: reportNow, scanning: model.isAnalyzingRepositories,
                                    scan: { model.analyzeActivityRepositories() }, openProjects: { navigation.navigate(to: .projects) },
                                    from: cutoff)
            }
            if showsAccount, model.accounts.status(.codex)?.isSubscription == true || model.status.quota["codex"]?.credits != nil {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    CreditBalanceView(estimate: model.status.quota["codex"], account: model.accounts.status(.codex), now: context.date,
                        onRefresh: { model.refreshCodexCredits() }, refreshing: model.isRefreshingCodexCredits || !model.isReady,
                        onVisibilityChanged: { model.observeCreditBalance("overview", visible: $0) },
                        openHistory: { model.openPage(.credits) })
                }
                .bridgeCard(padding: 16)
            }
            if showsAccount, let account = overview.accountUsage, let range = accountDateRange {
                AccountUsagePanel(account: account, fromDate: range.from, toDate: range.to, now: reportNow)
            }
            if isHourly { requestsByHourCard(tokenData) } else { weekHourCard }
            HStack(alignment: .top, spacing: 12) {
                workMixCard
                modelsCard
            }
            .fixedSize(horizontal: false, vertical: true)
            JEVInsightsCard(overview: overview, sessionIDs: accounting.scope.sessionIDs, snapshotRevision: readyReport.key.scope.snapshotRevision) { sessionID, turnID in
                navigation.inspectTurn(overview: overview, sessionID: sessionID, turnID: turnID, snapshotRevision: readyReport.key.scope.snapshotRevision)
            }
            HStack(alignment: .top, spacing: 12) {
                projectsCard
                tokenMixCard
            }
            .fixedSize(horizontal: false, vertical: true)
            aboutThisData
        }
    }

    private func highlightSection(_ highlights: [ActivityHighlight]) -> some View {
        HighlightsSection(periodPhrase: period.phrase,
                          info: "Picked from your activity, plan limits and OpenAI account. Red needs attention soon, amber is worth watching, cyan is unusual, green is good news. Hover a card to see how it was measured. Anything that can't be measured is left out.",
                          items: highlights, action: highlightAction)
    }

    private func highlightAction(_ highlight: ActivityHighlight) -> (() -> Void)? {
        if let id = highlight.sessionID { return { navigation.selectedSessionID = id } }
        switch highlight.kind {
        case .planPace, .planLow, .planHealthy: return { navigation.navigate(to: .accounts) }
        case .topProject: return { navigation.navigate(to: .projects) }
        case .providerShare: return { navigation.navigate(to: .models) }
        case .parallel: return { navigation.navigate(to: .goals) }
        default: return nil
        }
    }

    private func kpiGrid(current: ActivityAccounting.Totals, daily: [ActivityAccounting.Point]) -> some View {
        let summed: String? = {
            guard let agent = current.agentSeconds, let active = current.activeSeconds, active > 0, agent > active * 1.05 else { return nil }
            return "\(ActivityFormat.duration(agent)) of agent time"
        }()
        let coverage = current.tokenCoverage.map { Int(($0 * 100).rounded()) }
        let children = memo("overview.children") { sessions.filter(\.isChild).count }
        let models = current.modelIdentities
        let durations = Array(accounting.sessionWorkSeconds.values)
        let perBucket = memo("overview.agentsPerBucket") { agentsPerBucket(daily) }
        let histogram = Self.durationHistogram(durations)
        let unit = isHourly ? "hour" : "day"
        let trend = isHourly ? " Bars show each hour; the brightest is the current hour." : " Bars show each day; the brightest is today."
        let gaps = " A dot marks missing measurements. A faint baseline marks no dated observations, not confirmed zero usage."
        let noRecords = Set(daily.indices.filter { daily[$0].nativeRecords == 0 && daily[$0].usageRecords == 0 })
        return MetricStrip(items: [
            MetricItem(title: "Active time", icon: "clock", value: ActivityFormat.duration(current.activeSeconds),
                       footnote: summed ?? "At least one agent working",
                       info: "Time when at least one agent was working, with overlaps counted once. It includes waiting for tools and replies. Claude doesn't save when a request ends, so its time isn't counted yet." + trend + gaps,
                       series: daily.map(\.measuredActiveSeconds), emptyIndices: noRecords),
            MetricItem(title: "Model steps", icon: "bubble.left.and.text.bubble.right", value: ActivityReportPresentation.steps(accounting),
                       footnote: stepPace,
                       info: "Observed model responses and distinct usage advances, from the same Core accounting records as Models and the toolbar. Not human prompts or exact billable API attempts." + trend,
                       series: daily.map { $0.modelStepCount > 0 ? Double($0.modelStepCount) : nil }, emptyIndices: noRecords),
            MetricItem(title: "Sessions", icon: "person.2", value: current.sessions.formatted(),
                       footnote: "\(children) sub-\(children == 1 ? "agent" : "agents") · \(models) \(models == 1 ? "model" : "models")",
                       info: "Core-counted participating sessions. Open goals stay visible even without new observations. A sub-agent is a session another agent started. Bars show distinct sessions with supporting evidence in each \(unit); those counts are not additive.",
                       series: perBucket),
            MetricItem(title: "Tokens", icon: "circle.hexagongrid", value: ActivityReportPresentation.tokens(accounting),
                       footnote: coverage.map { "Usage coverage \($0)%" } ?? "No measured usage",
                       info: "The same known local token subtotal as Models, charts, CLI and exports for this exact snapshot and window. Provider account and goal counters are separate scopes. Interval-only usage may remain unplaced in daily bars." + trend + gaps,
                       series: daily.map { $0.measuredTokens.map(Double.init) }, emptyIndices: noRecords),
            MetricItem(title: "Written", icon: "pencil.line", value: ActivityReportPresentation.tokens(accounting, output: true),
                       footnote: writtenCoverage(current),
                       info: "Output tokens reported by the provider: the text and code agents wrote. Some providers include hidden reasoning." + trend + gaps,
                       series: daily.map { $0.measuredOutputTokens.map(Double.init) }, emptyIndices: noRecords),
            MetricItem(title: "Typical session", icon: "timer", value: ActivityFormat.duration(current.medianSessionSeconds),
                       footnote: durations.isEmpty ? "No timed sessions" : "Average \(ActivityFormat.duration(current.meanSessionSeconds))",
                       info: "Median recorded request time across \(durations.count) timed sessions, including waits; this isn't a full conversation lifetime. Bars group sessions by length. For an even sample, the lower middle observed session's group is highlighted.",
                       series: histogram.counts, emphasis: histogram.medianBucket),
        ])
    }

    /// How many usage records reported written tokens, in a few words.
    private func writtenCoverage(_ totals: ActivityAccounting.Totals) -> String {
        guard totals.usageRecords > 0 else { return "No usage records" }
        if totals.outputReceipts >= totals.usageRecords { return "Reported on every record" }
        return "Reported on \(percentText(Double(totals.outputReceipts) / Double(totals.usageRecords))) of records"
    }

    /// Session lengths in five groups, and the group holding the median.
    static func durationHistogram(_ durations: [Double]) -> (counts: [Double?], medianBucket: Int?) {
        let result = SessionDurationHistogram.build(durations)
        return (result.counts, result.medianBucket)
    }

    /// Distinct sessions with a dated request in each chart bucket.
    private func agentsPerBucket(_ points: [ActivityAccounting.Point]) -> [Double?] {
        points.map { $0.sessionIDs.isEmpty ? nil : Double($0.sessionIDs.count) }
    }

    private func requestPace(_ count: Int) -> String {
        guard let cutoff else { return "\(sessions.count) sessions" }
        let elapsed = max(1, reportNow.timeIntervalSince(cutoff))
        if isHourly {
            let perHour = Double(count) / (elapsed / 3_600)
            return perHour >= 1 ? "About \(Int(perHour.rounded()).formatted()) an hour" : "\(sessions.count) sessions"
        }
        return "About \(Int((Double(count) / max(1, elapsed / 86_400)).rounded()).formatted()) a day"
    }

    private func shareText(_ value: Int, _ total: Int) -> String {
        let fraction = Double(value) / Double(max(1, total))
        if fraction > 0 && fraction < 0.005 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private func percentText(_ fraction: Double) -> String {
        if fraction > 0 && fraction < 0.005 { return "<1%" }
        if fraction > 0.99 && fraction < 1 { return ">99%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Cards in a row (an HStack fixed to its ideal height) stretch to the
    /// tallest one; a chart inside grows into the extra height.
    private func reportCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            .background(BridgeTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1))
    }

    /// Average agents working each day. Hours with at least one agent
    /// saturate at 24 when work runs around the clock; how many agents shared
    /// the day still varies and says more.
    private func agentsPerDayChart(_ points: [ActivityAccounting.Point]) -> some View {
        let scale = HourlyAgentChart.Scale(values: points.map(\.averageAgents))
        let peak = points.filter { ($0.averageAgents ?? 0) > 0 }.max { ($0.averageAgents ?? 0) < ($1.averageAgents ?? 0) }
        let format: (Double) -> String = {
            if $0 > 0 && $0 < 0.05 { return "<0.1" }
            return $0.formatted(.number.precision(.fractionLength(1)))
        }
        // Covered hours per full day, as context beside the average.
        let covered = points.filter { $0.end.timeIntervalSince($0.windowStart) >= 86_000 }.compactMap(\.measuredActiveSeconds)
        let typicalHours = covered.isEmpty ? nil : covered.reduce(0, +) / Double(covered.count)
        return reportCard {
            CardHeader(title: "Agents at work, day by day", icon: "person.2.wave.2",
                       subtitle: peak.flatMap { day in day.averageAgents.map { "Busiest: \(format($0)) agents on average · \(weekdayLabel(day.day))" } } ?? "No timed requests yet",
                       info: "Average agents working across each day, from saved request start and end times, including waits. 2.5 can mean two agents all day and a third for half of it. Requests overlapping in the same session count once, and copied history is not another agent. Today covers only the hours so far. Claude doesn't save when a request ends, so its time isn't counted yet. A dotted line means requests were saved without usable timing; a dash means no dated requests were saved. Neither proves no work happened.") {
                if let typicalHours, typicalHours > 0 {
                    Tag(text: "Busy \(hoursLabel(typicalHours)) a day", color: BridgeTheme.codex)
                        .help("Average hours per full day when at least one agent was working, overlaps counted once")
                }
            }
            Chart(points) { point in
                if let agents = point.averageAgents {
                    if agents > 0 {
                        BarMark(x: .value("Day", point.day, unit: .day), y: .value("Average agents", agents), width: .ratio(0.62))
                            .foregroundStyle(isCurrentBucket(point.day) ? BridgeTheme.codex : BridgeTheme.codex.opacity(0.62))
                            .cornerRadius(3)
                            .annotation(position: .top, spacing: 3) {
                                if point.id == peak?.id {
                                    Text(format(agents)).font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
                                }
                            }
                            .accessibilityLabel(bucketLabel(point.day))
                            .accessibilityValue("\(format(agents)) agents on average\(point.measuredActiveSeconds.map { "; at least one agent working for \(hoursLabel($0))" } ?? "")")
                    } else {
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value("Average agents", 0))
                            .symbolSize(12).foregroundStyle(BridgeTheme.codex)
                            .accessibilityLabel("\(bucketLabel(point.day)): recorded zero-duration requests")
                    }
                } else if point.turns > 0 {
                    RuleMark(x: .value("Day", point.day, unit: .day), yStart: .value("Average agents", 0), yEnd: .value("Average agents", scale.upperBound))
                        .foregroundStyle(BridgeTheme.textTertiary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .accessibilityLabel("\(bucketLabel(point.day)): timing unavailable")
                } else {
                    PointMark(x: .value("Day", point.day, unit: .day), y: .value("Average agents", 0))
                        .symbol { Image(systemName: "minus").font(.system(size: 7)).foregroundStyle(BridgeTheme.textTertiary) }
                        .accessibilityLabel("\(bucketLabel(point.day)): no dated saved requests; average agents unavailable, not confirmed zero")
                }
            }
            .chartYScale(domain: 0 ... scale.upperBound)
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine().foregroundStyle(BridgeTheme.separator)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.precision(.fractionLength(0)).notation(.compactName))).font(BridgeFont.micro)
                        }
                    }
                }
            }
            .chartXAxis { bucketAxis(count: points.count) }
            .chartXScale(domain: chartDateDomain, range: .plotDimension(padding: 16))
            .environment(\.timeZone, ActivityAnalytics.reportingTimeZone)
            .frame(minHeight: 180, idealHeight: 180, maxHeight: .infinity)
        }
    }

    private typealias HourLoad = HourlyAgentChart.Bucket

    /// Average agents working in each hour: summed agent time over the hour.
    /// Active minutes saturate when work runs around the clock; how many agents
    /// shared each hour still varies and says more.
    private func agentsAtWork(_ points: [ActivityAccounting.Point]) -> [HourLoad] {
        HourlyAgentChart.buckets(points)
    }

    private func agentsPerHourChart(_ hours: [HourLoad]) -> some View {
        let peak = hours.filter { $0.averageAgents != nil }.max { ($0.averageAgents ?? 0) < ($1.averageAgents ?? 0) }
        let scale = HourlyAgentChart.Scale(values: hours.map(\.averageAgents))
        let start = hours.first?.start ?? chartCutoff
        let end = max(start.addingTimeInterval(1), hours.last?.end ?? reportNow)
        let ticks = HourlyAgentChart.ticks(from: start, to: end)
        let format: (Double) -> String = {
            if $0 > 0 && $0 < 0.05 { return "<0.1" }
            return $0.formatted(.number.precision(.fractionLength(1)).notation(.compactName))
        }
        return reportCard {
            CardHeader(title: "Agents at work, hour by hour", icon: "person.2.wave.2",
                       subtitle: peak.flatMap { hour in hour.averageAgents.map { "Busiest: \(format($0)) agents on average · \(HourlyAgentChart.intervalLabel(hour))" } } ?? "No timed requests yet",
                       info: "Average agents working during the time shown, based on saved request start and end times, including waits. A value of 0.5 means one agent worked for half that time; 4.5 can mean four throughout and a fifth for half. These are time averages, not a scaling factor or a current live-agent count. Requests overlapping in the same session count once, and copied history is not another agent. Narrow edge bars cover only the part of an hour in this window. Open requests without a saved end time are not counted yet, so even a measured bar may be incomplete. A dotted line means requests were saved without usable timing; a dash means no dated requests were saved. Neither proves no work happened.")
            Chart(hours) { hour in
                if let agents = hour.averageAgents {
                    if agents > 0 {
                        RectangleMark(xStart: .value("From", hour.barStart), xEnd: .value("To", hour.barEnd),
                                      yStart: .value("Average agents", 0), yEnd: .value("Average agents", agents))
                            .foregroundStyle(isCurrentBucket(hour.hourStart) ? BridgeTheme.codex : BridgeTheme.codex.opacity(0.62))
                            .cornerRadius(2)
                            .accessibilityLabel(HourlyAgentChart.intervalLabel(hour))
                            .accessibilityValue("\(format(agents)) agents on average over the time shown, not a live count; requests without end times are not included")
                    } else {
                        PointMark(x: .value("Hour", hour.midpoint), y: .value("Average agents", 0))
                            .symbolSize(12).foregroundStyle(BridgeTheme.codex)
                            .accessibilityLabel(HourlyAgentChart.intervalLabel(hour))
                            .accessibilityValue("Recorded zero-duration requests; open requests without end times are not included")
                    }
                } else if hour.hasObservations {
                    RuleMark(x: .value("Hour", hour.midpoint), yStart: .value("Average agents", 0), yEnd: .value("Average agents", scale.upperBound))
                        .foregroundStyle(BridgeTheme.textTertiary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .accessibilityLabel("\(HourlyAgentChart.intervalLabel(hour)): timing unavailable")
                } else {
                    PointMark(x: .value("Hour", hour.midpoint), y: .value("Average agents", 0))
                        .symbol { Image(systemName: "minus").font(.system(size: 7)).foregroundStyle(BridgeTheme.textTertiary) }
                        .accessibilityLabel("\(HourlyAgentChart.intervalLabel(hour)): no dated saved requests; average agents unavailable, not confirmed zero")
                }
            }
            .chartYScale(domain: 0 ... scale.upperBound)
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine().foregroundStyle(BridgeTheme.separator)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.precision(.fractionLength(0)).notation(.compactName))).font(BridgeFont.micro)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: ticks.map(\.date)) { value in
                    AxisValueLabel(centered: false, anchor: value.index == 0 ? .topLeading : value.index == ticks.count - 1 ? .topTrailing : .top) {
                        if let date = value.as(Date.self), let tick = ticks.first(where: { $0.date == date }) {
                            VStack(spacing: 1) {
                                Text(tick.timeLabel)
                                Text(tick.dateLabel).foregroundStyle(BridgeTheme.textTertiary)
                            }.font(BridgeFont.micro).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .chartXScale(domain: start ... end, range: .plotDimension(padding: 0))
            .environment(\.timeZone, ActivityAnalytics.reportingTimeZone)
            .frame(minHeight: 180, idealHeight: 180, maxHeight: .infinity)
        }
    }

    /// Requests per hour, stacked by provider. Replaces the weekday grid for
    /// the 24-hour view, where a week-shaped chart would be mostly empty.
    private func requestsByHourCard(_ data: TokenChartData) -> some View {
        let series = ["Claude", "Codex", "Grok", "Unattributed"].filter { name in data.requests.contains { $0.series == name } }
        let peak = data.days.filter { $0.end.timeIntervalSince($0.windowStart) >= 3_599.999 }.max { $0.modelStepCount < $1.modelStepCount }
        let total = data.period.observedModelSteps
        let overnightShare = readyReport.overnightShare
        let scale = ChartScale(stacked: data.requests.map { ($0.day, $0.tokens) })
        return reportCard {
            CardHeader(title: "Model steps per hour", icon: "chart.bar.xaxis",
                       subtitle: total == 0 ? "No observed steps in the last 24 hours" : "\(total.formatted()) observed model steps · by provider",
                       info: "The same deduplicated model steps as Models and the API, dated by their own provider event time. Not conversation-turn or human-prompt counts. The brightest bars are the current hour.") {
                HStack(spacing: 6) {
                    if let peak, peak.modelStepCount > 0 {
                        Tag(text: "Busiest: \(hourLabel(peak.day))", color: BridgeTheme.codex)
                            .help("\(peak.modelStepCount) observed model steps in that full hour")
                    }
                    if let overnightShare, overnightShare >= 0.1 {
                        Tag(text: "\(percentText(overnightShare)) overnight", color: BridgeTheme.brand)
                            .help("Requests between midnight and 7 AM")
                    }
                }
            }
            if total == 0 {
                Text("No dated observed model steps in this window.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(data.requests) { bar in
                    BarMark(x: .value("Hour", bar.day, unit: .hour), y: .value("Observed model steps", bar.tokens))
                        .foregroundStyle(by: .value("Provider", bar.series))
                        .opacity(isCurrentBucket(bar.day) ? 1 : 0.78)
                        .cornerRadius(2)
                        .accessibilityLabel("\(bar.series), \(hourLabel(bar.day))")
                        .accessibilityValue("\(bar.tokens) observed model steps")
                }
                .chartForegroundStyleScale(domain: series, range: series.map { $0 == "Unattributed" ? BridgeTheme.textSecondary : BridgeTheme.color(forParticipant: $0) })
                .chartLegend(position: .top, alignment: .trailing, spacing: 6)
                .chartYScale(domain: 0 ... scale.upperBound)
                .chartYAxis {
                    AxisMarks(position: .leading, values: scale.ticks) { value in
                        AxisGridLine().foregroundStyle(BridgeTheme.separator)
                        AxisValueLabel { if let amount = value.as(Double.self) { Text(amount.formatted(.number.notation(.compactName))).font(BridgeFont.micro) } }
                    }
                }
                .chartXAxis { bucketAxis(count: data.days.count) }
                .chartXScale(domain: chartDateDomain, range: .plotDimension(padding: 16))
                .environment(\.timeZone, ActivityAnalytics.reportingTimeZone)
                .frame(height: 170)
            }
        }
    }

    private func hoursLabel(_ seconds: Double) -> String {
        let hours = seconds / 3_600
        return hours >= 10 ? "\(Int(hours.rounded()))h" : String(format: "%.1fh", hours)
    }

    private func isToday(_ day: Date) -> Bool {
        reportCalendar.isDate(reportNow, inSameDayAs: Date()) && reportCalendar.isDate(day, inSameDayAs: reportNow)
    }

    /// True for the bucket that contains "now": this hour or today.
    private func isCurrentBucket(_ start: Date) -> Bool {
        isHourly ? reportCalendar.isDate(start, equalTo: reportNow, toGranularity: .hour) : isToday(start)
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = ActivityAnalytics.reportingTimeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private func hourLabel(_ date: Date) -> String { Self.hourFormatter.string(from: date) }

    private func bucketLabel(_ date: Date) -> String {
        isHourly ? "\(chartDate(date)) \(hourLabel(date))" : chartDate(date)
    }

    private func bucketAxis(count: Int) -> some AxisContent {
        // Two charts share the minimum-width report row. Six-hour labels
        // remain readable there; the data itself still retains every hour.
        AxisMarks(values: isHourly ? .stride(by: .hour, count: 6) : .stride(by: .day, count: count > 14 ? 5 : count > 8 ? 2 : 1)) { value in
            AxisValueLabel(centered: !isHourly) {
                if let date = value.as(Date.self) {
                    Text(isHourly ? hourLabel(date) : count <= 8 ? weekdayLabel(date) : chartDate(date))
                        .font(BridgeFont.micro).fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private func weekdayLabel(_ date: Date) -> String {
        if isToday(date) { return "Today" }
        let formatter = DateFormatter()
        formatter.timeZone = ActivityAnalytics.reportingTimeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEd")
        return formatter.string(from: date)
    }

    private func chartDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = ActivityAnalytics.reportingTimeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: date)
    }

    private struct TokenBar: Identifiable {
        var day: Date
        var series: String
        var tokens: Int
        var id: String { "\(series):\(day.timeIntervalSince1970)" }
    }
    private struct TokenChartData {
        var bars: [TokenBar]
        /// Observed model steps per provider, not native-turn counts.
        var requests: [TokenBar]
        var days: [ActivityAccounting.Point]
        var period: ActivityAccounting.Totals
        var series: ActivityAccounting.Series
    }
    private var tokenBars: TokenChartData {
        let report = chartAccounting
        let series = readyReport.chartSeries
        var bars: [TokenBar] = [], steps: [TokenBar] = []
        for point in series.points {
            for provider in point.byProvider.keys.sorted() {
                guard let usage = point.byProvider[provider] else { continue }
                let name = provider == "none" ? "Unattributed" : provider.capitalized
                if let tokens = usage.tokensKnown { bars.append(TokenBar(day: point.start, series: name, tokens: tokens)) }
                if usage.modelStepCount > 0 { steps.append(TokenBar(day: point.start, series: name, tokens: usage.modelStepCount)) }
            }
        }
        return TokenChartData(bars: bars, requests: steps, days: series.points, period: report.totals, series: series)
    }

    private func tokensPerDayChart(_ data: TokenChartData) -> some View {
        let series = ["Claude", "Codex", "Grok", "Unattributed"].filter { name in data.bars.contains { $0.series == name } }
        let scale = ChartScale(stacked: data.bars.map { ($0.day, $0.tokens) })
        let interruptions = overview.connectionHistory?.interruptions(from: data.days.first?.windowStart ?? scope.accounting.scope.to, to: data.days.last?.end ?? scope.accounting.scope.to) ?? []
        return reportCard {
            CardHeader(title: isHourly ? "Tokens per hour" : "Tokens per day", icon: "chart.bar.fill",
                       subtitle: "\(knownTokenValue(data.period.tokensKnown, partial: data.period.tokensArePartial)) local tokens · \(period == .all ? "last 30 days (chart subset)" : "same accounting window as the table")",
                       info: "Canonical accounting/1 usage receipts. A ? means missing usage, not zero or a confirmed API outage. Missing readings can follow connection, provider or collection problems; a gap alone does not identify the cause. Usage known only across a native interval stays separate when it cannot fit a single bucket. Your provider account total is a different scope. " + ActivityConnectionHistory.explanation + (period == .all ? " This chart shows the separately labeled last 30 days." : "")) {
                HStack(spacing: 6) {
                    if !interruptions.isEmpty {
                        Image(systemName: "wifi.slash").foregroundStyle(BridgeTheme.warning)
                            .help(ActivityConnectionHistory.explanation)
                            .accessibilityLabel("Network interruption observed on this Mac; shaded intervals")
                    }
                    Text(period == .all ? "Last 30 days" : period.short).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
            Chart {
                ForEach(interruptions) { interval in
                    RectangleMark(xStart: .value("Network interruption start", interval.start), xEnd: .value("Network interruption end", interval.end),
                                  yStart: .value("Plot baseline", 0), yEnd: .value("Plot extent", scale.upperBound))
                        .foregroundStyle(BridgeTheme.warning.opacity(0.10))
                        .accessibilityLabel("Network interruption observed on this Mac")
                        .accessibilityValue("\(bucketLabel(interval.start)); connection evidence only, not missing or zero tokens")
                }
                ForEach(data.bars) { bar in
                    if bar.tokens > 0 {
                        BarMark(x: .value("Day", bar.day, unit: isHourly ? .hour : .day), y: .value("Known tokens", bar.tokens))
                            .foregroundStyle(by: .value("Provider", bar.series)).cornerRadius(2)
                            .accessibilityLabel("\(bar.series), \(bucketLabel(bar.day))")
                            .accessibilityValue("\(bar.tokens.formatted()) recorded tokens; lower bound")
                    } else {
                        PointMark(x: .value("Day", bar.day, unit: isHourly ? .hour : .day), y: .value("Known tokens", 0))
                            .foregroundStyle(by: .value("Provider", bar.series)).symbolSize(16)
                            .accessibilityLabel("\(bar.series), \(bucketLabel(bar.day)): reported zero")
                    }
                }
                // No-record and missing-measurement buckets have different
                // symbols, but neither is upgraded to reported zero usage.
                ForEach(data.days.filter { $0.measuredTokens == nil && $0.turns > 0 }) { day in
                    RuleMark(x: .value("Unmeasured day", day.day, unit: isHourly ? .hour : .day),
                             yStart: .value("Known tokens", 0), yEnd: .value("Known tokens", scale.upperBound))
                        .foregroundStyle(BridgeTheme.textTertiary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .overlay, alignment: .top) { Image(systemName: "questionmark.circle").font(.caption2).foregroundStyle(BridgeTheme.textTertiary) }
                        .accessibilityLabel("\(bucketLabel(day.day)): " + ActivityConnectionHistory.gapDescription(hasRecords: true, networkInterrupted: interruptions.contains { $0.start < day.end && $0.end > day.windowStart }))
                }
                ForEach(data.days.filter { $0.measuredTokens == nil && $0.turns == 0 }) { day in
                    PointMark(x: .value("No records", day.day, unit: isHourly ? .hour : .day), y: .value("Known tokens", 0))
                        .symbol { Image(systemName: "minus").font(.system(size: 7)).foregroundStyle(BridgeTheme.textTertiary) }
                        .accessibilityLabel("\(bucketLabel(day.day)): " + ActivityConnectionHistory.gapDescription(hasRecords: false, networkInterrupted: interruptions.contains { $0.start < day.end && $0.end > day.windowStart }))
                }
            }
            .chartForegroundStyleScale(domain: series, range: series.map { $0 == "Unattributed" ? BridgeTheme.textSecondary : BridgeTheme.color(forParticipant: $0) })
            .chartLegend(position: .top, alignment: .trailing, spacing: 6)
            .chartYScale(domain: 0 ... scale.upperBound)
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine().foregroundStyle(BridgeTheme.separator)
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(ActivityFormat.compact(Int(exactly: amount.rounded()))).font(BridgeFont.micro) } }
                }
            }
            .chartXAxis { bucketAxis(count: data.days.count) }
            .chartXScale(domain: chartDateDomain, range: .plotDimension(padding: 16))
            .environment(\.timeZone, ActivityAnalytics.reportingTimeZone)
            .frame(minHeight: 180, idealHeight: 180, maxHeight: .infinity)
            if let unplaced = data.series.unallocated.tokensKnown, unplaced > 0 {
                Text("\(ActivityFormat.compact(unplaced)) known tokens are included in the total but cannot be assigned to one \(isHourly ? "hour" : "day").")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }
        }
    }

    private var weekHourCard: some View {
        let measured = readyReport.weekdayHour
        let grid = measured ?? Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let total = grid.flatMap { $0 }.reduce(0, +)
        let night = grid.reduce(0) { $0 + $1.prefix(7).reduce(0, +) }
        let peak = grid.enumerated().flatMap { day, hours in hours.enumerated().map { (day, $0.offset, $0.element) } }.max { $0.2 < $1.2 }
        let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return reportCard {
            CardHeader(title: "When agents work", icon: "calendar.day.timeline.left",
                       subtitle: "Observed model steps by weekday and hour · \(period == .all ? "last 30 days" : period.phrase)",
                       info: "The shared accounting receipt timestamps, grouped by weekday and hour. Brighter means more observed model steps, not human prompts or native-turn completions. Missing history is not confirmed inactivity.") {
                HStack(spacing: 6) {
                    if let peak, peak.2 > 0 {
                        Tag(text: "Busiest: \(days[peak.0]) \(hourName(peak.1))", color: BridgeTheme.codex)
                    }
                    if total > 0, Double(night) / Double(total) >= 0.1 {
                        Tag(text: "\(Int((Double(night) / Double(total) * 100).rounded()))% overnight", color: BridgeTheme.brand)
                            .help("Requests between midnight and 7 AM")
                    }
                }
            }
            if measured == nil || total == 0 {
                Text(measured == nil ? "Activity pattern unavailable for this window." : "No dated model steps in this view.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
            } else {
                WeekHourGrid(counts: grid)
            }
        }
    }

    private func hourName(_ hour: Int) -> String {
        var components = DateComponents(); components.hour = hour
        let date = Calendar(identifier: .gregorian).date(from: components) ?? Date()
        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    private var workMixCard: some View {
        let mix = memo("overview.workMix") { accounting.categoryMix }
        let scale = ActivityAnalytics.categoryBarScale(mix)
        let withTools = memo("overview.workMixTools") { accounting.nativeObservations.filter { $0.countersIncludedInWindow && !$0.categories.isEmpty }.count }
        let toolCalls = OverviewToolCallKPI.make(accounting)
        return reportCard {
            CardHeader(title: "What the work involved", icon: "square.stack.3d.up.fill",
                       subtitle: turns.isEmpty ? nil : "From the tools agents used",
                       info: "Date-qualified tool observations from the shared accounting report. Categories are inferred from tools, not token spending. \(withTools) native records have allocated tool categories; unplaced native counters stay separate.")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("Recorded tool calls").font(BridgeFont.secondaryMedium)
                        InfoButton(title: "Recorded tool calls", text: OverviewToolCallKPI.explanation)
                    }
                    Text(toolCalls.detail).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
                Spacer(minLength: 6)
                Text(toolCalls.value).font(BridgeFont.heading.monospacedDigit())
                    .accessibilityLabel("Recorded tool calls, \(toolCalls.value), \(toolCalls.detail)")
            }.padding(10).bridgeWell(cornerRadius: BridgeTheme.radiusWell)
            if mix.isEmpty {
                Text("No tool categories recorded in this view.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(mix.prefix(7))) { share in
                        let color = BridgeTheme.category(share.name, in: mix.map(\.name))
                        HStack(spacing: 8) {
                            Image(systemName: BridgeTheme.categorySymbol(share.name)).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(color).frame(width: 16)
                            Text(share.name).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textPrimary).frame(width: 104, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule().fill(color.opacity(0.85))
                                    .frame(width: min(proxy.size.width, max(3, proxy.size.width * CGFloat(scale.barFraction(for: share.value) ?? 0))))
                            }.frame(height: 6)
                            Text(scale.total.map { shareText(share.value, $0) } ?? "—")
                                .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary).frame(width: 32, alignment: .trailing)
                        }
                        .help(share.overflow ? "\(share.name): count exceeds the supported range" : "\(share.name): \(share.value.formatted()) tool calls")
                    }
                }
            }
        }
    }

    private var modelsCard: some View {
        let shares = modelRows.filter { $0.requests > 0 }
        let total = max(1, shares.reduce(0) { $0 + $1.requests })
        return reportCard {
            CardHeader(title: "Models", icon: "cpu.fill",
                       subtitle: shares.isEmpty ? nil : "Share of observed model steps",
                       info: "The same step-level evidence as Models. One native conversation turn can contain many model steps. Missing or repeated usage updates are not invented as extra requests.") {
                Button("Details") { navigation.navigate(to: .models) }.buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
            }
            if shares.isEmpty {
                Text("No step-level model evidence in this view yet.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
            } else {
                VStack(spacing: 9) {
                    ForEach(Array(shares.prefix(6))) { share in
                        HStack(spacing: 8) {
                            AgentAvatar(name: share.provider.rawValue.capitalized, size: 14)
                            Text(modelTitle(share)).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                                .lineLimit(1).frame(width: 128, alignment: .leading).help(share.name ?? "Model not recorded")
                            GeometryReader { proxy in
                                Capsule().fill(BridgeTheme.color(for: share.provider).opacity(0.8))
                                    .frame(width: min(proxy.size.width, max(0, proxy.size.width * CGFloat(share.requests) / CGFloat(total))))
                            }.frame(height: 6)
                            Text(shareText(share.requests, total))
                                .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary).frame(width: 32, alignment: .trailing)
                        }
                        .help("\(modelTitle(share)): \(modelCountText(share)) observed model steps · \(knownTokenValue(share.tokens, partial: share.tokensArePartial)) tokens")
                    }
                }
            }
        }
    }

    private var projectsCard: some View {
        let ranked = memo("overview.projects") {
            Array(projectGroups.map { group -> (String, Int, Int?) in
                let report = projectAccountingReports[group.path == ActivityAccountingQuery.unattributedProjectID ? "" : group.path] ?? readyReport.emptyAccounting
                return (group.path, report.totals.observedModelSteps, report.totals.tokensKnown)
            }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6))
        }
        let top = max(1, ranked.map(\.1).max() ?? 1)
        return reportCard {
            CardHeader(title: "Projects", icon: "folder.fill", subtitle: "Observed model steps per project") {
                Button("All projects") { navigation.navigate(to: .projects) }.buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
            }
            if ranked.isEmpty { Text("No projects in this view.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary) }
            VStack(spacing: 9) {
                ForEach(Array(ranked), id: \.0) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(BridgeTheme.textTertiary).frame(width: 14)
                        Text(projectName(item.0)).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                            .lineLimit(1).truncationMode(.tail).frame(width: 170, alignment: .leading)
                        // When in the period the project was busy.
                        let trend = readyReport.projectTrends[item.0 == ActivityAccountingQuery.unattributedProjectID ? "" : item.0]
                        Group {
                            if let trend { MiniBars(values: trend.values, tint: BridgeTheme.brand, emptyIndices: trend.empty, height: 14) }
                            else { Color.clear }
                        }
                        .frame(width: 56, height: 14)
                        GeometryReader { proxy in
                            Capsule().fill(BridgeTheme.brand.opacity(0.7)).frame(width: max(3, proxy.size.width * CGFloat(item.1) / CGFloat(top)))
                        }.frame(height: 6)
                        Text(item.1.formatted()).font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .help("\(projectName(item.0))\n\(item.1) observed model steps · \(ActivityFormat.compact(item.2)) known tokens")
                }
            }
        }
    }

    private var tokenMixCard: some View {
        let composition = accounting.totals.composition
        let story = composition.flatMap(TokenMixStory.init)
        return reportCard {
            CardHeader(title: "Where tokens went", icon: "circle.hexagongrid.fill",
                       subtitle: composition.map { "Breakdown covers \(ActivityFormat.compact($0.total)) of \(ActivityFormat.compact(accounting.totals.tokensKnown)) known tokens" },
                       info: "Canonical reconciled token components from the same accounting receipts as the totals. Cache reads and reasoning subsets are never added twice. New input is fresh text; written may include provider-reported reasoning counts, never private reasoning content. Agents send the conversation again with every step, so most tokens are context the model has already seen; that re-read context is billed at a discount.\(composition.map { " Based on \($0.receipts) usage records with a consistent breakdown." } ?? "")")
            if let composition, let story, story.rereadDominates {
                HStack(alignment: .center, spacing: 12) {
                    Text(TokenMixStory.percent(story.rereadShare))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(BridgeTheme.codex)
                        .lineLimit(1).fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("was context re-read").font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
                        Text(story.rereadPerWritten.map { "About \(Int($0.rounded()).formatted()) tokens re-read for every token written" } ?? "Nothing written in this view")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !story.remainder.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The other \(TokenMixStory.percent(1 - story.rereadShare))")
                            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                        TokenCompositionBar(composition: composition, omitReread: true)
                    }
                }
                HStack(spacing: 0) {
                    miniStat(ActivityFormat.compact(composition.rereadContext), "re-read", BridgeTheme.codex)
                    miniStat(ActivityFormat.compact(composition.freshInput), "new input", BridgeTheme.gemini)
                    miniStat(ActivityFormat.compact(composition.output), "written", BridgeTheme.claude)
                }
            } else if let composition {
                TokenCompositionBar(composition: composition)
                HStack(spacing: 0) {
                    miniStat(ActivityFormat.compact(composition.rereadContext), "re-read", BridgeTheme.codex)
                    miniStat(ActivityFormat.compact(composition.freshInput), "new input", BridgeTheme.gemini)
                    miniStat(ActivityFormat.compact(composition.output), "written", BridgeTheme.claude)
                }
            } else {
                Text("No token breakdowns in this view.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
            }
        }
    }

    private func miniStat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(BridgeTheme.textPrimary)
            HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(label) }
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountDateRange: (from: String, to: String)? {
        guard period == .week || period == .month || period == .all else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ActivityAnalytics.reportingTimeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let from = cutoff.map { formatter.string(from: $0) }
            ?? ActivityAnalytics.accountDays(overview.accountUsage?.daily ?? []).first?.date
        guard let from, let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reportNow)) else { return nil }
        return (from, formatter.string(from: nextDay))
    }

    private var accountingWindowLabel: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let beginning = accounting.scope.from.map { formatter.string(from: $0) } ?? "all saved dates"
        return "Window \(beginning) to \(formatter.string(from: accounting.scope.to)) (end excluded). As of \(formatter.string(from: accounting.scope.asOf))."
    }

    private var aboutThisData: some View {
        DisclosureGroup(isExpanded: $aboutExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Engine \(accounting.schemaVersion) · definitions \(accounting.metricDefinitionsVersion) · local native history. These exact scoped facts also drive the toolbar, CLI, API, briefs and exports. Provider account, goal and Bridge-only counters use visibly different scopes.")
                Text(accountingWindowLabel)
                if aboutExpanded {
                    EvidenceChecksum(report: accounting, revision: readyReport.key.scope.snapshotRevision)
                }
                Text("Native session files are read, never changed. A dash or gap means unknown; reported zero remains zero. Cache and reasoning subsets are not added twice. Interval-only usage stays unallocated when it cannot be dated safely.")
                ForEach(overview.sources) { source in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: source.status == "ok" ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                            .foregroundStyle(source.status == "ok" ? BridgeTheme.success : BridgeTheme.warning).font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.id.hasPrefix("claude") ? "Claude Code sessions" : source.id.hasPrefix("codex") ? "Codex sessions" : source.id)
                                .font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                            Text(source.message).foregroundStyle(BridgeTheme.textTertiary).textSelection(.enabled)
                            Text(source.lastSuccessAt.map { "Last read \(ActivityFormat.relative($0, now: Date()))" } ?? "Not read yet")
                                .foregroundStyle(BridgeTheme.textTertiary)
                        }
                    }
                }
            }
            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        } label: {
            Label("About this data", systemImage: "info.circle").font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textSecondary)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Sessions

    private var sessionDurations: [Double] {
        Array(accounting.sessionWorkSeconds.values)
    }

    private struct SessionRowStats {
        var requests: Int
        var seconds: Double?
        var recent: Bool
        var lastModel: String? = nil
        var lastEvidence: Date? = nil
        var countsArePartial = false
        var unmeasured = false
    }

    /// Top-level sessions, newest first, with their sub-agents folded beneath.
    /// The pinned session leads. A sub-agent whose parent isn't in view stays
    /// top-level so nothing disappears behind a filter.
    private var sessionTree: (roots: [ActivitySession], children: [String: [ActivitySession]]) {
        memo("sessionTree") { ReportScope.sessionTree(sessions, pinnedID: overview.pinnedSessionID) }
    }

    private var sessionRowStats: [String: SessionRowStats] {
        memo("sessionRowStats") {
            let reports = readyReport.bySession
            return Dictionary(uniqueKeysWithValues: sessions.map { session in
                let report = reports[session.id] ?? readyReport.emptyAccounting
                let latest = report.receipts.filter { $0.includedInTotals && $0.kind == .modelStep }.max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
                return (session.id, SessionRowStats(requests: report.totals.observedModelSteps,
                    seconds: report.totals.activeSeconds,
                    recent: ActivityPresentationPolicy.isRecent(latest?.timestamp, now: reportNow), lastModel: latest?.model,
                    lastEvidence: ActivityReportPresentation.lastActivity(report),
                    countsArePartial: report.totals.modelStepsArePartial, unmeasured: report.summary.unmeasuredTurns > 0))
            })
        }
    }

    private var sessionsContent: some View {
        let current = accounting.totals
        let assignments = scope.assignments
        let tree = sessionTree
        let children = memo("sessions.childCount") { sessions.filter(\.isChild).count }
        let shownRoots = Array(tree.roots.prefix(60))
        let live = readyReport.liveWork
        let peakSteps = sessionRowStats.values.map(\.requests).max()
        return VStack(alignment: .leading, spacing: 16) {
            LiveWorkView(summary: live, assignments: assignments, now: reportNow, projectName: projectName,
                         selectedID: navigation.selectedSessionID, select: { navigation.selectedSessionID = $0 }, goals: overview.goals,
                         feed: readyReport.liveFeed,
                         inspect: { session, turn in navigation.inspectTurn(overview: overview, sessionID: session, turnID: turn, snapshotRevision: readyReport.key.scope.snapshotRevision) })
                .padding(.bottom, 6)
            SessionStatsLine(items: [
                .init(value: tree.roots.count.formatted(), label: tree.roots.count == 1 ? "session" : "sessions", icon: "rectangle.stack", help: "Top-level saved sessions in this view, excluding sub-agents; not a model-step or participating-work-session count"),
                .init(value: children.formatted(), label: "sub-agents", icon: "arrow.turn.down.right", help: "Sessions another agent started"),
                .init(value: ActivityReportPresentation.steps(accounting), label: "model steps", icon: "bubble.left.and.text.bubble.right", help: "Same observed model steps as Models, charts and exports; not human prompts"),
                .init(value: ActivityFormat.duration(current.activeSeconds), label: "active", icon: "clock", help: "Time with at least one agent working, overlaps counted once"),
                .init(value: ActivityFormat.duration(current.medianSessionSeconds), label: "typical session", icon: "timer", help: "Core median recorded time among sessions with timed evidence"),
            ])
            if sessions.isEmpty {
                HubEmptyState(icon: "rectangle.stack", title: "No sessions in this view",
                              message: "Try a longer period or clear the filters. Agent Hub picks up new sessions automatically.",
                              actionTitle: isFiltered || provider != "all" ? "Clear filters" : nil,
                              action: { query = ""; provider = "all"; project = "all" })
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sessionGroups(shownRoots, children: tree.children, live: live), id: \.title) { group in
                        Text(group.title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.7)
                            .foregroundStyle(group.live ? BridgeTheme.brand : BridgeTheme.textTertiary)
                            .padding(.leading, 4).padding(.top, 10).padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.sessions) { session in
                            let kids = tree.children[session.id] ?? []
                            sessionRow(session, assignment: assignments[session.id], childCount: kids.count, peakSteps: peakSteps)
                            if !kids.isEmpty, expandedParents.contains(session.id) {
                                ForEach(kids) { child in
                                    sessionRow(child, assignment: assignments[child.id], nested: true, parentTitle: session.title, peakSteps: peakSteps)
                                }
                            }
                        }
                    }
                }
                if tree.roots.count > shownRoots.count {
                    Text("Showing the newest \(shownRoots.count) of \(tree.roots.count). Search or pick a project to find older sessions.")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Active now, then by day, so the list reads as a recent history.
    private func sessionGroups(_ roots: [ActivitySession], children: [String: [ActivitySession]], live: LiveWork.Summary)
        -> [(title: String, live: Bool, sessions: [ActivitySession])] {
        let active = Set(live.active.flatMap { job in job.agents.filter { $0.state != .finished }.map(\.id) })
        let clocks = sessionRowStats
        func lastEvidence(_ root: ActivitySession) -> Date? {
            var stack = [root], visited = Set<String>(), dates: [Date] = []
            while let value = stack.popLast() {
                guard visited.insert(value.id).inserted else { continue }
                if let date = clocks[value.id]?.lastEvidence { dates.append(date) }
                stack.append(contentsOf: children[value.id] ?? [])
            }
            return dates.max()
        }
        let now = Date()
        let order = SessionActivityGrouping.Group.allCases.map(\.rawValue)
        var buckets: [String: [ActivitySession]] = [:]
        for root in roots {
            let open = active.contains(root.id) || (children[root.id] ?? []).contains(where: { active.contains($0.id) })
            let title = SessionActivityGrouping.group(lastEvidence: lastEvidence(root), openOrRecent: open, now: now).rawValue
            buckets[title, default: []].append(root)
        }
        return order.compactMap { title in buckets[title].map { (title, title == order[0], $0) } }
    }

    private func sessionRow(_ session: ActivitySession, assignment: AgentPersonaCatalog.Assignment?, childCount: Int = 0, nested: Bool = false,
                            parentTitle: String? = nil, peakSteps: Int? = nil) -> some View {
        let stats = sessionRowStats[session.id] ?? SessionRowStats(requests: 0, seconds: nil, recent: false)
        let selected = navigation.selectedSessionID == session.id
        let pinned = overview.pinnedSessionID == session.id
        let expanded = expandedParents.contains(session.id)
        return HStack(spacing: 11) {
            if nested {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BridgeTheme.textTertiary).frame(width: 16)
            }
            AgentPortrait(persona: assignment?.persona, provider: session.provider, size: nested ? 24 : 30, recent: stats.recent)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(BridgeTheme.brand).help("Pinned")
                    }
                    if session.goal != nil {
                        Image(systemName: "scope").font(.system(size: 10, weight: .semibold)).foregroundStyle(BridgeTheme.success).help("Has a goal")
                    }
                    Text(ActivityFormat.headline(ActivityTitles.display(session.goal?.objective ?? session.title, provider: session.provider,
                                                                        projectPath: session.projectPath, parentTitle: parentTitle), limit: 90))
                        .font(nested ? BridgeFont.secondaryMedium : BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                }
                HStack(spacing: 5) {
                    if !nested {
                        Image(systemName: "folder").font(.system(size: 9))
                        Text(projectName(session.projectPath))
                    }
                    if let model = stats.lastModel {
                        if !nested { Text("·") }
                        Text(ModelNaming.display(model))
                    }
                    if let role = assignment?.role {
                        Text("·")
                        Image(systemName: role.symbol).font(.system(size: 9))
                        Text(role.title)
                    }
                }
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if childCount > 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if expanded { expandedParents.remove(session.id) } else { expandedParents.insert(session.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill").font(.system(size: 9))
                        Text("\(childCount)").font(BridgeFont.captionMedium.monospacedDigit())
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .foregroundStyle(expanded ? BridgeTheme.brand : BridgeTheme.textSecondary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background((expanded ? BridgeTheme.brand : Color.white).opacity(expanded ? 0.14 : 0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide sub-agents" : "Show \(childCount) sub-\(childCount == 1 ? "agent" : "agents")")
                .accessibilityLabel("\(childCount) sub-agents")
                .accessibilityValue(expanded ? "Shown" : "Hidden")
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(ActivityFormat.relative(stats.lastEvidence, now: Date()))
                    .help("Latest recorded work evidence, not a metadata refresh")
                    .font(BridgeFont.captionMedium.monospacedDigit()).foregroundStyle(stats.recent ? BridgeTheme.success : BridgeTheme.textSecondary)
                Text(stats.requests == 0 ? (stats.unmeasured ? "Steps unmeasured" : "No observed model steps") : "\(stats.countsArePartial ? "≥" : "")\(stats.requests) model \(stats.requests == 1 ? "step" : "steps")\(stats.seconds.map { " · " + ActivityFormat.duration($0) } ?? "")")
                    .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                    .help("Canonical model-step count and recorded time for this session, excluding inherited parent work" + (session.historyComplete ? "" : ". Only part of this session's history was available, so its numbers are minimums."))
                if let peakSteps, peakSteps > 0, stats.requests > 0 {
                    // Relative size beside its neighbours; the count above is the value.
                    Capsule().fill(Color.white.opacity(0.06)).frame(width: 72, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule().fill(BridgeTheme.color(for: session.provider).opacity(0.85))
                                .frame(width: max(3, 72 * CGFloat(stats.requests) / CGFloat(peakSteps)), height: 3)
                        }
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 96, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, nested ? 6 : 9)
        .padding(.leading, nested ? 18 : 0)
        .background(selected ? Color.white.opacity(0.09) : (nested ? BridgeTheme.surface.opacity(0.55) : BridgeTheme.surface),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? BridgeTheme.brand.opacity(0.5) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { navigation.selectedSessionID = session.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Open session details")
    }

    // MARK: Goals

    private var goalContent: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            let goalSessions = sessions.filter { $0.goal != nil }
            if goalSessions.isEmpty {
                HubEmptyState(icon: "scope", title: "No goals in this view",
                              message: "A goal appears when you give Codex a long-running objective. Its agents, timeline and progress show up here.")
            }
            ForEach(goalSessions) { session in
                GoalDetailCard(session: session, overview: overview, snapshotRevision: readyReport.key.scope.snapshotRevision,
                               selectSession: { navigation.selectedSessionID = $0 })
                    .acceptanceProbe("goal-card")
            }
        }
    }

    // MARK: Projects

    private var projectLabels: [String: String] { prepared?.scope.projectLabels ?? ReportScope.labels(for: Set(projects)) }

    private func projectName(_ path: String?) -> String {
        guard let path else { return ActivityDisplay.project(nil) }
        if path == ActivityAccountingQuery.unattributedProjectID { return "Unattributed project" }
        return projectLabels[path] ?? ActivityDisplay.project(path)
    }

    /// Most work first (observed model steps), then most sessions, then name.
    private var projectGroups: [(path: String, sessions: [ActivitySession])] {
        memo("projectGroups") {
            let reports = readyReport.byProject
            func steps(_ path: String) -> Int {
                reports[path == ActivityAccountingQuery.unattributedProjectID ? "" : path]?.totals.observedModelSteps ?? 0
            }
            return Dictionary(grouping: sessions, by: { $0.projectPath ?? ActivityAccountingQuery.unattributedProjectID })
                .map { (path: $0.key, sessions: $0.value) }
                .sorted {
                    let left = steps($0.path), right = steps($1.path)
                    if left != right { return left > right }
                    if $0.sessions.count != $1.sessions.count { return $0.sessions.count > $1.sessions.count }
                    return $0.path < $1.path
                }
        }
    }

    private var projectContent: some View {
        let assignments = scope.assignments
        let shipped = readyReport.shipped
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 14, weight: .semibold)).foregroundStyle(BridgeTheme.brand)
                    .frame(width: 30, height: 30).background(BridgeTheme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Shipped code").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                        InfoButton(title: "Shipped code", text: (["Scan projects reads branches, changed files and recent commits with their line counts for up to 12 project folders, starting with the pinned goal. It only reads; nothing is changed."] + shipped.notes).joined(separator: "\n\n"))
                    }
                    Text(shipped.hasScan ? "Commits and lines changed, linked to the agent sessions that worked on them · \(ShippedPresentation.scanLine(shipped.totals, now: reportNow).lowercased())"
                                         : "Scan your projects to see commits and lines changed, linked to the sessions that worked on them.")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(2)
                }
                Spacer()
                Button(model.isAnalyzingRepositories ? "Scanning…" : (shipped.hasScan ? "Scan again" : "Scan projects")) { model.analyzeActivityRepositories() }
                    .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                    .disabled(model.isAnalyzingRepositories || overview.sessions.compactMap(\.projectPath).isEmpty)
            }
            .bridgeCard(padding: 14)
            if shipped.hasScan {
                MetricStrip(items: ShippedPresentation.metrics(shipped, periodPhrase: period.phrase), tint: BridgeTheme.brand)
            }
            ForEach(projectGroups, id: \.path) { group in projectCard(group, assignments: assignments) }
            if projectGroups.isEmpty {
                HubEmptyState(icon: "folder.badge.questionmark", title: "No projects in this view", message: "Sessions show up here once Agent Hub knows which folder they worked in.")
            }
        }
    }

    private var projectAccountingReports: [String: ActivityAccounting.Report] {
        readyReport.byProject
    }

    private func projectCard(_ group: (path: String, sessions: [ActivitySession]), assignments: [String: AgentPersonaCatalog.Assignment]) -> some View {
        let key = group.path == ActivityAccountingQuery.unattributedProjectID ? "" : group.path
        let report = projectAccountingReports[key] ?? readyReport.emptyAccounting
        let last = group.sessions.map(\.updatedAt).max()
        let repo = overview.repositories.first { $0.root == group.path || $0.worktrees.contains { $0.path == group.path } }
        let noGit = repo.map { $0.worktrees.isEmpty && $0.commits.isEmpty } ?? false
        let providers = Array(Set(group.sessions.map(\.provider))).sorted { $0.rawValue < $1.rawValue }
        let trend = readyReport.projectTrends[key]
        let allSteps = accounting.totals.observedModelSteps
        let share = allSteps > 0 ? Double(report.totals.observedModelSteps) / Double(allSteps) : nil
        return reportCard {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "folder.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(BridgeTheme.brand)
                    .frame(width: 34, height: 34)
                    .background(BridgeTheme.brand.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(projectName(group.path)).font(BridgeFont.title).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                        if let share, share > 0 {
                            Tag(text: "\(percentText(share)) of model steps", color: BridgeTheme.brand)
                                .help("This project's share of observed model steps in \(period.phrase)")
                        }
                        if noGit {
                            Tag(text: "No Git details").help(repo?.warning == nil ? "No branches or commits were found yet" : "Not a Git repository, or it couldn't be read")
                        }
                    }
                    Text(group.path == ActivityAccountingQuery.unattributedProjectID ? "Project folder not recorded" : group.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(BridgeFont.mono).foregroundStyle(BridgeTheme.textTertiary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                PortraitStack(items: group.sessions.prefix(6).map { (assignments[$0.id]?.persona, $0.provider, false) }, size: 22, limit: 5)
                HStack(spacing: -4) { ForEach(providers, id: \.self) { AgentAvatar(name: $0.rawValue.capitalized, size: 14) } }
            }
            let stats = HStack(spacing: 0) {
                projectStat("\(report.totals.sessions)", "sessions", "rectangle.stack")
                projectStat(ActivityReportPresentation.steps(report), "model steps", "bubble.left.and.text.bubble.right")
                projectStat(ActivityReportPresentation.tokens(report), "tokens", "circle.hexagongrid")
                projectStat("\(report.totals.modelIdentities)", "models", "cpu")
                projectStat(ActivityFormat.relative(last, now: Date()), "last updated", "clock")
            }
            if let trend, trend.values.contains(where: { $0 != nil }) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        projectTrend(trend).frame(width: 300)
                        Rectangle().fill(BridgeTheme.separator).frame(width: 1).padding(.vertical, 4)
                        stats.frame(minWidth: 420)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10).bridgeWell()
                    VStack(spacing: 10) {
                        projectTrend(trend)
                        stats
                    }
                    .padding(10).bridgeWell()
                }
            } else {
                stats.padding(.vertical, 8).bridgeWell()
            }
            if let shipped = readyReport.shipped.project(containing: group.path == ActivityAccountingQuery.unattributedProjectID ? nil : group.path), shipped.available {
                shippedRow(shipped)
            }
            if let repo, !noGit { repositoryDetails(repo) }
            VStack(spacing: 4) {
                ForEach(Array(group.sessions.prefix(3))) { sessionRow($0, assignment: assignments[$0.id]) }
            }
            if group.sessions.count > 3 {
                Button("Show all \(group.sessions.count) sessions") { project = group.path; navigation.navigate(to: .now) }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
            }
        }
    }

    /// Observed model steps across the period, brightest for the current bucket.
    private func projectTrend(_ trend: PreparedReportScope.Trend) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MiniBars(values: trend.values, tint: BridgeTheme.brand, emptyIndices: trend.empty, height: 30)
            HStack {
                Text(isHourly ? "24h ago" : (period == .all ? "30 days ago" : (cutoff.map(weekdayLabel) ?? "")))
                Spacer()
                Text(isHourly ? "Steps per hour" : "Steps per day")
                Spacer()
                Text(isHourly ? "Now" : "Today")
            }
            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isHourly ? "Model steps per hour" : "Model steps per day")
        .accessibilityValue(MiniBarsPresentation.accessibilitySummary(trend.values, emptyIndices: trend.empty))
    }

    /// This project's lines and commits, and how many are linked to sessions.
    @ViewBuilder private func shippedRow(_ project: ShippedCodeReport.Project) -> some View {
        if project.commits == 0 {
            Label("No commits in \(period.phrase)\(project.sessions > 0 ? " · \(project.sessions) agent \(project.sessions == 1 ? "session" : "sessions") here" : "")", systemImage: "arrow.triangle.branch")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                .padding(.horizontal, 10).padding(.vertical, 6)
        } else {
            shippedTotals(project)
        }
    }

    private func shippedTotals(_ project: ShippedCodeReport.Project) -> some View {
        HStack(spacing: 12) {
            LinesChangedLabel(lines: project.lines, font: .system(size: 13, weight: .semibold))
            Text("\(project.commits) \(project.commits == 1 ? "commit" : "commits") · \(project.linkedCommits) linked")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            if project.coAuthoredCommits > 0 {
                Tag(text: "\(project.coAuthoredCommits) co-authored", color: BridgeTheme.brand)
            }
            Spacer(minLength: 6)
            if let perLine = project.tokensPerLine {
                Text("\(ShippedPresentation.tokensPerLine(perLine)) tokens a line").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            }
            if project.sessions > 0 {
                Text("\(project.sessionsWithCommits) of \(project.sessions) sessions linked").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .bridgeWell(cornerRadius: 8)
        .accessibilityElement(children: .combine)
    }

    private func projectStat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
            Label(label, systemImage: icon).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func repositoryDetails(_ repo: ActivityRepository) -> some View {
        if repo.worktrees.isEmpty && repo.commits.isEmpty {
            Label(repo.warning == nil ? "No Git details yet" : "Not a Git repository, or it couldn't be read", systemImage: "exclamationmark.circle")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(repo.worktrees) { tree in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(BridgeTheme.textTertiary)
                        Text(branchName(tree.branch)).font(tree.branch == nil || tree.branch == "Detached HEAD" ? BridgeFont.secondary : BridgeFont.mono)
                            .foregroundStyle(tree.branch == nil || tree.branch == "Detached HEAD" ? BridgeTheme.textSecondary : BridgeTheme.textPrimary)
                        Spacer()
                        if let changed = tree.changedFiles {
                            Tag(text: changed == 0 ? "No changes" : "\(changed) changed \(changed == 1 ? "file" : "files")", color: changed == 0 ? nil : BridgeTheme.warning)
                        }
                    }
                    .help(tree.path)
                }
                if !repo.commits.isEmpty {
                    let linked = readyReport.shipped.commits.filter { $0.repositoryID == repo.id }
                    let sessionIndex = Dictionary(overview.sessions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
                    DisclosureGroup(linked.isEmpty ? "\(repo.commits.count) recent \(repo.commits.count == 1 ? "commit" : "commits")"
                                                   : "\(linked.count) \(linked.count == 1 ? "commit" : "commits") in \(period.phrase)") {
                        VStack(alignment: .leading, spacing: 6) {
                            if linked.isEmpty {
                                ForEach(Array(repo.commits.prefix(20))) { commit in
                                    ShippedCommitRow(commit: ShippedCodeReport.Commit(commit: commit, repositoryID: repo.id, repositoryName: repo.name, sessionIDs: [], link: nil, agents: commit.coAuthors ?? []),
                                                     sessions: sessionIndex, now: reportNow, showSession: { navigation.selectedSessionID = $0 })
                                }
                            } else {
                                ForEach(Array(linked.prefix(30))) { commit in
                                    ShippedCommitRow(commit: commit, sessions: sessionIndex, now: reportNow, showSession: { navigation.selectedSessionID = $0 })
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(BridgeFont.secondaryMedium)
                }
            }
        }
    }

    private func branchName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.lowercased() != "detached head" else { return "No branch (a specific commit is checked out)" }
        return raw
    }

    // MARK: Models

    private typealias ModelRow = ModelUsageReport.Row

    private var modelRows: [ModelRow] {
        accounting.modelRows
    }

    private var modelContent: some View {
        let rows = modelRows
        let known = rows.filter { $0.name != nil }
        let unknownCount = rows.filter { $0.name == nil }.reduce(0) { $0 + $1.requests }
        let summary = accounting.summary
        let total = max(1, summary.totalObservedSteps)
        return VStack(alignment: .leading, spacing: 14) {
            if rows.isEmpty {
                HubEmptyState(icon: "cpu", title: "No models in this view", message: "Models appear once a session records which one answered.")
            } else {
                reportCard {
                    CardHeader(title: "Share of the work", icon: "chart.bar.xaxis", subtitle: summary.totalObservedSteps > 0 ? "\(summary.totalObservedSteps.formatted()) observed model steps in \(period.phrase)" : "Step-level details aren't available in this view yet",
                               info: "One step is one observed model response or distinct token-usage advance. A conversation turn can contain many steps. Repeated usage snapshots count once. This is not an exact count of billable API attempts. Shares use only observed steps; missing details are not zero. Models come from the context recorded with that evidence. Native token totals that cannot be assigned safely are shown separately, never guessed into a model or date.")
                    GeometryReader { proxy in
                        let counts = known.map(\.requests) + (unknownCount > 0 ? [unknownCount] : [])
                        let widths = ModelUsageReport.segmentWidths(counts: counts, width: Double(proxy.size.width))
                        HStack(spacing: 0) {
                            ForEach(Array(known.enumerated()), id: \.element.id) { index, row in
                                Rectangle().fill(modelColor(row, index: index))
                                    .frame(width: CGFloat(widths[index]))
                                    .overlay(alignment: .trailing) { Rectangle().fill(BridgeTheme.inkRaised).frame(width: min(1, CGFloat(widths[index]))) }
                                    .help("\(row.provider.rawValue.capitalized) · \(modelTitle(row)): \(row.requests.formatted()) observed model steps")
                            }
                            if unknownCount > 0 {
                                Rectangle().fill(Color.white.opacity(0.12))
                                    .frame(width: CGFloat(widths.last ?? 0))
                                    .help("Model not recorded: \(unknownCount.formatted()) observed steps")
                            }
                        }
                    }
                    .frame(height: 10).clipShape(Capsule())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(Array(known.enumerated()), id: \.element.id) { index, row in
                            legendItem(modelColor(row, index: index), modelTitle(row), modelShareText(row, total: total))
                        }
                        if unknownCount > 0 { legendItem(Color.white.opacity(0.25), "Not recorded", shareText(unknownCount, total)) }
                    }
                }
                modelProfileCard(known.filter { $0.requests > 0 })
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ViewThatFits(in: .horizontal) {
                            modelTable(rows, total: total, wide: true)
                            modelTable(rows, total: total, wide: false)
                            modelCompactList(rows, total: total)
                        }
                    }
                    .bridgeCard(padding: 0)
                }
                // Coverage gaps as compact chips; the full sentence is on hover.
                if unknownCount > 0 || summary.unmeasuredTurns > 0 || summary.unallocatedTurns > 0 {
                    let chips = Group {
                        if unknownCount > 0 {
                            coverageChip("\(unknownCount.formatted()) steps without a model", icon: "questionmark.circle",
                                         help: "\(unknownCount.formatted()) observed steps didn't record which model answered.")
                        }
                        if summary.unmeasuredTurns > 0 {
                            coverageChip("\(summary.unmeasuredTurns.formatted()) turns without step details", icon: "clock.badge.questionmark",
                                         help: "\(summary.unmeasuredTurns.formatted()) saved turns don't yet have step-level details. They aren't counted as one model step.")
                        }
                        if summary.unallocatedTurns > 0 {
                            coverageChip("\(summary.unallocatedTurns.formatted()) \(summary.unallocatedTurns == 1 ? "turn" : "turns") not dated" + (summary.unallocatedTokens.map { " · ≥\(ActivityFormat.compact($0)) tokens" } ?? ""),
                                         icon: "questionmark.folder", help: unallocatedUsageText(summary))
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text("Coverage").font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary)
                            chips
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Coverage").font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary)
                            chips
                        }
                    }
                }
                Label("≥ marks a known subtotal and — means unavailable. Hover a figure for its coverage.", systemImage: "info.circle")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).labelStyle(CompactLabelStyle())
            }
        }
    }

    /// Context sent and text written per step, side by side, so a chatty
    /// model and a context-heavy one are visible at a glance.
    @ViewBuilder private func modelProfileCard(_ rows: [ModelRow]) -> some View {
        let profiles = rows.prefix(6).map { ($0, ModelWorkProfile($0)) }.filter { $0.1.contextPerStep != nil || $0.1.writtenPerStep != nil }
        if profiles.count > 0 {
            let writer = profiles.filter { $0.1.writtenPerStep != nil }.max { ($0.1.writtenPerStep ?? 0) < ($1.1.writtenPerStep ?? 0) }
            reportCard {
                CardHeader(title: "How each model works", icon: "gauge.with.dots.needle.33percent",
                           subtitle: writer.map { "\(modelTitle($0.0)) writes the most each step" } ?? "Average per step",
                           info: "Averages per usage record: known tokens divided by the records that reported tokens, and written tokens divided by the records that reported output. Context sent includes the conversation re-read on every step. ≈ marks an average that mixes in older records covering several steps, or records with partial usage. Missing usage is left out, never counted as zero.")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        profileColumn("Context sent per step", icon: "tray.full", profiles, value: \.contextPerStep)
                        profileColumn("Written per step", icon: "pencil.line", profiles, value: \.writtenPerStep)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        profileColumn("Context sent per step", icon: "tray.full", profiles, value: \.contextPerStep)
                        profileColumn("Written per step", icon: "pencil.line", profiles, value: \.writtenPerStep)
                    }
                }
            }
        }
    }

    private func profileColumn(_ title: String, icon: String, _ profiles: [(ModelRow, ModelWorkProfile)],
                               value: KeyPath<ModelWorkProfile, Double?>) -> some View {
        let peak = profiles.compactMap { $0.1[keyPath: value] }.max() ?? 0
        return VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary)
                .labelStyle(CompactLabelStyle())
            ForEach(profiles, id: \.0.id) { row, profile in
                let amount = profile[keyPath: value]
                HStack(spacing: 8) {
                    AgentAvatar(name: row.provider.rawValue.capitalized, size: 14)
                    Text(modelTitle(row)).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                        .lineLimit(1).frame(width: 128, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.05))
                            if let amount, peak > 0 {
                                Capsule().fill(BridgeTheme.color(for: row.provider).opacity(0.8))
                                    .frame(width: max(3, proxy.size.width * CGFloat(amount / peak)))
                            }
                        }
                    }
                    .frame(height: 6)
                    Text(amount.map { (profile.approximate ? "≈" : "") + ActivityFormat.compact(Int($0.rounded())) } ?? "—")
                        .font(BridgeFont.caption.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .help(amount.map { "\(modelTitle(row)): about \(Int($0.rounded()).formatted()) tokens per step" } ?? "\(modelTitle(row)): no usage reported")
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelColor(_ row: ModelRow, index: Int) -> Color {
        if row.name == nil { return BridgeTheme.textTertiary }
        return BridgeTheme.color(for: row.provider).opacity(max(0.4, 1 - Double(index) * 0.16))
    }

    private func coverageChip(_ text: String, icon: String, help: String) -> some View {
        Label(text, systemImage: icon).labelStyle(CompactLabelStyle())
            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1))
            .help(help)
    }

    private func unallocatedUsageText(_ summary: ModelUsageReport.Summary) -> String {
        let amount = summary.unallocatedTokens.map { "At least \(ActivityFormat.compact($0)) known native tokens" } ?? "Some native usage"
        let noun = summary.unallocatedTurns == 1 ? "turn" : "turns"
        return "\(amount) from \(summary.unallocatedTurns.formatted()) \(noun) cannot be placed safely in this time window. That usage is separate from the dated step totals."
    }

    private func modelTitle(_ row: ModelRow) -> String {
        row.name.map { ModelNaming.display($0) } ?? "Model not recorded"
    }

    private func modelCountText(_ row: ModelRow) -> String {
        guard let count = row.requestCount else { return "—" }
        return (row.requestsArePartial ? "≥" : "") + count.formatted()
    }

    private func modelShareText(_ row: ModelRow, total: Int) -> String {
        row.shareOfObservedSteps.map(percentText) ?? "—"
    }

    private func legendItem(_ color: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
            Text(value).font(BridgeFont.caption.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
        }
    }

    /// One aligned row per model. The narrow layout drops the detail columns.
    private func modelTable(_ rows: [ModelRow], total: Int, wide: Bool) -> some View {
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Model").frame(minWidth: wide ? 190 : 140, maxWidth: .infinity, alignment: .leading)
                Text("Share").frame(width: wide ? 150 : 70, alignment: .leading)
                Text("Steps").frame(width: 66, alignment: .trailing)
                    .help("Observed model responses, not conversation turns or human prompts")
                Text("Tokens").frame(width: 62, alignment: .trailing)
                if wide {
                    Text("Written").frame(width: 62, alignment: .trailing)
                    Text("Re-read").frame(width: 58, alignment: .trailing)
                        .help("Share of tokens that were saved context sent again with each step")
                    Text("Effort").frame(width: 120, alignment: .leading)
                }
                Text("Last used").frame(width: 72, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            ForEach(rows) { row in
                Rectangle().fill(BridgeTheme.separator).frame(height: 1)
                Button {
                    showModelSessions(row)
                } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: 9) {
                            AgentAvatar(name: row.provider.rawValue.capitalized, size: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(modelTitle(row)).font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                                Text("\(row.sessions) \(row.sessions == 1 ? "session" : "sessions")")
                                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                            }
                        }
                        .frame(minWidth: wide ? 190 : 140, maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.06))
                                    Capsule().fill(BridgeTheme.color(for: row.provider).opacity(0.85))
                                        .frame(width: min(proxy.size.width, max(0, proxy.size.width * CGFloat(row.shareOfObservedSteps ?? 0))))
                                }
                            }
                            .frame(height: 6)
                            Text(modelShareText(row, total: total)).font(BridgeFont.caption.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                        .frame(width: wide ? 150 : 70)
                        numberCell(modelCountText(row), width: 66, strong: true)
                            .help("\(row.nativeTurns) native turns use this model; \(row.unmeasuredTurns) lack step-level details. Repeated usage snapshots are not extra steps.")
                        numberCell(knownTokenValue(row.tokens, partial: row.tokensArePartial), width: 62).help(row.tokenCoverage)
                        if wide {
                            numberCell(knownTokenValue(row.output, partial: row.outputIsPartial), width: 62).help(row.outputCoverage)
                            numberCell(row.reread.map { percentText($0) } ?? "—", width: 58)
                                .help("Re-read share from \(row.breakdownReceipts) of \(row.usageRecords) usage records with a consistent token breakdown.")
                            Text(row.efforts.prefix(2).map { ModelNaming.effort($0.name) }.joined(separator: ", ").ifEmpty("—"))
                                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                                .help(row.efforts.map { "\(ModelNaming.effort($0.name)): \($0.count)" }.joined(separator: "\n"))
                        }
                        Text(row.lastUsed.map { ActivityFormat.relative($0, now: Date()) } ?? "—")
                            .font(BridgeFont.caption.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowButtonStyle())
                .help("\(row.provider.rawValue.capitalized) · \(row.name ?? "") — search its sessions")
                .accessibilityLabel("\(row.provider.rawValue.capitalized), \(modelTitle(row)), \(modelCountText(row)) observed model steps, \(modelShareText(row, total: total))")
                .accessibilityValue(row.accessibilitySummary)
                .accessibilityHint("Searches this provider's sessions for the model name")
            }
        }
    }

    private func modelCompactList(_ rows: [ModelRow], total: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                Button { showModelSessions(row) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            AgentAvatar(name: row.provider.rawValue.capitalized, size: 20)
                            Text(modelTitle(row)).font(BridgeFont.bodyMedium).lineLimit(2)
                            Spacer(minLength: 4)
                            Text(modelShareText(row, total: total)).font(BridgeFont.caption.monospacedDigit())
                        }
                        Text("\(modelCountText(row)) observed steps · \(row.sessions) sessions · \(knownTokenValue(row.tokens, partial: row.tokensArePartial)) tokens")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                }
                .buttonStyle(HoverRowButtonStyle())
                .help(row.tokenCoverage)
                Hairline()
            }
        }
    }

    private func showModelSessions(_ row: ModelRow) {
        let name = row.name ?? ""
        query = name; appliedQuery = name
        provider = row.provider == .none ? "all" : row.provider.rawValue
        navigation.navigate(to: .now)
    }

    private func knownTokenValue(_ value: Int?, partial: Bool) -> String {
        guard let value else { return "—" }
        return (partial ? "≥" : "") + ActivityFormat.compact(value)
    }

    private func numberCell(_ text: String, width: CGFloat, strong: Bool = false) -> some View {
        Text(text).font((strong ? BridgeFont.secondaryMedium : BridgeFont.secondary).monospacedDigit())
            .foregroundStyle(strong ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
            .frame(width: width, alignment: .trailing)
    }

    // MARK: Journal
    private var journalContent: some View {
        DailyBriefView(journal: model.dailyBrief, hasActivity: !overview.sessions.isEmpty,
                       collectedAt: overview.generatedAt == .distantPast ? nil : overview.generatedAt,
                       create: model.publishActivityJournal)
    }

    // MARK: Export

    private func exportSnapshot() {
        guard let prepared else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "agent-hub-accounting.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ActivityAccountingExport.write(prepared.scope.accounting, to: url, overwrite: true)
        } catch { model.reportActivityExportError(error) }
    }


}

/// The accounting fingerprint, computed in the background when shown: it
/// encodes every receipt in the report, which takes seconds on a long history.
private struct EvidenceChecksum: View {
    var report: ActivityAccounting.Report
    var revision: UInt64
    @State private var digest: (revision: UInt64, value: String)?

    var body: some View {
        Text("Evidence checksum \(digest.map { $0.revision == revision ? $0.value : "updating…" } ?? "calculating…")")
            .font(BridgeFont.mono).textSelection(.enabled)
            .task(id: revision) {
                let report = report
                let value = await Task.detached(priority: .utility) { report.evidenceDigest }.value
                guard !Task.isCancelled else { return }
                digest = (revision, value)
            }
    }
}
